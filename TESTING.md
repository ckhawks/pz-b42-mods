# Testing

Mods are junctioned from `C:\Projects\pz-b42-mods\` into `C:\Users\stlrc\Zomboid\mods\`,
so editing the source here edits the installed mod - no copying step.

**Enable mods through Main Menu - Mods.** Editing `mods/default.txt` only seeds new games,
the game rewrites it on its own schedule, and relying on it silently failed several times.

**Mod Lua is cached per process.** Editing a file while the game is running has no effect
even on a fresh world load - the tell is stack traces reporting old line numbers against a
newer file. Restart the game fully between code changes.

| Shows as | id | Enable? |
|----------|-----|---------|
| Base Index | `baseIndex` | yes, required |
| Storage Terminal | `storageTerminal` | yes |
| Photo Probe | `photoProbe` | no - its questions are answered |
| Container Inject Spike | `containerInject` | no - superseded by the real mod |

Launch with `-debug` for the Lua console and richer `console.txt` output.

---

## Storage Terminal

### Setup

1. Right-click an appliance - a TV, radio, filing cabinet, fridge, desk. Choose
   **Make this a storage terminal**. Bare floor will not offer the option.
2. Right-click containers and choose **Link to base network**. Needs a screwdriver,
   an electric wire or electronics scrap, and Electrical 3 by default.
3. Right-click the terminal, **Open storage terminal**.

### Verified working

Terminal and injection, crafting and building integration, item icons, search, sort,
category filter, live refresh, change tracking, power and switch, timed linking with its
costs, take 1/10/all, put away, auto-close on walking away, persistence across a reload.

### Not yet verified

- **Multi-floor networks.** Needs a two storey building or a basement. Build a terminal on
  each floor within 30 tiles, link containers on both, then check that standing at one
  reaches the other floor's containers.
- **Anything multiplayer.** See the batched checklist below.
- **Broken link and dead terminal detection.** New, untested. See below.
- **Sandbox options.** New, untested.

### Testing broken links

Smash or remove a linked container, then stay nearby for a few seconds. After three
consecutive scans that confirm it is gone, the deposit button is replaced by
**Remove N broken links**.

The distinction that matters: walking far enough that a container's chunk unloads must
**not** mark it broken. Stale rows should stay dimmed with an age, and the repair button
should not appear. If it does, the loaded-versus-missing check is wrong.

Same for terminals - pick up or destroy the object a terminal was built on. The status line
should read `terminal is gone`, and the repair button should offer to remove it.

Terminals made before this change have no sprite recorded and are grandfathered in, so
they will never report as broken. Rebuild one if you want to test it.

### Testing sandbox options

New game - Sandbox - **Storage Terminal** page. Nine options: use range, cable range,
terminal spacing, terminal linking range, cable cost per floor, require electricity,
Electrical level, consume wire, link time.

Worth checking that a changed value actually takes effect, since the whole point is that
admins can tune this without editing Lua. Setting cable range to 5 and confirming distant
crates refuse to link is the quickest test.

---

## Multiplayer checklist - batched for one session with a second player

None of this has run against a real server. It is deliberately saved up rather than
tested piecemeal, so run the whole list in one sitting. Ordered so a failure early tells
you the most.

**Sync basics**

1. Player A builds a terminal. Does it appear for player B without a relog?
2. Player A links a container. Does B see it in their terminal window?
3. Player A switches the terminal off. Does B's window report `terminal switched off`?
4. Both quit, server restarts, both rejoin. Is everything still there?

**Races - the reason the server owns the table**

5. A and B link two *different* containers within a second of each other. Both survive?
   (Client-authoritative writes lose one here; that is the bug the command path fixes.)
6. A and B link the *same* container simultaneously. No duplicate, no error?
7. A unlinks a container while B has the terminal window open. Does B's list update?

**Transfers**

8. A and B both Take the last of an item at the same time. One succeeds, one fails
   cleanly - no duplication, no negative count.
9. A takes items while B watches. Does B's `recent:` line show the delta within a poll?
10. Put away with both players standing at the same terminal.

**Hostile input** - only if you care, and only on your own server

11. Confirm a client cannot place a terminal closer than the spacing rule by sending a
    crafted command. `applyAdd` re-checks server-side, so this should be refused.

**Known-unknown:** counts are client-authoritative by design - each client scans what its
own chunks can see. Expect brief disagreement between players about numbers for containers
only one of them is near. That is intended, not a bug, but confirm it self-corrects.

---

## Base Index

The shared library under the terminal. No UI of its own. Console helpers:

```lua
BaseIndexDebug.dump()
BaseIndexDebug.find("Base.Nails")
```

`dump()` reports `refreshed N, out of range M, changed K`. Walk away from linked containers
and confirm out-of-range entries keep their last known counts rather than reporting zero.

---

## Cleanup

```powershell
Remove-Item C:\Users\stlrc\Zomboid\mods\PhotoProbe, C:\Users\stlrc\Zomboid\mods\ContainerInject, C:\Users\stlrc\Zomboid\mods\BaseIndex, C:\Users\stlrc\Zomboid\mods\StorageTerminal -Recurse -Force
Copy-Item C:\Users\stlrc\Zomboid\mods\default.txt.bak-preinject C:\Users\stlrc\Zomboid\mods\default.txt -Force
```

Removing a junction with `-Recurse` deletes the link, not the source. The source in
`C:\Projects\pz-b42-mods\` is unaffected.
