-- whisper-dictation.lua — private, low-latency local dictation for macOS.
--
-- A persistent native helper prepares a stopped Core Audio HAL input unit, and
-- a local whisper-server keeps the Whisper model loaded. The microphone remains
-- inactive until the start hotkey, then releases again before transcription.
--
-- whisper-server is owned by launchd (LaunchAgent com.whisper-dictation.server,
-- installed by install.sh) with KeepAlive, so it restarts on its own if it dies.
-- This module never launches the server; it polls /health and reconnects.

-- ---- config -----------------------------------------------------------------
local HOME           = os.getenv("HOME")
local RECORDER       = HOME .. "/.hammerspoon/bin/whisper-recorder"
local CURL           = "/usr/bin/curl"
local MIC            = nil -- nil = built-in Mac mic; or an exact name such as ":Studio Display Microphone"
local LANG           = "en"
local WAV            = "/tmp/whisper-dictate.wav"
local SERVER_HOST    = "127.0.0.1"
local SERVER_PORT    = 8178
local HOTKEYS = {
  { {},       "f18"   },
  { {"alt"},  "space" },
}
-- -----------------------------------------------------------------------------

local SERVER_URL = "http://" .. SERVER_HOST .. ":" .. tostring(SERVER_PORT)
local phase = "warming"
local recorderReady = false
local serverReady = false
local recorderTask = nil
local transcriptionTask = nil
local recorderOutput = ""
local recorderRetries = 0
local serverPollGeneration = 0
local serverWatchdog = nil
local resetServer -- forward declaration; defined in the server section
local shuttingDown = false
local stopRequestedNs = nil
local transcriptionStartedNs = nil
local lastMetrics = {}
local microphoneActive = false

local menu = hs.menubar.new()
local function setIcon(icon) if menu then menu:setTitle(icon) end end
setIcon("⏳")

local function statusText()
  if phase == "warming" then
    local waiting = {}
    if not recorderReady then table.insert(waiting, "recorder") end
    if not serverReady then table.insert(waiting, "Whisper") end
    return "Warming " .. table.concat(waiting, " + ")
  end
  if phase == "ready" then return "Ready" end
  if phase == "recording" then return "Recording" end
  if phase == "transcribing" then return "Transcribing" end
  return phase
end

local function refreshReadyState(showAlert)
  if recorderReady and serverReady and phase == "warming" then
    phase = "ready"
    setIcon("🎙")
    if showAlert then hs.alert.show("Local Whisper dictation ready") end
  end
end

-- Paste transcribed text into the focused field. The transcript stays on the
-- clipboard, so the text survives when the paste lands in a window with no
-- focused text field.
local function typeText(text)
  text = text:gsub("^%s+", ""):gsub("%s+$", "")
  if text == "" then hs.alert.show("… no speech"); return end
  hs.pasteboard.setContents(text)
  hs.eventtap.keyStroke({"cmd"}, "v")
end

local function transcribe(path)
  if not serverReady then
    phase = "warming"
    setIcon("⏳")
    hs.alert.show("Whisper is restarting — try again in a moment")
    return
  end

  transcriptionStartedNs = hs.timer.absoluteTime()
  transcriptionTask = hs.task.new(CURL, function(code, stdout, stderr)
    local completedNs = hs.timer.absoluteTime()
    lastMetrics.transcription_ms = (completedNs - transcriptionStartedNs) / 1000000
    if stopRequestedNs then
      lastMetrics.stop_to_text_ms = (completedNs - stopRequestedNs) / 1000000
    end
    transcriptionTask = nil
    if code ~= 0 then
      hs.alert.show("Whisper transcription failed")
      print(stderr)
      -- The most common cause is a dead server; re-enter the health-poll loop
      -- so a launchd-restarted server is adopted without a config reload.
      resetServer()
      return
    end
    if recorderReady and serverReady then
      phase = "ready"
      setIcon("🎙")
    else
      phase = "warming"
      setIcon("⏳")
    end
    typeText(stdout)
  end, {
    "-sS", "--fail-with-body",
    "-F", "file=@" .. path,
    "-F", "response_format=text",
    "-F", "language=" .. LANG,
    SERVER_URL .. "/inference",
  })
  transcriptionTask:start()
end

local function handleRecorderEvent(event)
  if event.event == "ready" then
    recorderReady = true
    recorderRetries = 0
    microphoneActive = event.microphone_active == true
    lastMetrics.recorder_backend = event.backend
    lastMetrics.sample_rate = event.sample_rate
    refreshReadyState(true)
  elseif event.event == "started" then
    microphoneActive = event.microphone_active == true
    lastMetrics.capture_first_buffer_ms = event.command_to_first_buffer_ms
  elseif event.event == "stopped" then
    microphoneActive = event.microphone_active == true
    lastMetrics.wav_finalize_ms = event.command_to_wav_ms
    lastMetrics.wav_write_ms = event.wav_write_ms
    lastMetrics.microphone_release_ms = event.microphone_release_ms
    lastMetrics.samples = event.samples
    transcribe(event.path or WAV)
  elseif event.event == "error" then
    recorderReady = false
    microphoneActive = false
    phase = "warming"
    setIcon("⏳")
    print("Recorder error: " .. tostring(event.message or "unknown error"))
  end
end

local function consumeRecorderOutput(chunk)
  recorderOutput = recorderOutput .. (chunk or "")
  while true do
    local newline = recorderOutput:find("\n", 1, true)
    if not newline then return end
    local line = recorderOutput:sub(1, newline - 1)
    recorderOutput = recorderOutput:sub(newline + 1)
    if line ~= "" then
      local ok, event = pcall(hs.json.decode, line)
      if ok and event then handleRecorderEvent(event) end
    end
  end
end

local function startRecorder()
  recorderOutput = ""
  local arguments = {}
  if MIC then
    table.insert(arguments, "--device")
    table.insert(arguments, MIC:gsub("^:", ""))
  end

  recorderTask = hs.task.new(RECORDER, function(code, stdout, stderr)
    recorderTask = nil
    recorderReady = false
    if not shuttingDown then
      phase = "warming"
      setIcon("⏳")
      recorderRetries = recorderRetries + 1
      local retryDelay = math.min(5, 0.5 * (2 ^ (recorderRetries - 1)))
      if recorderRetries == 3 then
        hs.alert.show("Recorder is retrying — check Hammerspoon Microphone permission")
      end
      if stderr and stderr ~= "" then print(stderr) end
      hs.timer.doAfter(retryDelay, startRecorder)
    end
  end, function(_, stdout, stderr)
    consumeRecorderOutput(stdout)
    if stderr and stderr ~= "" then print(stderr) end
    return true
  end, arguments)
  recorderTask:start()
end

local pollServer
pollServer = function(generation)
  if shuttingDown or serverReady or generation ~= serverPollGeneration then return end
  hs.http.asyncGet(SERVER_URL .. "/health", nil, function(status)
    if generation ~= serverPollGeneration then return end
    if status == 200 then
      serverReady = true
      refreshReadyState(true)
    else
      hs.timer.doAfter(0.25, function() pollServer(generation) end)
    end
  end)
end

local function watchServer()
  serverPollGeneration = serverPollGeneration + 1
  pollServer(serverPollGeneration)
end

-- The server stopped answering. Drop back to warming and poll until launchd
-- restarts it (issue #4: an adopted server was never watched before).
resetServer = function()
  serverReady = false
  phase = "warming"
  setIcon("⏳")
  watchServer()
end

-- Catch a server that dies while dictation is idle, so the next dictation
-- does not have to fail once before recovery starts.
serverWatchdog = hs.timer.doEvery(10, function()
  if shuttingDown or not serverReady or phase ~= "ready" then return end
  local generation = serverPollGeneration
  hs.http.asyncGet(SERVER_URL .. "/health", nil, function(status)
    if shuttingDown or not serverReady or generation ~= serverPollGeneration then return end
    if status ~= 200 then resetServer() end
  end)
end)

local function startRecording()
  if phase ~= "ready" then
    hs.alert.show(statusText())
    return
  end
  phase = "recording"
  setIcon("🔴")
  recorderTask:setInput("START " .. WAV .. "\n")
end

local function stopRecording()
  if phase ~= "recording" then return end
  phase = "transcribing"
  setIcon("⏳")
  stopRequestedNs = hs.timer.absoluteTime()
  recorderTask:setInput("STOP\n")
end

local function toggle()
  if phase == "recording" then stopRecording() else startRecording() end
end

for _, hotkey in ipairs(HOTKEYS) do
  hs.hotkey.bind(hotkey[1], hotkey[2], toggle)
end

if menu then
  menu:setMenu(function()
    return {
      { title = "Status: " .. statusText(), disabled = true },
      { title = "Toggle dictation", fn = toggle },
      { title = "Reload Hammerspoon config", fn = function() hs.reload() end },
    }
  end)
end

local previousShutdownCallback = hs.shutdownCallback
hs.shutdownCallback = function()
  shuttingDown = true
  if recorderTask then
    recorderTask:setStreamingCallback(nil)
    recorderTask:setCallback(nil)
    recorderTask:setInput("QUIT\n")
  end
  if serverWatchdog then serverWatchdog:stop() end
  if previousShutdownCallback then previousShutdownCallback() end
end

startRecorder()
watchServer()

return {
  toggle = toggle,
  status = function() return phase end,
  diagnostics = function()
    return {
      phase = phase,
      recorder_ready = recorderReady,
      server_ready = serverReady,
      microphone_active = microphoneActive,
      last_metrics = lastMetrics,
    }
  end,
}
