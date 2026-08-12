--[[
Server side of the storage terminal.

Terminals are shared state - one player switching one off changes what another player's
window can reach - so the server owns the table for the same reason it owns registrations.
See BaseIndexServer.lua for the full reasoning.

Note that the spacing rule is re-checked here, inside applyAdd, rather than trusted from
the client. The menu's greyed-out option is a courtesy to the player; the server has to
assume a client can send whatever it likes.
]]

local MODULE = "StorageTerminal"

-- Created server side because that is the side that writes global_mod_data.bin. See the
-- longer note in BaseIndexServer.lua.
Events.OnInitGlobalModData.Add(function(isNewGame)
    ModData.getOrCreate(MODULE)
end)

local function isWellFormed(args)
    if type(args) ~= "table" then return false end
    if type(args.x) ~= "number" or type(args.y) ~= "number" or type(args.z) ~= "number" then
        return false
    end
    if args.enabled ~= nil and type(args.enabled) ~= "boolean" then return false end

    -- Sprite names are matched against world objects and rendered nowhere, but an
    -- unbounded string from a client still has no business being stored and broadcast.
    if args.sprite ~= nil and (type(args.sprite) ~= "string" or #args.sprite > 128) then
        return false
    end
    return true
end

local COMMANDS = {
    Add = function(args) return StorageTerminal.applyAdd(args) end,
    Remove = function(args) return StorageTerminal.applyRemove(args) end,
    SetEnabled = function(args) return StorageTerminal.applySetEnabled(args) end,
}

local function onClientCommand(module, command, player, args)
    if module ~= MODULE then return end
    if player == nil then return end
    if not isWellFormed(args) then return end

    local handler = COMMANDS[command]
    if handler == nil then return end

    -- Only broadcast when something actually changed. A rejected add - too close to an
    -- existing terminal - should not cost every client a table sync.
    if handler(args) then
        ModData.transmit(MODULE)
    end
end

Events.OnClientCommand.Add(onClientCommand)
