--[[
Linking a container, as a timed action with a cost.

The first version registered a container the instant the menu option was clicked, which
made the network feel like a settings screen. Wiring a crate into a base network should
take a moment and consume something, so this walks the player to it, plays the animation,
and charges for the run of cable.

The requirements split three ways on purpose:

  screwdriver          a tool. Required, never consumed.
  wire or scrap        a material. Consumed, one per container.
  Electrical level 3   a skill gate.

The tool is not consumed because per-crate consumption would make a large base a shopping
trip, and the interesting cost is owning the tool at all. The material *is* consumed
because that is what turns network size into a resource decision rather than a patience
one - without it, linking is free the moment you own a screwdriver, and there is no reason
not to wire everything.

Electrical 3 is the gate that stops this being a day-one mod. It is a skill people
otherwise only level for generators and car batteries, which puts the terminal on the same
progression as the power that runs it.
]]

require "TimedActions/ISBaseTimedAction"

BaseIndexLinkAction = ISBaseTimedAction:derive("BaseIndexLinkAction")

--[[
The link requirements are sandbox options, read at call time.

They live under the StorageTerminal page rather than a BaseIndex one because that is the
mod a server admin installs and thinks about; BaseIndex is a library they should never
need to know exists.

Falling back to these defaults means the library still works if it is ever used without
the terminal mod installed.
]]
local DEFAULTS = {
    RequiredElectricalLevel = 3,
    ConsumeMaterial = true,
    LinkTime = 180,
}

local function opt(name)
    local vars = SandboxVars and SandboxVars.StorageTerminal
    local value = vars and vars[name]
    if value == nil then return DEFAULTS[name] end
    return value
end

--[[
The tool, kept.

Several types are accepted because a mod that demands one exact `Base.Screwdriver` will
silently refuse to work for someone holding a perfectly reasonable substitute.
]]
local TOOL_TYPES = {
    "Base.Screwdriver",
    "Base.ElectricScrewdriver",
}

--[[
The material, consumed. One per container linked.
]]
local MATERIAL_TYPES = {
    "Base.ElectricWire",
    "Base.ElectronicsScrap",
}

local function firstOf(character, types)
    local inventory = character:getInventory()
    if inventory == nil then return nil end
    for _, fullType in ipairs(types) do
        local found = inventory:getFirstTypeRecurse(fullType)
        if found ~= nil then return found, fullType end
    end
    return nil
end

function BaseIndexLinkAction.findTool(character)
    return firstOf(character, TOOL_TYPES)
end

function BaseIndexLinkAction.findMaterial(character)
    return firstOf(character, MATERIAL_TYPES)
end

function BaseIndexLinkAction.skillLevel(character)
    return character:getPerkLevel(Perks.Electricity)
end

--[[
Why the player cannot link right now, or nil if they can.

One string, because only one fits on a tooltip, and ordered by what the player is most
likely to be able to fix. Unlinking asks for none of this: pulling a wire out is not the
fiddly half, and stranding a player who has since used their last screwdriver with a
network they cannot edit would be worse than the realism is worth.
]]
function BaseIndexLinkAction.blockedReason(character, unlink)
    if unlink then return nil end

    local required = opt("RequiredElectricalLevel")
    if required > 0 and BaseIndexLinkAction.skillLevel(character) < required then
        return string.format(
            "Requires Electrical %d. You have %d.",
            required, BaseIndexLinkAction.skillLevel(character)
        )
    end
    if BaseIndexLinkAction.findTool(character) == nil then
        return "Requires a screwdriver."
    end
    if opt("ConsumeMaterial") and BaseIndexLinkAction.findMaterial(character) == nil then
        return "Requires electric wire or electronics scrap, one per container."
    end
    return nil
end

function BaseIndexLinkAction:isValid()
    if self.containers == nil or #self.containers == 0 then return false end
    return BaseIndexLinkAction.blockedReason(self.character, self.unlink) == nil
end

function BaseIndexLinkAction:waitToStart()
    self.character:faceThisObject(self.object)
    return self.character:shouldBeTurning()
end

function BaseIndexLinkAction:update()
    self.character:faceThisObject(self.object)
end

function BaseIndexLinkAction:start()
    self:setActionAnim("Loot")
end

function BaseIndexLinkAction:stop()
    ISBaseTimedAction.stop(self)
end

function BaseIndexLinkAction:perform()
    if self.unlink then
        for _, container in ipairs(self.containers) do
            BaseIndex.unregisterContainer(container)
        end
    else
        for _, container in ipairs(self.containers) do
            --[[
            One wire per compartment, and the material is consumed here rather than in
            start().

            An action cancelled halfway - the player walks away, a zombie interrupts -
            must not have eaten the wire, and perform() only runs on completion.

            Charging per compartment rather than per appliance keeps the rule the player
            already learned: one container, one wire. A fridge is two containers and so
            costs two, which the menu says up front.

            Running out midway links what was paid for and stops. Partial is the honest
            outcome; the alternatives are wiring the second half for free or refusing an
            action the player has already spent the time on.
            ]]
            local paid = true
            if opt("ConsumeMaterial") then
                local material = BaseIndexLinkAction.findMaterial(self.character)
                if material == nil then
                    paid = false
                else
                    self.character:getInventory():Remove(material)
                end
            end

            if paid then
                BaseIndex.register(container, self.label)
                -- A small amount, because this is a use of the skill rather than a lesson.
                self.character:getXp():AddXP(Perks.Electricity, 5)
            end
        end
    end
    ISBaseTimedAction.perform(self)
end

function BaseIndexLinkAction:new(character, object, containers, label, unlink)
    local o = ISBaseTimedAction.new(self, character)
    o.object = object
    o.containers = containers
    o.label = label
    o.unlink = unlink

    -- Unlinking is a third of the time: pulling a wire out is not the fiddly half.
    local linkTime = opt("LinkTime")
    o.maxTime = unlink and math.max(1, math.floor(linkTime / 3)) or linkTime
    if character:isTimedActionInstant() then o.maxTime = 1 end
    return o
end
