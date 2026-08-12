--[[
Managing the base areas.

The list of rectangles that define the base, with the three ways to change it: draw one,
claim the building you are standing in, or delete one.

Claiming a building is not a separate concept - it produces an ordinary area from the
building's own footprint. That matters because a player should never have to reason about
two kinds of base region, and because a house claimed this way is exact rather than
approximately traced by hand.
]]

require "ISUI/ISCollapsableWindow"
require "ISUI/ISScrollingListBox"
require "ISUI/ISButton"

BaseAreaPanel = ISCollapsableWindow:derive("BaseAreaPanel")

local FONT = UIFont.Small
local PAD = 8
local ROW_H = 22

local instances = {}

function BaseAreaPanel:createChildren()
    ISCollapsableWindow.createChildren(self)

    local width = self.width - PAD * 2
    local y = self:titleBarHeight() + PAD

    self.list = ISScrollingListBox:new(PAD, y, width, self.height - y - (ROW_H * 2) - PAD * 4)
    self.list:initialise()
    self.list:instantiate()
    self.list.itemheight = ROW_H + 4
    self.list.font = FONT
    self.list.drawBorder = true
    self.list:setAnchorRight(true)
    self.list:setAnchorBottom(true)
    self.list.doDrawItem = BaseAreaPanel.drawRow
    self.list:setOnMouseDownFunction(self, BaseAreaPanel.onRowClicked)
    self:addChild(self.list)

    local buttonY = self.height - (ROW_H * 2) - PAD * 2
    local half = (width - PAD) / 2

    self.drawButton = ISButton:new(PAD, buttonY, half, ROW_H, "Draw an area", self, BaseAreaPanel.onDraw)
    self.drawButton:initialise()
    self.drawButton:setAnchorTop(false)
    self.drawButton:setAnchorBottom(true)
    self:addChild(self.drawButton)

    self.buildingButton = ISButton:new(
        PAD + half + PAD, buttonY, half, ROW_H, "Claim this building", self, BaseAreaPanel.onClaimBuilding
    )
    self.buildingButton:initialise()
    self.buildingButton:setAnchorTop(false)
    self.buildingButton:setAnchorBottom(true)
    self:addChild(self.buildingButton)

    self.removeButton = ISButton:new(
        PAD, self.height - ROW_H - PAD, width, ROW_H, "Remove selected area", self, BaseAreaPanel.onRemove
    )
    self.removeButton:initialise()
    self.removeButton:setAnchorTop(false)
    self.removeButton:setAnchorBottom(true)
    self.removeButton:setAnchorRight(true)
    self:addChild(self.removeButton)

    self.status = ""
    self:refresh()
end

function BaseAreaPanel.drawRow(self, y, item, alt)
    local area = item.item
    local height = self.itemheight

    if self.selected == item.index then
        self:drawRect(0, y, self:getWidth(), height, 0.3, 0.7, 0.35, 0.15)
    elseif alt then
        self:drawRect(0, y, self:getWidth(), height, 0.06, 1, 1, 1)
    end

    local textY = y + (height - getTextManager():getFontHeight(FONT)) / 2
    self:drawText(area.name or "Area", PAD, textY, 1, 1, 1, 1, self.font)

    local size = string.format(
        "%dx%d%s",
        area.x2 - area.x1 + 1, area.y2 - area.y1 + 1,
        area.z ~= 0 and string.format("  floor %d", area.z) or ""
    )
    local width = getTextManager():MeasureStringX(self.font, size)
    self:drawText(size, self:getWidth() - width - 24, textY, 0.7, 0.7, 0.7, 1, self.font)

    return y + height
end

-- The argument is the area itself, already unwrapped by the list box.
function BaseAreaPanel:onRowClicked(area)
    if area ~= nil then self.selectedArea = area end
end

-- ==========================================================================

function BaseAreaPanel:onDraw()
    local window = BaseAreaDrawUI:new(
        self.playerNum,
        string.format("Area %d", BaseIndex.areaCount() + 1),
        self,
        function(panel) if panel then panel:refresh() end end
    )
    window:initialise()
    window:addToUIManager()

    -- The panel gets out of the way while drawing. The player is looking at the ground and
    -- a list of areas sitting over it is just something to drag the window off.
    self:setVisible(false)
end

--[[
Claim the building the player is standing in.

`BuildingDef` gives exact bounds, so this is both easier and more accurate than tracing a
house by hand - and a house is the most common single thing anyone would want to claim.

Refused rather than guessed at when the player is outdoors: a building claim with no
building is not something to approximate.
]]
function BaseAreaPanel:onClaimBuilding()
    local playerObj = getSpecificPlayer(self.playerNum)
    if playerObj == nil then return end

    local square = playerObj:getCurrentSquare()
    local building = square and square:getBuilding() or nil
    if building == nil then
        self.status = "Stand inside a building to claim it."
        return
    end

    local def = building:getDef()
    if def == nil then
        self.status = "That building has no definition to read."
        return
    end

    local x1, y1 = def:getX(), def:getY()
    local x2, y2 = def:getX2(), def:getY2()
    local z = math.floor(playerObj:getZ())

    -- Already claimed is a no-op with an explanation, not a duplicate rectangle.
    for _, area in ipairs(BaseIndex.areas()) do
        if area.z == z and area.x1 == x1 and area.y1 == y1 and area.x2 == x2 and area.y2 == y2 then
            self.status = "This building is already claimed."
            return
        end
    end

    BaseIndex.addArea(string.format("Building %d", BaseIndex.areaCount() + 1), x1, y1, x2, y2, z)
    self.status = string.format("Claimed a %dx%d building.", x2 - x1 + 1, y2 - y1 + 1)
    self:refresh()
end

function BaseAreaPanel:onRemove()
    if self.selectedArea == nil then
        self.status = "Select an area first."
        return
    end
    BaseIndex.removeArea(self.selectedArea.id)
    self.selectedArea = nil
    self.status = ""
    self:refresh()
end

-- ==========================================================================

function BaseAreaPanel:refresh()
    local selectedId = self.selectedArea and self.selectedArea.id
    self.list:clear()

    for index, area in ipairs(BaseIndex.areas()) do
        self.list:addItem(area.name or "Area", area)
        if area.id == selectedId then
            self.list.selected = index
            self.selectedArea = area
        end
    end
end

function BaseAreaPanel:prerender()
    ISCollapsableWindow.prerender(self)

    --[[
    Areas are highlighted on the ground whenever this window is open.

    The list alone tells you sizes and names; it does not tell you whether the rectangle
    actually covers the field. Showing them makes the answer obvious without a separate
    preview mode.
    ]]
    local playerObj = getSpecificPlayer(self.playerNum)
    if playerObj == nil then return end

    local z = math.floor(playerObj:getZ())
    for _, area in ipairs(BaseIndex.areas()) do
        if area.z == z then
            local selected = self.selectedArea ~= nil and area.id == self.selectedArea.id
            local r, g, b = 0.35, 0.55, 0.9
            if selected then r, g, b = 0.4, 0.9, 0.45 end
            addAreaHighlightForPlayer(
                self.playerNum, area.x1, area.y1, area.x2 + 1, area.y2 + 1, z,
                r, g, b, selected and 0.45 or 0.25
            )
        end
    end
end

function BaseAreaPanel:render()
    ISCollapsableWindow.render(self)

    local lineHeight = getTextManager():getFontHeight(FONT)
    local y = self.height - (ROW_H * 2) - PAD * 3 - lineHeight

    if self.status ~= "" then
        self:drawText(self.status, PAD, y, 0.9, 0.8, 0.5, 1, FONT)
    elseif BaseIndex.areaCount() == 0 then
        self:drawText("No areas yet - draw one or claim a building", PAD, y, 0.95, 0.8, 0.45, 1, FONT)
    else
        self:drawText(
            string.format("%d areas, %d squares surveyed", BaseIndex.areaCount(), BaseIndex.areaSquares()),
            PAD, y, 0.6, 0.6, 0.6, 1, FONT
        )
    end
end

-- ==========================================================================

function BaseAreaPanel:new(playerNum)
    local width, height = 380, 380
    local o = ISCollapsableWindow:new(180, 180, width, height)
    setmetatable(o, self)
    self.__index = self
    o.playerNum = playerNum
    o.title = "Base Areas"
    o.resizable = true
    o:setResizable(true)
    o.status = ""
    return o
end

function BaseAreaPanel.toggle(playerNum)
    playerNum = playerNum or 0

    local existing = instances[playerNum]
    if existing ~= nil then
        existing:removeFromUIManager()
        instances[playerNum] = nil
        return
    end

    local window = BaseAreaPanel:new(playerNum)
    window:initialise()
    window:addToUIManager()
    instances[playerNum] = window
end
