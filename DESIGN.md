# Project Zomboid Build 42 mod concepts

Feasibility assessment and build plan for four mod ideas.

Verified against the local install at
`C:\Program Files (x86)\Steam\steamapps\common\ProjectZomboid` (Build 42 confirmed:
`media/basement_access`, `media/lua/client/Entity`, `Fluids`, `FeedingTrough`, `Mining`).

Lua paths below are relative to `media/lua/`. Java references are class names inside
`projectzomboid.jar`.

---

## Status

Three mods exist in this repo, junctioned into `C:\Users\stlrc\Zomboid\mods\`.
See [TESTING.md](TESTING.md) for how to run them.

| Directory | Purpose | State |
|-----------|---------|-------|
| `PhotoProbe/` | Answered the idea 3 open questions | Done, disabled |
| `ContainerInject/` | Answered the idea 4 open question | Done, disabled |
| `BaseIndex/` | Shared registration, scan, and cache layer | Working |
| `StorageTerminal/` | Idea 4, the real mod | **Working and playable** |

Idea 4 is built. It has a terminal object with range and power gating, cabled container
links with a tool, material and skill cost, multi-floor terminal networks, an item list
with icons, search, sort and category filter, taking and bulk depositing, live refresh
with change tracking, sandbox options, and broken-link detection.

Still open on it: multiplayer is entirely untested, multi-floor is untested, and
`isAllowed()` on the server lets any player unlink anything pending a permissions decision
(parked - this group is not using safehouses).

See [TESTING.md](TESTING.md) for how to run any of it.

### Environment notes that cost time

**Enable mods through Main Menu - Mods**, not by editing `mods/default.txt`. That file only
seeds new games and the game rewrites it on its own schedule.

**Mod Lua is cached per process.** Editing a file while the game runs has no effect even on
a fresh world load; stack traces keep reporting the old line numbers. Restart fully.

**`[[wikilink]]` syntax cannot appear in a Lua block comment.** `]]` closes a `--[[` comment
and the rest of the prose is parsed as code. It killed both terminal files on first run.

**Global ModData needs `getOrCreate` guarded by `isNewGame`, registered server-side.** An
unconditional call runs before the save is deserialised and replaces the restored table
with an empty one - everything works until you reload. Register in a `lua/server/` file
too, since that is the side that writes `global_mod_data.bin`.

**Check argument counts against vanilla before calling a Java method.** `hasRoomFor` takes
`(character, item)`, not `(item)`. `haveElectricity()` is generator power only - the grid
is `hasGridPower()`. A mismatched arity throws rather than returning an error.

**Both open questions are now answered.** Verified in game on 42.20.

### Idea 4: confirmed

Injecting containers into the loot window on `OnRefreshInventoryWindowContainers`
propagates to everything that calls `getContainers()`:

```
injection OFF: 7 items visible to crafting and building
injection ON: 73 items visible to crafting and building
20 of 20 injected containers reached getContainers()
container buttons went 1 -> 21
```

### Idea 3: confirmed

```
getTextureFromSaveDir(fileName, saveDirectory)
```

Filename first, directory second, both Strings, both `/` and `\` accepted in the
directory. Verified against a save's own `thumb.png` (width 256) and against an arbitrary
screenshot copied into the save folder from outside the game (width 3440, the screen
width - so it really is the full image, decoded and live).

Capture works too: `getCore():TakeFullScreenshot("name.png")` and the global
`takeScreenshot("name.png")` each take one String and write a real PNG into
`Zomboid/Screenshots/`.

The returned `Texture` exposes 84 methods, including the two that close the loop:
**`saveToCurrentSavefileDirectory`** and **`saveToZomboidDirectory`**. A texture writes
itself into the save folder and `getTextureFromSaveDir` reads it back, so photos live
inside the save and travel with it rather than accumulating as orphans in a global
folder. Also present: `setRegion` / `split` / `splitIcon` for cropping into a frame,
`getData` / `setData` for raw pixels, `makeTransp` / `createMask` for the border.

### Notes on the environment

**The intro sequence ignores synthetic input.** PZ opens on a photosensitivity warning
drawn over bink playback and never advances by itself. SendKeys, `mouse_event` and
`keybd_event` were all tried with the window confirmed foreground and fullscreen, and
none moved it, while the process kept consuming more than a core - rendering, not
deadlocked. Screen capture works; input injection does not. Reaching a loaded world
needs a human click.

**Mod Lua is cached per process.** Editing a mod file while the game is running has no
effect even on a fresh world load - the stack traces keep reporting the old line numbers.
Restart the process between iterations.

**Arity faults were contained here.** Every wrong-argument call in these probes was
caught by `pcall`, and the session kept working afterwards - the container spike ran
normally 600 ticks later. That contradicts the craftgraphDump experience of a fault
corrupting the invoker for the rest of the session, so the corruption is probably
specific to overloaded instance methods rather than to every mismatched call. Guessing an
argument list cost one logged error per attempt, which is what made a nine-shape matrix in
one launch worthwhile.

---

## Summary

| # | Mod | Difficulty | Main risk | State |
|---|-----|-----------|-----------|-------|
| 4 | Storage terminal | Low-med | Chunk unloading, balance | **Built** |
| 2 | Loadout restock | Low-med | Action-queue orchestration | Not started |
| 3 | Polaroid photos | Medium | Moderation, MP transfer size | Not started, API verified |
| 1 | Base management board | High | B42 farming/animal API churn, UI volume | Not started |

Remaining build order: 2, then 3, then 1.

Idea 2 is next because it reuses `BaseIndex.locate()`, which already sorts containers
most-stocked-first specifically so a fetch visits one crate rather than four. The index
layer is proven by idea 4, so the fetch engine is the only new part.

Idea 3 moved ahead of idea 1 after the API audit resolved its blocking unknown.

---

## Key findings from the install audit

These three discoveries changed the assessment materially.

### 1. One injection point feeds every crafting and building system

`ISInventoryPaneContextMenu.getContainers(character)` at
`client/ISUI/ISInventoryPaneContextMenu.lua:2425` performs no distance check and no
square scanning. It reads the loot window's backpack list directly:

```lua
for i,v in ipairs(getPlayerLoot(playerNum).inventoryPane.inventoryPage.backpacks) do
```

That single function is the material source for:

- `client/Entity/ISUI/CraftRecipe/ISHandCraftPanel.lua:195` - crafting
- `client/Entity/ISUI/CraftRecipe/ISCraftInputItems.lua:9` - crafting
- `client/Entity/ISUI/BuildRecipe/ISBuildPanel.lua:215,318` - building
- `client/BuildingObjects/TimedActions/ISBuildAction.lua:148` - building
- `server/BuildingObjects/ISBuildingObject.lua:198` - building
- `client/Entity/ISUI/ISEntityBuildMenu.lua:119` - B42 workstation menu
- `client/XpSystem/ISUI/ISHealthPanel.lua:1042,1763` - medical
- `shared/Camping/ISCampingMenu.lua:106,512,554,564,589` - camping

Injecting containers into the loot window therefore extends all of them at once,
with no overrides.

The supported hook is `OnRefreshInventoryWindowContainers`, fired from
`client/ISUI/ISInventoryPage.lua` at lines 1560 (`"begin"`), 1794 (`"beforeFloor"`),
1801 (`"buttonsAdded"`), and 1902 (`"end"`).

### 2. Item transfers do not validate distance

`ISInventoryTransferAction:isValid()` at `client/TimedActions/ISInventoryTransferAction.lua:11`
contains no reach or distance check. The multiplayer gates are:

- `isItemTransactionConsistent(item, srcContainer, destContainer, nil, character)` (line 49)
- the `ItemNumbersLimitPerContainer` server option (line 52)
- a reach check only in the `isTransferIntoVehicleSeatFromOutside` branch, which itself
  calls `getContainers()` and so inherits any injection

Practical effect: an injected container is indistinguishable from a nearby one. Remote
transfer is a balance decision, not a technical obstacle.

### 3. The full screenshot-to-item chain is exposed to Lua

From the exposer in `zombie/Lua/LuaManager$GlobalObject`:

- `takeScreenshot`, `TakeFullScreenshot` - capture
- `getTextureFromSaveDir` - load a texture from the save directory
- `getFileOutput`, `getFileInput`, `endFileOutput`, `endFileInput`, `readByte`
  (with `DataInputStream` / `DataOutputStream` in the pool) - byte-level file I/O
- `getModFileWriter`, `getModFileReader`, `listFilesInModDirectory`
- Lua file-access extension allowlist: `.lua`, `.txt`, `.cfg`, `.png`, `.db`

`.png` being allowlisted alongside byte-level I/O means images can be written and read
by mod Lua on both ends of a multiplayer connection.

Supporting Java surface: `zombie/core/Core` exports `TakeScreenshot`,
`TakeFullScreenshot`, `getScreenshotDir`. `zombie/core/textures/Texture` has
`getSharedTexture`, `trygetTexture`, `reloadFromFile`, a `(String)` constructor, a
`(BufferedInputStream, String, boolean)` constructor, and `createSteamAvatar` (proof the
engine builds textures from runtime bytes). `zombie/savefile/SavefileThumbnail$TakeScreenShotDrawer`
shows the engine already screenshots to disk for save thumbnails.

There is no Lua-exposed HTTP client. `openUrl` / `openURL` launches the player's external
browser and cannot fetch bytes into the game. `URLConnection` appears in the constant pool
as internal machinery only. Web-server distribution is not available and is not needed.

---

## Shared foundation

Build once, roughly 2 days. Ideas 1, 2, and 4 all need it. Writing it three times
guarantees the three mods disagree about what is in the base.

- Container registration via context menu, coordinates persisted in ModData
- Cached index keyed by `fullType`, storing counts plus a per-container timestamp
- Never store item references; they go stale the moment a chunk unloads
- Scan routine that tolerates `getGridSquare` returning nil for unloaded cells
- Dirty-flag invalidation after any transfer the mod initiates

---

## 4. Storage terminal

Refined Storage style access to every linked container in the base.

### Design fork

Three possible behaviours:

- **View** - indexes containers and reports what you own and where. No items move.
- **Requisition** - queues your own walk-to and transfer actions to fetch what you asked for.
- **Portal** - items move without you walking.

Requisition is the recommended default. It is vanilla-legal, shares its engine with idea 2,
and reads as a base upgrade rather than a cheat. Portal is now technically viable (see
finding 2) but should ship as a sandbox option, off by default.

### Phases

1. Registration plus loot-window injection on `OnRefreshInventoryWindowContainers`.
   Crafting and building inherit it automatically. This alone is most of the mod's value.
2. Terminal UI: search and filter across the index, "where is X" locator.
3. "Put away all" - sort loose inventory back into linked containers by category.
   Same machinery inverted, and likely the most-used feature day to day.
4. Gating: requires power, linking costs wire plus an Electrical check, sandbox options
   for radius and remote-transfer toggle.

### Challenges

- Containers in unloaded cells cannot be read. Show timestamps and grey out stale entries.
- PZ items are individual objects, not stacks. A stocked base holds tens of thousands.
  Index on UI open and on a throttled tick, never per frame.
- Condition, rot state, and drainable charge must survive aggregation. Over-aggregating
  into a single number is the mistake that makes these mods feel wrong.

---

## 2. Loadout restock

Define a loadout preset, then pull it from nearby containers at exact quantities.

### Phases

1. Capture preset from current state: `getWornItems`, `getPrimaryHandItem`,
   `getSecondaryHandItem`, equipped bag contents. Store in `player:getModData()`.
2. Delta calculation plus a missing-items readout so you know what to go loot.
3. Fetch engine: queue `ISWalkToTimedAction` plus `ISInventoryTransferAction` onto
   `ISTimedActionQueue`.
4. Equip actions (`ISWearClothing`, `ISEquipWeaponAction`), hotkey binding, and the
   inverse "dump non-preset items into this container".

### Challenges

- Never call `addItem` / `removeItem` directly. That skips animations, ignores encumbrance,
  and desyncs in multiplayer.
- Weight limits mid-run. Check `getMaxWeight()` before queueing and bail with a clear message.
- Boxed and loose ammo are different items (`Bullets9mmBox` vs `Bullets9mm`). The preset
  needs explicit semantics, ideally "N rounds, unbox if needed".
- Re-validate each transfer at execution time. Containers change between plan and run,
  especially in multiplayer.

---

## 3. Polaroid photo system

Turn screenshots into physical, viewable, placeable photo items.

### Phases

0. **Verification pass first.** See open questions below. Do not plan past it.
1. Photo item, metadata in item ModData, right-click "View" showing the image in a UI window.
2. Photo book: container item with a paging UI.
3. Wall placement as a generic frame tile, with the real image shown on interact.
4. Stretch: runtime sprite on the wall tile itself so it is visible from a distance.

### Multiplayer distribution

Feasible over the normal command channel, given finding 3.

- Downscale to polaroid resolution before sending. A 256x256 PNG is roughly 30-60KB,
  about 40-80 chunks. A full-resolution screenshot is not viable.
- Address photos by content hash. Send hash plus metadata first, ship bytes only to
  clients that lack that hash. Each photo transfers once, ever.
- Rate-limit and cap: maximum dimensions, maximum photos per player, server-side size
  ceiling.
- Missing local file degrades to a placeholder frame rather than erroring.

An out-of-band sync (Syncthing, shared folder, small companion daemon) remains an optional
path for full-resolution photos, since the mod only ever touches local files. It is a
nice-to-have for private groups, not the architecture.

### Challenges

- Hide the HUD before capture.
- PNGs are loose files that outlive saves. Cap the count, handle missing files, offer cleanup.
- Content moderation. Hash addressing plus an admin blocklist is the cheap answer to
  someone putting something vile on a base wall.

`client/RecordedMedia/` is the closest vanilla precedent for a custom media item.

---

## 1. Base management board

Placeable board tracking base state, with claimable tasks for multiplayer.

### Phases

1. Board item, placement, and the task list: claim and release, server-authoritative,
   with claims that expire so a player who logged off last week does not hold a lock.
2. Supply tallies off the shared index: food, water, ammo. Timestamped.
3. Generator (`IsoGenerator` fuel, condition, activated), then vehicles (fuel is the
   `GasTank` part contents, damage is per-part condition).
4. Damaged defenses: scan the stored rectangle for `IsoThumpable` health against max.
   Spread the scan across frames.
5. Crops and animals. **Cut from v1.** B42 rewrote both systems. Read the installed
   `Farming` and animal Lua rather than any B41-era guide.

### Challenges

- The tab-heavy UI is the bulk of the hours, not the data gathering.
- Claim races need `sendClientCommand` / `OnClientCommand` with server-side validation.
- Chunks unload, so the board cannot show live truth. Lean into it: "Food: 214 units,
  as of 6 hours ago" is what a whiteboard would actually say.
- Confirm the multiplayer status of the installed B42 build before designing that half.

---

## Open questions

Idea 3, phase 0. Run in the Lua console with `-debug`:

1. `print(getTextureFromSaveDir)` and `print(getFileOutput)` - confirm existence and
   check signatures.
2. `getCore():TakeFullScreenshot()` - confirm a PNG lands, and note whether it goes to
   the screenshot directory or the save directory. `getTextureFromSaveDir` implies a
   copy or write into the save directory will be needed.
3. Round-trip a small PNG: read with `getFileInput` / `readByte`, write back under a new
   name with `getFileOutput`, load via `getTextureFromSaveDir`, draw in an `ISImage`.

If step 3 draws, idea 3 is fully unblocked including multiplayer.

Idea 4, one-hour proof:

1. Register `Events.OnRefreshInventoryWindowContainers`.
2. On `"buttonsAdded"`, add one hardcoded distant container via `addContainerButton`.
3. Walk to a workbench and check whether the crafting panel lists that container's items
   as available.

If it does, the entire terminal design is confirmed.

---

## Packaging notes

- B42 uses the versioned mod layout: `mods/YourMod/42/media/...` alongside `common/`.
  Set this up at the start; retrofitting is tedious.
- Run with `-debug` for the UI inspector. Keep `Zomboid/console.txt` open. `/reloadlua`
  saves restarts.
- Reuse vanilla sprites (corkboard, whiteboard, picture frames) rather than making tile art.
  Art is the hidden time sink on all four.
