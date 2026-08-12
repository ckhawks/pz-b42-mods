--[[
Server side of the base board.

The task list is the most contended state in any of these mods - two people claiming jobs is
the normal case, not an edge case - so the server owns it. See BaseIndexServer.lua for the
full reasoning on why client-authoritative ModData writes lose edits.

Created here as well as client side because the server is what writes
`global_mod_data.bin`, and unconditionally rather than on `isNewGame`, because that guard
means a mod added to an existing save never registers its key at all.
]]

local MODULE = "BaseBoard"

Events.OnInitGlobalModData.Add(function(isNewGame)
    ModData.getOrCreate(MODULE)

    --[[
    Temporary diagnostic.

    The key is absent from global_mod_data.bin while BaseIndex, StorageTerminal and
    LoadoutRestock - registered exactly this way - are all present. Rather than guess at a
    fourth explanation, this says whether the hook runs at all and what the table looks
    like when it does. Remove once the cause is known.
    ]]
    local data = ModData.getOrCreate(MODULE)
    local boards, tasks = 0, 0
    for _ in pairs(data.boards or {}) do boards = boards + 1 end
    for _ in pairs(data.tasks or {}) do tasks = tasks + 1 end
    print(string.format(
        "baseboard: server init ran, isNewGame=%s, boards=%d tasks=%d",
        tostring(isNewGame), boards, tasks
    ))
end)

local function isWellFormed(command, args)
    if type(args) ~= "table" then return false end

    if command == "Add" or command == "Remove" then
        return type(args.x) == "number" and type(args.y) == "number" and type(args.z) == "number"
    end

    if command == "AddTask" then
        --[[
        Task text is rendered in every player's window, so it is bounded here rather than
        trusted. An unbounded string from a client is a way to break somebody else's UI.
        ]]
        if type(args.text) ~= "string" then return false end
        if #args.text == 0 or #args.text > 120 then return false end
        if args.by ~= nil and (type(args.by) ~= "string" or #args.by > 64) then return false end
        return true
    end

    if command == "ClearDone" then return true end

    if command == "ToggleClaim" or command == "ToggleDone" or command == "RemoveTask" then
        if type(args.id) ~= "string" or #args.id > 32 then return false end
        if args.by ~= nil and (type(args.by) ~= "string" or #args.by > 64) then return false end
        return true
    end

    if command == "PostSkills" then
        if type(args.by) ~= "string" or #args.by == 0 or #args.by > 64 then return false end
        if type(args.perks) ~= "table" then return false end

        --[[
        A skill sheet is bounded on every axis before it is stored and broadcast.

        This table goes into shared ModData and out to every client, so an unbounded one is
        a way to bloat everyone's save and slow everyone's window. Roughly thirty skills
        exist; fifty is generous headroom without being a hole.
        ]]
        local count = 0
        for name, level in pairs(args.perks) do
            count = count + 1
            if count > 50 then return false end
            if type(name) ~= "string" or #name > 40 then return false end
            if type(level) ~= "number" or level < 0 or level > 10 then return false end
        end
        return true
    end

    return false
end

local COMMANDS = {
    Add = true, Remove = true,
    AddTask = true, ToggleClaim = true, ToggleDone = true,
    ClearDone = true, RemoveTask = true,
    PostSkills = true,
}

local function onClientCommand(module, command, player, args)
    if module ~= MODULE then return end
    if player == nil then return end
    if not COMMANDS[command] then return end
    if not isWellFormed(command, args) then return end

    -- Timestamps come from the server, not the client's payload. They order the list and
    -- date the completion, and a client that supplies its own decides both.
    if command == "AddTask" or command == "ToggleDone" then
        args.at = BaseBoard.now()
    end

    -- Only broadcast when something changed. A refused claim - someone else got there
    -- first - should not cost every client a table sync.
    if BaseBoard["apply" .. command](args) then
        ModData.transmit(MODULE)
    end
end

Events.OnClientCommand.Add(onClientCommand)
