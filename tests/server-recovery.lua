-- Hammerspoon regression test for whisper-server death and recovery (issue #4).
-- The server is owned by launchd; the module must notice a dead server (via the
-- watchdog or a failed transcription), drop to warming, and reconnect on its
-- own once launchd has restarted the server.
-- Run from the Hammerspoon Console:
--   dofile("/absolute/path/to/tests/server-recovery.lua")

local scriptPath = debug.getinfo(1, "S").source:sub(2)
local repoRoot = scriptPath:match("^(.*)/tests/[^/]+$")

local healthStatus = 200
local curlExit = 0
local clipboard = nil
local watchdogTick = nil
local pendingTimers = {}

local function flushTimers()
  local safety = 0
  while #pendingTimers > 0 do
    safety = safety + 1
    assert(safety < 100, "poll loop did not settle — possible infinite retry")
    table.remove(pendingTimers, 1)()
  end
end

local fakeHs = {
  alert = { show = function() end },
  eventtap = { keyStroke = function() end },
  hotkey = { bind = function() end },
  http = {
    asyncGet = function(_, _, callback) callback(healthStatus, "", {}) end,
  },
  json = hs.json,
  menubar = {
    new = function()
      return { setMenu = function() end, setTitle = function() end }
    end,
  },
  pasteboard = {
    getContents = function() return clipboard end,
    setContents = function(text) clipboard = text end,
  },
  timer = {
    absoluteTime = (function()
      local now = 1000000000
      return function()
        now = now + 1000000
        return now
      end
    end)(),
    doAfter = function(_, callback) table.insert(pendingTimers, callback) end,
    doEvery = function(_, callback)
      watchdogTick = callback
      return { stop = function() end }
    end,
  },
}

fakeHs.task = {
  new = function(path, completion, streamOrArguments, arguments)
    local stream = type(streamOrArguments) == "function" and streamOrArguments or nil
    local task = {}

    function task:start()
      if path:match("/whisper%-recorder$") then
        stream(task, '{"event":"ready","backend":"AUHAL","microphone_active":false,"sample_rate":48000}\n', "")
      elseif path == "/usr/bin/curl" then
        if curlExit == 0 then
          completion(0, "test transcript", "")
        else
          completion(curlExit, "", "curl: (7) Failed to connect")
        end
      end
      return task
    end

    function task:setInput(command)
      if command:match("^START ") then
        stream(task, '{"event":"started","command_to_first_buffer_ms":64,"microphone_active":true}\n', "")
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

assert(module.status() == "ready", "healthy launchd server should be adopted at load")
assert(watchdogTick ~= nil, "a server watchdog timer should be armed")

-- A healthy watchdog tick must change nothing.
watchdogTick()
assert(module.status() == "ready", "a healthy watchdog check must keep the ready state")

-- Case 1: the server dies while dictation is idle; the watchdog must notice.
healthStatus = 0
watchdogTick()
assert(module.status() == "warming", "watchdog must drop to warming when the server dies")
assert(module.diagnostics().server_ready == false, "server_ready must reset when the server dies")

-- launchd restarts the server; the queued poll retries must reconnect.
healthStatus = 200
flushTimers()
assert(module.status() == "ready", "the module must reconnect after launchd restarts the server")

-- Case 2: the server dies between the health check and a transcription.
healthStatus = 0
curlExit = 7
module.toggle()
module.toggle()
assert(module.status() == "warming", "a failed transcription must drop to warming")
assert(module.diagnostics().server_ready == false, "a failed transcription must reset server_ready")

-- launchd restarts the server again; dictation must work end to end.
healthStatus = 200
curlExit = 0
flushTimers()
assert(module.status() == "ready", "the module must reconnect after a failed transcription")
module.toggle()
module.toggle()
assert(clipboard == "test transcript", "dictation must work again after recovery")
assert(module.status() == "ready", "pipeline should return to ready after recovery")

print("PASS: dictation recovers when the launchd-owned server dies and restarts")
