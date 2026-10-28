--[[
Keeps the device awake while a Mealie recipe is open.

On a Kindle two things put the device to sleep while KOReader runs:
  1. the Kindle's own power daemon (powerd) after its idle timeout, and
  2. KOReader's AutoSuspend plugin after its own timeout.
This uses the same switches KOReader itself provides:
  * `lipc-set-prop com.lab126.powerd preventScreenSaver 1`, exactly what the
    bundled "Keep alive" plugin runs on Kindle, stops powerd from sleeping;
  * PluginShare.keepalive = true makes AutoSuspend skip its powerd timer reset,
    which its source says must not be combined with preventScreenSaver;
  * PluginShare.pause_auto_suspend = true stops AutoSuspend from suspending.
On Kobo/Cervantes only pause_auto_suspend is used (what "Keep alive" does there).

Safety:
  * stop() restores the previous values, so a user who turned on KOReader's own
    "Keep alive" keeps it;
  * a persisted flag lets the next KOReader start undo a keep-awake left on by
    a crash (preventScreenSaver otherwise stays set until reboot);
  * an idle limit releases the device after N seconds with no input.

State is module-level so it is shared by every plugin instance.
--]]

local M = {
    active = false,
    last_input = 0,
    limit = 3 * 3600,
    prev = nil,
    task = nil,
}

-- Dependencies, replaceable in tests.
M.deps = {
    device = function() return require("device") end,
    uimanager = function() return require("ui/uimanager") end,
    pluginshare = function() return require("pluginshare") end,
    exec = function(cmd) return os.execute(cmd) end,
    now = function() return os.time() end,
    persist = function(_value) end,
}

local LIPC_ON = "lipc-set-prop com.lab126.powerd preventScreenSaver 1"
local LIPC_OFF = "lipc-set-prop com.lab126.powerd preventScreenSaver 0"

local function isKindle()
    local ok, Device = pcall(M.deps.device)
    return ok and Device and Device.isKindle and Device:isKindle() and true or false
end

local function unschedule()
    if M.task then
        M.deps.uimanager():unschedule(M.task)
        M.task = nil
    end
end

local function schedule(seconds)
    unschedule()
    M.task = function()
        M.task = nil
        M.check()
    end
    M.deps.uimanager():scheduleIn(math.max(1, seconds), M.task)
end

function M.start(limit_seconds)
    M.limit = tonumber(limit_seconds) or M.limit
    M.last_input = M.deps.now()
    if M.active then
        schedule(M.limit)
        return
    end
    local share = M.deps.pluginshare()
    M.prev = { keepalive = share.keepalive, pause = share.pause_auto_suspend }
    if isKindle() and not share.keepalive then
        M.deps.exec(LIPC_ON)
    end
    if isKindle() then
        share.keepalive = true
    end
    share.pause_auto_suspend = true
    M.active = true
    M.deps.persist(true)
    schedule(M.limit)
end

function M.stop()
    unschedule()
    if not M.active then
        return
    end
    local share = M.deps.pluginshare()
    local prev = M.prev or {}
    if isKindle() and not prev.keepalive then
        M.deps.exec(LIPC_OFF)
    end
    share.keepalive = prev.keepalive
    share.pause_auto_suspend = prev.pause
    M.prev = nil
    M.active = false
    M.deps.persist(false)
end

-- Undo a keep-awake that a previous KOReader session left on (crash).
function M.cleanupStale(was_persisted)
    if was_persisted and not M.active then
        if isKindle() then
            M.deps.exec(LIPC_OFF)
        end
        M.deps.persist(false)
        return true
    end
    return false
end

function M.touch()
    if M.active then
        M.last_input = M.deps.now()
    end
end

function M.check()
    if not M.active then
        return
    end
    local idle = M.deps.now() - M.last_input
    if idle >= M.limit then
        M.stop()
    else
        schedule(M.limit - idle)
    end
end

return M
