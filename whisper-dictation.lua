-- whisper-dictation.lua — a private, local replacement for macOS Dictation.
--
-- Press a hotkey to start recording the mic; press again to stop. The audio is
-- transcribed locally with whisper.cpp and pasted into whatever field is
-- focused. Audio never leaves the machine.
--
-- Load it from your Hammerspoon init.lua with:   require("whisper-dictation")
--
-- Requirements (all local):
--   ffmpeg, whisper-cli  (brew install ffmpeg whisper-cpp)
--   a ggml Whisper model at MODEL below
-- Optional: Karabiner-Elements remaps the F5/dictation key to F18 so the bare
--   dictation key triggers this (see karabiner/whisper-dictation.json).
--
-- One-time macOS permissions (System Settings -> Privacy & Security):
--   * Microphone    -> enable Hammerspoon (so ffmpeg can capture the mic)
--   * Accessibility -> enable Hammerspoon (so it can paste into other apps)

-- ---- config -----------------------------------------------------------------
local FFMPEG  = "/opt/homebrew/bin/ffmpeg"
local WHISPER = "/opt/homebrew/bin/whisper-cli"
local MODEL   = os.getenv("HOME") .. "/.cache/whisper/ggml-large-v3-turbo-q5_0.bin"
local MIC     = ":0"              -- avfoundation "video:audio"; 0 = built-in mic (see README)
local LANG    = "en"              -- spoken language, or "auto"
local WAV     = "/tmp/whisper-dictate.wav"
local OUTPFX  = "/tmp/whisper-dictate"    -- whisper writes OUTPFX.txt
-- Hotkeys that toggle dictation. f18 is what the Karabiner rule sends from the
-- F5/dictation key; alt+space is a keyboard-only fallback.
local HOTKEYS = {
  { {},       "f18"   },
  { {"alt"},  "space" },
}
-- -----------------------------------------------------------------------------

local recording = false
local recTask = nil

local menu = hs.menubar.new()
local function setIcon(s) if menu then menu:setTitle(s) end end
setIcon("🎙")

-- Paste transcribed text into the focused field, then restore the clipboard.
local function typeText(text)
  text = text:gsub("^%s+", ""):gsub("%s+$", "")
  if text == "" then hs.alert.show("… no speech"); return end
  local prev = hs.pasteboard.getContents()
  hs.pasteboard.setContents(text)
  hs.eventtap.keyStroke({"cmd"}, "v")
  hs.timer.doAfter(0.35, function()
    if prev ~= nil then hs.pasteboard.setContents(prev) end
  end)
end

local function transcribe()
  setIcon("⏳")
  local t = hs.task.new(WHISPER, function(code, stdout, stderr)
    setIcon("🎙")
    if code ~= 0 then hs.alert.show("whisper failed"); print(stderr); return end
    local f = io.open(OUTPFX .. ".txt", "r")
    if not f then hs.alert.show("no transcript"); return end
    local text = f:read("*a"); f:close()
    typeText(text)
  end, { "-m", MODEL, "-f", WAV, "-l", LANG, "-otxt", "-of", OUTPFX, "-np", "-nt" })
  t:start()
end

local function startRec()
  if recording then return end
  recording = true
  setIcon("🔴")
  os.remove(WAV); os.remove(OUTPFX .. ".txt")
  recTask = hs.task.new(FFMPEG, function(code, stdout, stderr)
    -- ffmpeg has exited.
    if recording then
      -- It quit without us asking → startup failure (mic permission, bad device).
      recording = false
      setIcon("🎙")
      hs.alert.show("mic error — check Hammerspoon Microphone permission")
      print(stderr)
      return
    end
    transcribe()  -- normal stop: the WAV is finalized, go transcribe it
  end, {
    "-nostdin", "-y", "-f", "avfoundation", "-i", MIC,
    "-ar", "16000", "-ac", "1", "-c:a", "pcm_s16le", WAV,
  })
  recTask:start()
end

local function stopRec()
  if not recording then return end
  recording = false
  setIcon("⏳")
  if recTask then recTask:terminate() end  -- SIGTERM → ffmpeg finalizes the WAV, then its callback transcribes
end

local function toggle()
  if recording then stopRec() else startRec() end
end

for _, hk in ipairs(HOTKEYS) do
  hs.hotkey.bind(hk[1], hk[2], toggle)
end

if menu then
  menu:setMenu({
    { title = "Toggle dictation", fn = toggle },
    { title = "Reload Hammerspoon config", fn = function() hs.reload() end },
  })
end

hs.alert.show("Local Whisper dictation ready")

return { toggle = toggle }
