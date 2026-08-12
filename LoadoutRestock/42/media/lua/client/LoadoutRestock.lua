--[[
Loadout restock.

Save what you are wearing, holding and carrying as a named loadout, then refill it from
whatever containers you can currently reach.

The idea it is built on: **the game already knows what "reachable" means.**
`ISInventoryPaneContextMenu.getContainers(character)` returns the containers the player can
act on right now, and it does that by reading the loot window's button list rather than by
measuring distance. So this mod never scans squares, never measures range, and needs no
opinion about how far an arm reaches.

It also means the Storage Terminal integration is free. When that mod injects networked
containers into the loot window, they appear in `getContainers` too, so standing at a
terminal restocks from the entire base network with no code here knowing the terminal
exists.

There is no capture form to fill in. A loadout is a snapshot of a working kit, so the way
to define one is to assemble it and press save.
]]

LoadoutRestock = LoadoutRestock or {}

local MOD_DATA_KEY = "LoadoutRestock"

-- ==========================================================================
-- Storage
-- ==========================================================================

--[[
Presets are keyed by username inside one global table.

Global rather than per-character ModData, because the entire point of a saved loadout is
that you rebuild it after dying, and per-character storage evaporates at exactly the moment
the feature becomes useful.

Keyed by username so a multiplayer server does not merge everyone's loadouts into one list.
]]
local function store()
    local data = ModData.getOrCreate(MOD_DATA_KEY)
    data.presets = data.presets or {}
    return data
end

local function initModData(isNewGame)
    -- Unconditional, matching forageClient.lua:7. Guarding on isNewGame means a mod added
    -- to an existing save never registers its key and never persists. See the note in
    -- LoadoutRestockServer.lua.
    ModData.getOrCreate(MOD_DATA_KEY)
    if isClient() then
        ModData.request(MOD_DATA_KEY)
    end
end

Events.OnInitGlobalModData.Add(initModData)

local function usernameOf(playerObj)
    local name = playerObj:getUsername()
    if name == nil or name == "" then return "player" end
    return tostring(name)
end

function LoadoutRestock.all(playerObj)
    local presets = store().presets
    local key = usernameOf(playerObj)
    presets[key] = presets[key] or {}
    return presets[key]
end

function LoadoutRestock.get(playerObj, name)
    return LoadoutRestock.all(playerObj)[name]
end

function LoadoutRestock.delete(playerObj, name)
    LoadoutRestock.all(playerObj)[name] = nil
    if isClient() then ModData.transmit(MOD_DATA_KEY) end
end

-- ==========================================================================
-- What the player currently has
-- ==========================================================================

--[[
Split the player's belongings into the three things a loadout describes.

Worn and held are recorded as ordered lists of types rather than counts, because wearing
two of the same jacket is not a thing and the order is what a restock replays.

Carried is counted by type, because "six water bottles" is a quantity and nothing about
which particular bottle matters.

Bags are the subtle case. An equipped backpack is *worn*, and its contents are *carried* -
so a loadout that says "this bag with ten bandages in it" is expressed as one worn bag plus
ten carried bandages, which is also exactly how a restock should rebuild it.
]]
function LoadoutRestock.survey(playerObj)
    local worn, held, carried = {}, {}, {}
    local wornSet = {}

    local wornItems = playerObj:getWornItems()
    if wornItems ~= nil then
        for i = 0, wornItems:size() - 1 do
            local entry = wornItems:get(i)
            local item = entry ~= nil and entry:getItem() or nil
            if item ~= nil then
                worn[#worn + 1] = tostring(item:getFullType())
                wornSet[item] = true
            end
        end
    end

    local primary = playerObj:getPrimaryHandItem()
    local secondary = playerObj:getSecondaryHandItem()
    if primary ~= nil then
        held.primary = tostring(primary:getFullType())
        wornSet[primary] = true
    end
    if secondary ~= nil then
        held.secondary = tostring(secondary:getFullType())
        wornSet[secondary] = true
    end

    --[[
    getItems() on the player inventory is recursive through equipped bags in practice,
    which is what makes "carried" mean what a player means by it. Worn and held items are
    subtracted because they are described separately - counting a worn jacket as carried
    would make a restock try to fetch a second one.
    ]]
    local items = playerObj:getInventory():getItems()
    for i = 0, items:size() - 1 do
        local item = items:get(i)
        if not wornSet[item] then
            local fullType = tostring(item:getFullType())
            carried[fullType] = (carried[fullType] or 0) + 1
        end
    end

    return worn, held, carried
end

--[[
Capture the current state as a named loadout.

Overwrites silently if the name exists. Re-saving under the same name after tweaking a kit
is the common case, and a confirmation prompt for it would be friction on the action people
take most.
]]
function LoadoutRestock.capture(playerObj, name)
    local worn, held, carried = LoadoutRestock.survey(playerObj)

    local names = {}
    for fullType in pairs(carried) do names[#names + 1] = fullType end
    table.sort(names)

    LoadoutRestock.all(playerObj)[name] = {
        name = name,
        worn = worn,
        held = held,
        carried = carried,
        -- Kept so the UI can list contents in a stable order without re-sorting a hash
        -- every frame.
        carriedOrder = names,
    }

    if isClient() then ModData.transmit(MOD_DATA_KEY) end
end

-- ==========================================================================
-- What is missing
-- ==========================================================================

--[[
Compare a preset against what the player has right now.

Returns three things, because the UI wants all of them and computing them separately would
mean surveying three times:

  missing   type to count still needed
  extra     type to count carried beyond the loadout
  wearing   whether each worn and held slot is already correct

Extra is not "wrong" - it is what the dump action offers to put back, and what the UI greys
rather than flags. A loadout is a floor, not a straitjacket.
]]
function LoadoutRestock.delta(playerObj, preset)
    local worn, held, carried = LoadoutRestock.survey(playerObj)

    local missing, extra = {}, {}

    for fullType, want in pairs(preset.carried or {}) do
        local have = carried[fullType] or 0
        if have < want then missing[fullType] = want - have end
    end

    for fullType, have in pairs(carried) do
        local want = (preset.carried or {})[fullType] or 0
        if have > want then extra[fullType] = have - want end
    end

    local wornNow = {}
    for _, fullType in ipairs(worn) do wornNow[fullType] = true end

    local slots = {}
    for _, fullType in ipairs(preset.worn or {}) do
        slots[#slots + 1] = { fullType = fullType, kind = "worn", satisfied = wornNow[fullType] == true }
    end
    if preset.held and preset.held.primary then
        slots[#slots + 1] = {
            fullType = preset.held.primary, kind = "primary",
            satisfied = held.primary == preset.held.primary,
        }
    end
    if preset.held and preset.held.secondary then
        slots[#slots + 1] = {
            fullType = preset.held.secondary, kind = "secondary",
            satisfied = held.secondary == preset.held.secondary,
        }
    end

    return missing, extra, slots
end

-- ==========================================================================
-- Sourcing
-- ==========================================================================

--[[
Containers worth taking from.

`getContainers` includes the player's own inventory and their bags, which must be excluded:
moving an item from your backpack into your inventory satisfies nothing, and would let a
restock claim success while fetching from itself.

`isInCharacterInventory` is the same test ISInventoryTransferAction uses at line 646 to
decide whether a transfer counts as leaving the player, so this agrees with the game about
what "somewhere else" means.
]]
function LoadoutRestock.sources(playerObj)
    local sources, seen = {}, {}

    local function consider(container)
        if container == nil or seen[container] then return end
        if container:isInCharacterInventory(playerObj) then return end
        seen[container] = true
        sources[#sources + 1] = container
    end

    --[[
    The loot window is rebuilt before it is read.

    `getContainers` does not compute anything - it reports the loot window's button list,
    and that list is only rebuilt when `refreshBackpacks()` runs. A storage terminal injects
    its networked containers *during* that rebuild, so if the window has not refreshed since
    the player walked into terminal range, the network is simply absent from the answer.

    That was the bug: restock found nothing in a freezer that the terminal could plainly
    see, because the terminal computes its network directly while this read a stale window.
    ]]
    local loot = getPlayerLoot(playerObj:getPlayerNum())
    if loot ~= nil and loot.inventoryPane ~= nil then
        local page = loot.inventoryPane.inventoryPage
        if page ~= nil then page:refreshBackpacks() end
    end

    local all = ISInventoryPaneContextMenu.getContainers(playerObj)
    for i = 0, (all and all:size() or 0) - 1 do
        consider(all:get(i))
    end

    --[[
    Then ask the terminal directly, if one is installed.

    Belt and braces, and it removes the dependency on refresh timing entirely rather than
    just narrowing the window. `reachableContainers` computes the network from terminal
    positions and registrations, so it is correct regardless of what any UI has done.

    Guarded on the global existing, because this mod does not require the terminal and has
    to keep working on its own.
    ]]
    if StorageTerminal ~= nil and StorageTerminal.reachableContainers ~= nil then
        for _, entry in ipairs(StorageTerminal.reachableContainers()) do
            consider(entry.container)
        end
    end

    return sources
end
