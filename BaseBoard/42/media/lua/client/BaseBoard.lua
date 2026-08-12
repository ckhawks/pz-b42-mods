--[[
Base board.

A corkboard you hang in a long-term base that answers the three questions people actually
ask each other over voice chat: what are we low on, is the generator fine, and who is doing
what.

It reads supplies from BaseIndex rather than scanning anything itself, which means it shows
the same numbers the storage terminal does and cannot disagree with it. The generator it
finds by looking; the task list is its own.

The task list is the reason this is a board and not a screen. Tasks are shared, claimable,
and claims expire, because the failure mode of a co-op base is two people independently
deciding to go get water while nobody fixes the wall.
]]

BaseBoard = BaseBoard or {}

local MOD_DATA_KEY = "BaseBoard"

--[[
The corkboard sprite.

`Mov_CorkBoard` is a vanilla moveable - you find one, pick it up and place it - and its
script gives `WorldObjectSprite = location_business_office_generic_01_7`. Matching that one
sprite means this mod adds a context option to exactly one kind of object in the world
rather than taxing every right click, which is the lesson the storage terminal learned the
hard way.

A list rather than a single value so other noticeboard sprites can be added without
touching the logic.
]]
local BOARD_SPRITES = {
    ["location_business_office_generic_01_7"] = true,
}

local DEFAULTS = {
    -- How far from the board a generator is considered part of this base.
    GeneratorRange = 30,



    --[[
    The burn-rate assumptions.

    Hunger in Project Zomboid runs 0 to 1 and a survivor works through roughly a whole
    unit in a day at default settings, so 1.0 is the starting guess. Water is in fluid
    units and 2.0 a day is a bottle and a bit.

    Both are options rather than constants because the true numbers depend on traits and
    sandbox settings, and a figure the group calibrates after a week of play is worth more
    than one guessed at up front.
    ]]
    HungerPerPersonPerDay = 1.0,
    WaterPerPersonPerDay = 2.0,

    --[[
    Generator fuel burned per hour at a fuel consumption multiplier of 1.

    Multiplied by SandboxVars.GeneratorFuelConsumption when the estimate is made, so
    changing the game's own setting moves this without touching the mod.
    ]]
    GeneratorBurnPerHour = 2.0,
}

local function opt(name)
    local vars = SandboxVars and SandboxVars.BaseBoard
    local value = vars and vars[name]
    if value == nil then return DEFAULTS[name] end
    return value
end

BaseBoard.opt = opt

-- ==========================================================================
-- Storage
-- ==========================================================================

local function store()
    local data = ModData.getOrCreate(MOD_DATA_KEY)
    data.boards = data.boards or {}
    data.tasks = data.tasks or {}
    data.roster = data.roster or {}
    data.nextId = data.nextId or 1
    return data
end

Events.OnInitGlobalModData.Add(function(isNewGame)
    -- Unconditional, and mirrored in lua/server. An isNewGame guard means a mod added to
    -- an existing save never registers its key and never persists.
    ModData.getOrCreate(MOD_DATA_KEY)
    if isClient() then ModData.request(MOD_DATA_KEY) end
end)

local function boardKey(x, y, z)
    return string.format("%d,%d,%d", x, y, z)
end

local function now()
    local time = getGameTime()
    if time == nil then return 0 end
    return time:getWorldAgeHours()
end

BaseBoard.now = now

-- ==========================================================================
-- Boards
-- ==========================================================================

function BaseBoard.isBoardSprite(object)
    local sprite = object:getSprite()
    if sprite == nil then return false end
    return BOARD_SPRITES[tostring(sprite:getName())] == true
end

function BaseBoard.applyAdd(args)
    store().boards[boardKey(args.x, args.y, args.z)] = { x = args.x, y = args.y, z = args.z }
    return true
end

function BaseBoard.applyRemove(args)
    store().boards[boardKey(args.x, args.y, args.z)] = nil
    return true
end

function BaseBoard.boardAt(object)
    if object == nil then return nil end
    return store().boards[boardKey(
        math.floor(object:getX()), math.floor(object:getY()), math.floor(object:getZ())
    )]
end

-- ==========================================================================
-- Tasks
-- ==========================================================================

--[[
Claims are a set of names, and anyone can add themselves.

The first version had a single owner and refused a second claimant. Two problems with
that, and the second is the one that decided it.

A shared board is not a ticket queue. "Clear the horde by the north wall" is a three person
job, and an exclusive claim leaves the second and third people with no way to say they are
helping - so the board actively misrepresents what is happening.

And a single owner field is a genuine race: two players claiming in the same tick, one
silently loses. **A set is commutative** - you adding yourself and me adding myself cannot
conflict in any order - which is the only shape that is naturally correct under concurrent
edits without the server arbitrating.

Nobody can release anyone else, because the only operation is toggling your own name. That
removes the "whose claim is this" question rather than answering it.

There is no expiry. It was there to stop a logged-off player holding a job forever, which
was only a problem because claims were exclusive. Now a stale name is just a name.
]]
function BaseBoard.claimants(task)
    local names = {}
    for name in pairs(task.claimants or {}) do names[#names + 1] = name end
    table.sort(names)
    return names
end

function BaseBoard.claimCount(task)
    local count = 0
    for _ in pairs(task.claimants or {}) do count = count + 1 end
    return count
end

function BaseBoard.hasClaimed(task, name)
    return (task.claimants or {})[name] == true
end

function BaseBoard.applyAddTask(args)
    local data = store()
    local id = data.nextId
    data.nextId = id + 1
    data.tasks[tostring(id)] = {
        id = tostring(id),
        text = args.text,
        addedBy = args.by,
        addedAt = args.at,
    }
    return true
end

--[[
Toggle one player's name on a task.

Never refuses on the grounds of someone else's claim, because there is no such thing here.
The only failure is a task that no longer exists.
]]
function BaseBoard.applyToggleClaim(args)
    local task = store().tasks[args.id]
    if task == nil then return false end

    task.claimants = task.claimants or {}
    if task.claimants[args.by] then
        task.claimants[args.by] = nil
    else
        task.claimants[args.by] = true
    end
    return true
end

--[[
Completion is a state, not a deletion.

Deleting on Done loses the one thing a shared board is for: knowing whether the water run
actually happened, or whether somebody just tidied the list. So a finished task stays,
carrying who finished it and when, and is cleared deliberately later.

Toggling rather than one-way, because the common mistake is marking the wrong row done and
the fix should not be retyping the task.
]]
function BaseBoard.applyToggleDone(args)
    local task = store().tasks[args.id]
    if task == nil then return false end

    if task.doneAt ~= nil then
        task.doneAt, task.doneBy = nil, nil
    else
        task.doneAt, task.doneBy = args.at, args.by
    end
    return true
end

function BaseBoard.applyRemoveTask(args)
    store().tasks[args.id] = nil
    return true
end

--[[
Clear every completed task at once.

The alternative is deleting them one at a time, which nobody will do, so the list grows
until it is ignored. One button, and it only ever touches tasks somebody already marked
finished.
]]
function BaseBoard.applyClearDone(args)
    local tasks = store().tasks
    for id, task in pairs(tasks) do
        if task.doneAt ~= nil then tasks[id] = nil end
    end
    return true
end

function BaseBoard.isDone(task)
    return task.doneAt ~= nil
end

function BaseBoard.doneCount()
    local count = 0
    for _, task in pairs(store().tasks) do
        if task.doneAt ~= nil then count = count + 1 end
    end
    return count
end

function BaseBoard.tasks()
    local list = {}
    for _, task in pairs(store().tasks) do list[#list + 1] = task end

    --[[
    Unclaimed first, then claimed, each oldest first.

    The board is read to answer "what should I do next", and a claimed task is not an
    answer to that. Sorting by age within each group means the thing that has been waiting
    longest is the thing at the top, which is the nudge a shared list should provide.
    ]]
    --[[
    Unclaimed, then claimed, then done. Oldest first within each group.

    The board is read to answer "what should I do next", and neither a task somebody is
    already on nor one that is finished is an answer to that - but both are worth seeing,
    so they sink rather than disappear.
    ]]
    table.sort(list, function(left, right)
        local leftDone = BaseBoard.isDone(left)
        local rightDone = BaseBoard.isDone(right)
        if leftDone ~= rightDone then return rightDone end

        local leftClaimed = BaseBoard.claimCount(left) > 0
        local rightClaimed = BaseBoard.claimCount(right) > 0
        if leftClaimed ~= rightClaimed then return rightClaimed end

        return (left.addedAt or 0) < (right.addedAt or 0)
    end)

    return list
end

-- ==========================================================================
-- Command routing
-- ==========================================================================

--[[
Shared state goes through the server when there is one.

Same reasoning as the storage terminal: `ModData.transmit` sends the whole table, so two
players editing in the same tick means one edit silently vanishes. A task list is exactly
the thing two people touch at once.
]]
local function mutate(command, args)
    if args == nil then return end

    if isClient() then
        sendClientCommand(getPlayer(), MOD_DATA_KEY, command, args)
        -- Applied locally too so the acting player sees it immediately; the server's
        -- broadcast overwrites this a moment later.
        BaseBoard["apply" .. command](args)
        return
    end

    BaseBoard["apply" .. command](args)

    --[[
    Temporary diagnostic, paired with the one in BaseBoardServer.

    Says whether a write actually reached the table. If boards go up here but the key is
    still missing from the save, the problem is serialisation rather than the write path.
    ]]
    local data = store()
    local boards, tasks = 0, 0
    for _ in pairs(data.boards) do boards = boards + 1 end
    for _ in pairs(data.tasks) do tasks = tasks + 1 end
    print(string.format("baseboard: %s applied, boards=%d tasks=%d", command, boards, tasks))

    ModData.transmit(MOD_DATA_KEY)
end

BaseBoard.mutate = mutate

local function describe(object)
    if object == nil then return nil end
    return {
        x = math.floor(object:getX()),
        y = math.floor(object:getY()),
        z = math.floor(object:getZ()),
    }
end

function BaseBoard.addBoard(object) mutate("Add", describe(object)) end
function BaseBoard.removeBoard(object) mutate("Remove", describe(object)) end

local function usernameOf(playerObj)
    local name = playerObj and playerObj:getUsername()
    if name == nil or name == "" then return "Survivor" end
    return tostring(name)
end

BaseBoard.usernameOf = usernameOf

function BaseBoard.addTask(playerObj, text)
    mutate("AddTask", { text = text, by = usernameOf(playerObj), at = now() })
end

function BaseBoard.toggleClaim(playerObj, id)
    mutate("ToggleClaim", { id = id, by = usernameOf(playerObj) })
end

function BaseBoard.toggleDone(playerObj, id)
    mutate("ToggleDone", { id = id, by = usernameOf(playerObj), at = now() })
end

function BaseBoard.clearDone() mutate("ClearDone", {}) end
function BaseBoard.removeTask(id) mutate("RemoveTask", { id = id }) end

-- ==========================================================================
-- Crew skills
-- ==========================================================================

--[[
Who can do what, and therefore what nobody can do.

A client cannot read another player's perks - they are on that player's character, on their
machine - so this works by each player posting their own sheet to the board when they read
it. The board is then a noticeboard in the literal sense: it knows what people have written
on it, and it says when each entry was written.

That is also why nobody is ever asked to post. Opening the board posts your own skills as a
side effect, which means the roster stays current for anyone who actually uses the thing
and does not require a habit.
]]

--[[
Every trainable skill, as the game defines them.

`PerkFactory.PerkList` includes parent categories - Agility, Combat, Crafting - which are
headings rather than skills, and `perk:getParent() ~= Perks.None` is how vanilla's own
character screen filters them out (ISCharacterInfo.lua:272).
]]
function BaseBoard.eachSkill(fn)
    local list = PerkFactory.PerkList
    for i = 0, list:size() - 1 do
        local perk = list:get(i)
        if perk:getParent() ~= Perks.None then
            fn(perk)
        end
    end
end

function BaseBoard.applyPostSkills(args)
    store().roster[args.by] = { by = args.by, at = args.at, perks = args.perks }
    return true
end

function BaseBoard.postSkills(playerObj)
    if playerObj == nil then return end

    local perks = {}
    BaseBoard.eachSkill(function(perk)
        local level = playerObj:getPerkLevel(perk:getType())
        -- Only levelled skills are sent. A sheet of thirty zeroes is the same information
        -- as an absent entry, and this table is broadcast to every client.
        if level and level > 0 then
            perks[tostring(perk:getName())] = level
        end
    end)

    mutate("PostSkills", { by = usernameOf(playerObj), at = now(), perks = perks })
end

--[[
The crew's coverage, worst first.

For each skill: the best level anyone has posted, and who has it. Sorted ascending so the
gaps float to the top, because "what can nobody here do" is the question this answers and
it should not require scrolling.

Stale entries still count. Someone who has not opened the board in a week has not forgotten
how to fix a generator, and dropping them would make the roster oscillate as people come
and go. Their age is shown instead.
]]
function BaseBoard.coverage()
    local roster = store().roster

    local best = {}
    BaseBoard.eachSkill(function(perk)
        best[tostring(perk:getName())] = { name = tostring(perk:getName()), level = 0, who = nil }
    end)

    local crew = 0
    for _, entry in pairs(roster) do
        crew = crew + 1
        for name, level in pairs(entry.perks or {}) do
            local row = best[name]
            if row ~= nil and level > row.level then
                row.level = level
                row.who = entry.by
            end
        end
    end

    local rows = {}
    for _, row in pairs(best) do rows[#rows + 1] = row end
    table.sort(rows, function(left, right)
        if left.level ~= right.level then return left.level < right.level end
        return left.name < right.name
    end)

    return rows, crew
end

function BaseBoard.rosterEntries()
    local list = {}
    for _, entry in pairs(store().roster) do list[#list + 1] = entry end
    table.sort(list, function(left, right) return (left.at or 0) > (right.at or 0) end)
    return list
end

-- ==========================================================================
-- Burn rate
-- ==========================================================================

--[[
How long the base can feed and water its crew.

This is an estimate and the board says so. The point is not to be exact - it is to turn
three numbers nobody can hold in their head into one sentence somebody can act on: "eleven
days of food, three of water" tells you what today's run is for.

Every assumption is a sandbox option rather than a constant, because the honest answer to
"how much does a survivor eat" is that it depends on the traits they took and the settings
you play with, and a number you can calibrate after a week of play beats a number I guessed
at now.

Crew size comes from the roster - people who have actually read the board. It is clamped to
at least one so a solo player is not dividing by zero, and a base whose crew has never
opened the board estimates for one person and says so by way of the crew count.
]]
function BaseBoard.burnRate()
    local nutrition = BaseIndex.nutrition()
    local _, crew = BaseBoard.coverage()
    crew = math.max(crew, 1)

    local foodPerDay = opt("HungerPerPersonPerDay") * crew
    local waterPerDay = opt("WaterPerPersonPerDay") * crew

    --[[
    Water counted here is only what BaseIndex can see, because this runs without a survey.

    The window adds the barrels in before it draws, since it has the survey to hand. Doing
    it here as well would double count.
    ]]
    return {
        crew = crew,
        foodDays = foodPerDay > 0 and (nutrition.hunger / foodPerDay) or nil,
        waterDays = waterPerDay > 0 and (nutrition.water / waterPerDay) or nil,
        foodPerDay = foodPerDay,
        waterPerDay = waterPerDay,
        spoiling = nutrition.spoiling,
        rotten = nutrition.rotten,
    }
end

-- ==========================================================================
-- Generator
-- ==========================================================================

--[[
The nearest generator to a board, if one is loaded.

Scanned rather than registered, because a generator is a single obvious object with a fixed
place in a base and asking the player to link it as well would be ceremony for no
information. The scan only runs when the window is open, and only over loaded squares.

Returns nil when nothing is found, which covers both "no generator" and "its chunk is not
loaded" - the window says which by checking whether it has ever seen one.
]]
function BaseBoard.findGenerator(board)
    local cell = getCell()
    if cell == nil then return nil end

    local range = opt("GeneratorRange")
    local best, bestDistance = nil, nil

    for x = board.x - range, board.x + range do
        for y = board.y - range, board.y + range do
            local square = cell:getGridSquare(x, y, board.z)
            if square ~= nil then
                local objects = square:getObjects()
                for i = 0, objects:size() - 1 do
                    local object = objects:get(i)
                    if instanceof(object, "IsoGenerator") then
                        local dx, dy = x - board.x, y - board.y
                        local distance = dx * dx + dy * dy
                        if bestDistance == nil or distance < bestDistance then
                            best, bestDistance = object, distance
                        end
                    end
                end
            end
        end
    end

    return best
end
