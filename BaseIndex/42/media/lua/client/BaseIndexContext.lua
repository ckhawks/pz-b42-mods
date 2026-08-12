--[[
Linking containers to the index.

Registration is explicit rather than automatic, and that is a design decision rather than
a shortcut. Auto-discovery has to answer "where does the base end", which it cannot, and
it has to scan a large area to do it, which is the expensive thing this whole library
exists to avoid. Asking the player to link a crate answers both questions exactly.

It also makes the scope legible: what the terminal can see is what you told it about, so
nothing surprising ever appears in the list.
]]

--[[
No require here.

`require "TimedActions/ISWalkToTimedAction"` was wrong - no such file exists anywhere in
media/lua - and a failed require aborts the rest of the file, which silently took the link
context menu with it. `luautils.walkAdj` is what this actually uses, and luautils is always
loaded.
]]

local function startLink(worldobjects, playerNum, object, containers, label, unlink)
    local playerObj = getSpecificPlayer(playerNum)
    if playerObj == nil then return end

    --[[
    Walk to the container first.

    walkAdj rather than a direct move: the action plays a looting animation at the crate,
    and starting that from across the room looks like the character is wiring thin air.
    It also fails cleanly when the square is unreachable, which is the case that would
    otherwise leave a queued action waiting forever.
    ]]
    local square = object:getSquare()
    if square ~= nil and not luautils.walkAdj(playerObj, square) then return end

    ISTimedActionQueue.add(
        BaseIndexLinkAction:new(playerObj, object, containers, label, unlink)
    )
end

--[[
Every container belonging to the object under the cursor.

Returns a list rather than one container because a fridge is two - a refrigerator and a
freezer - and a stove is an oven and a grill. Linking such an object should wire the whole
appliance in one action, not leave the player wondering why half of it never appears in
the terminal.
]]
local function containersAt(worldobjects)
    for _, object in ipairs(worldobjects) do
        local containers = BaseIndex.containersOf(object)
        if #containers > 0 then return containers, object end
    end
    return nil, nil
end

--[[
When this mod is allowed to touch the context menu at all.

The first version added an option to every container in the world, greyed out with an
explanation when it could not be used. That is defensible in isolation and awful in
practice: a player who has never built a terminal still pays for this mod on every single
right click, forever, in every house they loot.

So relevance is decided before anything is added:

  already linked            always offer to unlink, so a link can always be undone
  a terminal is in range    offer to link, greyed with the reason if something is missing
  otherwise                 add nothing at all

The middle case is what keeps the requirements teachable. Standing in your own base
without a screwdriver, the option is there and says what it needs. Standing in a stranger's
kitchen forty tiles from anything, the menu is untouched.
]]
--[[
An appliance counts as linked when any of its containers is.

Partially linked is possible - link a fridge, then unlink only the freezer through some
future UI - and treating that as unlinked would offer to re-wire the whole thing and
charge for both halves again. Offering to unlink is the safer default: it is the reversible
direction, and re-linking afterwards is one action.
]]
local function relevance(playerObj, containers, object)
    for _, container in ipairs(containers) do
        if BaseIndex.isRegistered(container) then return "linked" end
    end

    if BaseIndex.canRegister(containers[1], object) then return "linkable" end

    return "irrelevant"
end

local function onFillMenu(playerNum, context, worldobjects, test)
    if test then return end

    local containers, object = containersAt(worldobjects)
    if containers == nil then return end

    local playerObj = getSpecificPlayer(playerNum)
    if playerObj == nil then return end

    local state = relevance(playerObj, containers, object)
    if state == "irrelevant" then return end

    local label = tostring(containers[1]:getType())
    if object ~= nil and object:getName() ~= nil then
        label = tostring(object:getName())
    end

    if state == "linked" then
        context:addOption(
            "Unlink from base network", worldobjects, startLink,
            playerNum, object, containers, label, true
        )
        return
    end

    -- The count is named so a fridge does not silently cost two wires.
    local text = "Link to base network"
    if #containers > 1 then
        text = string.format("Link to base network (%d compartments)", #containers)
    end

    local option = context:addOption(
        text, worldobjects, startLink,
        playerNum, object, containers, label, false
    )

    -- Geometry already passed to get here, so anything blocking now is about the player:
    -- a missing tool, missing wire, or too little Electrical. Those are worth stating.
    local blocked = BaseIndexLinkAction.blockedReason(playerObj, false)
    if blocked ~= nil then
        option.notAvailable = true
        local tooltip = ISWorldObjectContextMenu.addToolTip()
        tooltip.description = blocked
        option.toolTip = tooltip
    end
end

Events.OnFillWorldObjectContextMenu.Add(onFillMenu)

-- ==========================================================================

--[[
Console helpers.

Run BaseIndexDebug.dump() after linking a few crates and walking away from them - the
point is to watch entries go stale rather than go to zero.
]]


-- ==========================================================================

BaseIndexDebug = {}

function BaseIndexDebug.dump()
    local refreshed, skipped, changed = BaseIndex.refresh()
    print(string.format(
        "baseindex: refreshed %d, out of range %d, changed %d",
        refreshed, skipped, changed
    ))

    local total = 0
    for fullType, record in pairs(BaseIndex.contents()) do
        total = total + 1
        if total <= 40 then
            print(string.format("  %-40s %d", fullType, record.count))
        end
    end
    print(string.format("baseindex: %d distinct item types across the base", total))
end

function BaseIndexDebug.find(fullType)
    for _, place in ipairs(BaseIndex.locate(fullType)) do
        print(string.format(
            "  %s at %d,%d,%d - %d",
            place.label, place.x, place.y, place.z, place.count
        ))
    end
end
