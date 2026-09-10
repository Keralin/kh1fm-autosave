# KH1 Auto Save

Autosave for **Kingdom Hearts Final Mix** on PC (the KH1 half of *KINGDOM HEARTS HD
1.5+2.5 ReMIX*, Steam or Epic). Every time a room finishes loading it writes the game state
into **save slot 99**, where it shows up in the Load menu like any other save. A crash, an
alt-F4 or a fight that goes wrong costs you the current room instead of everything since the
last save point.

Same approach as the autosave in KH2FM Re:Fined: no new save system and no menu, just the
save file the game already understands, written from the state the game already keeps for the
Continue option after a game over.

## What it does

- **Slot 99** holds the newest snapshot. Load it from the title screen like a normal save.
- **Two side copies** (`kh1-autosave.dat`, `kh1-autosave-prev.dat`) sit next to the LuaBackend
  dll and can be dropped straight back into the running game:

| Combo | What it does |
| --- | --- |
| `L1 + L2 + R1 + R2 + D-pad Right` | Restore the latest snapshot in place |
| `L1 + L2 + R1 + R2 + D-pad Down` | Restore the one before it |

Nothing to press to save. That happens on its own on every room load.

The older side copy is there for the one case that bites: you walk into a boss arena
underleveled, the autosave points at that room, and restoring it drops you straight back into
the fight. Down instead of Right gets you the room before.

Loading a save fades the HUD in exactly like walking through a door, so the first snapshot after
a load is skipped. Without that, recovering from a crash overwrote the snapshot you crashed with
using the save point you had just loaded, and Right handed you back your own save point.

Your own saves start at slot 0 and are never touched. To put the autosave somewhere else,
change `AUTOSAVE_SLOT` at the top of `1fmAutosave.lua` (it is the slot index, one below the
save number you see in-game).

## Back up first

Every one of your 200 save slots lives in a single file. This mod writes into that file. Copy
your save folder somewhere safe before the first run:

```
%USERPROFILE%\Documents\My Games\KINGDOM HEARTS HD 1.5+2.5 ReMIX\
```

After the first autosave, open the container in
[KingdomSaveEditor](https://github.com/Xeeynamo/KingdomSaveEditor) and check your own saves are
intact and slot 99 has appeared. Do that once and you never have to think about it again.

## Requirements

- PC only. This hooks a Windows process, so PS4, PS5, Switch and PCSX2 are out. It works under
  Proton / Steam Deck with the usual LuaBackend setup.
- [LuaBackend](https://github.com/Sirius902/LuaBackend) (or LuaFrontend) with KH1 enabled.
- The `io_packages` address files from
  [Denhonator/KHPCSpeedrunTools](https://github.com/Denhonator/KHPCSpeedrunTools/tree/main/1FMMods/scripts/io_packages),
  which map every game version's memory layout. This mod reads them instead of hardcoding
  addresses, the same way the KH2 autosave mod leans on KH2-Lua-Library.

Verified game versions are whatever `io_packages` covers: Epic 1.0.0.8 / 1.0.0.9 / 1.0.0.10 and
Steam 1.0.0.1 / 1.0.0.2, Global and JP.

## Install

### OpenKH Mods Manager

1. Install OpenKH Mods Manager, run the wizard, install Panacea and **Lua Backend with KH1
   selected**. Game extraction can be skipped, this is a script-only mod.
2. Pick **Kingdom Hearts 1** in the game dropdown, add this repo from GitHub, enable it.
3. Add `Denhonator/KHPCSpeedrunTools` from GitHub as well. Its `mod.yml` is a collection that
   installs nothing but the address files, so none of its speedrun mods get enabled.
4. **Build and Run**.

### Manual

Open `Documents\My Games\KINGDOM HEARTS HD 1.5+2.5 ReMIX\scripts\kh1\` and:

1. Copy `1fmAutosave.lua` into it.
2. Create `io_packages\` inside it and copy in `VersionCheck.lua` plus the one version file that
   matches your install (e.g. `SteamGlobal_1_0_0_2.lua`).

`F1` in-game reloads scripts, `F2` opens the console.

## Checking it works

Load a save and press `F2`. At startup you should see which slot and file it will write:

```
Autosave: writing slot 98 (BISLPS-25198-99) in C:\Users\...\KHFM_WW.png
```

Then walk through a door:

```
Autosave written: world 3 room 7, 93184 bytes
```

93184 is the full save body. Quit to the title screen and save 99 should be in the Load menu.

If the container cannot be found it says so and keeps writing the side copies, which still work
with the button combos. To point it at the file yourself, put the full path on the first line of
`kh1-autosave-path.txt` next to the LuaBackend dll.

## Save container format

Worked out from
[KingdomSaveEditor](https://github.com/Xeeynamo/KingdomSaveEditor)'s `PcKh1Factory` and
`PcSaveArchive`, then confirmed byte for byte against a real Steam file. The container is
`KHFM_WW.png`, a valid PNG with the save data inside, exactly 18,788,509 bytes:

| Offset | What |
| --- | --- |
| `0x00` | PNG header, `0x70` bytes |
| `0x70` | Entry table, 200 entries of `0x158` |
| `0x10D30` | Save bodies, 200 of stride `0x16C40`, `0x16C00` used |
| tail | PNG footer |

Each entry: name at `0x00` (`0x40` bytes, e.g. `BISLPS-25198-01`, the number being the slot
index plus one), created unix seconds at `0x40`, modified at `0x48`, body length at `0x50`.

Two things make this easier than the KH2 equivalent:

- **No checksum.** The game validates a body by its first uint32 alone: `5` for Final Mix, `4`
  for vanilla. KH2 needs a CRC-32 over the whole body.
- **The continue block is a save body.** Both are `0x16C00` bytes with the same magic, so the
  snapshot needs no conversion, just an entry written around it.

The first `0xF0` bytes of the entry table are XOR'd with a 16-byte key held in the clear at
table offset `0xE0`, which means slot 0 is the only encrypted entry (the key's own 16 bytes
decrypt to zeros). Any slot above 0 is plaintext, so the autosave never touches the encrypted
region. This is also why slot 0 looks like garbage in a hex editor while holding a perfectly
good save.

`tools/inspect-save.ps1` is a read-only reporter for all of the above.

## Limits worth knowing

- The container is written on disk, so if the game caches it in RAM, slot 99 may only appear in
  the Load menu after restarting the game. That is exactly when you need it.
- Snapshots are written on room load only, so a long fight in one room is not covered.
- No room blacklist. The KH2 version skips a handful of rooms where a snapshot softlocks; the
  KH1 equivalent has not been mapped, and the older side copy is the workaround.

## Credit

The snapshot mechanism (the continue block, its size, the warp used to restore it, the HUD
signal for "a room finished loading") is [Denhonator](https://github.com/Denhonator)'s, from
`1fmSaveAnywhere.lua` in KHPCSpeedrunTools, where it ships alongside save-anywhere, soft reset
and instant-death tools. This is that one feature pulled out on its own, packaged for the Mods
Manager, plus writing into a real save slot the way
[Re:Fined](https://github.com/KH-ReFined/KH-ReFined) does for KH2.

Unlicense, same as upstream.

## Tests

```
lua test_autosave.lua     # side-file rotation, both combos, truncated and missing snapshots
lua test_container.lua    # builds a synthetic container, writes a slot, checks slot 0 is untouched
```

Neither can test anything about the running game.
