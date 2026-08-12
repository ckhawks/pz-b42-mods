--[[
Running a restock.

Two phases, and the split matters. Fetching is a queue of transfers; equipping can only
happen once those transfers have actually landed, because you cannot wear a jacket that is
still in a crate.

The naive version queues both up front and fails: `ISWearClothing:new(character, item)`
captures the item at queue time, and at that moment the item is still in the container.
So equipping is deferred behind a marker action that runs after the transfers and only
then looks at what the player is holding.
]]

require "TimedActions/ISBaseTimedAction"
require "TimedActions/ISInventoryTransferAction"
require "TimedActions/ISWearClothing"
require "TimedActions/ISEquipWeaponAction"

-- ==========================================================================
-- Phase two, deferred
-- ==========================================================================

LoadoutEquipAction = ISBaseTimedAction:derive("LoadoutEquipAction")

function LoadoutEquipAction:isValid() return true end
function LoadoutEquipAction:update() end
function LoadoutEquipAction:start() end
function LoadoutEquipAction:stop() ISBaseTimedAction.stop(self) end

--[[
Find an item of this type that the player is now carrying.

By type rather than by identity, deliberately. The transfer queue may have moved a
different instance than the one that existed when the restock was planned - someone else
took the first one, a stack resolved differently - and for a loadout any bandage is a
bandage.
]]
local function findCarried(playerObj, fullType)
    local items = playerObj:getInventory():getItems()
    for i = 0, items:size() - 1 do
        local item = items:get(i)
        if tostring(item:getFullType()) == fullType then return item end
    end
    return nil
end

local function isWearing(playerObj, fullType)
    local worn = playerObj:getWornItems()
    if worn == nil then return false end
    for i = 0, worn:size() - 1 do
        local entry = worn:get(i)
        local item = entry ~= nil and entry:getItem() or nil
        if item ~= nil and tostring(item:getFullType()) == fullType then return true end
    end
    return false
end

function LoadoutEquipAction:perform()
    local playerObj = self.character
    local preset = self.preset

    --[[
    Clothing first, then hands.

    Wearing is the slower animation and the one most likely to be interrupted, and a
    player who gets attacked halfway through a restock is better off having been given
    their armour than their axe - the axe is one click, the jacket is not.
    ]]
    for _, fullType in ipairs(preset.worn or {}) do
        if not isWearing(playerObj, fullType) then
            local item = findCarried(playerObj, fullType)
            if item ~= nil then
                ISTimedActionQueue.add(ISWearClothing:new(playerObj, item))
            end
        end
    end

    local held = preset.held or {}

    if held.primary ~= nil then
        local current = playerObj:getPrimaryHandItem()
        if current == nil or tostring(current:getFullType()) ~= held.primary then
            local item = findCarried(playerObj, held.primary)
            if item ~= nil then
                ISTimedActionQueue.add(ISEquipWeaponAction:new(playerObj, item, 25, true))
            end
        end
    end

    if held.secondary ~= nil then
        local current = playerObj:getSecondaryHandItem()
        if current == nil or tostring(current:getFullType()) ~= held.secondary then
            local item = findCarried(playerObj, held.secondary)
            if item ~= nil then
                ISTimedActionQueue.add(ISEquipWeaponAction:new(playerObj, item, 25, false))
            end
        end
    end

    ISBaseTimedAction.perform(self)
end

function LoadoutEquipAction:new(character, preset)
    local o = ISBaseTimedAction.new(self, character)
    o.preset = preset
    -- A marker, not work. It exists purely to occupy a position in the queue after the
    -- transfers, so it should cost no visible time.
    o.maxTime = 1
    return o
end

-- ==========================================================================
-- Phase one, and the entry point
-- ==========================================================================

--[[
Fetch everything missing, then equip.

Containers are visited in whatever order `getContainers` reports, which is roughly nearest
first, and each is drained of the wanted type before moving on. That is deliberately not
optimal - a smarter planner would prefer the container holding the most - but the ordering
the game gives is the one that matches what the player sees in their loot window, and
surprising them by walking somewhere else to fetch a bandage is worse than one extra stop.

Weight is not pre-checked. ISInventoryTransferAction refuses when the player is full, so a
duplicate check here would be a second thing to keep in agreement with the game.

Returns what it queued and what it could not find, so the caller can say so - a restock
that silently comes up four bandages short is the failure mode this whole feature exists to
prevent.
]]
function LoadoutRestock.restock(playerObj, preset)
    local missing = LoadoutRestock.delta(playerObj, preset)
    local sources = LoadoutRestock.sources(playerObj)

    local fetched, unavailable = 0, {}

    for fullType, wanted in pairs(missing) do
        local remaining = wanted

        for _, container in ipairs(sources) do
            if remaining <= 0 then break end

            local items = container:getItems()
            for i = 0, items:size() - 1 do
                if remaining <= 0 then break end
                local item = items:get(i)
                if tostring(item:getFullType()) == fullType then
                    ISTimedActionQueue.add(ISInventoryTransferAction:new(
                        playerObj, item, container, playerObj:getInventory()
                    ))
                    remaining = remaining - 1
                    fetched = fetched + 1
                end
            end
        end

        if remaining > 0 then unavailable[fullType] = remaining end
    end

    --[[
    The equip pass is queued even when nothing was fetched.

    A player who already owns everything but is holding the wrong weapon still expects
    pressing Restock to fix their hands.
    ]]
    ISTimedActionQueue.add(LoadoutEquipAction:new(playerObj, preset))

    return fetched, unavailable
end

--[[
Put back everything the loadout does not ask for.

The mirror of restock, and the same conservative rule the storage terminal uses: an item is
only deposited into a container that already holds that type. Nothing is filed somewhere
new, because a sorter that guesses will eventually put ammunition in the food crate.

Worn, held and favourited items are never touched.
]]
function LoadoutRestock.dumpExtra(playerObj, preset)
    local _, extra = LoadoutRestock.delta(playerObj, preset)
    local sources = LoadoutRestock.sources(playerObj)

    local destination = {}
    for _, container in ipairs(sources) do
        local items = container:getItems()
        for i = 0, items:size() - 1 do
            local fullType = tostring(items:get(i):getFullType())
            if destination[fullType] == nil then destination[fullType] = container end
        end
    end

    local protected = {}
    local worn = playerObj:getWornItems()
    if worn ~= nil then
        for i = 0, worn:size() - 1 do
            local entry = worn:get(i)
            if entry ~= nil and entry:getItem() ~= nil then protected[entry:getItem()] = true end
        end
    end
    if playerObj:getPrimaryHandItem() then protected[playerObj:getPrimaryHandItem()] = true end
    if playerObj:getSecondaryHandItem() then protected[playerObj:getSecondaryHandItem()] = true end

    -- Snapshotted before queueing, so the collection is not modified underneath the loop.
    local candidates = {}
    local items = playerObj:getInventory():getItems()
    for i = 0, items:size() - 1 do candidates[#candidates + 1] = items:get(i) end

    local queued = 0
    for _, item in ipairs(candidates) do
        local fullType = tostring(item:getFullType())
        local surplus = extra[fullType] or 0

        if surplus > 0
            and not protected[item]
            and not item:isFavorite()
            and not item:isEquipped()
        then
            local container = destination[fullType]
            if container ~= nil and container:hasRoomFor(playerObj, item) then
                ISTimedActionQueue.add(ISInventoryTransferAction:new(
                    playerObj, item, playerObj:getInventory(), container
                ))
                extra[fullType] = surplus - 1
                queued = queued + 1
            end
        end
    end

    return queued
end
