--[[
Everything the board reports that BaseIndex does not.

Crops, animals, defenses and vehicles are all things you find by looking at the world
rather than by reading a container, so they are surveyed here on a slow timer instead of
being registered like containers are.

The four scans that need squares share **one** pass over the rectangle. Three separate
loops over a 60x60 area would be three times the cost for the same information, and this
runs while a window is open rather than in the background, so it should be cheap enough
that nobody notices.

Every API used here was read out of the game's own Lua or off the class in the jar, not
guessed:

  square:getAnimals()                              seen in ISVehicleMenu.lua:779
  animal:getHunger/getThirst/getHealth/getFullName off IsoAnimal in projectzomboid.jar
  CFarmingSystem.instance:getLuaObjectOnSquare()   seen in CFarmingSystem.lua:50
  plant.health / waterLvl / aphidLvl / ...         plain table fields, ISFarmingInfo.lua
  thumpable:getHealth() / getMaxHealth()           seen throughout server/BuildingObjects
  getCell():getVehicles()                          seen in ISVehicleBloodUI.lua:77
  part:getContainerContentAmount() / Capacity      seen in ISRefuelFromGasPump.lua:95
]]

BaseBoardSurvey = BaseBoardSurvey or {}

--[[
Thresholds for "worth mentioning".

A board exists to tell you what needs doing, so the numbers it reports are counts of
problems rather than inventories of everything. These are the lines between fine and worth
walking over to look at.

Plant health runs 0-100 and ISFarmingInfo calls anything above 50 healthy, so 50 is the
game's own boundary rather than one invented here. Animal hunger and thirst run 0-1 with
higher meaning worse.
]]
local PLANT_DRY = 20
local PLANT_SICK = 50
local ANIMAL_HUNGRY = 0.6
local ANIMAL_THIRSTY = 0.6
local ANIMAL_UNWELL = 60
local DEFENCE_DAMAGED = 0.99
local VEHICLE_LOW_FUEL = 0.25

--[[
One pass over the loaded squares around the board.

Unloaded squares are skipped silently. A base larger than the loaded area reports only what
is currently simulated, which is the same honest limitation everything else here has - and
unlike container counts there is nothing sensible to cache, because a crop that was thirsty
six hours ago tells you nothing about whether it is thirsty now.
]]
function BaseBoardSurvey.scanSquares(areas)
    local crops = { total = 0, dry = 0, diseased = 0, dead = 0 }
    local animals = { total = 0, hungry = 0, thirsty = 0, unwell = 0 }
    local defenses = { total = 0, damaged = 0, worst = nil }
    local water = { sources = 0, amount = 0, capacity = 0 }

    local cell = getCell()
    if cell == nil then return crops, animals, defenses, water end

    local farming = CFarmingSystem and CFarmingSystem.instance or nil

    --[[
    One pass per drawn area, rather than one pass over a box containing all of them.

    This is the whole reason for rectangles. A house and a farm sixty tiles apart are two
    small scans; a single bounding box around both would walk every street between them for
    nothing, and report the neighbours' crops as yours.

    Squares in overlapping areas are visited twice. Not worth preventing - it needs a seen
    set the size of the base, and overlapping areas are a thing the player can see and fix
    in the panel.
    ]]
    for _, area in ipairs(areas) do
    for x = area.x1, area.x2 do
        for y = area.y1, area.y2 do
            local square = cell:getGridSquare(x, y, area.z)
            if square ~= nil then

                -- Crops. getLuaObjectOnSquare returns a plain Lua table, or nil.
                if farming ~= nil then
                    local plant = farming:getLuaObjectOnSquare(square)
                    if plant ~= nil and plant.typeOfSeed ~= nil and plant.typeOfSeed ~= "none" then
                        crops.total = crops.total + 1

                        if (plant.health or 100) <= 0 then
                            crops.dead = crops.dead + 1
                        else
                            if (plant.waterLvl or 100) < PLANT_DRY then crops.dry = crops.dry + 1 end

                            -- Four separate afflictions, but a player only needs to know
                            -- that something is wrong and how many plots have it.
                            local sick = (plant.aphidLvl or 0) > 0
                                or (plant.mildewLvl or 0) > 0
                                or (plant.fliesLvl or 0) > 0
                                or (plant.slugsLvl or 0) > 0
                                or (plant.health or 100) < PLANT_SICK
                            if sick then crops.diseased = crops.diseased + 1 end
                        end
                    end
                end

                -- Animals.
                local herd = square:getAnimals()
                if herd ~= nil then
                    for i = 0, herd:size() - 1 do
                        local animal = herd:get(i)
                        if animal ~= nil and animal:getHealth() > 0 then
                            animals.total = animals.total + 1
                            if animal:getHunger() >= ANIMAL_HUNGRY then
                                animals.hungry = animals.hungry + 1
                            end
                            if animal:getThirst() >= ANIMAL_THIRSTY then
                                animals.thirsty = animals.thirsty + 1
                            end
                            if animal:getHealth() < ANIMAL_UNWELL then
                                animals.unwell = animals.unwell + 1
                            end
                        end
                    end
                end

                --[[
                Plumbed water: rain barrels, sinks, toilets, anything holding water.

                Not containers in the inventory sense, so BaseIndex never sees them - but
                they are usually the majority of a base's water, and a supply readout that
                ignored the rain barrels would be worse than none.

                IsoObject exposes the same fluid API items do, so this is the same test.
                ]]
                local objectsForWater = square:getObjects()
                for i = 0, objectsForWater:size() - 1 do
                    local object = objectsForWater:get(i)
                    local fluids = object:getFluidContainer()
                    if fluids ~= nil
                        and (fluids:contains(Fluid.Water) or fluids:contains(Fluid.TaintedWater))
                    then
                        local amount = fluids:getAmount()
                        if type(amount) == "number" and amount > 0 then
                            water.sources = water.sources + 1
                            water.amount = water.amount + amount

                            local capacity = object:getFluidCapacity()
                            if type(capacity) == "number" then
                                water.capacity = water.capacity + capacity
                            end
                        end
                    end
                end

                --[[
                Defenses, meaning player-built structures.

                IsoThumpable is what every player-built wall, door, gate and barricade
                is, and vanilla world walls are not - so this counts what you built
                without needing a list of what belongs to the base.
                ]]
                local objects = square:getObjects()
                for i = 0, objects:size() - 1 do
                    local object = objects:get(i)
                    if instanceof(object, "IsoThumpable") then
                        local max = object:getMaxHealth()
                        if type(max) == "number" and max > 0 then
                            defenses.total = defenses.total + 1
                            local ratio = object:getHealth() / max
                            if ratio < DEFENCE_DAMAGED then
                                defenses.damaged = defenses.damaged + 1
                                if defenses.worst == nil or ratio < defenses.worst then
                                    defenses.worst = ratio
                                end
                            end
                        end
                    end
                end
            end
        end
    end

    end

    return crops, animals, defenses, water
end

--[[
Vehicles near the board.

Found through the cell rather than by walking squares, because a vehicle is not an object
on a tile and would not be seen by the scan above. Distance is measured from the board so a
neighbour's abandoned car three streets away is not reported as base stock.

Fuel comes from the GasTank part's container amount against its capacity, which is the same
pair the refuelling action uses.
]]
--[[
Vehicles use the same bounds as everything else.

An earlier version gave them extra padding on the grounds that a parking lot is obviously
base stock and vehicles are cheap to enumerate. Both true, and it was still wrong: it meant
two different answers to "is this inside the base" living in one window, and a car counted
that a crop on the same tile would not have been.

If the parking lot is part of the base, mark it. One rule.
]]
--[[
Whether an object responds to a method, checked before calling it.

`getCell():getVehicles()` is used in vanilla as `:size()` and `:get(i)`, but the only place
that does so is ISVehicleBloodUI - a debug tool that may never run - so it is weak evidence
for the collection's actual shape. Calling `get` on something that has no `get` is what
threw here, once per frame, and took the board's whole refresh chain down with it.

So the shape is tested rather than assumed, and reported once if it is neither of the two
things it could reasonably be.
]]
local function responds(object, name)
    if type(object) ~= "userdata" and type(object) ~= "table" then return false end
    local ok, meta = pcall(getmetatable, object)
    if not ok or type(meta) ~= "table" or type(meta.__index) ~= "table" then return false end
    return meta.__index[name] ~= nil
end

local reportedVehicleShape = false

function BaseBoardSurvey.scanVehicles()
    local summary = { total = 0, lowFuel = 0, damaged = 0 }

    local cell = getCell()
    if cell == nil then return summary end

    local ok, vehicles = pcall(function() return cell:getVehicles() end)
    if not ok or vehicles == nil then return summary end

    --[[
    Build a plain Lua list first, whichever shape the collection turns out to be.

    Java collection, Lua array, or something else entirely - the rest of this function only
    wants a list it can walk, and deciding that once here beats guarding every access.
    ]]
    local list = {}
    if responds(vehicles, "size") and responds(vehicles, "get") then
        for i = 0, vehicles:size() - 1 do
            list[#list + 1] = vehicles:get(i)
        end
    elseif type(vehicles) == "table" then
        for _, vehicle in ipairs(vehicles) do list[#list + 1] = vehicle end
    else
        -- Said once rather than every refresh. If this ever prints, the message names what
        -- to write the next accessor against.
        if not reportedVehicleShape then
            reportedVehicleShape = true
            print(string.format(
                "baseboard: getVehicles() returned a %s with no size/get - vehicles not surveyed",
                type(vehicles)
            ))
        end
        return summary
    end

    for _, vehicle in ipairs(list) do
        if vehicle ~= nil then
            local x = math.floor(vehicle:getX())
            local y = math.floor(vehicle:getY())
            local z = math.floor(vehicle:getZ())

            -- The same containsPoint every other feature uses, so a car in the parking lot
            -- counts exactly when the parking lot is a drawn area, and never otherwise.
            if BaseIndex.containsPoint(x, y, z) then
                summary.total = summary.total + 1

                local tank = vehicle:getPartById("GasTank")
                if tank ~= nil then
                    local capacity = tank:getContainerCapacity()
                    if type(capacity) == "number" and capacity > 0 then
                        local level = tank:getContainerContentAmount() / capacity
                        if level < VEHICLE_LOW_FUEL then
                            summary.lowFuel = summary.lowFuel + 1
                        end
                    end
                end

                --[[
                A vehicle counts as damaged if its engine is.

                Every part has a condition and summing them would produce a number nobody
                can act on. The engine is the one that decides whether the thing drives,
                which is the question a board is being asked.
                ]]
                local engine = vehicle:getPartById("Engine")
                if engine ~= nil and engine:getCondition() < 50 then
                    summary.damaged = summary.damaged + 1
                end
            end
        end
    end

    return summary
end

--[[
Everything at once, for the window to render.

Returned as one table so the UI does a single call per refresh and cannot end up drawing
half a survey from before a scan and half from after.
]]
function BaseBoardSurvey.run()
    local areas = BaseIndex.areas()
    local crops, animals, defenses, water = BaseBoardSurvey.scanSquares(areas)

    --[[
    Water comes from two places and has to be added up before it means anything.

    Bottles and cans live in linked containers and are counted by BaseIndex; barrels and
    sinks are world objects and are counted above. A player thinks of both as "our water",
    so reporting them separately would just make them do the arithmetic.
    ]]
    local stored = BaseIndex.nutrition()
    water.amount = water.amount + (stored.water or 0)

    return {
        crops = crops,
        animals = animals,
        defenses = defenses,
        water = water,
        vehicles = BaseBoardSurvey.scanVehicles(),
        nutrition = stored,
        areas = #areas,
        squares = BaseIndex.areaSquares(),
    }
end
