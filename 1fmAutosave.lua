LUAGUI_NAME = "1fmAutosave"
LUAGUI_AUTH = "Denhonator (snapshot logic), standalone build by Keralin"
LUAGUI_DESC = "Autosaves on every room load. Restore with L1+L2+R1+R2+Right, or promote into save 99 with the game closed."

-- Writing the save container from here races the game, which keeps the same file open and
-- rewrites it on its own schedule (saving, quitting, Steam Cloud syncing). A 93 KB write landing
-- inside one of those leaves a mixed file, and that can wreck slots this mod never aimed at.
-- It corrupted a real save that way. Re:Fined gets away with it in KH2 because it lives inside
-- the process and writes at a moment it controls; this script only knows the HUD faded in.
-- So the slot write is off, and tools/promote-autosave.ps1 does it with the game closed.
local WRITE_TO_SAVE_SLOT = false

-- Which container slot the autosave lands in when enabled. Slot 98 is named "-99", so it shows
-- up as save 99 in-game, the same slot Re:Fined uses for KH2. Saves start at slot 0.
local AUTOSAVE_SLOT = 98

local SAVE_FILE = "kh1-autosave.dat"
local PREV_FILE = "kh1-autosave-prev.dat"
local TMP_FILE = "kh1-autosave.tmp"
local PATH_FILE = "kh1-autosave-path.txt"

--------------------------------------------------------------------------------
-- Save container
--
-- Layout (from KingdomSaveEditor's PcKh1Factory/PcSaveArchive, confirmed byte for byte
-- against a real Steam file):
--   0x00     PNG header, 0x70 bytes
--   0x70     entry table, 200 entries of 0x158
--   0x10D30  save bodies, 200 of stride 0x16C40 with 0x16C00 used
-- The first 0xF0 bytes of the entry table are XOR'd with a 16-byte key stored in the clear at
-- table offset 0xE0, so slot 0 is the only encrypted entry. Unlike KH2 there is no checksum:
-- the game validates a body by its first uint32 alone, 5 for Final Mix and 4 for vanilla.
--------------------------------------------------------------------------------

local container = {
    PNG_HEADER = 0x70,
    ENTRY_LEN = 0x158,
    ENTRY_COUNT = 200,
    BODY_BASE = 0x10D30,
    STRIDE = 0x16C40,
    BODY_LEN = 0x16C00,
    FILE_SIZE = 18788509,
    MAGIC_FM = 5,
}

function container.entryOffset(slot) return container.PNG_HEADER + slot * container.ENTRY_LEN end
function container.bodyOffset(slot) return container.BODY_BASE + slot * container.STRIDE end

function container.isSaveBody(body)
    return #body == container.BODY_LEN and string.unpack("<I4", body) == container.MAGIC_FM
end

-- Slot 0's entry, decrypted. The key is its own ciphertext at table offset 0xE0, so those 16
-- bytes decrypt to zeros. That is the scheme, not a bug.
function container.readSlotZeroEntry(f)
    f:seek("set", container.PNG_HEADER)
    local head = f:read(0xF0)
    if head == nil or #head < 0xF0 then return nil end
    local key = {}
    for i = 1, 16 do key[i] = head:byte(0xE0 + i) end
    local out = {}
    for i = 1, 0xF0 do out[i] = string.char(head:byte(i) ~ key[((i - 1) % 16) + 1]) end
    return table.concat(out)
end

-- "BISLPS-25198-01" -> "BISLPS-25198". Read from the file rather than hardcoded, so a release
-- with a different product code still works.
function container.namePrefix(entry)
    local name = entry:match("^[^\0]+")
    if name == nil then return nil end
    return name:match("^(.*)%-%d+$")
end

function container.slotName(prefix, slot)
    return string.format("%s-%02d", prefix, slot + 1)
end

function container.open(path)
    local f = io.open(path, "r+b")
    if f == nil then return nil, "cannot open for writing: " .. path end
    local size = f:seek("end")
    if size ~= container.FILE_SIZE then
        f:close()
        return nil, string.format("size %d, expected %d, not a KH1 container", size, container.FILE_SIZE)
    end
    return f
end

-- Blanks the name, writes the body, then writes the entry. An interrupted write leaves the slot
-- looking empty instead of leaving a valid-looking entry over a half-written save.
function container.writeSlot(f, slot, name, body)
    if #body ~= container.BODY_LEN then
        return false, string.format("body is %d bytes, expected %d", #body, container.BODY_LEN)
    end
    if #name > 0x3F then return false, "name too long" end

    local entry = container.entryOffset(slot)

    f:seek("set", entry)
    f:write(string.rep("\0", 0x10))

    f:seek("set", container.bodyOffset(slot))
    f:write(body)

    local now = os.time()
    f:seek("set", entry)
    f:write(name .. string.rep("\0", 0x40 - #name))
    f:write(string.pack("<I4I4I4I4I4I4", now, 0, now, 0, container.BODY_LEN, 0))
    f:flush()
    return true
end

-- ponytail: exposed so test_container.lua can drive the container code without the game.
AutosaveContainer = container

--------------------------------------------------------------------------------
-- Mod
--------------------------------------------------------------------------------

-- Button bits as the game reports them at inputAddress (PSX layout).
local L2, R2, L1, R1 = 0x100, 0x200, 0x400, 0x800
local DPAD_RIGHT, DPAD_DOWN = 0x020, 0x040
local SHOULDERS = L1 | L2 | R1 | R2
local LOAD_LATEST = SHOULDERS | DPAD_RIGHT
local LOAD_PREV = SHOULDERS | DPAD_DOWN

local prevHUD = 0
local lastInput = 0
local skipNextWrite = false

local containerPath = nil
local slotName = nil
local warnedMagic = false

local function findContainer()
    -- An explicit path wins, for an install the search below does not cover.
    local hint = io.open(PATH_FILE, "r")
    if hint ~= nil then
        local line = hint:read("*l")
        hint:close()
        if line ~= nil and line ~= "" then return line end
    end

    local roots = {}
    local function addRoot(base)
        if base == nil or base == "" then return end
        roots[#roots + 1] = base .. "\\Documents\\My Games\\KINGDOM HEARTS HD 1.5+2.5 ReMIX"
        roots[#roots + 1] = base .. "\\Documents\\KINGDOM HEARTS HD 1.5+2.5 ReMIX"
    end
    addRoot(os.getenv("USERPROFILE"))
    addRoot(os.getenv("OneDrive"))
    addRoot(os.getenv("OneDriveConsumer"))

    -- The store and Steam-id subfolders vary per install, so let the shell find the one file.
    for _, root in ipairs(roots) do
        local pipe = io.popen(string.format('dir /b /s "%s\\KHFM*.png" 2>nul', root))
        if pipe ~= nil then
            local line = pipe:read("*l")
            pipe:close()
            if line ~= nil and line:match("%S") then return (line:gsub("%s+$", "")) end
        end
    end
    return nil
end

function _OnInit()
    if GAME_ID == 0xAF71841E and ENGINE_TYPE == "BACKEND" then
        require("VersionCheck")
    else
        ConsolePrint("KH1 not detected, not running script")
        return
    end

    if not WRITE_TO_SAVE_SLOT then
        ConsolePrint("Autosave: slot writing off, keeping side copies only.")
        ConsolePrint("Autosave: promote one into save 99 with tools/promote-autosave.ps1, game closed.")
        return
    end

    containerPath = findContainer()
    if containerPath == nil then
        ConsolePrint("Autosave: no save container found, writing the side file only.")
        ConsolePrint("Autosave: put its full path in " .. PATH_FILE .. " to enable slot writing.")
        return
    end

    local f, err = container.open(containerPath)
    if f == nil then
        ConsolePrint("Autosave: " .. err)
        containerPath = nil
        return
    end

    local prefix = container.namePrefix(container.readSlotZeroEntry(f) or "")
    f:close()

    if prefix == nil then
        ConsolePrint("Autosave: cannot read a save name from slot 0, save once in-game first.")
        ConsolePrint("Autosave: writing the side file only for now.")
        containerPath = nil
        return
    end

    slotName = container.slotName(prefix, AUTOSAVE_SLOT)
    ConsolePrint(string.format("Autosave: writing slot %d (%s) in %s",
        AUTOSAVE_SLOT, slotName, containerPath))
end

local function writeSideFile(body)
    local tmp = io.open(TMP_FILE, "wb")
    if tmp == nil then
        ConsolePrint("Autosave: cannot write " .. TMP_FILE .. ", check folder permissions")
        return
    end
    tmp:write(body)
    tmp:close()

    -- Rotate through a temp file so a crash mid-write cannot leave a half-written snapshot
    -- where the loader expects a whole one.
    os.remove(PREV_FILE)
    os.rename(SAVE_FILE, PREV_FILE)
    os.rename(TMP_FILE, SAVE_FILE)
end

local function writeContainerSlot(body)
    if containerPath == nil then return end

    if not container.isSaveBody(body) then
        if not warnedMagic then
            ConsolePrint(string.format(
                "Autosave: continue block is not a save body (magic %d, expected %d), slot writing off",
                string.unpack("<I4", body), container.MAGIC_FM))
            warnedMagic = true
        end
        return
    end

    local f, err = container.open(containerPath)
    if f == nil then
        ConsolePrint("Autosave: " .. err)
        return
    end
    local ok, why = container.writeSlot(f, AUTOSAVE_SLOT, slotName, body)
    f:close()
    if not ok then ConsolePrint("Autosave: " .. why) end
end

local function snapshot()
    local body = ReadString(continue, container.BODY_LEN)
    writeSideFile(body)
    writeContainerSlot(body)
    ConsolePrint(string.format("Autosave written: world %d room %d, %d bytes",
        ReadByte(world), ReadByte(room), #body))
end

local function restore(path)
    local f = io.open(path, "rb")
    if f == nil then
        ConsolePrint("Autosave: nothing stored in " .. path .. " yet")
        return
    end
    local body = f:read("*a")
    f:close()

    if #body ~= container.BODY_LEN then
        ConsolePrint(string.format("Autosave: %s is %d bytes, expected %d, refusing to load",
            path, #body, container.BODY_LEN))
        return
    end

    WriteString(continue, body)
    WriteByte(closeMenu, 0)

    -- The same warp the game runs when you pick Continue after a game over.
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
            restore(SAVE_FILE)
        elseif input == LOAD_PREV then
            restore(PREV_FILE)
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
            snapshot()
        end
    end
    prevHUD = hud
end
