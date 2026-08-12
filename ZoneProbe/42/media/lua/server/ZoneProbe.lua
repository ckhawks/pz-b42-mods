--[[
Zone probe.

`DesignationZone` in the jar is generic over a type string - the constructor takes a type
and a name before its coordinates, and lookups are `getAllZonesByType`, `getZoneByType`,
`getZoneByNameAndType`. If a mod can register zones under its own type, the base-area
feature gets multiple named rectangles, persistence, multiplayer sync and a point-in-zone
test from the engine instead of from our own ModData.

The risk is that the save and packet code only knows about the animal type, so a custom one
is accepted at runtime and then quietly lost. That cannot be settled by reading the class;
it needs a save and a reload.

So this runs on every game start and reports what it finds. Run it once, quit to desktop,
load the same save, and read the file again:

  run 1   creates a zone of type BaseArea and confirms it is queryable
  run 2   says whether that zone came back

If run 2 finds it, we build the base-area system on this. If not, we keep our own storage
and steal only the drag UI, which is most of the value anyway.

Report goes to Zomboid/Lua/zoneprobe.txt. Nothing here changes gameplay - a designation
zone with a type nothing else reads has no effect on anything.
]]

local REPORT = "zoneprobe.txt"
local ZONE_TYPE = "BaseArea"
local ZONE_NAME = "ProbeZone"

-- ==========================================================================

local Report = {}
Report.__index = Report

function Report.new(path)
    return setmetatable({ path = path, lines = {} }, Report)
end

function Report:add(text) self.lines[#self.lines + 1] = text end
function Report:addf(format, ...) self:add(string.format(format, ...)) end

--[[
Rewritten from the start on every flush.

Same reasoning as the photo probe: a call that kills the session must still leave a
complete file whose last line names the step that did it. Appending would risk a truncated
final line, and depending on a close() that a broken session may never reach.
]]
function Report:flush()
    local writer = getFileWriter(self.path, true, false)
    if writer == nil then return end
    writer:write(table.concat(self.lines, "\r\n"))
    writer:close()
end

local function methodNames(object)
    local names = {}
    local ok, meta = pcall(getmetatable, object)
    if ok and type(meta) == "table" and type(meta.__index) == "table" then
        for key in pairs(meta.__index) do
            if type(key) == "string" then names[#names + 1] = key end
        end
    end
    table.sort(names)
    return names
end

--[[
Every call is flushed before it runs and wrapped.

The arity rule from craftgraph still applies: Kahlua raises on an argument list matching no
overload. Globals proved recoverable in 42.20, but this touches a class nobody has called
from Lua before, so the file is written first and read afterwards regardless of what
happens.
]]
local function step(report, label, fn)
    report:add("")
    report:addf("--- %s ---", label)
    report:flush()

    local ok, result = pcall(fn)
    report:add(ok and ("  " .. tostring(result)) or ("  FAILED: " .. tostring(result)))
    report:flush()
    return ok, result
end

-- ==========================================================================

local function countZones()
    local zones = DesignationZone.getAllZonesByType(ZONE_TYPE)
    if zones == nil then return -1 end
    return zones:size()
end

local function run()
    local report = Report.new(REPORT)
    report:add("zone probe")
    report:add("Does DesignationZone accept a custom type, and does it survive a reload?")
    report:add("")

    local playerObj = getSpecificPlayer(0)
    if playerObj == nil then
        report:add("no player")
        report:flush()
        return
    end

    local px = math.floor(playerObj:getX())
    local py = math.floor(playerObj:getY())
    local pz = math.floor(playerObj:getZ())
    report:addf("player at %d,%d,%d", px, py, pz)

    step(report, "DesignationZone exists", function()
        return type(DesignationZone)
    end)

    step(report, "DesignationZone method list", function()
        local names = methodNames(DesignationZone)
        if #names == 0 then return "no method list on the class table" end
        return string.format("%d: %s", #names, table.concat(names, " "))
    end)

    --[[
    The question run 2 answers.

    Counted before anything is created, so a non-zero count on a later run is proof the
    zone was written to the save and read back - which is the entire point of the probe.
    ]]
    local existing = nil
    step(report, "getAllZonesByType at start", function()
        existing = countZones()
        if existing < 0 then return "returned nil" end
        if existing > 0 then
            return string.format("%d zone(s) ALREADY PRESENT - persistence works", existing)
        end
        return "0 zones - this is the first run, or they did not persist"
    end)

    if existing ~= nil and existing > 0 then
        step(report, "describe the surviving zone", function()
            local zones = DesignationZone.getAllZonesByType(ZONE_TYPE)
            local zone = zones:get(0)
            return string.format(
                "name=%s x=%s y=%s z=%s w=%s h=%s",
                tostring(zone:getName()), tostring(zone:getX()), tostring(zone:getY()),
                tostring(zone:getZ()), tostring(zone:getW()), tostring(zone:getH())
            )
        end)

        step(report, "getZone at its own corner", function()
            local zones = DesignationZone.getAllZonesByType(ZONE_TYPE)
            local zone = zones:get(0)
            local found = DesignationZone.getZone(ZONE_TYPE, zone:getX(), zone:getY(), zone:getZ())
            return found ~= nil and ("found: " .. tostring(found:getName())) or "nil"
        end)

        report:add("")
        report:add("VERDICT: custom zone types persist. Build the base area on this.")
        report:flush()
        return
    end

    --[[
    Creation, tried two ways.

    The jar shows a constructor taking (String, String, int,int,int,int,int, boolean) and a
    factory taking (String, String, int,int,int,int,int). The animal subclass is constructed
    in Lua as `DesignationZoneAnimal.new(name, x1, y1, z, x2, y2, true)`, so the base class
    most likely takes the same list with a type in front - but "most likely" is what probes
    are for.
    ]]
    step(report, "DesignationZone.new(type, name, x1, y1, z, x2, y2, true)", function()
        local zone = DesignationZone.new(ZONE_TYPE, ZONE_NAME, px, py, pz, px + 8, py + 8, true)
        return zone ~= nil and ("created: " .. tostring(zone:getName())) or "returned nil"
    end)

    step(report, "count after new()", function()
        return tostring(countZones())
    end)

    if countZones() <= 0 then
        step(report, "DesignationZone.addZone(type, name, x1, y1, z, x2, y2)", function()
            local zone = DesignationZone.addZone(ZONE_TYPE, ZONE_NAME, px, py, pz, px + 8, py + 8)
            return zone ~= nil and ("created: " .. tostring(zone:getName())) or "returned nil"
        end)

        step(report, "count after addZone()", function()
            return tostring(countZones())
        end)
    end

    report:add("")
    if countZones() > 0 then
        report:add("Zone created. Now quit to desktop, reload this save, and read this file")
        report:add("again. If the count at start is above zero, persistence works.")
    else
        report:add("VERDICT: could not create a zone of a custom type from Lua.")
        report:add("Fall back to our own storage and reuse only the drag UI.")
    end
    report:flush()

    print("zoneprobe: wrote " .. REPORT)
end

Events.OnGameStart.Add(run)
