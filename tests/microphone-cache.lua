-- Regression test for microphone discovery on the recording hot path.
-- Run from the Hammerspoon Console:
--   dofile("/absolute/path/to/tests/microphone-cache.lua")

local scriptPath = debug.getinfo(1, "S").source:sub(2)
local repoRoot = scriptPath:match("^(.*)/tests/[^/]+$")

local executeCalls = 0
local ffmpegStarts = 0
local boundHotkeys = 0

local fakeHs = {
  alert = { show = function() end },
  eventtap = { keyStroke = function() end },
  hotkey = {
    bind = function()
      boundHotkeys = boundHotkeys + 1
    end,
  },
  menubar = {
    new = function()
      return {
        setMenu = function() end,
        setTitle = function() end,
      }
    end,
  },
  pasteboard = {
    getContents = function() return nil end,
    setContents = function() end,
  },
  timer = { doAfter = function() end },
}

fakeHs.execute = function()
  executeCalls = executeCalls + 1
  return table.concat({
    "AVFoundation video devices:",
    "AVFoundation audio devices:",
    "[0] Continuity Microphone",
    "[1] MacBook Pro Microphone",
  }, "\n")
end

fakeHs.task = {
  new = function(path)
    return {
      start = function()
        if path:match("/ffmpeg$") then ffmpegStarts = ffmpegStarts + 1 end
      end,
      terminate = function() end,
    }
  end,
}

local fakeOs = {
  getenv = os.getenv,
  remove = function() end,
}

local env = setmetatable({ hs = fakeHs, os = fakeOs }, { __index = _G })
local chunk = assert(loadfile(repoRoot .. "/whisper-dictation.lua", "t", env))
local module = chunk()

assert(executeCalls == 1, "microphone should be resolved exactly once during module load")
assert(boundHotkeys == 2, "expected both dictation hotkeys to be bound")

module.toggle()
assert(ffmpegStarts == 1, "recording should launch FFmpeg")
assert(executeCalls == 1, "starting a recording must not enumerate microphones")

module.toggle()
module.toggle()
assert(ffmpegStarts == 2, "a later recording should still launch FFmpeg")
assert(executeCalls == 1, "later recordings must reuse the resolved microphone")

print("PASS: microphone discovery is outside the recording hot path")
