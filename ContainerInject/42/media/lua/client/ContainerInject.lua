--[[
Container inject spike.

The storage terminal design rests on one claim, and this is the smallest thing that
tests it.

`ISInventoryPaneContextMenu.getContainers(character)` in
client/ISUI/ISInventoryPaneContextMenu.lua:2425 does no distance check and no square
scanning. It reads the loot window's button list:

    for i,v in ipairs(getPlayerLoot(playerNum).inventoryPane.inventoryPage.backpacks) do

and that one function is the material source for crafting (ISHandCraftPanel:195,
ISCraftInputItems:9), building (ISBuildPanel:215,318, ISBuildAction:148,
ISBuildingObject:198), the B42 workstation menu (ISEntityBuildMenu:119), medicine
(ISHealthPanel:1042,1763) and camping.

If that is right, then adding a button for a distant container to the loot window makes
every one of those systems see its contents, with no overrides anywhere. That would be
most of the terminal mod, for about forty lines.

This mod adds those buttons and reports what happened. It is a test harness, not a
gameplay mod - there is no power requirement, no linking, and no balance. Do not play a
save you care about with it enabled.
]]

--[[
Tunables.

RADIUS is deliberately larger than vanilla's reach (one to two tiles) and small enough
that a scan is cheap. LIMIT keeps the container button panel from growing past what the
window can scroll.
]]
local RADIUS = 12
local LIMIT = 20

local enabled = true

-- Populated on each injection so report() can say whether the containers it added
-- actually reached getContainers().
local lastInjected = {}

-- ==========================================================================

--[[
Every container within RADIUS of the player, at the player's z level.

getGridSquare returns nil for an unloaded cell rather than erroring, so the nil check is
the whole of the chunk-unloading story at this radius. It matters far more at the scale
the real mod works at, where linked containers can be cells away.

getContainer() rather than getContainerCount()/getContainerByIndex(): the zero-argument
form is the one whose arity is beyond doubt, and this is a spike. The cost is that
multi-container objects like double counters contribute only their first container,
which does not affect what is being tested.
]]
local function nearbyContainers(playerObj)
    local found = {}
    local cell = getCell()
    if cell == nil then return found end

    local px = math.floor(playerObj:getX())
    local py = math.floor(playerObj:getY())
    local pz = math.floor(playerObj:getZ())

    for x = px - RADIUS, px + RADIUS do
        for y = py - RADIUS, py + RADIUS do
            local square = cell:getGridSquare(x, y, pz)
            if square ~= nil then
                local objects = square:getObjects()
                for i = 0, objects:size() - 1 do
                    local container = objects:get(i):getContainer()
                    if container ~= nil then
                        found[#found + 1] = container
                    end
                end
            end
        end
    end
    return found
end

--[[
Add buttons for containers the window does not already have.

Only the loot window is touched. ISInventoryPage.onCharacter is true for the player's
own inventory panel, and injecting there would put crates in the player's bag list,
which is both wrong and confusing to read in the report.

The already-present set is built from the window's own buttons rather than from a list
this mod keeps, because vanilla rebuilds that list from scratch on every refresh and any
cache of ours would be a frame behind.
]]
local function inject(inventoryPage, phase)
    if not enabled then return end
    if phase ~= "buttonsAdded" then return end
    if inventoryPage.onCharacter then return end

    local playerObj = getSpecificPlayer(inventoryPage.player)
    if playerObj == nil then return end

    local present = {}
    for _, button in ipairs(inventoryPage.backpacks) do
        present[button.inventory] = true
    end

    lastInjected = {}
    for _, container in ipairs(nearbyContainers(playerObj)) do
        if #lastInjected >= LIMIT then break end
        if not present[container] then
            present[container] = true

            -- nil texture is the shape vanilla uses for vehicle part containers at
            -- ISInventoryPage.lua:1588, so it is a supported argument rather than a
            -- guess. The label is what distinguishes injected buttons in the UI.
            local label = "REMOTE " .. tostring(container:getType())
            inventoryPage:addContainerButton(container, nil, label, label)
            lastInjected[#lastInjected + 1] = container
        end
    end
end

-- ==========================================================================
-- Reporting
-- ==========================================================================

--[[
Whether the injection propagated.

This is the actual result of the experiment. getContainers() is what crafting and
building call, so if the injected containers appear in its output, every one of those
systems can already see them.
]]
local function report()
    local playerObj = getSpecificPlayer(0)
    if playerObj == nil then
        print("containerinject: no player")
        return
    end

    local loot = getPlayerLoot(0)
    local buttons = loot and loot.inventoryPane.inventoryPage.backpacks or {}
    print(string.format("containerinject: loot window has %d container buttons", #buttons))
    print(string.format("containerinject: injected %d on the last refresh", #lastInjected))

    local containers = ISInventoryPaneContextMenu.getContainers(playerObj)
    local total = containers and containers:size() or 0
    print(string.format("containerinject: getContainers() returned %d", total))

    -- Membership is checked by identity against what was injected, because a count
    -- alone cannot distinguish "the injection propagated" from "the player happened to
    -- be standing next to that many containers anyway".
    local seen = {}
    for i = 0, total - 1 do
        seen[containers:get(i)] = true
    end

    local propagated = 0
    for _, container in ipairs(lastInjected) do
        if seen[container] then propagated = propagated + 1 end
    end

    print(string.format(
        "containerinject: %d of %d injected containers reached getContainers()",
        propagated, #lastInjected
    ))

    if #lastInjected == 0 then
        print("containerinject: nothing was injected - stand near crates outside arm's reach")
    elseif propagated == #lastInjected then
        print("containerinject: PROPAGATED. Crafting and building should now see them.")
    elseif propagated == 0 then
        print("containerinject: NOT propagated. getContainers reads a different list than assumed.")
    else
        print("containerinject: partial. Something is filtering the list.")
    end
end

--[[
Total item count across everything getContainers() reports.

The crafting panel is the real test, but it only shows materials for recipes you can
almost make, so a recipe you cannot see proves nothing. This number moving when you walk
away from a crate, and not moving when the injection is on, is the same answer without
needing the right recipe in front of you.
]]
local function count()
    local playerObj = getSpecificPlayer(0)
    if playerObj == nil then return end
    local containers = ISInventoryPaneContextMenu.getContainers(playerObj)
    local total = 0
    for i = 0, (containers and containers:size() or 0) - 1 do
        total = total + containers:get(i):getItems():size()
    end
    print(string.format("containerinject: %d items visible to crafting and building", total))
end

local function setEnabled(value)
    enabled = value and true or false
    print("containerinject: enabled = " .. tostring(enabled))
    -- The window only picks the change up on its next rebuild.
    local loot = getPlayerLoot(0)
    if loot then loot.inventoryPane.inventoryPage:refreshBackpacks() end
end

-- ==========================================================================

ContainerInject = {
    report = report,
    count = count,
    selfTest = nil, -- assigned below
    enable = function() setEnabled(true) end,
    disable = function() setEnabled(false) end,
    setRadius = function(value) RADIUS = value end,
}

Events.OnRefreshInventoryWindowContainers.Add(inject)

-- ==========================================================================
-- Self test
-- ==========================================================================

--[[
The whole experiment, run without anyone typing into the console.

Everything above can be driven by hand, and should be when the result is in doubt. This
exists because the result is not in doubt yet - nobody has seen it once - and the first
run is worth having without also depending on someone being at the keyboard to trigger it.

Output goes to print(), which lands in Zomboid/console.txt.
]]
local function selfTest()
    print("containerinject: ======== self test ========")

    local loot = getPlayerLoot(0)
    if loot == nil then
        print("containerinject: no loot window yet, self test skipped")
        return
    end

    local page = loot.inventoryPane.inventoryPage

    --[[
    The window is rebuilt explicitly rather than waited for.

    refreshBackpacks is what fires OnRefreshInventoryWindowContainers, and it otherwise
    runs only when something the player does causes it. A test that depends on the player
    having opened a container is a test that reports nothing on an unattended run.
    ]]
    setEnabled(false)
    page:refreshBackpacks()
    print("containerinject: --- injection OFF ---")
    count()
    local baselineButtons = #page.backpacks

    setEnabled(true)
    page:refreshBackpacks()
    print("containerinject: --- injection ON ---")
    count()
    report()

    print(string.format(
        "containerinject: container buttons went %d -> %d",
        baselineButtons, #page.backpacks
    ))
    print("containerinject: ======== end self test ========")
end

ContainerInject.selfTest = selfTest

--[[
Run once, a few seconds after the world is up.

Not on OnGameStart directly: the loot window is constructed as part of the player's UI
and is not reliably there at that moment, and a self test that reports "no loot window"
teaches nothing. Counting ticks is cruder than an event but there is no event for "the
player UI is ready", and being late costs nothing here.
]]
local ticks = 0
local function tickUntilReady()
    ticks = ticks + 1
    if ticks < 600 then return end
    Events.OnTick.Remove(tickUntilReady)
    local ok, err = pcall(selfTest)
    if not ok then print("containerinject: self test failed - " .. tostring(err)) end
end

Events.OnTick.Add(tickUntilReady)
