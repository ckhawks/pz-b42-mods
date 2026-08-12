# Project Zomboid Build 42 mods

Four mods for long-term and multiplayer bases, built against **PZ 42.20**.

They share one library, so they cannot disagree with each other about what is in your base.

| Mod | What it does |
|-----|--------------|
| **Base Index** | Library. Registers containers, scans them safely across chunk boundaries, caches counts with timestamps, and holds the drawn base areas. No UI of its own beyond area management. |
| **Storage Terminal** | Convert a TV into a terminal. Every container wired into its network becomes reachable from the loot window, from crafting, and from building. |
| **Loadout Restock** | Save what you wear, hold and carry as a named loadout, then refill it in one action from whatever you can reach. |
| **Base Board** | Hang a corkboard. Reports supplies, water, fuel, ammunition, crops, animals, vehicles, defenses and the generator, plus a shared task list and the crew's skills. |

`Base Index` is required by the other three.

## The idea the storage terminal is built on

`ISInventoryPaneContextMenu.getContainers` does no distance check. It reads the loot
window's container list, and that one function is what crafting, building, the B42
workstation menu, medicine and camping all use to find materials.

So adding container buttons to the loot window extends every one of those systems at once,
through vanilla's own code path. Measured with a throwaway spike:

```
injection OFF:  7 items visible to crafting and building
injection ON:  73 items visible to crafting and building
20 of 20 injected containers reached getContainers()
```

## Two scopes, deliberately

**Linked containers** are ones you wired into the network with a screwdriver, wire and
Electrical 3. Supplies - food, water, fuel, ammunition - are counted from those.

**Base areas** are rectangles you drew on the ground. Crops, animals, defenses and vehicles
are surveyed inside those.

Both are explicit because the alternative is guessing where a base ends, and every attempt
at inferring it produced a number nobody could predict or correct.

## Layout

```
<Mod>/42/mod.info
<Mod>/42/media/lua/{client,server,shared}/*.lua
<Mod>/42/media/sandbox-options.txt
```

B42 reads mod content from a version subfolder. A mod with only a root-level `mod.info` is
treated as Build 41 and never appears in the B42 mod list.

## Status

Singleplayer: working and played. Multiplayer: written to be server-authoritative for all
shared state, and **entirely untested** - see the checklist in `TESTING.md`.

`PhotoProbe`, `ContainerInject` and `ZoneProbe` are throwaway probes kept for the record.
Each one settled a question that reading the game's code could not: whether Lua can load an
arbitrary PNG as a texture, whether the container injection propagates, and whether a
custom `DesignationZone` type survives a save. They are not gameplay mods and should stay
disabled.

See [DESIGN.md](DESIGN.md) for the reasoning and [TESTING.md](TESTING.md) for how to run
any of it.
