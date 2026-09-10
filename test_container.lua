-- Builds a synthetic save container, writes a slot into it and checks the result byte for byte,
-- including that slot 0 is untouched. Run with: lua test_container.lua
-- The container code lives inside the mod file, so load that with the game API stubbed out.
local here = arg[0]:match("^(.*/)") or "./"
GAME_ID, ENGINE_TYPE = 0, "TEST"
function ConsolePrint() end
assert(load(assert(io.open(here .. "1fmAutosave.lua")):read("*a"), "1fmAutosave.lua"))()
local C = assert(AutosaveContainer, "the mod did not expose AutosaveContainer")

local KEY = "\x83\x0c\xd2\xbb\xc8\x8b\x43\xde\x0d\x73\xaa\x4b\x0f\xb6\x36\xff"
local PREFIX = "BISLPS-25198"
local path = (os.getenv("TMPDIR") or "/tmp/") .. "kh1test-container.png"

local function buildPlainEntryZero()
    local name = PREFIX .. "-01"
    return name .. string.rep("\0", 0x40 - #name)
        .. string.pack("<I4I4I4I4I4I4", 0x6a9d799a, 0, 0x6aa29a88, 0, C.BODY_LEN, 0)
        .. string.rep("\0", 0x158 - 0x58)
end

local function xorWithKey(s)
    local out = {}
    for i = 1, #s do out[i] = string.char(s:byte(i) ~ KEY:byte(((i - 1) % 16) + 1)) end
    return table.concat(out)
end

-- Slot 0's plaintext is zero across 0xE0..0xEF, so its ciphertext there is the bare key. That
-- is exactly how the real file carries it.
local function buildContainer()
    local f = assert(io.open(path, "wb"))
    local chunk = string.rep("\0", 1024 * 1024)
    local written = 0
    while written + #chunk <= C.FILE_SIZE do f:write(chunk); written = written + #chunk end
    f:write(string.rep("\0", C.FILE_SIZE - written))
    f:close()

    local entry0 = buildPlainEntryZero()
    local body0 = "\5\0\0\0" .. string.rep("\xA5", C.BODY_LEN - 4)

    f = assert(io.open(path, "r+b"))
    f:seek("set", C.PNG_HEADER)
    f:write(xorWithKey(entry0:sub(1, 0xF0)))
    f:write(entry0:sub(0xF1))
    f:seek("set", C.bodyOffset(0))
    f:write(body0)
    f:close()
    return entry0, body0
end

local function readAt(offset, count)
    local f = assert(io.open(path, "rb"))
    f:seek("set", offset)
    local d = f:read(count)
    f:close()
    return d
end

local entry0, body0 = buildContainer()

-- Offsets must match the ones the real file reported.
assert(C.entryOffset(0) == 0x70, "entry 0 offset")
assert(C.entryOffset(1) == 0x1c8, "entry 1 offset")
assert(C.entryOffset(98) == 0x8420, "entry 98 offset")
assert(C.bodyOffset(0) == 0x10d30, "body 0 offset")
assert(C.bodyOffset(1) == 0x27970, "body 1 offset")
assert(C.bodyOffset(98) == 0x8c7db0, "body 98 offset")

-- The container must be recognised, and a wrong-sized file must not be.
local f, err = C.open(path)
assert(f ~= nil, "failed to open a valid container: " .. tostring(err))

-- Slot 0 decrypts to a readable entry, and the prefix comes from it.
local decrypted = C.readSlotZeroEntry(f)
assert(decrypted:sub(1, #PREFIX + 3) == PREFIX .. "-01", "slot 0 did not decrypt: " .. decrypted:sub(1, 20))
local prefix = C.namePrefix(decrypted)
assert(prefix == PREFIX, "wrong prefix: " .. tostring(prefix))
assert(C.slotName(prefix, 98) == "BISLPS-25198-99", "wrong slot name: " .. C.slotName(prefix, 98))
assert(C.slotName(prefix, 0) == "BISLPS-25198-01", "slot 0 name should round-trip")

-- A body of the wrong size is refused and writes nothing.
local before98 = readAt(C.bodyOffset(98), 32)
local ok, why = C.writeSlot(f, 98, "X", "too short")
assert(not ok and why:find("expected"), "short body should be refused")
assert(readAt(C.bodyOffset(98), 32) == before98, "a refused write still touched the slot")

-- The real write.
local body = "\5\0\0\0" .. string.rep("\x5A", C.BODY_LEN - 4)
local name = C.slotName(prefix, 98)
local t0 = os.time()
assert(C.writeSlot(f, 98, name, body))
f:close()

local entry = readAt(C.entryOffset(98), C.ENTRY_LEN)
assert(entry:match("^[^\0]+") == name, "slot 98 name is " .. tostring(entry:match("^[^\0]+")))
local created, flagC, modified, flagM, length, extra = string.unpack("<I4I4I4I4I4I4", entry, 0x41)
assert(length == C.BODY_LEN, string.format("length is %#x", length))
assert(flagC == 0 and flagM == 0 and extra == 0, "flags should be zero")
assert(created >= t0 and created <= t0 + 5, "created timestamp out of range")
assert(modified >= t0 and modified <= t0 + 5, "modified timestamp out of range")
assert(readAt(C.bodyOffset(98), C.BODY_LEN) == body, "slot 98 body does not match")

-- Nothing outside slot 98 moved.
assert(readAt(C.PNG_HEADER, 0x158) == xorWithKey(entry0:sub(1, 0xF0)) .. entry0:sub(0xF1),
    "slot 0 entry changed")
assert(readAt(C.bodyOffset(0), C.BODY_LEN) == body0, "slot 0 body changed")
assert(readAt(C.entryOffset(97), C.ENTRY_LEN) == string.rep("\0", C.ENTRY_LEN), "slot 97 entry changed")
assert(readAt(C.entryOffset(99), C.ENTRY_LEN) == string.rep("\0", C.ENTRY_LEN), "slot 99 entry changed")
assert((io.open(path, "rb"):seek("end")) == C.FILE_SIZE, "file size changed")

-- A truncated file is not accepted as a container.
local short = path .. ".short"
local sf = assert(io.open(short, "wb")); sf:write(string.rep("\0", 1024)); sf:close()
local bad, badErr = C.open(short)
assert(bad == nil and badErr:find("not a KH1 container"), "a short file was accepted")

os.remove(path); os.remove(short)
print("all container checks passed")
