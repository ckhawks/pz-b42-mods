--[[
Drawing a base area by dragging a rectangle in the world.

Adapted from `ISAddDesignationAnimalZoneUI`, which is the interaction B42 already teaches
players when they fence a pasture. Reusing it means there is nothing new to learn, and the
three globals that do the actual work are vanilla:

  screenToIsoX / screenToIsoY      mouse position to world tile
  addAreaHighlightForPlayer        draw a highlighted rectangle on the ground

The panel deliberately stays small and out of the way, because the thing the player is
looking at is the ground, not this window.
]]

require "ISUI/ISPanel"
require "ISUI/ISButton"
require "ISUI/ISTextEntryBox"

BaseAreaDrawUI = ISPanel:derive("BaseAreaDrawUI")

local FONT = UIFont.Small
local PAD = 10

--[[
Size limits.

A one-tile area is a misclick, not an intention. The upper bound exists because every
survey walks these squares, and a base drawn the size of a town would stall the game for a
second each time the board refreshed - the same reason the old bounds had a cap, but now
enforced where the player can see it happening rather than silently afterwards.
]]
local MIN_SIDE = 2
local MAX_SIDE = 120

function BaseAreaDrawUI:createChildren()
    local buttonWidth = 90
    local buttonHeight = 22

    self.nameEntry = ISTextEntryBox:new(
        self.suggestedName or "Area", PAD, PAD + 40, self.width - PAD * 2, buttonHeight
    )
    self.nameEntry:initialise()
    self.nameEntry:instantiate()
    self.nameEntry.font = FONT
    self:addChild(self.nameEntry)

    self.cancelButton = ISButton:new(
        self.width - buttonWidth - PAD, self.height - buttonHeight - PAD,
        buttonWidth, buttonHeight, "Cancel", self, BaseAreaDrawUI.onCancel
    )
    self.cancelButton:initialise()
    self:addChild(self.cancelButton)
end

-- ==========================================================================
-- Picking tiles
-- ==========================================================================

function BaseAreaDrawUI:pickSquare(screenX, screenY)
    local z = math.floor(self.player:getZ())
    local worldX = screenToIsoX(self.playerNum, screenX, screenY, z)
    local worldY = screenToIsoY(self.playerNum, screenX, screenY, z)
    return math.floor(worldX), math.floor(worldY), z
end

--[[
Mouse handling is "outside" because the drag happens on the world, not on this panel.

`disableWorldMenu` is set while dragging so releasing the button does not also open the
usual right-click menu on whatever tile the drag ended on.
]]
function BaseAreaDrawUI:onMouseDownOutside(x, y)
    if self.playerNum ~= 0 then return end
    if self.startX ~= nil then return end

    local wx, wy = self:pickSquare(getMouseX(), getMouseY())
    self.startX, self.startY = wx, wy
    self.endX, self.endY = wx, wy
    self.dragging = true
    ISWorldObjectContextMenu.disableWorldMenu = true
end

function BaseAreaDrawUI:onMouseMoveOutside(dx, dy)
    if self.playerNum ~= 0 or not self.dragging then return end
    local wx, wy = self:pickSquare(getMouseX(), getMouseY())
    self.endX, self.endY = wx, wy
end

function BaseAreaDrawUI:onMouseUpOutside(x, y)
    if self.playerNum ~= 0 or not self.dragging then return end
    self.dragging = false

    --[[
    The drag ends by committing, not by opening a confirmation dialog.

    The animal zone flow asks "are you sure" after every drag. Here the rectangle is
    visible while you draw it, the size is on screen, and a wrong one takes two clicks to
    delete - so a modal would be one interruption per area for no information the player
    did not already have.
    ]]
    local width, height = self:currentSize()
    if width < MIN_SIDE or height < MIN_SIDE
        or width > MAX_SIDE or height > MAX_SIDE
    then
        self.problem = string.format(
            "%dx%d is out of range - sides must be %d to %d", width, height, MIN_SIDE, MAX_SIDE
        )
        self.startX, self.startY, self.endX, self.endY = nil, nil, nil, nil
        return
    end

    local name = self.nameEntry:getInternalText()
    if name == nil or name == "" then name = self.suggestedName or "Area" end

    BaseIndex.addArea(name, self.startX, self.startY, self.endX, self.endY, math.floor(self.player:getZ()))
    self:close()
end

function BaseAreaDrawUI:currentSize()
    if self.startX == nil then return 0, 0 end
    return math.abs(self.endX - self.startX) + 1, math.abs(self.endY - self.startY) + 1
end

-- ==========================================================================

function BaseAreaDrawUI:prerender()
    ISPanel.prerender(self)

    self:drawText("Drag across the ground to draw an area", PAD, PAD, 1, 1, 1, 1, FONT)

    local lineHeight = getTextManager():getFontHeight(FONT)
    local y = PAD + 18

    --[[
    Existing areas stay highlighted while drawing a new one.

    Without this a player has no idea what they have already covered and ends up drawing
    overlapping rectangles, or leaving a gap between two they thought met.
    ]]
    local z = math.floor(self.player:getZ())
    for _, area in ipairs(BaseIndex.areas()) do
        if area.z == z then
            addAreaHighlightForPlayer(
                self.playerNum, area.x1, area.y1, area.x2 + 1, area.y2 + 1, z,
                0.35, 0.55, 0.9, 0.25
            )
        end
    end

    if self.startX ~= nil then
        local x1 = math.min(self.startX, self.endX)
        local y1 = math.min(self.startY, self.endY)
        local x2 = math.max(self.startX, self.endX)
        local y2 = math.max(self.startY, self.endY)

        local width, height = self:currentSize()
        local ok = width >= MIN_SIDE and height >= MIN_SIDE
            and width <= MAX_SIDE and height <= MAX_SIDE

        -- Red while the rectangle is an unacceptable size, so the limit is learned during
        -- the drag rather than reported after it.
        local r, g, b = 0.4, 0.9, 0.45
        if not ok then r, g, b = 0.9, 0.3, 0.25 end

        addAreaHighlightForPlayer(self.playerNum, x1, y1, x2 + 1, y2 + 1, z, r, g, b, 0.45)

        self:drawText(
            string.format("%d x %d  (%d squares)", width, height, width * height),
            PAD, self.height - 46, r, g, b, 1, FONT
        )
    else
        local mx, my = self:pickSquare(getMouseX(), getMouseY())
        addAreaHighlightForPlayer(self.playerNum, mx, my, mx + 1, my + 1, z, 1, 1, 1, 0.5)
    end

    if self.problem ~= nil then
        self:drawText(self.problem, PAD, self.height - 46, 0.95, 0.5, 0.45, 1, FONT)
    end
end

function BaseAreaDrawUI:onCancel()
    self:close()
end

function BaseAreaDrawUI:close()
    ISWorldObjectContextMenu.disableWorldMenu = false
    self:setVisible(false)
    self:removeFromUIManager()
    if self.onFinish then self.onFinish(self.parentPanel) end
end

function BaseAreaDrawUI:new(playerNum, suggestedName, parentPanel, onFinish)
    local width, height = 320, 130
    local o = ISPanel:new(
        getCore():getScreenWidth() / 2 - width / 2, 60, width, height
    )
    setmetatable(o, self)
    self.__index = self
    o.playerNum = playerNum
    o.player = getSpecificPlayer(playerNum)
    o.suggestedName = suggestedName
    o.parentPanel = parentPanel
    o.onFinish = onFinish
    o.moveWithMouse = true
    o.backgroundColor = { r = 0, g = 0, b = 0, a = 0.8 }
    return o
end
