--[[
Converting a television into a terminal.

Until now this was the one free thing in the mod: linking a crate cost a tool, a wire and
Electrical 3, while building the console it all hangs off cost a right click. That is
backwards - the terminal is the more significant object, and the one the whole network
depends on.

The requirements deliberately differ from linking rather than repeating it:

  screwdriver          the same tool, kept
  electronics scrap    specifically, and consumed. Not wire.
  Electrical level     the same gate as linking, from the same sandbox option

Wire is the right material for running cable to a crate; it is not the right material for
turning a television into a control panel. Demanding scrap specifically also puts a real
scavenging step in front of the mod, because scrap comes from dismantling electronics
rather than from a hardware store shelf.

The action is longer than a link for the same reason: this is the build, not the wiring.
]]

require "TimedActions/ISBaseTimedAction"

StorageTerminalBuildAction = ISBaseTimedAction:derive("StorageTerminalBuildAction")

local DEFAULTS = {
    TerminalBuildTime = 400,
}

local function opt(name)
    local vars = SandboxVars and SandboxVars.StorageTerminal
    local value = vars and vars[name]
    if value == nil then return DEFAULTS[name] end
    return value
end

local MATERIAL_TYPE = "Base.ElectronicsScrap"

function StorageTerminalBuildAction.findMaterial(character)
    local inventory = character:getInventory()
    if inventory == nil then return nil end
    return inventory:getFirstTypeRecurse(MATERIAL_TYPE)
end

--[[
Why the player cannot build here, or nil if they can.

Returns one string, because only one fits on a tooltip, ordered by what the player is most
able to act on. The skill gate and the consume toggle are read from the same sandbox
options the linking action uses, so an admin who relaxes one relaxes both - two knobs that
have to be kept in agreement is a knob too many.
]]
function StorageTerminalBuildAction.blockedReason(character)
    local vars = SandboxVars and SandboxVars.StorageTerminal
    local required = (vars and vars.RequiredElectricalLevel) or 3
    local consume = true
    if vars ~= nil and vars.ConsumeMaterial ~= nil then consume = vars.ConsumeMaterial end

    if required > 0 and character:getPerkLevel(Perks.Electricity) < required then
        return string.format(
            "Requires Electrical %d. You have %d.",
            required, character:getPerkLevel(Perks.Electricity)
        )
    end
    if BaseIndexLinkAction.findTool(character) == nil then
        return "Requires a screwdriver."
    end
    if consume and StorageTerminalBuildAction.findMaterial(character) == nil then
        return "Requires electronics scrap."
    end
    return nil
end

function StorageTerminalBuildAction:isValid()
    if self.object == nil then return false end
    return StorageTerminalBuildAction.blockedReason(self.character) == nil
end

function StorageTerminalBuildAction:waitToStart()
    self.character:faceThisObject(self.object)
    return self.character:shouldBeTurning()
end

function StorageTerminalBuildAction:update()
    self.character:faceThisObject(self.object)
end

function StorageTerminalBuildAction:start()
    self:setActionAnim("Loot")
end

function StorageTerminalBuildAction:stop()
    ISBaseTimedAction.stop(self)
end

function StorageTerminalBuildAction:perform()
    --[[
    The scrap is consumed here, not in start().

    An action interrupted halfway - the player walks off, a zombie arrives - must not have
    eaten the part. perform() only runs on completion.
    ]]
    local vars = SandboxVars and SandboxVars.StorageTerminal
    local consume = true
    if vars ~= nil and vars.ConsumeMaterial ~= nil then consume = vars.ConsumeMaterial end

    if consume then
        local material = StorageTerminalBuildAction.findMaterial(self.character)
        if material ~= nil then
            self.character:getInventory():Remove(material)
        end
    end

    StorageTerminal.addTerminal(self.object)

    -- More than a link awards, because this is the larger piece of work.
    self.character:getXp():AddXP(Perks.Electricity, 15)

    ISBaseTimedAction.perform(self)
end

function StorageTerminalBuildAction:new(character, object)
    local o = ISBaseTimedAction.new(self, character)
    o.object = object
    o.maxTime = opt("TerminalBuildTime")
    if character:isTimedActionInstant() then o.maxTime = 1 end
    return o
end
