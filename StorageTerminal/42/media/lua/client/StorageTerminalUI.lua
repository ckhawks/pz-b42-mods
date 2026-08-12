--[[
The terminal window.

Shows what the network holds, where it is, and lets you pull items out of it.

Everything shown comes from the BaseIndex cache rather than a live scan, which is what
lets it report a crate three cells away at all. Entries whose chunk is not loaded keep
their last known counts and are drawn dimmed with their age, because a stale number
labelled as stale is worth much more than a zero that looks current.

Taking is the one thing here that touches the world, and it is deliberately routed through
vanilla's own transfer action rather than moving items directly. That keeps encumbrance,
animations and the multiplayer server's validation all working - a direct AddItem/Remove
would skip every one of them and desync in MP.
]]

require "ISUI/ISCollapsableWindow"
require "ISUI/ISScrollingListBox"
require "ISUI/ISTextEntryBox"
require "ISUI/ISComboBox"
require "ISUI/ISButton"
require "ISUI/ISLabel"
require "TimedActions/ISInventoryTransferAction"

StorageTerminalUI = ISCollapsableWindow:derive("StorageTerminalUI")

local FONT = UIFont.Small
local PAD = 8
local ICON = 24
local ROW_EXTRA = 10
local ROW_H = 22

--[[
How often the list rebuilds while the window is open.

Counted in frames rather than against a clock so nothing depends on a timing API whose
argument list would need guessing at. At roughly sixty frames a second this is about two
seconds - fast enough that another player emptying a crate shows up while you are still
looking, slow enough to cost nothing.

There is no event for "a container's contents changed", so polling is the only mechanism
available. BaseIndex only rescans loaded containers, so the cost scales with what is
nearby rather than with the size of the base.
]]
local REFRESH_FRAMES = 120

--[[
The faster cadence used while transfers are in flight.

Taking an item queues timed actions, so the crate does not empty at the moment of the
click - the character has to walk through the queue first. Polling at the normal rate
means the number sits visibly wrong for up to two seconds afterwards, which reads as the
button having failed.

So a take switches the window to a quarter-second poll for a few seconds, long enough to
cover the queue draining. This is also the window in which another player's transfers show
up fastest, which is a reasonable side effect: if you are taking from a crate, that is
exactly when a conflict with someone else matters.
]]
local FAST_REFRESH_FRAMES = 15
local FAST_REFRESH_DURATION = 420

--[[
Sort modes, in the order they appear in the dropdown.

`compare` receives two rows. Name is the default because a list you are reading is a list
you want alphabetised; count answers "what do I have a lot of"; category groups; recent
surfaces what someone just touched, which is the multiplayer question.
]]
local SORTS = {
    { label = "Name", compare = function(a, b) return a.name < b.name end },
    { label = "Count", compare = function(a, b) return a.count > b.count end },
    {
        label = "Category",
        compare = function(a, b)
            if a.category ~= b.category then return a.category < b.category end
            return a.name < b.name
        end,
    },
    {
        label = "Recently changed",
        compare = function(a, b)
            local aAge = a.ageHours or 9999
            local bAge = b.ageHours or 9999
            if aAge ~= bAge then return aAge < bAge end
            return a.name < b.name
        end,
    },
}

local instances = {}

-- ==========================================================================

function StorageTerminalUI:createChildren()
    ISCollapsableWindow.createChildren(self)

    local lineHeight = getTextManager():getFontHeight(FONT)
    local width = self.width - PAD * 2
    local y = self:titleBarHeight() + PAD

    local half = (width - PAD) / 2

    self.searchEntry = ISTextEntryBox:new("", PAD, y, half, ROW_H)
    self.searchEntry:initialise()
    self.searchEntry:instantiate()
    self.searchEntry.font = FONT
    self:addChild(self.searchEntry)

    self.categoryCombo = ISComboBox:new(PAD + half + PAD, y, half, ROW_H)
    self.categoryCombo:initialise()
    self.categoryCombo.font = FONT
    self.categoryCombo:addOption("All categories")
    self.categoryCombo:setAnchorRight(true)
    self:addChild(self.categoryCombo)

    y = y + ROW_H + PAD

    --[[
    The sort dropdown is labelled because its options are ambiguous on their own.

    "Name" and "Count" sitting in a bare combo next to a category filter read as another
    filter rather than an ordering. The label is measured rather than hardcoded so a
    translation cannot overlap the box.
    ]]
    local sortLabelText = "Sort by"
    local sortLabelWidth = getTextManager():MeasureStringX(FONT, sortLabelText) + 6

    self.sortLabel = ISLabel:new(PAD, y, ROW_H, sortLabelText, 0.8, 0.8, 0.8, 1, FONT, true)
    self.sortLabel:initialise()
    self:addChild(self.sortLabel)

    self.sortCombo = ISComboBox:new(PAD + sortLabelWidth, y, half - sortLabelWidth, ROW_H)
    self.sortCombo:initialise()
    self.sortCombo.font = FONT
    for _, sort in ipairs(SORTS) do
        self.sortCombo:addOption(sort.label)
    end
    self:addChild(self.sortCombo)

    y = y + ROW_H + PAD

    -- Two button rows now, plus the three status lines above them, plus a double gap
    -- under the bottom row so it does not sit flush on the frame.
    local footer = (lineHeight * 3) + (ROW_H * 2) + PAD * 5
    local listHeight = self.height - y - footer

    self.list = ISScrollingListBox:new(PAD, y, width, listHeight)
    self.list:initialise()
    self.list:instantiate()
    self.list.itemheight = math.max(ICON, lineHeight) + ROW_EXTRA
    self.list.font = FONT
    self.list.drawBorder = true
    self.list:setAnchorRight(true)
    self.list:setAnchorBottom(true)
    self.list.doDrawItem = StorageTerminalUI.drawRow

    --[[
    setOnMouseDownFunction, not an assignment to onMouseDown.

    The first version assigned the handler straight onto `list.onMouseDown`, which is the
    widget's own `(x, y)` mouse handler - so the "item" argument arrived as a mouse
    coordinate and every click threw.
    ]]
    self.list:setOnMouseDownFunction(self, StorageTerminalUI.onRowClicked)
    self:addChild(self.list)

    -- PAD * 2 below, so the row does not sit flush against the window frame.
    --[[
    Two rows: taking is three narrow buttons, depositing is one wide one.

    The deposit action needs a sentence rather than a word - "Put away" does not say that
    it only files things a container already holds, and a player who reads it as "empty my
    bag" will be surprised by what stays behind. A quarter-width button cannot carry that
    label, so it gets its own row.

    Note the field names end in Button. Storing the deposit button as `self.putAway`
    shadowed the `putAway` method on the same table, so `self:putAway()` resolved to an
    ISButton and threw "did not have __call metatable set" - which is a confusing way for
    Lua to say you assigned a widget over a function.
    ]]
    local depositY = self.height - ROW_H - PAD * 2
    local takeY = depositY - ROW_H - PAD
    local takeW = (width - PAD * 2) / 3

    local function addButton(x, y, w, text, handler)
        local button = ISButton:new(x, y, w, ROW_H, text, self, handler)
        button:initialise()
        button:setAnchorTop(false)
        button:setAnchorBottom(true)
        self:addChild(button)
        return button
    end

    self.takeOneButton = addButton(PAD, takeY, takeW, "Take 1", StorageTerminalUI.onTakeOne)
    self.takeTenButton = addButton(PAD + takeW + PAD, takeY, takeW, "Take 10", StorageTerminalUI.onTakeTen)
    self.takeAllButton = addButton(PAD + (takeW + PAD) * 2, takeY, takeW, "Take all", StorageTerminalUI.onTakeAll)

    self.putAwayButton = addButton(
        PAD, depositY, width, "Put away items into matching containers",
        StorageTerminalUI.onPutAway
    )
    self.putAwayButton:setAnchorRight(true)

    --[[
    The repair button occupies the same row as the deposit button and is normally hidden.

    Broken links are the exception, not the routine case, and a permanently visible
    "Remove broken links" button in a healthy base is clutter that also invites clicking
    when there is nothing to fix. It appears only when there is something to remove, and
    it says how many.
    ]]
    self.repairButton = addButton(PAD, depositY, width, "", StorageTerminalUI.onRepair)
    self.repairButton:setAnchorRight(true)
    self.repairButton:setVisible(false)

    self.lastQuery = nil
    self.lastCategory = nil
    self.lastSort = nil
    self.detail = ""
    self.frames = 0
    self:refresh()
end

-- ==========================================================================

function StorageTerminalUI.drawRow(self, y, item, alt)
    local record = item.item
    local height = self.itemheight

    if self.selected == item.index then
        self:drawRect(0, y, self:getWidth(), height, 0.3, 0.7, 0.35, 0.15)
    elseif alt then
        self:drawRect(0, y, self:getWidth(), height, 0.06, 1, 1, 1)
    end

    local r, g, b = 1, 1, 1
    if record.stale then r, g, b = 0.65, 0.65, 0.6 end

    --[[
    The icon is whatever the scan saw.

    BaseIndex caches one texture per item type off a live item during the scan, so a type
    that has never been scanned has no icon. Drawing nothing then is correct: the row is a
    cached count from an out-of-range container, and a placeholder would imply more
    certainty than the row has.
    ]]
    local texture = BaseIndex.textureFor(record.fullType)
    local textX = PAD
    if texture ~= nil then
        self:drawTextureScaledAspect(texture, PAD, y + (height - ICON) / 2, ICON, ICON, 1, r, g, b)
        textX = PAD + ICON + 6
    end

    local textY = y + (height - getTextManager():getFontHeight(FONT)) / 2
    self:drawText(record.name, textX, textY, r, g, b, 1, self.font)

    local countText = tostring(record.count)
    local countWidth = getTextManager():MeasureStringX(self.font, countText)
    self:drawText(countText, self:getWidth() - countWidth - 24, textY, r, g, b, 1, self.font)

    if record.stale and record.ageHours ~= nil then
        local ageText = string.format("%dh old", math.floor(record.ageHours))
        local ageWidth = getTextManager():MeasureStringX(self.font, ageText)
        self:drawText(
            ageText, self:getWidth() - countWidth - ageWidth - 48, textY,
            0.55, 0.5, 0.45, 1, self.font
        )
    end

    return y + height
end

-- The argument is the row's data, already unwrapped by
-- ISScrollingListBox:invokeOnMouseDownFunction. See the note in BaseBoardUI.
function StorageTerminalUI:onRowClicked(row)
    if row == nil or row.fullType == nil then return end
    self:showLocations(row.fullType)
end

function StorageTerminalUI:showLocations(fullType)
    local places = BaseIndex.locate(fullType)
    if #places == 0 then
        self.detail = "Not in any linked container"
        return
    end

    local parts = {}
    for index = 1, math.min(#places, 3) do
        local place = places[index]
        parts[#parts + 1] = string.format("%s (%d)", place.label, place.count)
    end
    if #places > 3 then
        parts[#parts + 1] = string.format("and %d more", #places - 3)
    end
    self.detail = table.concat(parts, ", ")
end

-- ==========================================================================
-- Taking
-- ==========================================================================

function StorageTerminalUI:onTakeOne() self:take(1) end
function StorageTerminalUI:onTakeTen() self:take(10) end
function StorageTerminalUI:onTakeAll() self:take(10000) end

--[[
Pull up to `count` of the selected type out of the network.

Containers are visited most-stocked first, which is why BaseIndex sorts `locate` that way:
a request for ten nails should empty one crate rather than take three from each of four.

Only containers currently reachable through the network are touched. A registration whose
chunk is unloaded, or which belongs to a terminal the player is not standing at, is skipped
- taking from a crate the game is not simulating is exactly the kind of thing that desyncs
in multiplayer.

Encumbrance is not checked here. ISInventoryTransferAction already refuses when the player
is full, and duplicating that check would only mean two places to keep in agreement.
]]
function StorageTerminalUI:take(count)
    local selected = self.list.items[self.list.selected]
    if selected == nil or selected.item == nil then
        self.detail = "Select an item first."
        return
    end

    local playerObj = getSpecificPlayer(self.playerNum)
    if playerObj == nil then return end

    local reachable = {}
    for _, entry in ipairs(StorageTerminal.reachableContainers()) do
        reachable[entry.key] = entry.container
    end

    local fullType = selected.item.fullType
    local remaining = count
    local queued = 0

    for _, place in ipairs(BaseIndex.locate(fullType)) do
        if remaining <= 0 then break end

        local container = reachable[place.key]
        if container ~= nil then
            local items = container:getItems()
            for i = 0, items:size() - 1 do
                if remaining <= 0 then break end
                local item = items:get(i)
                if tostring(item:getFullType()) == fullType then
                    ISTimedActionQueue.add(ISInventoryTransferAction:new(
                        playerObj, item, container, playerObj:getInventory()
                    ))
                    remaining = remaining - 1
                    queued = queued + 1
                end
            end
            -- The cached count is now wrong by however much is in flight. Marking it
            -- forces a rescan rather than letting the display drift until the next
            -- poll happens to catch it.
            BaseIndex.invalidate(place.key)
        end
    end

    if queued == 0 then
        self.detail = "Nothing reachable. The container may be out of range."
        return
    end

    self.detail = string.format("Taking %d %s.", queued, selected.item.name)

    --[[
    Show the new number immediately, then let the real scan correct it.

    The queued transfers have not happened yet, so the index is still telling the truth
    when it reports the old count - but a count that does not move when you press Take
    reads as a broken button, and the player has no way to tell the difference.

    So the row is decremented optimistically and the window switches to a fast poll. Within
    a few frames the real scan overwrites this with whatever actually happened, which is
    what makes the lie safe: it cannot persist, and if a transfer fails - inventory full,
    someone else got there first - the number simply comes back.
    ]]
    selected.item.count = math.max(0, selected.item.count - queued)
    self.fastUntil = (self.totalFrames or 0) + FAST_REFRESH_DURATION
end

-- ==========================================================================

-- ==========================================================================
-- Putting away
-- ==========================================================================

--[[
Items the player is currently using, which must never be deposited.

Built from what the character is actually wearing and holding rather than from item flags,
because the flags are inconsistent across item types and the failure here is severe: a
"put away" that strips your backpack and your weapon into a crate is worse than no feature
at all.

Favourites are protected too. That is what the star is for, and a player who has bothered
to mark something has said exactly what they mean.
]]
local function protectedItems(playerObj)
    local protected = {}

    local function protect(item)
        if item ~= nil then protected[item] = true end
    end

    local worn = playerObj:getWornItems()
    if worn ~= nil then
        for i = 0, worn:size() - 1 do
            local entry = worn:get(i)
            if entry ~= nil then protect(entry:getItem()) end
        end
    end

    protect(playerObj:getPrimaryHandItem())
    protect(playerObj:getSecondaryHandItem())

    return protected
end

function StorageTerminalUI:onPutAway() self:putAway() end

--[[
Clear out registrations and terminals whose objects are gone.

Explicitly player-triggered rather than automatic. The underlying detection is a heuristic
over streaming world state - a square can be loaded while its objects are still arriving -
so BaseIndex only calls something broken after three consecutive confirmed misses, and even
then it reports rather than deletes. Wire and time were spent on these links; removing them
should be somebody's decision.
]]
function StorageTerminalUI:onRepair()
    local links = BaseIndex.removeBrokenLinks()
    local terminals = StorageTerminal.removeBrokenTerminals()

    local parts = {}
    if links > 0 then parts[#parts + 1] = string.format("%d dead links", links) end
    if terminals > 0 then parts[#parts + 1] = string.format("%d dead terminals", terminals) end

    if #parts == 0 then
        self.detail = "Nothing to clean up."
    else
        self.detail = "Removed " .. table.concat(parts, " and ")
    end

    self:refresh()
end

--[[
Show or hide the repair button based on what is currently broken.

Called from refresh rather than render so the counts come from the same scan the list was
built from - a button that disagrees with the list it sits under is worse than no button.
]]
function StorageTerminalUI:updateRepairButton()
    local links = #BaseIndex.brokenLinks()
    local terminals = #StorageTerminal.brokenTerminals()
    local total = links + terminals

    if total == 0 then
        self.repairButton:setVisible(false)
        self.putAwayButton:setVisible(true)
        return
    end

    -- The repair button takes the deposit button's row while it is showing. Depositing
    -- into a network with dead links is not dangerous, just less useful than fixing them,
    -- and a third button row for a rare case is not worth the height.
    self.putAwayButton:setVisible(false)
    self.repairButton:setVisible(true)
    self.repairButton:setTitle(string.format(
        "Remove %d broken %s", total, total == 1 and "link" or "links"
    ))
end

--[[
Send everything back to the crate it came from.

The rule is deliberately conservative: an item is only deposited if some reachable
container **already holds that type**. Nothing gets filed somewhere new.

That is the difference between a feature people trust and one they turn off. A sorter that
guesses where things belong will eventually put your ammo in the food crate, and the cost
of being wrong - hunting through twenty containers for one item - is much higher than the
cost of leaving something in your bag. If it has a home, it goes home; if it does not, it
stays with you and the message says how many.
]]
function StorageTerminalUI:putAway()
    local playerObj = getSpecificPlayer(self.playerNum)
    if playerObj == nil then return end

    local reachable = StorageTerminal.reachableContainers()
    if #reachable == 0 then
        self.detail = "Network is unreachable."
        return
    end

    --[[
    One pass over the network to learn where each type lives.

    Built fresh per press rather than cached, because the answer changes as soon as anyone
    moves anything, and a stale destination map is how items end up in the wrong crate.
    ]]
    local destination = {}
    for _, entry in ipairs(reachable) do
        local items = entry.container:getItems()
        for i = 0, items:size() - 1 do
            local fullType = tostring(items:get(i):getFullType())
            if destination[fullType] == nil then
                destination[fullType] = entry
            end
        end
    end

    local protected = protectedItems(playerObj)
    local inventory = playerObj:getInventory()
    local items = inventory:getItems()

    --[[
    The list is snapshotted before anything is queued.

    Iterating a container while queueing transfers out of it is asking for the collection
    to be modified underneath the loop. Copying the references first costs nothing at
    inventory scale and removes the question entirely.
    ]]
    local candidates = {}
    for i = 0, items:size() - 1 do
        candidates[#candidates + 1] = items:get(i)
    end

    local queued, homeless = 0, 0
    local touched = {}

    for _, item in ipairs(candidates) do
        --[[
        isEquipped as well as the worn-items sweep.

        Vanilla pairs `isFavorite() or isEquipped()` when deciding what may be moved in
        bulk - ISCampingMenu.lua:33 and TransferSameTypeMultiContainer.lua:40 both do it -
        and it costs nothing to agree with the game about what counts as in use.
        ]]
        if not protected[item] and not item:isFavorite() and not item:isEquipped() then
            local entry = destination[tostring(item:getFullType())]
            if entry == nil then
                homeless = homeless + 1

            --[[
            hasRoomFor takes the character as well as the item.

            The one argument form threw: vanilla calls `hasRoomFor(character, item)` in
            every case that matters - ISInventoryTransferAction.lua:110,
            ISGrabItemAction.lua:27, ISBaseIcon.lua:127 - and Kahlua raises on an argument
            list that matches no overload rather than returning an error.
            ]]
            elseif entry.container:hasRoomFor(playerObj, item) then
                ISTimedActionQueue.add(ISInventoryTransferAction:new(
                    playerObj, item, inventory, entry.container
                ))
                queued = queued + 1
                touched[entry.key] = true
            end
        end
    end

    for key in pairs(touched) do
        BaseIndex.invalidate(key)
    end

    if queued == 0 then
        self.detail = "Nothing in your inventory has a home in the network."
    elseif homeless > 0 then
        self.detail = string.format("Putting away %d. %d have no home yet.", queued, homeless)
    else
        self.detail = string.format("Putting away %d items.", queued)
    end

    self.fastUntil = (self.totalFrames or 0) + FAST_REFRESH_DURATION
end

-- ==========================================================================

function StorageTerminalUI:refresh()
    local refreshed, skipped, changed = BaseIndex.refresh()
    self.refreshed = refreshed
    self.skipped = skipped

    local query = string.lower(self.searchEntry:getInternalText() or "")
    local category = self.categoryCombo:getOptionText(self.categoryCombo.selected)
    local sortIndex = self.sortCombo.selected or 1

    self.lastQuery = query
    self.lastCategory = category
    self.lastSort = sortIndex

    --[[
    Selection is preserved across a rebuild.

    The list rebuilds every couple of seconds, and without this the row a player clicked
    would deselect itself under the cursor while they were reading it - or worse, while
    they were reaching for Take.
    ]]
    local selectedType = nil
    local selected = self.list.items[self.list.selected]
    if selected ~= nil and selected.item ~= nil then
        selectedType = selected.item.fullType
    end

    self.list:clear()

    local rows = {}
    local categories = { ["All categories"] = true }

    for fullType, record in pairs(BaseIndex.contents()) do
        local name = record.name or fullType
        local rowCategory = record.category or "Item"
        categories[rowCategory] = true

        local matchesQuery = query == "" or string.find(string.lower(name), query, 1, true)
        local matchesCategory = category == nil
            or category == "All categories"
            or rowCategory == category

        if matchesQuery and matchesCategory then
            local _, age = BaseIndex.totalOf(fullType)
            rows[#rows + 1] = {
                fullType = fullType,
                name = name,
                category = rowCategory,
                count = record.count,
                ageHours = age,
                -- Anything older than an in-game hour is worth flagging. Below that the
                -- number is effectively live and the marker would just be noise.
                stale = age ~= nil and age > 1,
            }
        end
    end

    table.sort(rows, (SORTS[sortIndex] or SORTS[1]).compare)

    for index, row in ipairs(rows) do
        self.list:addItem(row.name, row)
        if row.fullType == selectedType then self.list.selected = index end
    end

    self.rowCount = #rows
    self:syncCategories(categories)
    self:updateRepairButton()
end

--[[
Keep the category dropdown in step with what the base actually contains.

Rebuilt only when the set of categories changes, because rebuilding it every poll would
close it under the player's cursor mid-click.
]]
function StorageTerminalUI:syncCategories(categories)
    local names = {}
    for name in pairs(categories) do names[#names + 1] = name end
    table.sort(names)

    local signature = table.concat(names, "|")
    if signature == self.categorySignature then return end
    self.categorySignature = signature

    local previous = self.categoryCombo:getOptionText(self.categoryCombo.selected)
    self.categoryCombo:clear()
    for index, name in ipairs(names) do
        self.categoryCombo:addOption(name)
        if name == previous then self.categoryCombo.selected = index end
    end
end

--[[
Search, filter and sort are polled rather than hooked.

The change callbacks on ISTextEntryBox and ISComboBox vary between builds, and a wrong
signature would cost a restart to discover. Comparing three values once a frame is free at
this scale and cannot be wrong.
]]
--[[
Close the window when the player walks away from the terminal.

A console you can keep reading from across the base is a console that is not really a
place, which undoes the whole reason the range gate exists. Leaving it open also lets Take
be pressed from anywhere - the transfer would be refused, but offering a button that
cannot work is worse than not offering it.

Power loss deliberately does not close it. There the console is still in front of you and
the status line is the only explanation the player will get, so it stays open and says so.

The grace period exists because the player's position is sampled every frame and a
doorway, a shove or a knockback can move them momentarily. Snapping shut on a single
frame's reading would make the window feel twitchy at the edge of range.
]]
local AWAY_GRACE_FRAMES = 20

function StorageTerminalUI:checkStillThere()
    local playerObj = getSpecificPlayer(self.playerNum)
    if playerObj == nil or playerObj:isDead() then
        self:close()
        return false
    end

    if StorageTerminal.inRange(playerObj) then
        self.awayFrames = 0
        return true
    end

    self.awayFrames = (self.awayFrames or 0) + 1
    if self.awayFrames > AWAY_GRACE_FRAMES then
        self:close()
        return false
    end
    return true
end

function StorageTerminalUI:close()
    instances[self.playerNum] = nil
    self:removeFromUIManager()
end

function StorageTerminalUI:prerender()
    ISCollapsableWindow.prerender(self)

    if not self:checkStillThere() then return end

    local query = string.lower(self.searchEntry:getInternalText() or "")
    local category = self.categoryCombo:getOptionText(self.categoryCombo.selected)
    local sortIndex = self.sortCombo.selected or 1

    if query ~= self.lastQuery or category ~= self.lastCategory or sortIndex ~= self.lastSort then
        self:refresh()
        return
    end

    self.totalFrames = (self.totalFrames or 0) + 1
    self.frames = (self.frames or 0) + 1

    local interval = REFRESH_FRAMES
    if self.fastUntil ~= nil and self.totalFrames < self.fastUntil then
        interval = FAST_REFRESH_FRAMES
    end

    if self.frames >= interval then
        self.frames = 0
        self:refresh()
    end
end

function StorageTerminalUI:render()
    ISCollapsableWindow.render(self)

    -- Kept in step with the footer reservation in createChildren: three text lines sit
    -- above two button rows, the lower of which carries a double gap beneath it.
    local lineHeight = getTextManager():getFontHeight(FONT)
    local y = self.height - (ROW_H * 2) - PAD * 4 - (lineHeight * 3)

    --[[
    The status line exists because the failure mode of this whole feature is silence.

    If the terminal has no power, or someone switched it off, or the player walked out of
    range, the only visible symptom is a list that did not grow. Saying which of those
    happened turns a bug report into a fuel top-up.
    ]]
    local reachable, reason = StorageTerminal.status()
    if reachable then
        self:drawText(
            string.format(
                "%d types. %d containers read, %d out of range.",
                self.rowCount or 0, self.refreshed or 0, self.skipped or 0
            ),
            PAD, y, 0.6, 0.8, 0.6, 1, FONT
        )
    else
        self:drawText("Offline: " .. tostring(reason), PAD, y, 0.9, 0.5, 0.4, 1, FONT)
    end

    --[[
    Recent activity, which is mostly a multiplayer feature.

    There is no event for another player emptying a crate, so this is derived: BaseIndex
    fingerprints each container on every scan and stamps the ones whose total moved. Solo,
    it reports your own last few transfers, which is a decent check that it works at all.
    ]]
    local changed = BaseIndex.recentlyChanged(6)
    if #changed > 0 then
        local parts = {}
        for index = 1, math.min(#changed, 2) do
            local entry = changed[index]
            local sign = entry.delta > 0 and "+" or ""
            parts[#parts + 1] = string.format("%s %s%d", entry.label, sign, entry.delta)
        end
        if #changed > 2 then
            parts[#parts + 1] = string.format("and %d more", #changed - 2)
        end
        self:drawText(
            "Recent: " .. table.concat(parts, ", "),
            PAD, y + lineHeight, 0.8, 0.75, 0.5, 1, FONT
        )
    end

    if self.detail ~= "" then
        self:drawText(self.detail, PAD, y + lineHeight * 2, 0.75, 0.75, 0.8, 1, FONT)
    end
end

-- ==========================================================================

function StorageTerminalUI:new(x, y, width, height, playerNum)
    local o = ISCollapsableWindow:new(x, y, width, height)
    setmetatable(o, self)
    self.__index = self
    o.playerNum = playerNum
    o.title = "Storage Terminal"
    o.resizable = true
    o:setResizable(true)
    o.detail = ""
    o.rowCount = 0
    o.frames = 0
    o.totalFrames = 0
    o.fastUntil = 0
    o.awayFrames = 0
    return o
end

function StorageTerminalUI.toggle(playerNum)
    playerNum = playerNum or 0

    local existing = instances[playerNum]
    if existing ~= nil then
        existing:removeFromUIManager()
        instances[playerNum] = nil
        return
    end

    local window = StorageTerminalUI:new(120, 120, 480, 560, playerNum)
    window:initialise()
    window:addToUIManager()
    instances[playerNum] = window
end
