--[[
Storage terminal.

Built on a result rather than a guess. `ISInventoryPaneContextMenu.getContainers` does no
distance check at all - it reads the loot window's button list directly - and every system
that looks for materials goes through it: crafting, building, the B42 workstation menu,
medicine, camping. So adding buttons to the loot window is the whole mechanism.

Measured in game on 42.20 with a throwaway spike:

    injection OFF: 7 items visible to crafting and building
    injection ON:  73 items visible to crafting and building
    20 of 20 injected containers reached getContainers()

This mod is that hook plus the things that make it a game feature instead of a cheat:
containers have to be wired in deliberately at a cost, terminals have to be built and
powered, and the network only reaches so far.

Registration, scanning and the count cache live in BaseIndex, because the base board and
loadout restock need exactly the same thing and three copies would disagree.
]]

StorageTerminal = StorageTerminal or {}

--[[
Every number in this mod is a sandbox option.

A server admin tuning ranges by editing Lua is an admin who cannot tune ranges, and these
values are exactly the kind of thing different groups will disagree about - a hardcore
server wants a short leash, a builder server wants the whole warehouse.

Read through `opt` at call time rather than into locals at file load, because SandboxVars
does not exist yet when this file is parsed, and a value captured then would be the
default forever regardless of what the admin set.

The defaults below are the values this was actually played with, not guesses.
]]
local DEFAULTS = {
    --[[
    How close the player must stand to a terminal to use the network.

    Deliberately small. The fantasy is a control station you walk up to, not an ambient
    base-wide effect - if the network worked from anywhere the terminal object would be
    decoration and the whole thing would read as a toggle rather than a place.
    ]]
    TerminalRange = 4,

    --[[
    How far a container may be from a terminal and still be wired into it.

    The main balance lever. Without a limit the network is unbounded: wire a crate in a
    warehouse across town and its contents become craftable from your kitchen, which is
    fast travel for items rather than a base upgrade.

    With a limit the terminal becomes a question about base layout. A compact base gets
    everything on one network; a sprawling one has to choose what is worth wiring, or run
    a second terminal and link the two.
    ]]
    LinkRange = 25,

    --[[
    How far apart two terminals must be, and how far apart they may be while still forming
    one network.

    The gap between these two is the whole multi-floor answer. Closer than Spacing is
    refused, so a player cannot paper a room with terminals and delete the range gate.
    Within NetworkRange of each other - including across floors - they chain into one
    network, so standing at either reaches every container on both.

    Vertical is what makes this worth having: a two storey base cannot be one network
    under a flat same-floor rule, because a run of cable up a staircase is exactly the
    thing such a rule pretends does not exist.
    ]]
    TerminalSpacing = 20,
    NetworkRange = 30,

    --[[
    What one storey costs in tiles of cable.

    Three rather than one, so a tower block is not cheaper to wire than a bungalow with
    the same footprint.
    ]]
    FloorCost = 3,

    -- Whether the terminal needs electricity at all. Off makes it a pure convenience mod,
    -- which some groups will want and which is not a decision this mod should make for
    -- them.
    RequirePower = true,
}

local function opt(name)
    local vars = SandboxVars and SandboxVars.StorageTerminal
    local value = vars and vars[name]
    if value == nil then return DEFAULTS[name] end
    return value
end

StorageTerminal.opt = opt

local MOD_DATA_KEY = "StorageTerminal"

local lastReason = "Not checked yet"

-- Forward declaration. `mutate` is defined further down, but removeBrokenTerminals above
-- it needs to call it, and a local only becomes visible to closures defined after it.
local mutate

-- ==========================================================================
-- Terminals
-- ==========================================================================

local function store()
    local data = ModData.getOrCreate(MOD_DATA_KEY)
    data.terminals = data.terminals or {}
    return data
end

--[[
Register the table at load time, for the same reason BaseIndex does.

A lazy getOrCreate on first use writes fine and reads back empty after a reload, because
nothing has associated the saved table with this key. OnInitGlobalModData fires on both a
new game and a load, which is the hook that does.
]]
local function initModData(isNewGame)
    -- Unconditional. See the long note in BaseIndex.lua: an isNewGame guard means a mod
    -- added to an existing save never registers its key and never persists.
    ModData.getOrCreate(MOD_DATA_KEY)
    if isClient() then
        ModData.request(MOD_DATA_KEY)
    end
end

Events.OnInitGlobalModData.Add(initModData)

local function terminalKey(x, y, z)
    return string.format("%d,%d,%d", x, y, z)
end

-- Straight line distance, with each storey weighted by the FloorCost option.
local function distance3(ax, ay, az, bx, by, bz)
    local dx, dy = ax - bx, ay - by
    local dz = (az - bz) * opt("FloorCost")
    return math.sqrt(dx * dx + dy * dy + dz * dz)
end

function StorageTerminal.conflictingTerminal(x, y, z)
    for _, terminal in pairs(store().terminals) do
        local distance = distance3(x, y, z, terminal.x, terminal.y, terminal.z)
        if distance < opt("TerminalSpacing") then return terminal, distance end
    end
    return nil
end

--[[
Applying a terminal change, shared by singleplayer and the server command handler.

Same reasoning as BaseIndex: one implementation, so the two paths cannot drift on what a
key looks like. The spacing rule is enforced here rather than only in the menu, because
the menu check is a client-side courtesy and a server has to assume a client may send
anything.
]]
function StorageTerminal.applyAdd(args)
    if StorageTerminal.conflictingTerminal(args.x, args.y, args.z) ~= nil then return false end
    store().terminals[terminalKey(args.x, args.y, args.z)] = {
        x = args.x, y = args.y, z = args.z, enabled = true, sprite = args.sprite,
    }
    return true
end

--[[
Whether the object a terminal was built on is still on its square.

Matched by sprite name, which is what distinguishes "the TV is still here" from "something
is on this tile". Returns true when the chunk is not loaded: absence of evidence is not
evidence the appliance was destroyed, and treating an unloaded chunk as a dead terminal
would break every terminal the moment a player walked away from it.
]]
function StorageTerminal.objectPresent(terminal)
    local cell = getCell()
    local square = cell and cell:getGridSquare(terminal.x, terminal.y, terminal.z)
    if square == nil then return true end

    local objects = square:getObjects()
    for i = 0, objects:size() - 1 do
        local sprite = objects:get(i):getSprite()
        if sprite ~= nil and tostring(sprite:getName()) == terminal.sprite then
            return true
        end
    end
    return false
end

--[[
Terminals whose object is confirmed gone, for the window to offer cleaning up.

Reported rather than auto-deleted, for the same reason broken container links are: the
check is a heuristic over streaming world state, and silently destroying a player's
terminal because a chunk misbehaved is unrecoverable.
]]
function StorageTerminal.brokenTerminals()
    local broken = {}
    for _, terminal in pairs(store().terminals) do
        if terminal.sprite ~= nil and not StorageTerminal.objectPresent(terminal) then
            broken[#broken + 1] = terminal
        end
    end
    return broken
end

function StorageTerminal.removeBrokenTerminals()
    local removed = 0
    for _, terminal in ipairs(StorageTerminal.brokenTerminals()) do
        mutate("Remove", { x = terminal.x, y = terminal.y, z = terminal.z })
        removed = removed + 1
    end
    return removed
end

function StorageTerminal.applyRemove(args)
    store().terminals[terminalKey(args.x, args.y, args.z)] = nil
    return true
end

function StorageTerminal.applySetEnabled(args)
    local terminal = store().terminals[terminalKey(args.x, args.y, args.z)]
    if terminal == nil then return false end
    terminal.enabled = args.enabled and true or false
    return true
end

local function describe(object)
    if object == nil then return nil end

    -- The sprite name is recorded so the terminal can later tell whether the appliance it
    -- was built on is still there. It travels in the command payload because the server
    -- never sees the client's IsoObject.
    local sprite = object:getSprite()

    return {
        x = math.floor(object:getX()),
        y = math.floor(object:getY()),
        z = math.floor(object:getZ()),
        sprite = sprite ~= nil and tostring(sprite:getName()) or nil,
    }
end

--[[
Route a terminal change through the server when there is one.

Terminals are shared state that everyone on the server depends on - one player switching
one off changes what another player's window can reach - so the server owns them for the
same reason it owns registrations.
]]
mutate = function(command, args)
    if args == nil then return end

    if isClient() then
        sendClientCommand(getPlayer(), "StorageTerminal", command, args)
        -- Applied locally as well so the acting player gets immediate feedback; the
        -- server's broadcast overwrites it a moment later.
        StorageTerminal["apply" .. command](args)
        return
    end

    StorageTerminal["apply" .. command](args)
    ModData.transmit(MOD_DATA_KEY)
end

function StorageTerminal.addTerminal(object)
    mutate("Add", describe(object))
end

function StorageTerminal.removeTerminal(object)
    mutate("Remove", describe(object))
end

function StorageTerminal.terminalAt(object)
    if object == nil then return nil end
    return store().terminals[terminalKey(
        math.floor(object:getX()), math.floor(object:getY()), math.floor(object:getZ())
    )]
end

function StorageTerminal.isTerminal(object)
    return StorageTerminal.terminalAt(object) ~= nil
end

--[[
The manual switch.

Asked for so a base can be shut down deliberately rather than only by running the
generator dry. It also matters in multiplayer, where "someone left the network on and
drained the fuel" is otherwise a real argument.

Off is stored per terminal, not per network, so one wing can be powered down while another
keeps running.
]]
function StorageTerminal.setEnabled(object, enabled)
    local args = describe(object)
    if args == nil then return end
    args.enabled = enabled and true or false
    mutate("SetEnabled", args)
end

-- ==========================================================================
-- Networks
-- ==========================================================================

--[[
Every terminal reachable from this one by cable, as a connected component.

A flood fill rather than a simple radius: three terminals in a line, each within
NETWORK_RANGE of the next, are one network even though the ends are further apart than the
range. That is how cable actually behaves, and it means a long base can be covered by
chaining terminals rather than by one absurd radius.

The set is small - a base has a handful of terminals, not hundreds - so the naive O(n^2)
sweep per hop is cheaper than any structure that would replace it.
]]
local function networkFrom(root)
    local network = { root }
    local seen = { [terminalKey(root.x, root.y, root.z)] = true }
    local frontier = { root }

    while #frontier > 0 do
        local current = table.remove(frontier)
        for key, candidate in pairs(store().terminals) do
            if not seen[key] then
                local distance = distance3(
                    current.x, current.y, current.z,
                    candidate.x, candidate.y, candidate.z
                )
                if distance <= opt("NetworkRange") then
                    seen[key] = true
                    network[#network + 1] = candidate
                    frontier[#frontier + 1] = candidate
                end
            end
        end
    end

    return network
end

--[[
Whether the player can use the network right now, and why not when they cannot.

The reason is returned alongside the verdict because "nothing happened" is the worst
possible feedback for a feature whose whole effect is that a list gets longer. A player
whose generator ran dry should be told that, not left wondering whether the mod broke.

Power and the switch are checked on the terminal the player is standing at, not across the
network. Walking to a dead console and being told the network is fine somewhere else would
be worse than useless.
]]
local function reachableTerminal(playerObj)
    if playerObj == nil then return nil, "No player" end

    local px, py, pz = playerObj:getX(), playerObj:getY(), playerObj:getZ()
    local anyTerminal, anyInRange = false, false

    for _, terminal in pairs(store().terminals) do
        anyTerminal = true
        if math.floor(pz) == terminal.z then
            local dx = px - (terminal.x + 0.5)
            local dy = py - (terminal.y + 0.5)
            if (dx * dx + dy * dy) <= (opt("TerminalRange") * opt("TerminalRange")) then
                anyInRange = true

                if terminal.enabled == false then
                    return nil, "Terminal is switched off"
                end

                local cell = getCell()
                local square = cell and cell:getGridSquare(terminal.x, terminal.y, terminal.z)
                if square == nil then return nil, "Terminal square is not loaded" end

                --[[
                Power is checked on the terminal's own square, and it takes two calls.

                `haveElectricity()` is *generator* power only. `hasGridPower()` is the city
                grid. The first version checked only the former, which meant the terminal
                reported no power for the entire pre-blackout period - the exact stretch
                where a player is most likely to be building one. Vanilla pairs them the
                same way in ISVehicleMenu.lua:1088 and ISButtonPrompt.lua:520.

                Together they give the progression this should follow: free while the grid
                lasts, then a reason to keep fuel in a generator once it dies.
                ]]
                if opt("RequirePower")
                    and not (square:hasGridPower() or square:haveElectricity())
                then
                    return nil, "Terminal has no power"
                end

                --[[
                The object has to still be there.

                Terminals are stored as coordinates, so removing or picking up the TV
                leaves a working terminal at a spot with nothing on it - invisible, and
                impossible to switch off or remove because the context menu has nothing to
                attach to.

                The sprite recorded at designation is what makes this precise: any
                non-floor object would be satisfied by a chair someone pushed onto the
                tile, whereas the sprite says it is the same appliance.

                Terminals designated before sprites were recorded have no sprite stored,
                and are grandfathered in rather than being declared broken - punishing a
                player for a change in the mod is not a tradeoff worth making.
                ]]
                if terminal.sprite ~= nil and not StorageTerminal.objectPresent(terminal) then
                    return nil, "Terminal is gone. It was removed or destroyed."
                end

                return terminal, nil
            end
        end
    end

    if not anyTerminal then return nil, "No terminal built" end
    if not anyInRange then return nil, "Not near a terminal" end
    return nil, "Unreachable"
end

function StorageTerminal.status()
    local terminal, reason = reachableTerminal(getSpecificPlayer(0))
    return terminal ~= nil, reason or "ok"
end

--[[
Whether the player is physically standing at a terminal, ignoring power and the switch.

Separate from `status` because the two answer different questions and the window treats
them differently. Walking away means you left the console, so the window should close.
A dead generator means the console is in front of you but not working, so the window
should stay open and say so - closing it there would hide the only explanation the player
is going to get.

Returned as a function rather than by string-matching `status`'s reason, because a caller
comparing prose to decide behaviour breaks the moment the wording changes.
]]
function StorageTerminal.inRange(playerObj)
    if playerObj == nil then return false end

    local px, py, pz = playerObj:getX(), playerObj:getY(), playerObj:getZ()
    for _, terminal in pairs(store().terminals) do
        if math.floor(pz) == terminal.z then
            local dx = px - (terminal.x + 0.5)
            local dy = py - (terminal.y + 0.5)
            if (dx * dx + dy * dy) <= (opt("TerminalRange") * opt("TerminalRange")) then
                return true
            end
        end
    end
    return false
end

--[[
Whether a point is wired into a given network.

Same floor as *some* terminal in the network, within opt("LinkRange") of it. The floor rule is
kept for containers even though terminals themselves link vertically: a crate is wired to
the console on its own floor, and the vertical run is terminal to terminal. That keeps the
mental model simple - cable goes along a floor, and terminals bridge between floors.
]]
local function inNetwork(network, x, y, z)
    for _, terminal in ipairs(network) do
        if terminal.z == z then
            local dx, dy = x - terminal.x, y - terminal.y
            if math.sqrt(dx * dx + dy * dy) <= opt("LinkRange") then return true end
        end
    end
    return false
end

-- ==========================================================================
-- The injection
-- ==========================================================================

local function inject(inventoryPage, phase)
    if phase ~= "buttonsAdded" then return end
    if inventoryPage.onCharacter then return end

    local playerObj = getSpecificPlayer(inventoryPage.player)
    local terminal, reason = reachableTerminal(playerObj)
    lastReason = reason or "ok"
    if terminal == nil then return end

    local network = networkFrom(terminal)

    local present = {}
    for _, button in ipairs(inventoryPage.backpacks) do
        present[button.inventory] = true
    end

    for _, entry in pairs(BaseIndex.all()) do
        if inNetwork(network, entry.x, entry.y, entry.z) then
            local container = BaseIndex.containerFor(
                string.format("%d,%d,%d,%s", entry.x, entry.y, entry.z, entry.containerType)
            )
            -- nil means the chunk is not loaded, which is ordinary for a large base and
            -- simply means that crate is not transferable right now.
            if container ~= nil and not present[container] then
                present[container] = true
                inventoryPage:addContainerButton(container, nil, entry.label, entry.label)
            end
        end
    end
end

Events.OnRefreshInventoryWindowContainers.Add(inject)

function StorageTerminal.lastReason()
    return lastReason
end

--[[
The containers the player can currently reach through the network.

Used by the terminal window to take items out. Returns key and container together so the
caller can invalidate the index entry after moving something.
]]
function StorageTerminal.reachableContainers()
    local terminal = reachableTerminal(getSpecificPlayer(0))
    if terminal == nil then return {} end

    local network = networkFrom(terminal)
    local found = {}
    for key, entry in pairs(BaseIndex.all()) do
        if inNetwork(network, entry.x, entry.y, entry.z) then
            local container = BaseIndex.containerFor(key)
            if container ~= nil then
                found[#found + 1] = { key = key, container = container, label = entry.label }
            end
        end
    end
    return found
end

-- ==========================================================================
-- Linking rules
-- ==========================================================================

--[[
The guard BaseIndex asks before allowing a link.

Only the geometry lives here. The tool, material and skill requirements are the link
action's business, because they are about the player rather than about the base.
]]
local function canLink(container, object)
    if object == nil then return false, "Nothing to link" end

    local x = math.floor(object:getX())
    local y = math.floor(object:getY())
    local z = math.floor(object:getZ())

    local nearest = nil
    for _, terminal in pairs(store().terminals) do
        if terminal.z == z then
            local dx, dy = x - terminal.x, y - terminal.y
            local distance = math.sqrt(dx * dx + dy * dy)
            if distance <= opt("LinkRange") then return true end
            if nearest == nil or distance < nearest then nearest = distance end
        end
    end

    if nearest == nil then
        return false, "No storage terminal on this floor. Build one here, or link a terminal on this floor to your network."
    end
    return false, string.format(
        "Nearest terminal on this floor is %d tiles away. Cable reaches %d.",
        math.floor(nearest), opt("LinkRange")
    )
end

BaseIndex.registerGuard = canLink

-- ==========================================================================
-- Context menu
-- ==========================================================================

--[[
Building a terminal walks the player there and runs the action, rather than converting the
television on click.

Same reasoning as linking: an instant conversion makes the network feel like a settings
screen, and the walk is also what guarantees the character is actually next to the object
when the animation plays.
]]
local function onMakeTerminal(worldobjects, playerNum, object)
    local playerObj = getSpecificPlayer(playerNum)
    if playerObj == nil then return end

    local square = object:getSquare()
    if square ~= nil and not luautils.walkAdj(playerObj, square) then return end

    ISTimedActionQueue.add(StorageTerminalBuildAction:new(playerObj, object))
end
local function onRemoveTerminal(worldobjects, object) StorageTerminal.removeTerminal(object) end
local function onSwitch(worldobjects, object, enabled) StorageTerminal.setEnabled(object, enabled) end
local function onOpenTerminal(worldobjects, playerNum) StorageTerminalUI.toggle(playerNum) end

local function onFillMenu(playerNum, context, worldobjects, test)
    if test then return end

    --[[
    Existing terminals are found first, on any object.

    Terminals are stored by coordinate, and some were designated on other furniture before
    this mod became television-only. Looking for them regardless of type means those keep
    working and stay removable, rather than becoming invisible fixtures nobody can switch
    off - which is the same failure the broken-terminal detection exists to prevent.
    ]]
    local object, terminal = nil, nil
    for _, candidate in ipairs(worldobjects) do
        local square = candidate:getSquare()
        if square ~= nil and square:getFloor() ~= candidate then
            local existing = StorageTerminal.terminalAt(candidate)
            if existing ~= nil then
                object, terminal = candidate, existing
                break
            end
        end
    end

    --[[
    Nothing else in the world may become a terminal except a television.

    This is what fixes the menu clutter properly. The earlier attempts - grey out the
    option everywhere, or require a screwdriver in inventory - both still meant this mod
    inspected and often added to the menu of every object in Knox County. A type check
    means the code returns immediately on the overwhelming majority of right clicks and
    the option appears in exactly one place a player would look for it.

    A television is also the right object for the fiction: it already has a screen, it
    already needs power, and a base's TV becoming its console reads as scavenging rather
    than as a mod bolting a new UI onto a filing cabinet.
    ]]
    if terminal == nil then
        for _, candidate in ipairs(worldobjects) do
            if instanceof(candidate, "IsoTelevision") then
                object = candidate
                break
            end
        end
    end

    if object == nil then return end

    --[[
    An existing terminal owns its menu. Three options on one specific object is not
    clutter - that object is the feature.
    ]]
    if terminal ~= nil then
        context:addOption("Open storage terminal", worldobjects, onOpenTerminal, playerNum)
        if terminal.enabled == false then
            context:addOption("Switch terminal on", worldobjects, onSwitch, object, true)
        else
            context:addOption("Switch terminal off", worldobjects, onSwitch, object, false)
        end
        context:addOption("Remove storage terminal", worldobjects, onRemoveTerminal, object)
        return
    end

    local playerObj = getSpecificPlayer(playerNum)
    if playerObj == nil then return end

    -- Greyed rather than hidden when something is missing: the player has picked a
    -- television and clearly intends to build one, so they deserve to know why not here.
    local option = context:addOption(
        "Convert this TV into a storage terminal", worldobjects, onMakeTerminal,
        playerNum, object
    )

    --[[
    Position is checked before parts.

    Two reasons can apply at once and only one fits on a tooltip. Being too close to
    another terminal is the one the player cannot fix by looting, so it goes first.
    ]]
    local blocked = nil

    local _, distance = StorageTerminal.conflictingTerminal(
        math.floor(object:getX()), math.floor(object:getY()), math.floor(object:getZ())
    )
    if distance ~= nil then
        blocked = string.format(
            "Another terminal is %d tiles away. They must be at least %d apart.",
            math.floor(distance), opt("TerminalSpacing")
        )
    else
        blocked = StorageTerminalBuildAction.blockedReason(playerObj)
    end

    if blocked ~= nil then
        option.notAvailable = true
        local tooltip = ISWorldObjectContextMenu.addToolTip()
        tooltip.description = blocked
        option.toolTip = tooltip
    end
end

Events.OnFillWorldObjectContextMenu.Add(onFillMenu)
