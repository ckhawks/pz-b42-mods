--[[
Server side of the base index.

The shared table is owned here. Clients ask for changes and the server makes them, which
is the only arrangement that survives two players editing at once: a client-authoritative
write transmits the whole table, so simultaneous edits mean the loser's change silently
disappears, and for registrations that means a crate someone spent wire on quietly falls
off the network.

Only registrations pass through here. Item counts stay client-side derived data - every
client recomputes them by scanning, a race costs one stale number that the next scan
repairs, and routing them through the server would be a command per container per scan for
no correctness gain.

This file lives under lua/server so a client never runs it.
]]

local MODULE = "BaseIndex"

--[[
Create the table server side, which is the side that saves it.

The shared file registers it too, but global mod data is written out by the server - in
singleplayer that is the same process, on a real server it is the only process that
persists anything. Vanilla's foraging does exactly this: forageServer.lua creates the
table and forageClient.lua requests it.

Registering it in both places is not redundant. Without the server half the key may never
be written to global_mod_data.bin at all; without the client half a joining player has no
local table to read until the first broadcast arrives.
]]
Events.OnInitGlobalModData.Add(function(isNewGame)
    ModData.getOrCreate(MODULE)
end)

--[[
Whether a player is allowed to change this registration.

Deliberately permissive for now: anyone can link or unlink anything. A cooperative server
is the assumed case, and the alternative - tying registrations to safehouse membership -
needs a design conversation about what happens when a safehouse is abandoned or a player
is kicked from one.

The hook is here so that conversation has somewhere to land, and so the permissive rule is
a visible decision rather than an oversight.
]]
local function isAllowed(player, command, args)
    if player == nil then return false end
    return true
end

--[[
Sanity check what arrived.

A command carries whatever the client put in it, so nothing here trusts the shape. A
malformed or hostile payload should be dropped rather than written into a table that is
about to be broadcast to everyone.
]]
local function isWellFormed(command, args)
    if type(args) ~= "table" then return false end
    if type(args.x) ~= "number" or type(args.y) ~= "number" or type(args.z) ~= "number" then
        return false
    end

    if type(args.containerType) ~= "string" then return false end
    if args.label ~= nil and type(args.label) ~= "string" then return false end

    -- Labels are shown in every player's terminal window, so an overlong one is a way to
    -- break other people's UI rather than a mistake.
    if args.label ~= nil and #args.label > 64 then return false end
    return true
end

--[[
Area payloads are checked separately, because they carry a name that every player will see
and coordinates that decide how much ground every survey walks.

The side limit is the same one the drawing UI enforces. Enforcing it only in the UI would
mean a client could ask the server to store a base the size of the map, and every other
player would then pay for it on every refresh.
]]
local AREA_MAX_SIDE = 120

local function isAreaWellFormed(command, args)
    if type(args) ~= "table" then return false end

    if command == "RemoveArea" then
        return type(args.id) == "string" and #args.id <= 32
    end

    if command == "RenameArea" then
        return type(args.id) == "string" and #args.id <= 32
            and type(args.name) == "string" and #args.name > 0 and #args.name <= 40
    end

    -- AddArea
    if type(args.name) ~= "string" or #args.name == 0 or #args.name > 40 then return false end
    for _, key in ipairs({ "x1", "y1", "x2", "y2", "z" }) do
        if type(args[key]) ~= "number" then return false end
    end
    if math.abs(args.x2 - args.x1) + 1 > AREA_MAX_SIDE then return false end
    if math.abs(args.y2 - args.y1) + 1 > AREA_MAX_SIDE then return false end
    return true
end

local AREA_COMMANDS = { AddArea = true, RemoveArea = true, RenameArea = true }

local function onClientCommand(module, command, player, args)
    if module ~= MODULE then return end
    if player == nil then return end

    if AREA_COMMANDS[command] then
        if not isAreaWellFormed(command, args) then return end
        BaseIndex["apply" .. command](args)
        ModData.transmit(MODULE)
        return
    end

    if not isWellFormed(command, args) then return end
    if not isAllowed(player, command, args) then return end

    if command == "register" then
        BaseIndex.applyRegister(args)
    elseif command == "unregister" then
        BaseIndex.applyUnregister(args)
    else
        return
    end

    --[[
    Broadcast the whole table.

    Coarse, and correct. ModData.transmit is the mechanism the game gives us and it works
    at table granularity, so there is no way to send just the delta. Registrations change
    rarely - a handful of times while a base is being set up and then almost never - so the
    cost is irrelevant next to the guarantee that every client ends up with the same table.
    ]]
    ModData.transmit(MODULE)
end

Events.OnClientCommand.Add(onClientCommand)
