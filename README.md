# KH1 Auto Save

Autosave for **Kingdom Hearts Final Mix** on PC (the KH1 half of *KINGDOM HEARTS HD
1.5+2.5 ReMIX*, Steam or Epic). Every time a room finishes loading the mod dumps the
game's continue block to disk, so a crash, an alt-F4 or a fight that goes wrong costs you
the current room instead of everything since the last save point.

Same idea as the autosave in KH2FM Re:Fined: no new save system, no menu, no save-point
emulation. It piggybacks the snapshot the game already takes for the Continue option after
a game over, and writes it to a file that survives closing the game.

## Buttons

| Combo | What it does |
| --- | --- |
| `L1 + L2 + R1 + R2 + D-pad Right` | Restore the latest snapshot |
| `L1 + L2 + R1 + R2 + D-pad Down` | Restore the one before it |

Nothing to press to save. That happens on its own on every room load.

The second slot is there for the one case that bites: you walk into a boss arena
underleveled, the autosave points at that room, and restoring it drops you straight back
into the fight. Down instead of Right gets you the room before.

## Requirements

- PC only. This hooks a Windows process, so PS4, PS5, Switch and PCSX2 are out. It works
  under Proton / Steam Deck with the usual LuaBackend setup.
- [LuaBackend](https://github.com/Sirius902/LuaBackend) (or LuaFrontend) with KH1 enabled.
- The `io_packages` address files from
  [Denhonator/KHPCSpeedrunTools](https://github.com/Denhonator/KHPCSpeedrunTools/tree/main/1FMMods/scripts/io_packages).
  They map every game version's memory layout and this mod reads them instead of hardcoding
  addresses, the same way the KH2 autosave mod leans on KH2-Lua-Library.

Verified game versions are whatever `io_packages` covers: Epic 1.0.0.8 / 1.0.0.9 / 1.0.0.10
and Steam 1.0.0.1 / 1.0.0.2, Global and JP.

## Install

### OpenKH Mods Manager

1. Install OpenKH Mods Manager, run the wizard, install Panacea and **Lua Backend with KH1
   selected**. Game extraction can be skipped, this is a script-only mod.
2. Pick **Kingdom Hearts 1** in the game dropdown, add this repo from GitHub, enable it.
3. Add `Denhonator/KHPCSpeedrunTools` from GitHub as well. Its `mod.yml` is a collection
   that installs nothing but the address files, so none of its speedrun mods get enabled.
4. **Build and Run**.

### Manual

Open `Documents/KINGDOM HEARTS HD 1.5+2.5 ReMIX/scripts/kh1/` and:

1. Copy `1fmAutosave.lua` into it.
2. Create `io_packages/` inside it and copy in `VersionCheck.lua` plus the one version file
   that matches your install (e.g. `SteamGlobal_1_0_0_2.lua`).

`F1` in-game reloads scripts, `F2` opens the console.

## Checking it works

Load a save, walk through a door, and the console should print:

```
Autosave written: world 3 room 7, 93184 bytes
```

93184 is the full continue block. A smaller number means the memory read is being cut short
and the snapshot will be refused on load rather than restoring a half state.

The snapshot files (`kh1-autosave.dat`, `kh1-autosave-prev.dat`) land next to the LuaBackend
exe/dll, not with your normal saves. Deleting them costs you nothing but the autosave.

## Limits worth knowing

- This restores a **continue state**, not a save file. It does not touch your save slots and
  it does not survive as one, so keep using save points for anything you care about.
- No room blacklist. The KH2 version skips a handful of rooms where a snapshot softlocks;
  the KH1 equivalent hasn't been mapped, and the second slot is the workaround.
- Snapshots are written on room load only, so a long fight in one room is not covered.
- It writes ~91 KB per room transition. Harmless on an SSD, worth knowing on a stick.

## Credit

The autosave mechanism (the continue block, its size, the warp used to restore it, the HUD
signal for "a room finished loading") is [Denhonator](https://github.com/Denhonator)'s, from
`1fmSaveAnywhere.lua` in KHPCSpeedrunTools, where it ships alongside save-anywhere, soft
reset and instant-death tools. This is that one feature pulled out on its own, packaged for
the Mods Manager, with atomic writes, a size check on load, and the second slot added.

Unlicense, same as upstream.

## Tests

`lua test_autosave.lua` stubs the LuaBackend memory API and drives the script through the
file rotation, both load combos, a truncated snapshot and a missing one. It cannot test
anything about the game itself.
