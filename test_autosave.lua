-- Stubs LuaBackend's memory API and drives 1fmAutosave.lua through the file rotation,
-- the load combos and the corrupt-snapshot path. Run with: lua test_autosave.lua
local CONTINUE_SIZE = 93184

-- Fake addresses. Values are arbitrary, only their distinctness matters.
continue, soraHUD, inputAddress, closeMenu = 100, 200, 300, 400
title = 1200
warpTrigger, warpType1, warpType2, cam, config = 500, 600, 700, 800, 900
world, room = 1000, 1100
canExecute = true

local hud, input, warpTriggerValue, titleValue = 0, 0, 0, 0
local continueData = string.rep("A", CONTINUE_SIZE)
local restored, writes, logs = nil, {}, {}

function ConsolePrint(s) logs[#logs + 1] = s end
function ReadFloat(a) return a == soraHUD and hud or 0 end
function ReadInt(a) return a == inputAddress and input or 0 end
function ReadLong(a) return 0 end
function ReadByte(a)
    if a == warpTrigger then return warpTriggerValue end
    if a == title then return titleValue end
    if a == world then return 3 end
    if a == room then return 7 end
    return 0
end
function ReadString(a, len) return continueData:sub(1, len) end
function WriteString(a, data) restored = data end
function WriteByte(a, v) writes[a] = v end
function WriteFloat(a, v) writes[a] = v end
function WriteInt(a, v) writes[a] = v end

local LOAD_LATEST = 0x400 | 0x100 | 0x800 | 0x200 | 0x020
local LOAD_PREV = 0x400 | 0x100 | 0x800 | 0x200 | 0x040

local function roomLoad()
    hud = 0; _OnFrame()
    hud = 1; _OnFrame()
end

local function press(combo)
    input = 0; _OnFrame()
    input = combo; _OnFrame()
end

local function read(path)
    local f = io.open(path, "rb")
    if f == nil then return nil end
    local d = f:read("*a"); f:close(); return d
end

local function lastLog() return logs[#logs] end

-- The script writes relative to the process CWD, which lua cannot change, so rewrite the
-- file names to an absolute scratch prefix instead.
local prefix = (os.getenv("TMPDIR") or "/tmp/") .. "kh1test-"
local here = arg[0]:match("^(.*/)") or "./"
local source = assert(io.open(here .. "1fmAutosave.lua")):read("*a")
source = source:gsub('"kh1%-autosave', '"' .. prefix)
assert(load(source, "1fmAutosave.lua"))()

local SAVE, PREV, TMP = prefix .. ".dat", prefix .. "-prev.dat", prefix .. ".tmp"
os.remove(SAVE); os.remove(PREV); os.remove(TMP)

-- 1. The first room load is a save being loaded, so it must not be recorded. Getting this
-- wrong overwrites the snapshot you crashed with using the save point you just loaded.
roomLoad()
assert(read(SAVE) == nil, "the load that starts a session was recorded as a room change")
assert(lastLog():find("skipped"), "no log line for the skipped load")

-- Now a real room load writes a whole snapshot and rotates nothing out.
roomLoad()
assert(#read(SAVE) == CONTINUE_SIZE, "first snapshot has wrong size")
assert(read(PREV) == nil, "nothing should be rotated out on the first write")

-- 2. Second room load rotates the old snapshot into the previous slot.
continueData = string.rep("B", CONTINUE_SIZE)
roomLoad()
assert(read(SAVE):sub(1, 1) == "B", "latest slot should hold the newest snapshot")
assert(read(PREV):sub(1, 1) == "A", "previous slot should hold the one before")

-- 3. The load combo restores the latest snapshot and fires the continue warp.
restored = nil
press(LOAD_LATEST)
assert(restored ~= nil and restored:sub(1, 1) == "B", "load combo did not restore the snapshot")
assert(writes[warpType1] == 5 and writes[warpType2] == 12 and writes[warpTrigger] == 2,
    "continue warp was not triggered")

-- 4. Holding the combo does not re-trigger.
restored = nil
_OnFrame()
assert(restored == nil, "load re-triggered while the combo was held")

-- 5. The HUD coming back after a load must not rotate the snapshots.
input = 0; _OnFrame()
roomLoad()
assert(read(PREV):sub(1, 1) == "A", "post-load HUD fade destroyed the previous snapshot")

-- 6. The next genuine room load rotates again.
continueData = string.rep("C", CONTINUE_SIZE)
roomLoad()
assert(read(SAVE):sub(1, 1) == "C" and read(PREV):sub(1, 1) == "B", "rotation stopped working")

-- 7. Passing through the title screen means the next HUD rise is a load, not a room change.
continueData = string.rep("T", CONTINUE_SIZE)
titleValue = 1; _OnFrame()
titleValue = 0; _OnFrame()
roomLoad()
assert(read(SAVE):sub(1, 1) == "C", "a load after the title screen overwrote the snapshot")
assert(read(PREV):sub(1, 1) == "B", "a load after the title screen rotated the slots")

-- 8. A truncated snapshot is refused instead of being written into memory.
local f = assert(io.open(SAVE, "wb")); f:write(string.rep("X", 512)); f:close()
restored = nil
press(LOAD_LATEST)
assert(restored == nil, "a truncated snapshot was loaded into the continue block")
assert(lastLog():find("refusing to load"), "no warning for the truncated snapshot")

-- 9. A missing snapshot is reported, not crashed on.
os.remove(PREV)
press(LOAD_PREV)
assert(restored == nil and lastLog():find("nothing stored"), "missing snapshot not handled")

os.remove(SAVE); os.remove(PREV); os.remove(TMP)
print("all checks passed")
