--[[
Base index.

Three planned mods need the same thing and would otherwise each grow their own copy:

  - the base management board, for supply tallies
  - loadout restock, to know where to fetch from
  - the storage terminal, for everything it does

Written three times they would disagree with each other about what is in the base, which
reads as a bug in all three at once. So this is the one place that answers "which
containers belong to this base, and what is in them".

It provides no UI and changes nothing on its own.

The two facts that shape the whole design:

Chunks unload. getGridSquare returns nil for a cell the game is not simulating, so a
container that was registered three cells away cannot be read while you stand here. The
index therefore stores counts and a timestamp rather than pretending to be live, and a
consumer showing "as of six hours ago" is telling the truth. A whiteboard that says that
is also more in keeping than one that updates itself.

Items are objects, not stacks. Five hundred nails is five hundred InventoryItems, and a
stocked base can hold tens of thousands. So the cache holds counts keyed by full type and
never holds item references - a reference into an unloaded chunk is a leak at best.
]]

BaseIndex = BaseIndex or {}

local MOD_DATA_KEY = "BaseIndex"

-- ==========================================================================
-- Persistence
-- ==========================================================================

--[[
Registrations live in global ModData rather than on the container object.

Object ModData travels with the object, which sounds right until the object is in an
unloaded chunk and there is nothing to read it off. The index has to be able to list
every registration while standing anywhere, so the list is global and each entry names a
location rather than the reverse.

In multiplayer, global ModData is the channel the game already synchronises, so this also
avoids inventing a transport.
]]
local function store()
    local data = ModData.getOrCreate(MOD_DATA_KEY)
    data.containers = data.containers or {}
    return data
end

--[[
Register the table with the global mod data system at load time.

Calling getOrCreate lazily on first use is not enough, and the symptom is that everything
works perfectly until you reload: the table is written into global_mod_data.bin, but
nothing has told the game to hand it back on load, so the first lazy call after loading
creates a fresh empty one and the registrations are gone.

OnInitGlobalModData fires on both a new game and a load, which is what wires the saved
table to this key. Vanilla does the same thing in ProfessionVehicles.lua:343 and
forageClient.lua:7.

In multiplayer the table lives on the server, so a client has to ask for its copy rather
than assume the local one is authoritative.
]]
local function initModData(isNewGame)
    --[[
    getOrCreate unconditionally, and registered on the server side too. Both halves matter
    and each one cost a debugging round.

    The **server** half, because global mod data is written to `global_mod_data.bin` by the
    server; in singleplayer that is the same process, on a real server it is the only one
    that persists anything. Vanilla splits foraging this way: `forageServer.lua` creates,
    `forageClient.lua` requests.

    **Unconditional**, because an `isNewGame` guard means a mod added to an existing save
    never creates its key, never registers it, and never saves. That was diagnosed by
    reading `global_mod_data.bin` directly and finding this key present while a newer mod's
    was absent. `forageClient.lua:7` calls it unconditionally for the same reason;
    `ProfessionVehicles.lua:344` guards it only because that mod genuinely wants a fresh
    table each new game.

    On a load `getOrCreate` returns the restored table rather than replacing it.
    ]]
    ModData.getOrCreate(MOD_DATA_KEY)

    -- On a client the authoritative copy lives on the server, so ask for it rather than
    -- trusting whatever happens to be local.
    if isClient() then
        ModData.request(MOD_DATA_KEY)
    end
end

Events.OnInitGlobalModData.Add(initModData)

--[[
A registration key that survives a save and a chunk reload.

Coordinates plus the container type, not an object reference and not an index into
square:getObjects(). The object list order is not stable across a reload, and an
IsoObject reference is meaningless once its chunk is gone.

The type disambiguates the common case of two containers on one square - a counter with
an overhead cupboard - without depending on ordering.
]]
local function keyFor(x, y, z, containerType)
    return string.format("%d,%d,%d,%s", x, y, z, tostring(containerType))
end

-- ==========================================================================
-- Resolving a registration back to a live container
-- ==========================================================================

--[[
The live container for a registration, or nil if its chunk is not loaded.

nil is an ordinary outcome here, not a failure. Every caller has to handle it, which is
why this returns nil rather than raising: the alternative is that a base larger than the
loaded area cannot be indexed at all.

Only zero-argument getters are called on the objects. Kahlua's overload dispatch throws
uncatchably when an argument list matches no overload, and a spurious getContainerByIndex
in a loop over a whole base would break every later Java call in the session. getObjects
and getContainer are both unambiguous.
]]
--[[
Resolve, and say *why* it failed.

The single most important distinction in this file. A nil container means one of two
completely different things:

  "unloaded"  the chunk is not simulated, the crate is probably fine, keep the cache
  "missing"   the chunk IS loaded and there is no such container, so it was destroyed

The first version collapsed both into nil, which meant a smashed crate kept reporting
stale counts forever and its registration could never be cleaned up. Telling them apart
costs one extra check - did we get a square at all - and is the difference between a
cache and a leak.
]]
--[[
Every container on one object, not just the first.

`getContainer()` returns only the first, and plenty of furniture has more than one: a
fridge is a refrigerator plus a freezer, a stove is an oven plus a grill. Using the
singular getter meant the second half of every such object was invisible - it could not be
linked, and worse, a registration for one would never resolve because the search never
looked past the first.

`getContainerCount()` takes no arguments and `getContainerByIndex(i)` takes an index, which
is the count-and-index shape whose arity is beyond doubt. Vanilla walks fridges this exact
way in ISInventoryPage.lua:1732.
]]
function BaseIndex.containersOf(object)
    local found = {}
    local count = object:getContainerCount()
    if type(count) ~= "number" then return found end
    for i = 0, count - 1 do
        local container = object:getContainerByIndex(i)
        if container ~= nil then found[#found + 1] = container end
    end
    return found
end

local function resolve(entry)
    local cell = getCell()
    if cell == nil then return nil, "unloaded" end

    local square = cell:getGridSquare(entry.x, entry.y, entry.z)
    if square == nil then return nil, "unloaded" end

    local objects = square:getObjects()
    for i = 0, objects:size() - 1 do
        for _, container in ipairs(BaseIndex.containersOf(objects:get(i))) do
            if tostring(container:getType()) == entry.containerType then
                return container, "ok"
            end
        end
    end

    -- The square is loaded and nothing on it matches, so the container is gone.
    return nil, "missing"
end

--[[
How many consecutive confirmed-missing scans before a registration is called broken.

Not one, because a square can be loaded while its objects are still streaming in, and a
single unlucky sample would condemn a perfectly good crate. Three consecutive misses across
separate scans is a state that does not happen transiently.

Held in a plain local rather than in ModData on purpose. It is transient, per-client
observation - persisting it would sync one player's streaming hiccup to everyone, and in
multiplayer two clients disagreeing about a miss count is meaningless noise.
]]
local MISSING_THRESHOLD = 3
local missCounts = {}

--[[
Registrations this client currently believes are dead.

Broken entries are reported, never auto-deleted. A silent deletion is unrecoverable and
this detection is heuristic - a mod that quietly unlinks crates because a chunk misbehaved
would be worse than one that occasionally shows a stale row. The player gets a button.
]]
function BaseIndex.brokenLinks()
    local broken = {}
    for key, entry in pairs(store().containers) do
        if (missCounts[key] or 0) >= MISSING_THRESHOLD then
            broken[#broken + 1] = { key = key, label = entry.label, x = entry.x, y = entry.y, z = entry.z }
        end
    end
    return broken
end

function BaseIndex.removeBrokenLinks()
    local removed = 0
    for _, entry in ipairs(BaseIndex.brokenLinks()) do
        BaseIndex.unregister(entry.key)
        missCounts[entry.key] = nil
        removed = removed + 1
    end
    return removed
end

-- ==========================================================================
-- Registration
-- ==========================================================================

--[[
Register a container the player is looking at.

Takes the container rather than coordinates because that is what a context menu has, and
because the coordinates have to come from the container's own parent object to be right -
the square the player is standing on is not the square the crate is on.
]]
--[[
Applying a registration change to the table.

Split out from `register` so that exactly one implementation runs in both places it needs
to: directly in singleplayer, and inside the server's command handler in multiplayer. Two
copies of this would be two chances for the client and server tables to disagree about
what a key looks like, and a key mismatch means unlinking silently stops working.

Deliberately takes plain values rather than a container. The server never sees the client's
IsoObject, only the numbers that describe it.
]]
function BaseIndex.applyRegister(args)
    local key = keyFor(args.x, args.y, args.z, args.containerType)
    local data = store()

    -- An existing entry keeps its counts. Re-linking a crate should not blank what is
    -- known about it, and in multiplayer a second player linking the same container is a
    -- normal race rather than an error.
    local existing = data.containers[key]
    data.containers[key] = {
        x = args.x,
        y = args.y,
        z = args.z,
        containerType = args.containerType,
        label = args.label or args.containerType,
        counts = existing and existing.counts or {},
        scannedAt = existing and existing.scannedAt or nil,
    }
    return key
end

function BaseIndex.applyUnregister(args)
    store().containers[keyFor(args.x, args.y, args.z, args.containerType)] = nil
end

--[[
Describe a container as the plain values a command can carry.
]]
local function describeContainer(container, label)
    if container == nil then return nil end
    local parent = container:getParent()
    if parent == nil then return nil end

    local containerType = tostring(container:getType())
    return {
        x = math.floor(parent:getX()),
        y = math.floor(parent:getY()),
        z = math.floor(parent:getZ()),
        containerType = containerType,
        label = label or containerType,
    }
end

--[[
Register a container, through the server when there is one.

Client-authoritative writes to a shared ModData table are fine until two players edit it
in the same tick, at which point the whole table is transmitted by both and the loser's
change vanishes. Registrations are the destructive case - losing one silently unlinks a
crate someone spent wire on - so they go through the server, which owns the table and
broadcasts the result.

Counts are left client-authoritative on purpose. They are derived data that every client
recomputes by scanning, so a race there costs a briefly stale number that the next scan
repairs, and routing them through the server would mean a command per container per scan.
]]
function BaseIndex.register(container, label)
    local args = describeContainer(container, label)
    if args == nil then return nil end

    if isClient() then
        sendClientCommand(getPlayer(), "BaseIndex", "register", args)
        -- Applied locally too, so the linking player sees it immediately rather than
        -- after a server round trip. The server's broadcast overwrites this shortly.
        return BaseIndex.applyRegister(args)
    end

    local key = BaseIndex.applyRegister(args)
    BaseIndex.save()
    return key
end

function BaseIndex.unregister(key)
    local data = store()
    data.containers[key] = nil
    BaseIndex.save()
end

--[[
Unregister by container rather than by key.

The context menu and the link action both hold a container and not a key, and deriving
the key in each of them means the coordinate-and-type formula gets duplicated. Duplicating
it is how the two halves drift and unlinking silently stops matching what linking wrote.
]]
function BaseIndex.unregisterContainer(container)
    local args = describeContainer(container, nil)
    if args == nil then return end

    if isClient() then
        sendClientCommand(getPlayer(), "BaseIndex", "unregister", args)
        BaseIndex.applyUnregister(args)
        return
    end

    BaseIndex.applyUnregister(args)
    BaseIndex.save()
end

--[[
An optional veto on linking, set by whatever is consuming the index.

BaseIndex has no opinion about how far a container may be from anything - it does not know
what a terminal is, and it should not, because the base board and loadout restock will want
the same registrations under different rules. So the rule lives with the consumer and
plugs in here.

A guard returns `ok, reason`. The reason is shown to the player, so it has to read as an
explanation rather than a code.
]]
BaseIndex.registerGuard = nil

function BaseIndex.canRegister(container, object)
    if BaseIndex.registerGuard == nil then return true end
    return BaseIndex.registerGuard(container, object)
end

function BaseIndex.isRegistered(container)
    if container == nil then return false end
    local parent = container:getParent()
    if parent == nil then return false end
    local key = keyFor(
        math.floor(parent:getX()),
        math.floor(parent:getY()),
        math.floor(parent:getZ()),
        tostring(container:getType())
    )
    return store().containers[key] ~= nil
end

--[[
Push the table to the server so other players see the same registrations.

Guarded on isClient() because ModData.transmit does not exist to be called in
singleplayer, and because a solo game has nobody to tell.
]]
function BaseIndex.save()
    if isClient() then
        ModData.transmit(MOD_DATA_KEY)
    end
end

function BaseIndex.all()
    return store().containers
end

-- ==========================================================================
-- Scanning
-- ==========================================================================

--[[
The clock the timestamps are measured against.

World age in hours rather than a real-world timestamp: the point of the number is to say
"this reading is six in-game hours old", and in-game hours are what the player thinks in.
It also survives a save being loaded on a different day.
]]
local function now()
    local time = getGameTime()
    if time == nil then return 0 end
    return time:getWorldAgeHours()
end

--[[
Tally one container by full type.

Condition is deliberately not aggregated away. Two bandages where one is dirty are not
"2 bandages", and the mods built on this have to be able to tell the difference, so the
record carries a count and a worst-condition alongside it rather than a bare number.

getFullType, getCondition and getConditionMax are all zero-argument. getCondition returns
nil for items that do not have one, which is most of them.
]]
--[[
Item icons, cached outside ModData.

The texture is taken off a live item during the scan, which is the one moment a real
InventoryItem for that type is guaranteed to be in hand. Looking one up later would mean
either constructing a throwaway item or calling into ScriptManager with an argument list
worth not guessing at.

This table is deliberately *not* in ModData. A Java texture handle in saved data would be
serialised into a save file, and the entry would come back as garbage on the next load.
Losing the cache on restart costs one scan and nothing else.
]]
local textures = {}

function BaseIndex.textureFor(fullType)
    return textures[fullType]
end

--[[
How close a food item is to going off, as 0-1, or nil when it cannot rot.

`getOffAge` is when a food starts turning and `getOffAgeMax` is when it is fully rotten,
both compared against `getAge`. Reporting the ratio rather than a day count keeps this
independent of the sandbox's rot-speed setting, which changes how long a day of freshness
actually lasts.
]]
local function spoilage(item)
    if not instanceof(item, "Food") then return nil end
    if item:isRotten() then return 1 end

    local offAge = item:getOffAge()
    if type(offAge) ~= "number" or offAge <= 0 then return nil end

    local age = item:getAge()
    if type(age) ~= "number" then return nil end

    local ratio = age / offAge
    if ratio < 0 then return 0 end
    if ratio > 1 then return 1 end
    return ratio
end

--[[
Drinkable water in an item, in fluid units.

Both water types count. Tainted water is still water you can boil, and a board that
reported only the clean half would understate the base's actual position on the thing most
likely to kill everyone.
]]
local function waterIn(item)
    local fluids = item:getFluidContainer()
    if fluids == nil then return 0 end
    if not (fluids:contains(Fluid.Water) or fluids:contains(Fluid.TaintedWater)) then return 0 end
    local amount = fluids:getAmount()
    return type(amount) == "number" and amount or 0
end

--[[
Petrol, counted the same way water is.

Fuel was landing in the board's "everything else" row, which is absurd next to a generator
line that reports hours remaining - the two numbers answer the same question and were
sitting in different places, one of them unlabelled.

Measured in fluid units rather than counting cans, because a half-empty can is not half a
can of information.
]]
local function petrolIn(item)
    local fluids = item:getFluidContainer()
    if fluids == nil then return 0 end
    if not fluids:contains(Fluid.Petrol) then return 0 end
    local amount = fluids:getAmount()
    return type(amount) == "number" and amount or 0
end

-- Anything past this fraction of its off-age is worth warning about while it can still
-- be eaten or cooked. Below it, saying so would be noise.
local SPOILING_AT = 0.7

local function tally(container)
    local counts = {}
    local nutrition = { hunger = 0, water = 0, petrol = 0, spoiling = 0, rotten = 0 }
    local items = container:getItems()
    for i = 0, items:size() - 1 do
        local item = items:get(i)
        local fullType = tostring(item:getFullType())

        --[[
        Nutrition is summed per container rather than stored per type.

        The board asks "how many days of food do we have", which is one number over
        everything, and keeping it per type would mean recomputing that sum from thousands
        of rows every refresh.

        Hunger change is negative for food - eating reduces hunger - so it is negated here
        to become "hunger this item can satisfy".
        ]]
        local rot = spoilage(item)
        if rot ~= nil then
            if rot >= 1 then
                nutrition.rotten = nutrition.rotten + 1
            else
                if rot >= SPOILING_AT then nutrition.spoiling = nutrition.spoiling + 1 end
                local hunger = item:getHungerChange()
                if type(hunger) == "number" and hunger < 0 then
                    nutrition.hunger = nutrition.hunger - hunger
                end
            end
        end

        nutrition.water = nutrition.water + waterIn(item)
        nutrition.petrol = nutrition.petrol + petrolIn(item)

        if textures[fullType] == nil then
            textures[fullType] = item:getTex()
        end

        local record = counts[fullType]
        if record == nil then
            --[[
            The display category is captured during the scan for the same reason the icon
            is: this is the one moment a real item of this type is in hand. It is what the
            terminal filters on, so it wants the player-facing grouping - "Weapon",
            "Food" - rather than the internal type.
            ]]
            local category = item:getDisplayCategory()
            if category == nil or category == "" then category = item:getCategory() end

            record = {
                count = 0,
                name = tostring(item:getName()),
                category = tostring(category or "Item"),
            }
            counts[fullType] = record
        end
        record.count = record.count + 1

        local condition = item:getCondition()
        local conditionMax = item:getConditionMax()
        if type(condition) == "number" and type(conditionMax) == "number" and conditionMax > 0 then
            local ratio = condition / conditionMax
            if record.worstCondition == nil or ratio < record.worstCondition then
                record.worstCondition = ratio
            end
        end
    end
    return counts, nutrition
end

--[[
Refresh every registration whose chunk happens to be loaded.

Entries that cannot be resolved keep their previous counts and their previous timestamp.
That is the point: stale data with an honest age beats no data, and beats silently
reporting zero for a crate that is merely out of range.

Returns how many were refreshed and how many were skipped, which is what a consumer needs
to decide whether to tell the player their reading is partial.
]]
--[[
A cheap fingerprint of a container's contents.

Summing counts catches an item leaving or arriving, which is all the change detection
needs to answer "did someone take something out of this crate". It does not catch a swap
of equal counts between two types, and deliberately so - a real diff would mean keeping
the previous table around for every container in the base, and the question being asked
is "is this crate worth looking at", not "what exactly moved".
]]
local function fingerprint(counts)
    local total = 0
    for _, record in pairs(counts or {}) do
        total = total + record.count
    end
    return total
end

--[[
Refresh every registration whose chunk happens to be loaded.

Entries that cannot be resolved keep their previous counts and their previous timestamp.
That is the point: stale data with an honest age beats no data, and beats silently
reporting zero for a crate that is merely out of range.

Containers whose fingerprint moved since the last scan are stamped with `changedAt`. In
multiplayer that is how another player emptying a crate becomes visible - there is no
event for it, but the next scan sees a different total.
]]
function BaseIndex.refresh()
    local refreshed, skipped, changed = 0, 0, 0
    local timestamp = now()

    for key, entry in pairs(store().containers) do
        local container, status = resolve(entry)
        if container == nil then
            skipped = skipped + 1

            --[[
            Only a confirmed miss counts against a registration.

            An unloaded chunk resets nothing and increments nothing - it is simply no
            information. Counting it would mean a crate on the far side of the base
            accumulates misses just by being far away, and every distant link would
            eventually be declared broken.
            ]]
            if status == "missing" then
                missCounts[key] = (missCounts[key] or 0) + 1
            end
        else
            missCounts[key] = nil
            local before = entry.scannedAt ~= nil and fingerprint(entry.counts) or nil
            entry.counts, entry.nutrition = tally(container)
            entry.scannedAt = timestamp

            local after = fingerprint(entry.counts)
            if before ~= nil and before ~= after then
                entry.changedAt = timestamp
                entry.delta = after - before
                changed = changed + 1
            end

            refreshed = refreshed + 1
        end
    end

    return refreshed, skipped, changed
end

--[[
Containers that changed within the last `withinHours` of world time.

Used by the terminal to say which crate someone has been into, which matters most in
multiplayer where the answer is usually another player rather than yourself.
]]
function BaseIndex.recentlyChanged(withinHours)
    local cutoff = now() - (withinHours or 6)
    local found = {}
    for key, entry in pairs(store().containers) do
        if entry.changedAt ~= nil and entry.changedAt >= cutoff then
            found[#found + 1] = {
                key = key,
                label = entry.label,
                delta = entry.delta or 0,
                changedAt = entry.changedAt,
                ageHours = now() - entry.changedAt,
            }
        end
    end
    table.sort(found, function(left, right) return left.changedAt > right.changedAt end)
    return found
end

--[[
Mark one container as needing a rescan.

Called after a transfer this mod family initiated. There is no reliable per-container
change event in the game, so the alternative to this is rescanning everything on a timer,
which at base scale is thousands of items for one nail moved.
]]
function BaseIndex.invalidate(key)
    local entry = store().containers[key]
    if entry == nil then return end

    --[[
    Marked dirty, not un-scanned.

    Clearing scannedAt was the obvious implementation and the wrong one: refresh() uses it
    as the "have I seen this container before" test for change detection, so nulling it
    threw away the fingerprint baseline and the very transfer that triggered the
    invalidation became invisible to the recent-activity list. It also made the row render
    as never-scanned for one frame.

    refresh() rescans every loaded container regardless, so the flag is advisory - it
    exists for a future incremental refresh, and to keep the intent recorded.
    ]]
    entry.dirty = true
end


-- ==========================================================================
-- Base areas
-- ==========================================================================

--[[
The base is a set of named rectangles the player drew.

Three earlier attempts are worth recording, because each was a step toward this one.

First, a radius from the terminal or board. A base is not a circle.

Second, inference: the bounding box of every linked container, unioned with the building
you stood in, plus a margin, capped, with a radius fallback. Individually defensible, and
together six interacting rules producing a number nobody could predict or correct - when it
measured the wrong ground the player had no lever at all.

Third, corner marks. Right idea, still one box, so marking a house and a distant farm
claimed every street between them.

Rectangles fix that last problem: a house, a farm and a parking lot are three tight regions
with nothing wasted between them, and each is small to scan.

The engine's own `DesignationZone` was the obvious home for this - it is generic over a
type string, it has the drag UI, and it does point-in-zone lookups. It was probed and
rejected on one specific finding: **a zone with a custom type is accepted at runtime and
silently dropped on save**, verified across four launches with the probe on both the client
and the server side. So the rectangles live here, in the ModData that is already proven to
persist and sync, and the engine is used only for the parts that work - the drag interaction
and `addAreaHighlightForPlayer` for drawing.
]]

local function areaStore()
    local data = store()
    data.areas = data.areas or {}
    data.nextAreaId = data.nextAreaId or 1
    return data
end

function BaseIndex.applyAddArea(args)
    local data = areaStore()
    local id = args.id or tostring(data.nextAreaId)
    if args.id == nil then data.nextAreaId = data.nextAreaId + 1 end

    data.areas[id] = {
        id = id,
        name = args.name,
        x1 = math.min(args.x1, args.x2),
        y1 = math.min(args.y1, args.y2),
        x2 = math.max(args.x1, args.x2),
        y2 = math.max(args.y1, args.y2),
        z = args.z,
    }
    return true
end

function BaseIndex.applyRemoveArea(args)
    areaStore().areas[args.id] = nil
    return true
end

function BaseIndex.applyRenameArea(args)
    local area = areaStore().areas[args.id]
    if area == nil then return false end
    area.name = args.name
    return true
end

--[[
Route area edits through the server when there is one.

Areas decide what every other feature measures, so two players editing them at once is
exactly the case that must not silently lose one of the edits. Same command path as
registrations.
]]
local function mutateArea(command, args)
    if isClient() then
        sendClientCommand(getPlayer(), MOD_DATA_KEY, command, args)
        BaseIndex["apply" .. command](args)
        return
    end
    BaseIndex["apply" .. command](args)
    BaseIndex.save()
end

function BaseIndex.addArea(name, x1, y1, x2, y2, z)
    mutateArea("AddArea", { name = name, x1 = x1, y1 = y1, x2 = x2, y2 = y2, z = z })
end

function BaseIndex.removeArea(id) mutateArea("RemoveArea", { id = id }) end
function BaseIndex.renameArea(id, name) mutateArea("RenameArea", { id = id, name = name }) end

--[[
Every area, newest last so the list does not reshuffle as one is added.
]]
function BaseIndex.areas()
    local list = {}
    for _, area in pairs(areaStore().areas) do list[#list + 1] = area end
    table.sort(list, function(left, right) return tostring(left.id) < tostring(right.id) end)
    return list
end

function BaseIndex.areaCount()
    local count = 0
    for _ in pairs(areaStore().areas) do count = count + 1 end
    return count
end

--[[
Whether a point is inside any area.

Exposed so every consumer asks the same question of the same data. Two features disagreeing
about which ground is yours is a bug the player experiences as the mods being unreliable,
which is what the whole rewrite was for.
]]
function BaseIndex.containsPoint(x, y, z)
    for _, area in pairs(areaStore().areas) do
        if area.z == z and x >= area.x1 and x <= area.x2 and y >= area.y1 and y <= area.y2 then
            return true, area
        end
    end
    return false
end

--[[
Total squares across all areas, for reporting the cost of a survey.

Overlapping areas are double counted. Not worth correcting: the number exists to tell a
player their survey area is getting expensive, and two overlapping rectangles genuinely do
cost twice over in a naive scan.
]]
function BaseIndex.areaSquares()
    local total = 0
    for _, area in pairs(areaStore().areas) do
        total = total + ((area.x2 - area.x1 + 1) * (area.y2 - area.y1 + 1))
    end
    return total
end

-- ==========================================================================
-- Queries
-- ==========================================================================

--[[
Total count of one full type across the whole base, with the age of the oldest reading
that contributed to it.

The age is returned rather than folded in because only the consumer knows whether it
matters. A terminal listing what you own should show it; a restock action about to walk
you to a crate should ignore it and just find out.
]]
function BaseIndex.totalOf(fullType)
    local total = 0
    local oldest = nil
    local current = now()

    for _, entry in pairs(store().containers) do
        local record = entry.counts and entry.counts[fullType]
        if record ~= nil and record.count > 0 then
            total = total + record.count
            if entry.scannedAt ~= nil then
                local age = current - entry.scannedAt
                if oldest == nil or age > oldest then oldest = age end
            end
        end
    end

    return total, oldest
end

--[[
Where a full type can be found, most-stocked container first.

This is what the "where is my screwdriver" lookup and the restock fetch planner both
want. Sorting by count means a fetch that needs ten nails visits one crate rather than
four.
]]
function BaseIndex.locate(fullType)
    local found = {}
    for key, entry in pairs(store().containers) do
        local record = entry.counts and entry.counts[fullType]
        if record ~= nil and record.count > 0 then
            found[#found + 1] = {
                key = key,
                label = entry.label,
                count = record.count,
                x = entry.x,
                y = entry.y,
                z = entry.z,
                scannedAt = entry.scannedAt,
            }
        end
    end
    table.sort(found, function(left, right) return left.count > right.count end)
    return found
end

--[[
Everything the base holds, merged across containers.

Returns a table of fullType to {count, name, worstCondition}. Built fresh on each call
rather than kept incrementally, because the incremental version has to be correct across
every path that can change a container and this one only has to be correct here.
]]
function BaseIndex.contents()
    local merged = {}
    for _, entry in pairs(store().containers) do
        for fullType, record in pairs(entry.counts or {}) do
            local into = merged[fullType]
            if into == nil then
                merged[fullType] = {
                    count = record.count,
                    name = record.name,
                    category = record.category,
                    worstCondition = record.worstCondition,
                }
            else
                into.count = into.count + record.count
                if record.worstCondition ~= nil then
                    if into.worstCondition == nil or record.worstCondition < into.worstCondition then
                        into.worstCondition = record.worstCondition
                    end
                end
            end
        end
    end
    return merged
end

--[[
Food, water and spoilage across everything linked.

Summed from the per-container figures the scan already produced, so this costs a walk over
the registrations rather than over every item. Cached figures from out-of-range containers
are included - a crate you cannot currently see still has food in it, and excluding it
would make the base's supply position appear to collapse whenever you walked away.
]]
function BaseIndex.nutrition()
    local total = { hunger = 0, water = 0, petrol = 0, spoiling = 0, rotten = 0 }
    for _, entry in pairs(store().containers) do
        local n = entry.nutrition
        if n ~= nil then
            total.hunger = total.hunger + (n.hunger or 0)
            total.water = total.water + (n.water or 0)
            total.petrol = total.petrol + (n.petrol or 0)
            total.spoiling = total.spoiling + (n.spoiling or 0)
            total.rotten = total.rotten + (n.rotten or 0)
        end
    end
    return total
end

--[[
Ammunition broken out by type.

"340 ammo" is not an answer to any question anyone asks. The question is always "do we have
9mm", and the item name already carries the calibre - so no calibre has to be inferred,
only grouped and sorted.

Boxes and loose rounds stay separate for the same reason the terminal keeps them separate:
they are different items and a player planning a run needs to know which they have.
]]
function BaseIndex.ammunition()
    local rows = {}
    for fullType, record in pairs(BaseIndex.contents()) do
        if record.category ~= nil and string.lower(record.category) == "ammo" then
            rows[#rows + 1] = { name = record.name or fullType, count = record.count }
        end
    end
    table.sort(rows, function(left, right) return left.count > right.count end)
    return rows
end

--[[
The live containers among the registrations.

This is what the storage terminal injects into the loot window, and it is deliberately
the only function here that hands back live objects. Everything else deals in counts, so
that nothing can accidentally hold a reference into a chunk that later unloads.
]]
--[[
The live container for one registration key, or nil if its chunk is not loaded.

Exposed so a consumer can act on a specific container it found through `locate` - taking
an item out of the crate that actually holds it, rather than searching the whole network
again for something the index already knows the location of.
]]
function BaseIndex.containerFor(key)
    local entry = store().containers[key]
    if entry == nil then return nil end
    return resolve(entry)
end

function BaseIndex.liveContainers()
    local live = {}
    for _, entry in pairs(store().containers) do
        local container = resolve(entry)
        if container ~= nil then live[#live + 1] = container end
    end
    return live
end

return BaseIndex
