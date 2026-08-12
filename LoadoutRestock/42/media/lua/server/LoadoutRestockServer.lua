--[[
Server side of loadout storage.

This file exists for one reason: global ModData is written to `global_mod_data.bin` by the
**server**, and a key that is only ever created from a client file may never be persisted
at all. In singleplayer that is the same process; on a real server it is the only process
that saves anything.

Vanilla splits foraging the same way - `forageServer.lua` creates the table,
`forageClient.lua` requests it - and the storage terminal needed exactly this file before
its terminals survived a reload. Loadouts were written without it and did not persist,
which is the same bug twice.

`getOrCreate` is called **unconditionally**, not guarded by `isNewGame`.

That guard was a mistake copied from the wrong vanilla example. `ProfessionVehicles.lua:344`
guards it because that mod only ever needs a fresh table on a new game. Foraging does not -
`forageClient.lua:7` calls `getOrCreate` unconditionally inside its init - and foraging is
the case this resembles.

The guard has a specific failure: a mod added to an **existing** save never sees
`isNewGame`, so its key is never created, never registered, and never written. Inspecting
`global_mod_data.bin` showed exactly that - `StorageTerminal` and `BaseIndex` present,
`LoadoutRestock` absent, because the save predated this mod.

`getOrCreate` does what its name says on a load: it returns the table that was restored,
and only creates one when there is nothing to restore.
]]

local MODULE = "LoadoutRestock"

Events.OnInitGlobalModData.Add(function(isNewGame)
    ModData.getOrCreate(MODULE)
end)
