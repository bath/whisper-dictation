-- Hammerspoon regression test for the persistent helper + cold microphone path.
-- Run from the Hammerspoon Console:
--   dofile("/absolute/path/to/tests/cold-microphone-hot-path.lua")

local scriptPath = debug.getinfo(1, "S").source:sub(2)
local repoRoot = scriptPath:match("^(.*)/tests/[^/]+$")

local recorderStarts = 0
local serverStarts = 0
local curlStarts = 0
local taskCreationsAtReady = 0
local recorderCommands = {}
local recorderArguments = nil
local pastedText = nil
local boundHotkeys = 0

local fakeHs = {
  alert = { show = function() end },
  eventtap = { keyStroke = function() end },
  hotkey = { bind = function() boundHotkeys = boundHotkeys + 1 end },
  http = { asyncGet = function(_, _, callback) callback(200, "ok", {}) end },
  json = hs.json,
  menubar = {
    new = function()
      return { setMenu = function() end, setTitle = function() end }
    end,
  },
  pasteboard = {
    getContents = function() return nil end,
    setContents = function(text) pastedText = text end,
  },
  timer = {
    absoluteTime = (function()
      local now = 1000000000
      return function()
        now = now + 1000000
        return now
      end
    end)(),
    doAfter = function(_, callback) callback() end,
  },
}

fakeHs.task = {
  new = function(path, completion, streamOrArguments, arguments)
    local stream = type(streamOrArguments) == "function" and streamOrArguments or nil
    local task = {}

    function task:start()
      if path:match("/whisper%-recorder$") then
        recorderStarts = recorderStarts + 1
        recorderArguments = arguments
        stream(task, '{"event":"ready","backend":"AUHAL","microphone_active":false,"sample_rate":48000,"device":"MacBook Pro Microphone"}\n', "")
      elseif path:match("/whisper%-server$") then
        serverStarts = serverStarts + 1
      elseif path == "/usr/bin/curl" then
        curlStarts = curlStarts + 1
        completion(0, "test transcript", "")
      end
      return task
    end

    function task:setInput(command)
      table.insert(recorderCommands, command)
      if command:match("^START ") then
        stream(task, '{"event":"started","command_to_first_buffer_ms":64,"microphone_active":true,"sample_rate":48000}\n', "")
      elseif command == "STOP\n" then
        stream(task, '{"event":"stopped","command_to_wav_ms":12,"microphone_release_ms":10,"microphone_active":false,"wav_write_ms":1,"samples":96000,"path":"/tmp/whisper-dictate.wav"}\n', "")
      end
      return task
    end

    function task:terminate() return task end
    return task
  end,
}

local fakeOs = { getenv = os.getenv }
local env = setmetatable({ hs = fakeHs, os = fakeOs }, { __index = _G })
local module = assert(loadfile(repoRoot .. "/whisper-dictation.lua", "t", env))()

assert(module.status() == "ready", "recorder and server should prepare during module load")
assert(module.diagnostics().microphone_active == false, "the microphone must be inactive while ready")
assert(recorderStarts == 1, "one persistent recorder helper should start")
assert(#recorderArguments == 0, "the helper should not receive warm-microphone or pre-roll options")
assert(serverStarts == 0, "a healthy existing Whisper server should be reused")
assert(boundHotkeys == 2, "both dictation hotkeys should be bound")
taskCreationsAtReady = recorderStarts + serverStarts + curlStarts

module.toggle()
assert(module.status() == "recording", "first toggle should start recording")
assert(module.diagnostics().microphone_active == true, "the microphone should activate after F5")
assert(recorderCommands[1] == "START /tmp/whisper-dictate.wav\n", "start should be an in-process command")
assert(recorderStarts + serverStarts + curlStarts == taskCreationsAtReady,
  "starting capture must not launch another process")

module.toggle()
assert(recorderCommands[2] == "STOP\n", "second toggle should stop the native helper")
assert(module.diagnostics().microphone_active == false, "the microphone must release before transcription")
assert(curlStarts == 1, "the finalized WAV should use the persistent Whisper server")
assert(pastedText == "test transcript", "the server transcript should be pasted")
assert(module.status() == "ready", "pipeline should return to ready after transcription")
local metrics = module.diagnostics().last_metrics
assert(metrics.capture_first_buffer_ms == 64, "first-buffer timing should be retained")
assert(metrics.microphone_release_ms == 10, "microphone release timing should be retained")
assert(metrics.transcription_ms == 1, "transcription timing should be retained")

print("PASS: persistent helper leaves the microphone inactive before F5")
