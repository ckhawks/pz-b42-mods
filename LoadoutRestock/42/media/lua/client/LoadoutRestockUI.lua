--[[
The loadout window.

Three things, in the order a player uses them: name and save what you are wearing now,
pick a saved loadout, then refill it.

The item list shows have against want rather than only what is missing. A loadout is a
checklist, and the value of a checklist is that you can see the whole thing at a glance -
hiding the satisfied rows would mean the list reshuffles as items arrive, which is exactly
when you are trying to read it.
]]

require "ISUI/ISCollapsableWindow"
require "ISUI/ISScrollingListBox"
require "ISUI/ISTextEntryBox"
require "ISUI/ISButton"

LoadoutRestockUI = ISCollapsableWindow:derive("LoadoutRestockUI")

local FONT = UIFont.Small
local PAD = 8
local ROW_H = 22
local ICON = 20

-- Slow poll so have-counts tick up as queued transfers land, without rescanning containers
-- every frame.
local REFRESH_FRAMES = 60

local instances = {}

--[[
Item icons, gathered from whatever real items happen to be in reach.

There is no reliable zero-argument way to get a texture from a type name alone, but any
live item of that type carries one. So the cache is filled opportunistically during
refresh, from the player's own inventory and from the containers they can reach. A type
that has never been seen simply draws without an icon, which is honest: it is a type you do
not currently have anywhere nearby.
]]
local textures = {}

local function rememberTexture(item)
    local fullType = tostring(item:getFullType())
    if textures[fullType] == nil then
        textures[fullType] = item:getTex()
    end
    return fullType
end

-- ==========================================================================

function LoadoutRestockUI:createChildren()
    ISCollapsableWindow.createChildren(self)

    local width = self.width - PAD * 2
    local y = self:titleBarHeight() + PAD

    local saveW = 110
    self.nameEntry = ISTextEntryBox:new("", PAD, y, width - saveW - PAD, ROW_H)
    self.nameEntry:initialise()
    self.nameEntry:instantiate()
    self.nameEntry.font = FONT
    self.nameEntry:setAnchorRight(true)
    self:addChild(self.nameEntry)

    self.saveButton = ISButton:new(
        self.width - PAD - saveW, y, saveW, ROW_H, "Save current", self, LoadoutRestockUI.onSave
    )
    self.saveButton:initialise()
    self.saveButton:setAnchorLeft(false)
    self.saveButton:setAnchorRight(true)
    self:addChild(self.saveButton)

    y = y + ROW_H + PAD

    -- The preset list is short by nature - people keep two or three loadouts, not twenty -
    -- so it gets a fixed slice and the item list takes the rest.
    local presetH = ROW_H * 4
    self.presetList = ISScrollingListBox:new(PAD, y, width, presetH)
    self.presetList:initialise()
    self.presetList:instantiate()
    self.presetList.itemheight = ROW_H
    self.presetList.font = FONT
    self.presetList.drawBorder = true
    self.presetList:setAnchorRight(true)
    self.presetList:setOnMouseDownFunction(self, LoadoutRestockUI.onPresetClicked)
    self:addChild(self.presetList)

    y = y + presetH + PAD

    local footer = ROW_H * 2 + PAD * 3 + getTextManager():getFontHeight(FONT)
    self.itemList = ISScrollingListBox:new(PAD, y, width, self.height - y - footer)
    self.itemList:initialise()
    self.itemList:instantiate()
    self.itemList.itemheight = math.max(ICON, getTextManager():getFontHeight(FONT)) + 6
    self.itemList.font = FONT
    self.itemList.drawBorder = true
    self.itemList:setAnchorRight(true)
    self.itemList:setAnchorBottom(true)
    self.itemList.doDrawItem = LoadoutRestockUI.drawItemRow
    self:addChild(self.itemList)

    local buttonY = self.height - ROW_H - PAD
    local buttonW = (width - PAD * 2) / 3

    local function addButton(index, text, handler)
        local button = ISButton:new(
            PAD + (buttonW + PAD) * index, buttonY, buttonW, ROW_H, text, self, handler
        )
        button:initialise()
        button:setAnchorTop(false)
        button:setAnchorBottom(true)
        self:addChild(button)
        return button
    end

    self.restockButton = addButton(0, "Restock", LoadoutRestockUI.onRestock)
    self.dumpButton = addButton(1, "Put back extras", LoadoutRestockUI.onDump)
    self.deleteButton = addButton(2, "Delete", LoadoutRestockUI.onDelete)

    self.status = ""
    self.frames = 0
    self:refresh()
end

-- ==========================================================================

function LoadoutRestockUI.drawItemRow(self, y, item, alt)
    local row = item.item
    local height = self.itemheight

    if self.selected == item.index then
        self:drawRect(0, y, self:getWidth(), height, 0.3, 0.7, 0.35, 0.15)
    elseif alt then
        self:drawRect(0, y, self:getWidth(), height, 0.06, 1, 1, 1)
    end

    --[[
    Green when satisfied, amber when short.

    Colour rather than an icon or a prefix, because the question being asked of this list
    is "am I ready" and that should be answerable without reading any of it.
    ]]
    local r, g, b = 0.6, 0.85, 0.6
    if not row.satisfied then r, g, b = 0.95, 0.8, 0.45 end

    local textX = PAD
    local texture = textures[row.fullType]
    if texture ~= nil then
        self:drawTextureScaledAspect(texture, PAD, y + (height - ICON) / 2, ICON, ICON, 1, 1, 1, 1)
        textX = PAD + ICON + 6
    end

    local textY = y + (height - getTextManager():getFontHeight(FONT)) / 2
    self:drawText(row.label, textX, textY, r, g, b, 1, self.font)

    local right = row.detail
    local rightWidth = getTextManager():MeasureStringX(self.font, right)
    self:drawText(right, self:getWidth() - rightWidth - 24, textY, r, g, b, 1, self.font)

    return y + height
end

-- The argument is the preset name, already unwrapped by the list box.
function LoadoutRestockUI:onPresetClicked(name)
    if name == nil then return end
    self.selectedPreset = name
    self.nameEntry:setText(name)
    self:refresh()
end

-- ==========================================================================

function LoadoutRestockUI:playerObj()
    return getSpecificPlayer(self.playerNum)
end

function LoadoutRestockUI:onSave()
    local playerObj = self:playerObj()
    if playerObj == nil then return end

    local name = self.nameEntry:getInternalText()
    if name == nil or name == "" then
        self.status = "Give the loadout a name first."
        return
    end

    LoadoutRestock.capture(playerObj, name)
    self.selectedPreset = name
    self.status = "Saved " .. name
    self:refresh()
end

function LoadoutRestockUI:onRestock()
    local playerObj = self:playerObj()
    local preset = self.selectedPreset and LoadoutRestock.get(playerObj, self.selectedPreset)
    if preset == nil then
        self.status = "Select a loadout first."
        return
    end

    local fetched, unavailable = LoadoutRestock.restock(playerObj, preset)

    --[[
    Say what could not be found, by name and count.

    This is the message the whole feature exists for. A restock that silently comes up four
    bandages short is worse than no restock, because you find out when you need them.
    ]]
    local short = {}
    for fullType, count in pairs(unavailable) do
        short[#short + 1] = string.format("%s x%d", LoadoutRestockUI.shortName(fullType), count)
    end
    table.sort(short)

    if #short == 0 then
        self.status = fetched > 0 and string.format("Fetching %d items.", fetched) or "Already complete."
    else
        self.status = string.format(
            "Fetching %d. Could not find %s.", fetched, table.concat(short, ", ")
        )
    end

    self:refresh()
end

function LoadoutRestockUI:onDump()
    local playerObj = self:playerObj()
    local preset = self.selectedPreset and LoadoutRestock.get(playerObj, self.selectedPreset)
    if preset == nil then
        self.status = "Select a loadout first."
        return
    end

    local queued = LoadoutRestock.dumpExtra(playerObj, preset)
    if queued == 0 then
        self.status = "Nothing spare has a home in reach."
    else
        self.status = string.format("Putting back %d items.", queued)
    end
    self:refresh()
end

function LoadoutRestockUI:onDelete()
    if self.selectedPreset == nil then return end
    LoadoutRestock.delete(self:playerObj(), self.selectedPreset)
    self.status = "Deleted " .. self.selectedPreset
    self.selectedPreset = nil
    self:refresh()
end

--[[
`Base.WaterBottleFull` reads as "WaterBottleFull".

Only used where a real item is not in hand to ask for a display name - the module prefix is
noise in every context a player sees.
]]
function LoadoutRestockUI.shortName(fullType)
    local stripped = string.match(fullType, "%.(.+)$")
    return stripped or fullType
end

-- ==========================================================================

function LoadoutRestockUI:refresh()
    local playerObj = self:playerObj()
    if playerObj == nil then return end

    -- Opportunistic icon harvest, from the player and from everything in reach.
    local items = playerObj:getInventory():getItems()
    for i = 0, items:size() - 1 do rememberTexture(items:get(i)) end
    for _, container in ipairs(LoadoutRestock.sources(playerObj)) do
        local contents = container:getItems()
        for i = 0, contents:size() - 1 do rememberTexture(contents:get(i)) end
    end

    local selected = self.selectedPreset
    self.presetList:clear()
    local names = {}
    for name in pairs(LoadoutRestock.all(playerObj)) do names[#names + 1] = name end
    table.sort(names)
    for index, name in ipairs(names) do
        self.presetList:addItem(name, name)
        if name == selected then self.presetList.selected = index end
    end

    self.itemList:clear()
    local preset = selected and LoadoutRestock.get(playerObj, selected)
    if preset == nil then
        self.ready = nil
        return
    end

    local missing, extra, slots = LoadoutRestock.delta(playerObj, preset)

    -- Worn and held slots first: they are the part of a loadout you notice missing.
    for _, slot in ipairs(slots) do
        self.itemList:addItem("", {
            fullType = slot.fullType,
            label = LoadoutRestockUI.shortName(slot.fullType),
            detail = slot.kind,
            satisfied = slot.satisfied,
        })
    end

    for _, fullType in ipairs(preset.carriedOrder or {}) do
        local want = preset.carried[fullType]
        local short = missing[fullType] or 0
        self.itemList:addItem("", {
            fullType = fullType,
            label = LoadoutRestockUI.shortName(fullType),
            detail = string.format("%d / %d", want - short, want),
            satisfied = short == 0,
        })
    end

    local outstanding = 0
    for _ in pairs(missing) do outstanding = outstanding + 1 end
    for _, slot in ipairs(slots) do
        if not slot.satisfied then outstanding = outstanding + 1 end
    end

    local spare = 0
    for _, count in pairs(extra) do spare = spare + count end

    self.ready = outstanding == 0
    self.spare = spare
end

function LoadoutRestockUI:prerender()
    ISCollapsableWindow.prerender(self)

    self.frames = (self.frames or 0) + 1
    if self.frames >= REFRESH_FRAMES then
        self.frames = 0
        self:refresh()
    end
end

function LoadoutRestockUI:render()
    ISCollapsableWindow.render(self)

    local lineHeight = getTextManager():getFontHeight(FONT)
    local y = self.height - ROW_H - PAD * 2 - lineHeight

    if self.status ~= "" then
        self:drawText(self.status, PAD, y, 0.75, 0.75, 0.8, 1, FONT)
    elseif self.ready == true then
        local text = "Loadout complete"
        if (self.spare or 0) > 0 then
            text = string.format("Loadout complete. %d spare items.", self.spare)
        end
        self:drawText(text, PAD, y, 0.6, 0.85, 0.6, 1, FONT)
    elseif self.ready == false then
        self:drawText("Loadout incomplete", PAD, y, 0.95, 0.8, 0.45, 1, FONT)
    end
end

-- ==========================================================================

function LoadoutRestockUI:new(x, y, width, height, playerNum)
    local o = ISCollapsableWindow:new(x, y, width, height)
    setmetatable(o, self)
    self.__index = self
    o.playerNum = playerNum
    o.title = "Loadouts"
    o.resizable = true
    o:setResizable(true)
    o.status = ""
    o.frames = 0
    return o
end

function LoadoutRestockUI.toggle(playerNum)
    playerNum = playerNum or 0

    local existing = instances[playerNum]
    if existing ~= nil then
        existing:removeFromUIManager()
        instances[playerNum] = nil
        return
    end

    local window = LoadoutRestockUI:new(140, 140, 420, 520, playerNum)
    window:initialise()
    window:addToUIManager()
    instances[playerNum] = window
end

-- ==========================================================================
-- Opening it
-- ==========================================================================

--[[
A keybind rather than a context menu entry.

Restocking is something you do on the way out of the door, not something you do to a
particular object, so there is no world object it naturally hangs off. A key also avoids
adding yet another entry to every right click, which is the thing the storage terminal
had to be walked back from.
]]
local function addKeyBinding()
    table.insert(keyBinding, { value = "[Loadouts]" })
    table.insert(keyBinding, { value = "Open loadouts", key = Keyboard.KEY_L })
end

Events.OnGameBoot.Add(addKeyBinding)

Events.OnKeyPressed.Add(function(key)
    if key == getCore():getKey("Open loadouts") then
        LoadoutRestockUI.toggle(0)
    end
end)
