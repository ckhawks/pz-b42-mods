--[[
The board window.

Two panes, because the board answers two different kinds of question and mixing them would
make both harder to read.

The top is state: generator, and supply totals by category from BaseIndex. It is a glance,
not a spreadsheet - if you want to know exactly how many nails you own, that is the storage
terminal's job and it is better at it.

The bottom is the task list, which is the part that only makes sense on a shared board.
]]

require "ISUI/ISCollapsableWindow"
require "ISUI/ISScrollingListBox"
require "ISUI/ISTextEntryBox"
require "ISUI/ISButton"

BaseBoardUI = ISCollapsableWindow:derive("BaseBoardUI")

local FONT = UIFont.Small
local PAD = 8
local ROW_H = 22

-- The board is glanced at, not watched, so it refreshes slowly. Nothing here is worth a
-- container rescan every frame.
local REFRESH_FRAMES = 180

--[[
Categories pinned to the top of the supply pane, in this order.

These are the ones a base actually runs out of, and the ones the original request named.
Everything else is folded into a single trailing row: a supply board that lists forty
categories is a spreadsheet, and nobody reads a spreadsheet on the way past.

Matched case-insensitively against whatever `getDisplayCategory` returned during the scan,
because the exact strings differ between item types and B42 has moved some of them.
]]
--[[
Ammo is deliberately absent from this list.

It gets its own broken-out rows below, by type, because "340 ammo" answers nothing and the
question is always whether there is 9mm. Water and fuel are absent for the same reason:
both are measured in fluid units from the fluid system, not counted as items.
]]
local PINNED = { "Food", "FirstAid", "Medical", "Tool", "Material" }

-- How many ammunition types to name before folding the rest into a count.
local AMMO_ROWS = 3

local instances = {}

-- ==========================================================================

function BaseBoardUI:createChildren()
    ISCollapsableWindow.createChildren(self)

    local lineHeight = getTextManager():getFontHeight(FONT)
    local width = self.width - PAD * 2
    local y = self:titleBarHeight() + PAD

    --[[
    Fixed slice for state, sized for the worst case rather than the current one.

    Generator, the pinned supply categories, an overflow row, a staleness row, and four
    survey lines. Reserving the maximum means the task list never moves when a section
    appears or disappears - a list that jumps as your animals get hungry is a list you
    misclick.
    ]]
    -- Generator, pinned supply categories, overflow, staleness, food, water, perishables,
    -- four survey lines, and the bounds note. Reserved at the maximum so the task list
    -- never shifts when a row appears.
    -- Generator, pinned categories, overflow, staleness, food, water, fuel, ammo,
    -- perishables, four survey lines, and the scope line. Reserved at the maximum so the
    -- task list never shifts when a row appears or disappears.
    self.statePanelHeight = lineHeight * (#PINNED + 13) + PAD
    y = y + self.statePanelHeight

    self.taskList = ISScrollingListBox:new(PAD, y, width, self.height - y - (ROW_H * 2) - PAD * 4)
    self.taskList:initialise()
    self.taskList:instantiate()
    self.taskList.itemheight = ROW_H + 6
    self.taskList.font = FONT
    self.taskList.drawBorder = true
    self.taskList:setAnchorRight(true)
    self.taskList:setAnchorBottom(true)
    self.taskList.doDrawItem = BaseBoardUI.drawTaskRow
    self.taskList:setOnMouseDownFunction(self, BaseBoardUI.onTaskClicked)
    self:addChild(self.taskList)

    local entryY = self.height - (ROW_H * 2) - PAD * 3
    local addW = 90

    self.taskEntry = ISTextEntryBox:new("", PAD, entryY, width - addW - PAD, ROW_H)
    self.taskEntry:initialise()
    self.taskEntry:instantiate()
    self.taskEntry.font = FONT
    self.taskEntry:setAnchorTop(false)
    self.taskEntry:setAnchorBottom(true)
    self.taskEntry:setAnchorRight(true)
    self:addChild(self.taskEntry)

    self.addButton = ISButton:new(
        self.width - PAD - addW, entryY, addW, ROW_H, "Add task", self, BaseBoardUI.onAdd
    )
    self.addButton:initialise()
    self.addButton:setAnchorTop(false)
    self.addButton:setAnchorBottom(true)
    self.addButton:setAnchorLeft(false)
    self.addButton:setAnchorRight(true)
    self:addChild(self.addButton)

    local buttonY = self.height - ROW_H - PAD * 2
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

    --[[
    Two buttons, not three.

    Release existed to give up a claim you owned. With claims as a set the only thing you
    can change is your own membership, so one button covers both directions and its label
    says which one you are about to do.
    ]]
    local third = (width - PAD * 2) / 3
    local function taskButton(index, text, handler)
        local button = ISButton:new(
            PAD + (third + PAD) * index, buttonY, third, ROW_H, text, self, handler
        )
        button:initialise()
        button:setAnchorTop(false)
        button:setAnchorBottom(true)
        self:addChild(button)
        return button
    end

    self.claimButton = taskButton(0, "Join", BaseBoardUI.onClaim)
    self.doneButton = taskButton(1, "Done", BaseBoardUI.onDone)

    -- Only appears when there is something to clear, and says how much. A permanently
    -- visible button for a rare action is clutter that also invites clicking.
    self.clearButton = taskButton(2, "Clear done", BaseBoardUI.onClearDone)
    self.clearButton:setVisible(false)

    --[[
    One button switches the lower half between tasks and the crew's skills.

    A tab strip would be more conventional and would cost a row of height for two options.
    The button names the thing you are *not* looking at, which is how a two-state toggle
    stays readable without a label explaining it.
    ]]
    self.modeButton = ISButton:new(
        self.width - PAD - 110, self.taskList:getY() - ROW_H - 2, 110, ROW_H,
        "Crew skills", self, BaseBoardUI.onToggleMode
    )
    self.modeButton:initialise()
    self.modeButton:setAnchorLeft(false)
    self.modeButton:setAnchorRight(true)
    self:addChild(self.modeButton)

    -- Areas are edited from the board because that is where their effect is visible: the
    -- survey lines above change as soon as one is drawn.
    self.areasButton = ISButton:new(
        PAD, self.taskList:getY() - ROW_H - 2, 110, ROW_H,
        "Base areas", self, BaseBoardUI.onAreas
    )
    self.areasButton:initialise()
    self:addChild(self.areasButton)

    self.mode = "tasks"
    self.frames = 0
    self.status = ""
    self:refresh()
end

function BaseBoardUI:onAreas()
    BaseAreaPanel.toggle(self.playerNum)
end

function BaseBoardUI:onToggleMode()
    self.mode = (self.mode == "tasks") and "crew" or "tasks"
    self.modeButton:setTitle(self.mode == "tasks" and "Crew skills" or "Tasks")

    -- The task controls are meaningless against a skill row, so they go away rather than
    -- sitting there doing nothing when clicked.
    local showTasks = self.mode == "tasks"
    self.taskEntry:setVisible(showTasks)
    self.addButton:setVisible(showTasks)
    self.claimButton:setVisible(showTasks)
    self.doneButton:setVisible(showTasks)
    -- The clear button manages its own visibility in updateClaimButton, which also knows
    -- whether there is anything to clear.
    self.clearButton:setVisible(false)

    self.status = ""
    self:refresh()
end

-- ==========================================================================

--[[
A skill row: name, best level in the crew, and who holds it.

Red at zero, amber below three, green above. The colour is the answer to "where are our
gaps" - a column of red at the top of the list is the whole feature, and the numbers are
for deciding which gap to close first.
]]
function BaseBoardUI.drawSkillRow(self, y, item, alt)
    local row = item.item
    local height = self.itemheight

    if alt then self:drawRect(0, y, self:getWidth(), height, 0.06, 1, 1, 1) end

    local r, g, b = 0.6, 0.85, 0.6
    if row.level == 0 then r, g, b = 0.95, 0.55, 0.5
    elseif row.level < 3 then r, g, b = 0.95, 0.8, 0.45 end

    local textY = y + (height - getTextManager():getFontHeight(FONT)) / 2
    self:drawText(row.name, PAD, textY, r, g, b, 1, self.font)

    local right = row.level == 0 and "nobody" or string.format("%d  %s", row.level, row.who or "")
    local width = getTextManager():MeasureStringX(self.font, right)
    self:drawText(right, self:getWidth() - width - 24, textY, r, g, b, 1, self.font)

    return y + height
end

function BaseBoardUI.drawTaskRow(self, y, item, alt)
    local task = item.item
    local height = self.itemheight

    if self.selected == item.index then
        self:drawRect(0, y, self:getWidth(), height, 0.3, 0.7, 0.35, 0.15)
    elseif alt then
        self:drawRect(0, y, self:getWidth(), height, 0.06, 1, 1, 1)
    end

    local names = BaseBoard.claimants(task)
    local done = BaseBoard.isDone(task)

    --[[
    Three states, three weights: open is bright, claimed is dimmed, done is dimmest.

    None are hidden. A claimed task is less likely to be your problem but is still the
    base's, and a finished one is the answer to "did anyone do the water run" - which is
    the question a shared board exists to settle.
    ]]
    local r, g, b = 1, 1, 1
    if done then r, g, b = 0.45, 0.5, 0.45
    elseif #names > 0 then r, g, b = 0.6, 0.6, 0.58 end

    local textY = y + (height - getTextManager():getFontHeight(FONT)) / 2
    self:drawText(task.text or "", PAD, textY, r, g, b, 1, self.font)

    if done then
        local by = task.doneBy and ("done by " .. tostring(task.doneBy)) or "done"
        local width = getTextManager():MeasureStringX(self.font, by)
        self:drawText(by, self:getWidth() - width - 24, textY, 0.5, 0.7, 0.5, 1, self.font)
    elseif #names > 0 then
        --[[
        Two names in full, then a count.

        A row that lists six people is unreadable and the sixth name is not the
        information anyone wants - "three others are on it" is.
        ]]
        local who = names[1]
        if #names == 2 then
            who = names[1] .. ", " .. names[2]
        elseif #names > 2 then
            who = string.format("%s, %s +%d", names[1], names[2], #names - 2)
        end

        local width = getTextManager():MeasureStringX(self.font, who)
        self:drawText(who, self:getWidth() - width - 24, textY, 0.55, 0.75, 0.9, 1, self.font)
    end

    return y + height
end

--[[
The argument is the row's data, already unwrapped.

`ISScrollingListBox:invokeOnMouseDownFunction` calls `onmousedown(target, items[i].item)`
- so what arrives here is the task itself, not the list entry wrapping it. Every one of
these handlers originally did `item.item`, unwrapping a second time, which silently
produced nil and made selection look broken everywhere.
]]
function BaseBoardUI:onTaskClicked(task)
    if task == nil then return end
    self.selectedTask = task
end

-- ==========================================================================

function BaseBoardUI:playerObj() return getSpecificPlayer(self.playerNum) end

function BaseBoardUI:onAdd()
    local text = self.taskEntry:getInternalText()
    if text == nil or text == "" then
        self.status = "Write the task first."
        return
    end
    BaseBoard.addTask(self:playerObj(), text)
    self.taskEntry:setText("")
    self.status = ""
    self:refresh()
end

function BaseBoardUI:onClaim()
    if self.selectedTask == nil then
        self.status = "Select a task first."
        return
    end
    BaseBoard.toggleClaim(self:playerObj(), self.selectedTask.id)
    self.status = ""
    self:refresh()
end

function BaseBoardUI:onDone()
    if self.selectedTask == nil then
        self.status = "Select a task first."
        return
    end
    BaseBoard.toggleDone(self:playerObj(), self.selectedTask.id)
    self.status = ""
    self:refresh()
end

function BaseBoardUI:onClearDone()
    local count = BaseBoard.doneCount()
    if count == 0 then return end
    BaseBoard.clearDone()
    self.selectedTask = nil
    self.status = string.format("Cleared %d finished task%s.", count, count == 1 and "" or "s")
    self:refresh()
end

-- ==========================================================================

function BaseBoardUI:refresh()
    local selectedId = self.selectedTask and self.selectedTask.id
    self.taskList:clear()

    if self.mode == "crew" then
        self.taskList.doDrawItem = BaseBoardUI.drawSkillRow
        local rows, crew = BaseBoard.coverage()
        self.crewCount = crew
        for _, row in ipairs(rows) do
            self.taskList:addItem(row.name, row)
        end
    else
        self.taskList.doDrawItem = BaseBoardUI.drawTaskRow
        for index, task in ipairs(BaseBoard.tasks()) do
            self.taskList:addItem(task.text or "", task)
            if task.id == selectedId then
                self.taskList.selected = index
                self.selectedTask = task
            end
        end
    end

    --[[
    Supply totals, grouped by the category BaseIndex captured during its scan.

    Counted rather than listed. "Food 214" is a board; "214 rows of food" is the storage
    terminal, and duplicating that here would make two screens that disagree the moment one
    of them is stale.
    ]]
    local totals, oldest = {}, nil
    for fullType, record in pairs(BaseIndex.contents()) do
        local category = record.category or "Other"
        totals[category] = (totals[category] or 0) + record.count

        local _, age = BaseIndex.totalOf(fullType)
        if age ~= nil and (oldest == nil or age > oldest) then oldest = age end
    end

    self.totals = totals
    self.oldest = oldest

    --[[
    The world survey runs on the same slow tick as everything else here.

    It walks a square rectangle, so it is the most expensive thing the board does. Doing it
    only on refresh - not per frame, and only while the window is open - is what keeps that
    acceptable.
    ]]
    -- The survey needs no anchor now: it walks the areas the player drew, wherever they
    -- are, rather than a box derived from where the board happens to hang.
    self.survey = BaseBoardSurvey.run()

end

--[[
The claim button names the direction it will go.

Updated every frame rather than only on refresh. Refresh runs every three seconds, so a
label set there is stale for as long as three seconds after you click a different task -
which is exactly the moment you are reading it to decide whether to press it.
]]
function BaseBoardUI:updateClaimButton()
    if self.claimButton == nil then return end

    local playerObj = self:playerObj()
    local mine = self.selectedTask ~= nil and playerObj ~= nil
        and BaseBoard.hasClaimed(self.selectedTask, BaseBoard.usernameOf(playerObj))
    self.claimButton:setTitle(mine and "Leave" or "Join")

    -- Done toggles, so it names which way it will go for the row you have selected.
    local done = self.selectedTask ~= nil and BaseBoard.isDone(self.selectedTask)
    self.doneButton:setTitle(done and "Reopen" or "Done")

    local finished = BaseBoard.doneCount()
    self.clearButton:setVisible(self.mode == "tasks" and finished > 0)
    if finished > 0 then
        self.clearButton:setTitle(string.format("Clear %d done", finished))
    end
end

--[[
Turn a survey section into one line, or nil when there is nothing to say.

Nothing to say is the common case for a base that is fine, and a board full of "0
problems" rows is a board nobody reads. So a healthy section reports only its total, and a
section with nothing in it at all reports nothing.
]]
local function summaryLine(label, total, problems)
    if total == 0 then return nil, false end

    local parts = {}
    for _, problem in ipairs(problems) do
        if problem.count > 0 then
            parts[#parts + 1] = string.format("%d %s", problem.count, problem.word)
        end
    end

    if #parts == 0 then
        return string.format("%s: %d, all fine", label, total), false
    end
    return string.format("%s: %d - %s", label, total, table.concat(parts, ", ")), true
end

function BaseBoardUI:prerender()
    ISCollapsableWindow.prerender(self)
    self:updateClaimButton()
    self.frames = (self.frames or 0) + 1
    if self.frames >= REFRESH_FRAMES then
        self.frames = 0
        BaseIndex.refresh()
        self:refresh()
    end
end

function BaseBoardUI:render()
    ISCollapsableWindow.render(self)

    local lineHeight = getTextManager():getFontHeight(FONT)
    local y = self:titleBarHeight() + PAD

    --[[
    The generator first, because it is the thing that fails hardest.

    Everything else on this board degrades gracefully when neglected. A generator running
    dry takes the lights, the freezers and the storage terminal with it.
    ]]
    local generator = self.board and BaseBoard.findGenerator(self.board) or nil
    if generator == nil then
        self:drawText("Generator: none found nearby", PAD, y, 0.6, 0.6, 0.6, 1, FONT)
    else
        local fuel = generator:getFuel()
        local maxFuel = generator:getMaxFuel()
        local percent = (maxFuel and maxFuel > 0) and math.floor((fuel / maxFuel) * 100) or 0
        local running = generator:isActivated()
        local condition = generator:getCondition()

        -- Amber below a quarter tank, red when it is off or breaking. The colour is the
        -- message; the numbers are for when you want to know how bad.
        local r, g, b = 0.6, 0.85, 0.6
        if not running or condition < 40 then r, g, b = 0.95, 0.6, 0.5
        elseif percent < 25 then r, g, b = 0.95, 0.8, 0.45 end

        --[[
        Hours remaining, not just a percentage.

        "34%" requires you to know the tank size and the burn rate to mean anything;
        "about 16h" is a decision. Scaled by the game's own GeneratorFuelConsumption
        setting so a server that changed it gets the right answer without touching the mod.

        Only shown while it is actually running - a generator that is off is not burning
        anything, and a countdown on an idle machine would be a lie.
        ]]
        local hours = nil
        if running then
            local multiplier = (SandboxVars and SandboxVars.GeneratorFuelConsumption) or 1
            local perHour = BaseBoard.opt("GeneratorBurnPerHour") * multiplier
            if perHour > 0 then hours = fuel / perHour end
        end

        self:drawText(
            string.format(
                "Generator: %s, fuel %d%%%s, condition %d%%",
                running and "running" or "off",
                percent,
                hours and string.format(" (about %dh left)", math.floor(hours)) or "",
                math.floor(condition or 0)
            ),
            PAD, y, r, g, b, 1, FONT
        )
    end
    y = y + lineHeight

    local totals = self.totals or {}
    local shown = {}

    for _, category in ipairs(PINNED) do
        local count = 0
        for name, value in pairs(totals) do
            if string.lower(name) == string.lower(category) then
                count = count + value
                shown[name] = true
            end
        end
        if count > 0 then
            self:drawText(
                string.format("%s: %d", category, count), PAD, y, 0.85, 0.85, 0.85, 1, FONT
            )
            y = y + lineHeight
        end
    end

    local other = 0
    for name, value in pairs(totals) do
        if not shown[name] then other = other + value end
    end
    if other > 0 then
        self:drawText(string.format("Everything else: %d", other), PAD, y, 0.65, 0.65, 0.65, 1, FONT)
        y = y + lineHeight
    end

    --[[
    The age of the oldest reading, stated plainly.

    A board that reports numbers it cannot currently verify should say so, and "as of six
    hours ago" is exactly what a whiteboard in a base would say anyway.
    ]]
    --[[
    Emptiness is tested with a loop, not with `next`.

    Kahlua does not expose `next` as a global - vanilla's own UI code never calls it
    anywhere - so `next(totals)` was calling a nil value. Because this is in render, it
    threw once per frame for as long as the window was open, which is why one click
    produced a wall of identical errors.
    ]]
    local hasTotals = false
    for _ in pairs(totals) do
        hasTotals = true
        break
    end

    if self.oldest ~= nil and self.oldest > 1 then
        self:drawText(
            string.format("Oldest reading: %dh ago", math.floor(self.oldest)),
            PAD, y, 0.55, 0.5, 0.45, 1, FONT
        )
        y = y + lineHeight
    elseif not hasTotals then
        self:drawText("No containers linked yet", PAD, y, 0.55, 0.5, 0.45, 1, FONT)
        y = y + lineHeight
    end

    --[[
    The world survey: crops, animals, defenses, vehicles.

    Each is one line, and a line that would only say "all fine" is still drawn - knowing
    the animals are fed is worth a row - but drawn in grey rather than amber. Sections with
    nothing in them are omitted entirely, so a base with no livestock never mentions
    livestock.
    ]]
    local survey = self.survey

    --[[
    The supply forecast, which is the line most worth having on a board.

    Food and water are already counted above as raw totals, and a raw total answers
    nothing - "482 hunger units" is not a decision. Days remaining is, and it is the
    sentence people actually say to each other: "we're fine for food, we need water".

    Water folds in the barrels the survey found, because the player thinks of bottles and
    barrels as one supply and would otherwise be doing the addition themselves.
    ]]
    if survey ~= nil then
        local burn = BaseBoard.burnRate()

        local waterDays = nil
        if burn.waterPerDay > 0 then
            waterDays = (survey.water.amount or 0) / burn.waterPerDay
        end

        local function daysColour(days)
            if days == nil then return 0.7, 0.7, 0.7 end
            if days < 2 then return 0.95, 0.55, 0.5 end
            if days < 7 then return 0.95, 0.8, 0.45 end
            return 0.6, 0.85, 0.6
        end

        local function daysText(days)
            if days == nil then return "unknown" end
            if days >= 60 then return "60+ days" end
            if days < 1 then return "under a day" end
            return string.format("%d days", math.floor(days))
        end

        local fr, fg, fb = daysColour(burn.foodDays)
        self:drawText(
            string.format("Food: %s for %d", daysText(burn.foodDays), burn.crew),
            PAD, y, fr, fg, fb, 1, FONT
        )
        y = y + lineHeight

        local wr, wg, wb = daysColour(waterDays)
        self:drawText(
            string.format(
                "Water: %s (%d units, %d source%s)",
                daysText(waterDays),
                math.floor(survey.water.amount or 0),
                survey.water.sources or 0,
                (survey.water.sources or 0) == 1 and "" or "s"
            ),
            PAD, y, wr, wg, wb, 1, FONT
        )
        y = y + lineHeight

        --[[
        Fuel, next to the generator it feeds.

        Reported in the same fluid units as water, and paired with an estimate of how long
        it would keep the generator running - which is the only reason anyone counts petrol.
        ]]
        local petrol = (survey.nutrition and survey.nutrition.petrol) or 0
        if petrol > 0 then
            local multiplier = (SandboxVars and SandboxVars.GeneratorFuelConsumption) or 1
            local perHour = BaseBoard.opt("GeneratorBurnPerHour") * multiplier
            local hours = perHour > 0 and (petrol / perHour) or nil

            self:drawText(
                string.format(
                    "Fuel: %d units%s",
                    math.floor(petrol),
                    hours and string.format(" (about %dh of generator)", math.floor(hours)) or ""
                ),
                PAD, y, 0.7, 0.7, 0.7, 1, FONT
            )
            y = y + lineHeight
        end

        --[[
        Ammunition by type, most plentiful first.

        Three named rows then a count, because a base with nine calibres does not want nine
        rows and the ninth is never the one being asked about.
        ]]
        local ammo = BaseIndex.ammunition()
        if #ammo > 0 then
            local parts = {}
            for index = 1, math.min(#ammo, AMMO_ROWS) do
                parts[#parts + 1] = string.format("%s %d", ammo[index].name, ammo[index].count)
            end
            if #ammo > AMMO_ROWS then
                parts[#parts + 1] = string.format("+%d more", #ammo - AMMO_ROWS)
            end
            self:drawText("Ammo: " .. table.concat(parts, ", "), PAD, y, 0.85, 0.85, 0.85, 1, FONT)
            y = y + lineHeight
        end

        --[[
        Spoilage is only mentioned when there is some.

        A base with nothing going off does not need a row saying so, and the whole value of
        this line is that it appears in time to do something about it.
        ]]
        if (burn.spoiling or 0) > 0 or (burn.rotten or 0) > 0 then
            local parts = {}
            if burn.spoiling > 0 then
                parts[#parts + 1] = string.format("%d going off", burn.spoiling)
            end
            if burn.rotten > 0 then
                parts[#parts + 1] = string.format("%d rotten", burn.rotten)
            end
            self:drawText(
                "Perishables: " .. table.concat(parts, ", "),
                PAD, y, 0.95, 0.8, 0.45, 1, FONT
            )
            y = y + lineHeight
        end
    end

    if survey ~= nil then
        local sections = {
            {
                label = "Crops", total = survey.crops.total,
                problems = {
                    { count = survey.crops.dry, word = "dry" },
                    { count = survey.crops.diseased, word = "diseased" },
                    { count = survey.crops.dead, word = "dead" },
                },
            },
            {
                label = "Animals", total = survey.animals.total,
                problems = {
                    { count = survey.animals.hungry, word = "hungry" },
                    { count = survey.animals.thirsty, word = "thirsty" },
                    { count = survey.animals.unwell, word = "unwell" },
                },
            },
            {
                label = "Defenses", total = survey.defenses.total,
                problems = { { count = survey.defenses.damaged, word = "damaged" } },
            },
            {
                label = "Vehicles", total = survey.vehicles.total,
                problems = {
                    { count = survey.vehicles.lowFuel, word = "low on fuel" },
                    { count = survey.vehicles.damaged, word = "needing repair" },
                },
            },
        }

        for _, section in ipairs(sections) do
            local text, alarming = summaryLine(section.label, section.total, section.problems)
            if text ~= nil then
                local r, g, b = 0.7, 0.7, 0.7
                if alarming then r, g, b = 0.95, 0.8, 0.45 end
                self:drawText(text, PAD, y, r, g, b, 1, FONT)
                y = y + lineHeight
            end
        end

        --[[
        Say what area was actually measured, when it is not the obvious one.

        A survey that reports nothing is ambiguous - no crops, or the wrong patch of
        ground? Naming the source resolves it. "Radius" means nothing has been linked yet
        and it is guessing; "capped" means something is linked far enough away that the
        claimed area was implausible and got clamped, which is a hint that a stray link
        wants cleaning up.
        ]]
        --[[
        The survey area, always stated.

        Shown even when it is correct, because the number it produces is only meaningful
        if you know what ground it covered - "no crops" means nothing until you know
        whether the field was inside the box. It also makes the marks visible, which they
        otherwise are not.
        ]]
        --[[
        Both scopes, stated together, because the board reads from two different things and
        never said so.

        Supplies come from **linked containers** - the ones wired into the network with a
        screwdriver and wire. Crops, animals, defenses and vehicles come from the **drawn
        areas**. A crate standing inside an area but never linked contributes nothing to the
        food count, and without this line there is no way to tell that from having no food.
        ]]
        local linked = 0
        for _ in pairs(BaseIndex.all()) do linked = linked + 1 end

        local scope
        local r, g, b = 0.55, 0.5, 0.45
        if (survey.areas or 0) == 0 and linked == 0 then
            scope = "Nothing set up yet - draw a base area, and link containers for supplies"
            r, g, b = 0.95, 0.8, 0.45
        elseif (survey.areas or 0) == 0 then
            scope = string.format("%d linked containers, but no areas drawn", linked)
            r, g, b = 0.95, 0.8, 0.45
        elseif linked == 0 then
            scope = string.format(
                "%d area%s surveyed, but no containers linked - supplies will read zero",
                survey.areas, survey.areas == 1 and "" or "s"
            )
            r, g, b = 0.95, 0.8, 0.45
        else
            scope = string.format(
                "Supplies from %d linked containers; %d area%s surveyed (%d squares)",
                linked, survey.areas, survey.areas == 1 and "" or "s", survey.squares or 0
            )
        end

        self:drawText(scope, PAD, y, r, g, b, 1, FONT)
        y = y + lineHeight
    end

    local footerY = self.height - ROW_H * 2 - PAD * 4 - lineHeight

    if self.status ~= "" then
        self:drawText(self.status, PAD, footerY, 0.9, 0.7, 0.5, 1, FONT)
    elseif self.mode == "crew" then
        --[[
        Who has read the board, and how long ago.

        The roster already carries a timestamp per player - it is what makes the skill list
        possible at all - and showing it answers the other question people ask a shared
        board: has anyone been here.

        Only shown in crew mode, where it is the context for the skills above it rather
        than another number competing with the supply rows.
        ]]
        local entries = BaseBoard.rosterEntries()
        if #entries == 0 then
            self:drawText("Nobody has read this board yet", PAD, footerY, 0.6, 0.6, 0.6, 1, FONT)
        else
            local now = BaseBoard.now()
            local parts = {}
            for index = 1, math.min(#entries, 4) do
                local entry = entries[index]
                local age = now - (entry.at or now)

                -- Hours up to a couple of days, then days. Nobody needs "68h ago".
                local when
                if age < 1 then when = "just now"
                elseif age < 48 then when = string.format("%dh", math.floor(age))
                else when = string.format("%dd", math.floor(age / 24)) end

                parts[#parts + 1] = string.format("%s %s", entry.by, when)
            end
            if #entries > 4 then
                parts[#parts + 1] = string.format("+%d", #entries - 4)
            end
            self:drawText("Last seen: " .. table.concat(parts, ", "), PAD, footerY, 0.6, 0.7, 0.75, 1, FONT)
        end
    end
end

-- ==========================================================================

function BaseBoardUI:new(x, y, width, height, playerNum, board)
    local o = ISCollapsableWindow:new(x, y, width, height)
    setmetatable(o, self)
    self.__index = self
    o.playerNum = playerNum
    o.board = board
    o.title = "Base Board"
    o.resizable = true
    o:setResizable(true)
    o.status = ""
    o.frames = 0
    return o
end

function BaseBoardUI.toggle(playerNum, board)
    playerNum = playerNum or 0

    local existing = instances[playerNum]
    if existing ~= nil then
        existing:removeFromUIManager()
        instances[playerNum] = nil
        return
    end

    --[[
    Reading the board posts your own skills to it.

    Nobody is ever asked to publish a sheet, because a feature that depends on a habit is a
    feature that is empty when you need it. Opening the board is already the moment you
    care what the crew can do, so it is the natural moment to contribute what you can do.
    ]]
    BaseBoard.postSkills(getSpecificPlayer(playerNum))

    local window = BaseBoardUI:new(160, 160, 440, 520, playerNum, board)
    window:initialise()
    window:addToUIManager()
    instances[playerNum] = window
end

-- ==========================================================================
-- Context menu
-- ==========================================================================

local function onOpen(worldobjects, playerNum, board) BaseBoardUI.toggle(playerNum, board) end
local function onMake(worldobjects, object) BaseBoard.addBoard(object) end
local function onRemove(worldobjects, object) BaseBoard.removeBoard(object) end

local function onFillMenu(playerNum, context, worldobjects, test)
    if test then return end

    --[[
    Only a corkboard, so this mod returns immediately on nearly every right click.

    The storage terminal reached the same rule by a longer route - grey everything out,
    then require a tool, then finally check the object type - and a type check is what
    actually works.
    ]]
    local object = nil
    for _, candidate in ipairs(worldobjects) do
        if BaseBoard.isBoardSprite(candidate) then
            object = candidate
            break
        end
    end
    if object == nil then return end

    local board = BaseBoard.boardAt(object)
    if board ~= nil then
        context:addOption("Read the base board", worldobjects, onOpen, playerNum, board)
        context:addOption("Take down the base board", worldobjects, onRemove, object)
    else
        context:addOption("Use this as the base board", worldobjects, onMake, object)
    end
end

Events.OnFillWorldObjectContextMenu.Add(onFillMenu)
