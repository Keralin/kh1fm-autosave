LUAGUI_NAME = "1fmAutosave"
LUAGUI_AUTH = "Denhonator (autosave logic), standalone build by Keralin"
LUAGUI_DESC = "Snapshots the game on every room load. L1+L2+R1+R2+Right restores it, +Down restores the one before."

-- Size of the continue block the game keeps for the post-death Continue option.
local CONTINUE_SIZE = 93184

local SAVE_FILE = "kh1-autosave.dat"
local PREV_FILE = "kh1-autosave-prev.dat"
local TMP_FILE = "kh1-autosave.tmp"

-- Button bits as the game reports them at inputAddress (PSX layout).
local L2, R2, L1, R1 = 0x100, 0x200, 0x400, 0x800
local DPAD_RIGHT, DPAD_DOWN = 0x020, 0x040
local SHOULDERS = L1 | L2 | R1 | R2
local LOAD_LATEST = SHOULDERS | DPAD_RIGHT
local LOAD_PREV = SHOULDERS | DPAD_DOWN

local prevHUD = 0
local lastInput = 0
local skipNextWrite = false

function _OnInit()
    if GAME_ID == 0xAF71841E and ENGINE_TYPE == "BACKEND" then
        require("VersionCheck")
    else
        ConsolePrint("KH1 not detected, not running script")
    end
end

local function writeSnapshot()
    local tmp = io.open(TMP_FILE, "wb")
    if tmp == nil then
        ConsolePrint("Autosave: cannot write " .. TMP_FILE .. ", check folder permissions")
        return
    end
    local data = ReadString(continue, CONTINUE_SIZE)
    tmp:write(data)
    tmp:close()

    -- Rotate through a temp file so a crash mid-write cannot leave a half-written snapshot
    -- where the loader expects a whole one.
    os.remove(PREV_FILE)
    os.rename(SAVE_FILE, PREV_FILE)
    os.rename(TMP_FILE, SAVE_FILE)

    ConsolePrint(string.format("Autosave written: world %d room %d, %d bytes",
        ReadByte(world), ReadByte(room), #data))
end

local function loadSnapshot(path)
    local f = io.open(path, "rb")
    if f == nil then
        ConsolePrint("Autosave: nothing stored in " .. path .. " yet")
        return
    end
    local data = f:read("*a")
    f:close()

    if #data ~= CONTINUE_SIZE then
        ConsolePrint(string.format("Autosave: %s is %d bytes, expected %d, refusing to load",
            path, #data, CONTINUE_SIZE))
        return
    end

    WriteString(continue, data)
    WriteByte(closeMenu, 0)

    -- Same warp the game runs when you pick Continue after a game over.
    if ReadByte(warpTrigger) == 0 then
        WriteByte(warpType1, 5)
        WriteByte(warpType2, 12)
        WriteByte(warpTrigger, 2)
    end

    -- Camera inversion lives in the options block, not in the snapshot, so it has to be
    -- reapplied or the sticks come back flipped.
    WriteFloat(cam, -1.0 + ReadByte(config + 20) * 2)
    WriteFloat(cam + 4, 1.0 - ReadByte(config + 24) * 2)

    -- The HUD fades in again right after the warp. Letting that count as a room load would
    -- push the restored snapshot into PREV_FILE and destroy the older one.
    skipNextWrite = true
    ConsolePrint("Autosave loaded from " .. path)
end

function _OnFrame()
    if not canExecute then
        return
    end

    local input = ReadInt(inputAddress)
    if input ~= lastInput and ReadLong(closeMenu) == 0 then
        if input == LOAD_LATEST then
            loadSnapshot(SAVE_FILE)
        elseif input == LOAD_PREV then
            loadSnapshot(PREV_FILE)
        end
    end
    lastInput = input

    -- Sora's HUD reaching full opacity is the cheapest "a room finished loading and you have
    -- control" signal in the game. It stays at 0 on the title screen and in the gummi ship,
    -- which is exactly where a snapshot would be useless.
    local hud = ReadFloat(soraHUD)
    if hud == 1 and prevHUD < 1 then
        if skipNextWrite then
            skipNextWrite = false
        else
            writeSnapshot()
        end
    end
    prevHUD = hud
end
