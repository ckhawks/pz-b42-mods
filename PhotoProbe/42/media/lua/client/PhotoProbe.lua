--[[
Photo probe.

The polaroid mod needs four things to be true, and reading the jar only shows that the
names exist in `zombie/Lua/LuaManager$GlobalObject`, not that they are callable or what
arguments they take:

  1. the game can take a screenshot from Lua
  2. Lua can read and write PNG bytes
  3. a PNG on disk can become a Texture
  4. that Texture can be drawn in a UI

This answers all four and changes nothing in game. Output goes to Zomboid/Lua:

  photoprobe-surface.txt   what exists, from type() and metatables only. No calls.
  photoprobe-calls.txt     what happened when each one was actually called.

The two files exist separately because the second one can poison the session and the
first one cannot. See "the arity rule" below.

`.txt` rather than `.json` or `.log`: LuaManager gates Lua file access on an extension
allowlist of .lua, .txt, .cfg, .png, .db. getFileWriter returns nil for anything else,
silently, which is how craftgraphDump lost its first run.
]]

local SURFACE_FILE = "photoprobe-surface.txt"
local CALLS_FILE = "photoprobe-calls.txt"

-- ==========================================================================
-- The arity rule
-- ==========================================================================

--[[
Kahlua dispatches overloaded Java methods through MultiLuaJavaInvoker. Calling one with
an argument list matching no overload throws inside ReturnValues rather than returning an
error, pcall does not contain it, and every later Java call in the session fails -
vanilla's included. craftgraphDump documents killing the main menu this way.

So the rules here are the same as that mod's, plus one more that it did not need:

  - a method is only called if its name is on the metatable
  - the whole report is flushed to disk before any call is attempted
  - risky calls run last and in increasing order of risk

The flush-before-call part is what makes a poisoned session still useful: whatever
already reached disk is the answer, and the last line in the file names the call that
broke it.
]]

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

local function hasMethod(object, name)
    if type(object) ~= "userdata" then return false end
    for _, found in ipairs(methodNames(object)) do
        if found == name then return true end
    end
    return false
end

-- ==========================================================================
-- Reporting
-- ==========================================================================

--[[
A report that is complete at every moment.

flush() rewrites the file from the start rather than appending, so there is no partial
last line and no dependence on a close() that a broken session may never reach. The
files are a few hundred lines, so rewriting them is free and the guarantee is worth more
than the writes.
]]
local Report = {}
Report.__index = Report

function Report.new(path)
    return setmetatable({ path = path, lines = {} }, Report)
end

function Report:add(text)
    self.lines[#self.lines + 1] = text
end

function Report:addf(format, ...)
    self:add(string.format(format, ...))
end

function Report:flush()
    local writer = getFileWriter(self.path, true, false)
    if writer == nil then
        print("photoprobe: could not open " .. self.path)
        return false
    end
    writer:write(table.concat(self.lines, "\r\n"))
    writer:close()
    return true
end

--[[
Record a value's shape without calling anything.

For a function this is just "function", which is the whole question for the globals -
the jar shows the name is registered, and this shows whether the exposer actually bound
it in this build.
]]
local function describe(value)
    local kind = type(value)
    if kind == "nil" then return "ABSENT" end
    if kind == "function" then return "function" end
    if kind == "userdata" then
        local names = methodNames(value)
        if #names == 0 then return "userdata, no method list" end
        return string.format("userdata, %d methods", #names)
    end
    if kind == "table" then return "table" end
    return kind .. " (" .. tostring(value) .. ")"
end

local function addMethodList(report, label, object)
    report:add("")
    report:add("=== " .. label .. " ===")
    if object == nil then
        report:add("  nil")
        return
    end
    local names = methodNames(object)
    if #names == 0 then
        report:add("  metatable exposed no method list")
        return
    end
    report:addf("  %d methods:", #names)
    local line = "   "
    for _, name in ipairs(names) do
        if #line + #name + 1 > 96 then
            report:add(line)
            line = "   "
        end
        line = line .. " " .. name
    end
    if line ~= "   " then report:add(line) end
end

-- ==========================================================================
-- Phase A: the surface, with no calls at all
-- ==========================================================================

--[[
Every global the jar's exposer lists that the photo mod might need, plus a few that
would change the design if they turned out to exist.

A name that is absent costs nothing to check and rules out a whole branch of the design,
which is why this list is generous rather than minimal.
]]
local GLOBALS = {
    -- capture
    "takeScreenshot",

    -- the texture loaders. getTextureFromSaveDir is the one the whole idea rests on:
    -- it is the only exposed name that reads a texture from a runtime location rather
    -- than from the packed game assets.
    "getTextureFromSaveDir",
    "getTexture",
    "tryGetTexture",
    "Texture",

    -- byte level file I/O. getFileWriter is text only, so these are what a PNG has to
    -- travel through when it arrives from another player over the command channel.
    "getFileOutput",
    "getFileInput",
    "endFileOutput",
    "endFileInput",
    "getGameFilesInput",
    "getGameFilesTextInput",
    "endTextFileInput",

    -- text I/O, already known to work from craftgraphDump
    "getFileWriter",
    "getFileReader",
    "getModFileWriter",
    "getModFileReader",

    -- directory listing, for the photo library and for cleanup of orphaned files
    "listFilesInModDirectory",
    "listFilesInZomboidLuaDirectory",

    -- save directory naming, which is where getTextureFromSaveDir will want its argument
    "getFileNameInCurrentSave",

    -- would change the design if present. Expected absent: the jar shows no HTTP client
    -- bound to Lua, and openUrl only launches the player's external browser.
    "getUrl",
    "downloadFile",
    "openUrl",
}

--[[
getCore() is where TakeScreenshot, TakeFullScreenshot and getScreenshotDir live in the
jar. Whether the exposer bound them is a metatable question, not a call.
]]
local CORE_METHODS = {
    "TakeScreenshot",
    "TakeFullScreenshot",
    "getScreenshotDir",
    "getVersionNumber",
    "getScreenWidth",
    "getScreenHeight",
}

local function runSurface()
    local report = Report.new(SURFACE_FILE)
    report:add("photoprobe surface")
    report:add("Nothing in this file calls a Java method. type() and metatables only.")
    report:add("")

    local core = getCore()
    report:add("game version: " .. tostring(core and core:getVersionNumber() or "unknown"))
    report:add("")
    report:add("=== globals ===")
    for _, name in ipairs(GLOBALS) do
        report:addf("  %-28s %s", name, describe(_G[name]))
    end

    report:add("")
    report:add("=== getCore() methods of interest ===")
    if core == nil then
        report:add("  getCore() returned nil")
    else
        for _, name in ipairs(CORE_METHODS) do
            report:addf("  %-28s %s", name, hasMethod(core, name) and "present" or "ABSENT")
        end
    end

    --[[
    The full Core method list is worth having even though it is long.

    The names above are what the jar's constant pool suggested. If the exposer bound a
    differently spelled variant - takeScreenshot versus TakeScreenshot, both of which
    appear in the pool - the full list is what shows it, and finding that out costs a
    launch otherwise.
    ]]
    addMethodList(report, "getCore() full", core)

    --[[
    Texture as a global class.

    If Texture is exposed with getSharedTexture on it, that is a second route to loading
    a PNG and it may accept paths that getTextureFromSaveDir does not. Worth knowing
    before designing around either one.
    ]]
    if _G["Texture"] ~= nil then
        addMethodList(report, "Texture (global)", _G["Texture"])
    end

    report:flush()
    print("photoprobe: wrote " .. SURFACE_FILE)
end

-- ==========================================================================
-- Phase B: actually calling things
-- ==========================================================================

--[[
Steps run in increasing order of risk and the report is flushed between every one, so a
session that dies mid-probe still leaves a file whose last line names the culprit.

Each step is wrapped so that a clean Lua error is recorded and the run continues. A
Kahlua arity fault is not a clean Lua error and will not be contained - that is what the
flushing is for, not the pcall.
]]
local function step(report, label, fn)
    report:add("")
    report:addf("--- %s ---", label)
    report:flush()

    local ok, result = pcall(fn)
    if ok then
        report:add("  " .. tostring(result))
    else
        report:add("  FAILED: " .. tostring(result))
    end
    report:flush()
    return ok, result
end

--[[
The save directory name, which getTextureFromSaveDir almost certainly wants a path
relative to. Read rather than assumed, because the naming differs between Sandbox,
Survivor and Multiplayer saves.
]]
local function saveDirName()
    if type(getFileNameInCurrentSave) ~= "function" then return nil end
    local ok, name = pcall(function() return getFileNameInCurrentSave("probe.png") end)
    if ok then return tostring(name) end
    return nil
end

local function runCalls()
    local report = Report.new(CALLS_FILE)
    report:add("photoprobe calls")
    report:add("Steps run in increasing order of risk. The report is flushed before each")
    report:add("call, so if the file ends mid-step, that step is what broke the session.")
    report:flush()

    local core = getCore()

    -- 1. Where do screenshots go. Zero-argument getter, lowest risk thing here.
    step(report, "getCore():getScreenshotDir()", function()
        if not hasMethod(core, "getScreenshotDir") then return "method absent, skipped" end
        return core:getScreenshotDir()
    end)

    -- 2. What the save directory helper returns, which tells us what shape of path the
    -- texture loader will want.
    step(report, "getFileNameInCurrentSave('probe.png')", function()
        local name = saveDirName()
        if name == nil then return "absent or failed" end
        return name
    end)

    --[[
    3. Take a screenshot.

    TakeFullScreenshot is listed with no argument in the pool alongside TakeScreenshot,
    which suggests one of them takes a filename. Only the no-argument shape is attempted:
    guessing the other arity is exactly the fault that kills the session, and if this
    one is wrong the file ends here and we know to try the other next launch.
    ]]
    step(report, "getCore():TakeFullScreenshot()", function()
        if not hasMethod(core, "TakeFullScreenshot") then return "method absent, skipped" end
        core:TakeFullScreenshot()
        return "returned without error"
    end)

    --[[
    4. Byte level file I/O.

    The metatable of whatever getFileOutput returns is the answer to whether PNG bytes
    can be written from Lua at all. Nothing is written yet - this only opens a handle,
    reads its method list, and closes it.
    ]]
    step(report, "getFileOutput('photoprobe-scratch.png') method list", function()
        if type(getFileOutput) ~= "function" then return "getFileOutput absent" end
        local handle = getFileOutput("photoprobe-scratch.png")
        if handle == nil then return "returned nil - extension may be rejected" end
        local names = methodNames(handle)
        local summary = table.concat(names, " ")
        if type(endFileOutput) == "function" then pcall(endFileOutput) end
        if #names == 0 then return "handle has no method list" end
        return string.format("%d methods: %s", #names, summary)
    end)

    step(report, "getFileInput on the same path", function()
        if type(getFileInput) ~= "function" then return "getFileInput absent" end
        local handle = getFileInput("photoprobe-scratch.png")
        if handle == nil then return "returned nil" end
        local names = methodNames(handle)
        if type(endFileInput) == "function" then pcall(endFileInput) end
        if #names == 0 then return "handle has no method list" end
        return string.format("%d methods: %s", #names, table.concat(names, " "))
    end)

    --[[
    5. The load. This is the go/no-go for the whole mod.

    Only the single-argument shape is tried, for the arity reason above. If the file ends
    here, the answer is "getTextureFromSaveDir takes something other than one string",
    and the next launch tries two.
    ]]
    --[[
    Round two.

    Run one established three things. Both of the interesting calls exist and are bound,
    neither takes the argument count guessed, and - contrary to what the craftgraphDump
    notes led me to expect - an arity fault here was contained by pcall and did not
    corrupt the session. The probe finished and the container spike ran normally
    afterwards, so guessing an argument list costs one logged error rather than the run.

    That makes it worth trying several shapes in one launch instead of one per launch.

      getCore():TakeFullScreenshot()  ->  expected 1 argument, got 0
      getTextureFromSaveDir(name)     ->  expected 2 arguments, got 1

    getScreenshotDir turned out not to be bound on Core at all, but getSaveFolder is, and
    a save-relative path is what a function called getTextureFromSaveDir would want.
    ]]

    local saveFolder = nil

    step(report, "getCore():getSaveFolder()", function()
        if not hasMethod(core, "getSaveFolder") then return "method absent" end
        saveFolder = core:getSaveFolder()
        return tostring(saveFolder)
    end)

    -- The one argument is almost certainly the filename. `.png` is on the Lua file
    -- extension allowlist, so the name is chosen to be accepted by whatever writes it.
    step(report, "getCore():TakeFullScreenshot('photoprobe-shot.png')", function()
        if not hasMethod(core, "TakeFullScreenshot") then return "method absent" end
        core:TakeFullScreenshot("photoprobe-shot.png")
        return "returned without error"
    end)

    step(report, "takeScreenshot('photoprobe-shot2.png')", function()
        if type(takeScreenshot) ~= "function" then return "absent" end
        takeScreenshot("photoprobe-shot2.png")
        return "returned without error"
    end)

    --[[
    Both argument orderings for the loader, plus the two plausible second arguments.

    Nothing here is known; the point is to spend one launch on all four rather than four
    launches on one each. Each is flushed before it runs, so even if one of these does
    poison the session the file names which.
    ]]
    --[[
    Round three narrows it with two facts round two established.

    Both arguments are Strings - passing a boolean returned "expected argument of type
    String, got Boolean" rather than an arity fault, which is the type signature stated
    outright. And every String pair returned nil rather than throwing, so the call was
    well formed and simply found no file. That means this is now a path question, not an
    API question.

    The name is also no longer a mystery. Every save folder on disk contains a `thumb.png`
    - the image the load-game menu shows - written by SavefileThumbnail. So this function
    exists to load save thumbnails, and its two Strings are a save directory and a file
    within it. The only open question is the order and the shape of the directory.

    Two files are targeted in an existing save rather than the current one:

      thumb.png       written by the game, proves the path is right
      photoprobe.png  a screenshot copied in from outside, proves arbitrary PNGs load

    Using a fixed old save rather than the running one is deliberate. The current save's
    name is not known at authoring time, and a matrix that has to discover it first cannot
    distinguish "wrong path shape" from "wrong save name".
    ]]
    local SAVE = "Apocalypse/2026-08-11_17-58-56"
    local SAVE_BACKSLASH = "Apocalypse\\2026-08-11_17-58-56"
    local SAVE_LEAF = "2026-08-11_17-58-56"

    local attempts = {
        { label = "(dir, thumb.png)", a = SAVE, b = "thumb.png" },
        { label = "(thumb.png, dir)", a = "thumb.png", b = SAVE },
        { label = "(dir-backslash, thumb.png)", a = SAVE_BACKSLASH, b = "thumb.png" },
        { label = "(thumb.png, dir-backslash)", a = "thumb.png", b = SAVE_BACKSLASH },
        { label = "(leaf, thumb.png)", a = SAVE_LEAF, b = "thumb.png" },
        { label = "(thumb.png, leaf)", a = "thumb.png", b = SAVE_LEAF },
        { label = "(mode, leaf)", a = "Apocalypse", b = SAVE_LEAF },

        -- Whichever ordering wins above, this is the one that matters: an arbitrary PNG
        -- placed in a save folder, which is exactly what a photo item would be.
        { label = "(dir, photoprobe.png)", a = SAVE, b = "photoprobe.png" },
        { label = "(photoprobe.png, dir)", a = "photoprobe.png", b = SAVE },
    }

    for _, attempt in ipairs(attempts) do
        step(report, "getTextureFromSaveDir " .. attempt.label, function()
            if type(getTextureFromSaveDir) ~= "function" then return "absent" end
            local texture = getTextureFromSaveDir(attempt.a, attempt.b)
            if texture == nil then return "returned nil" end
            local names = methodNames(texture)
            local width = nil
            if hasMethod(texture, "getWidth") then width = texture:getWidth() end
            return string.format(
                "GOT A TEXTURE. width=%s, %d methods: %s",
                tostring(width), #names, table.concat(names, " ")
            )
        end)
    end

    --[[
    Where the screenshot actually landed.

    getScreenshotDir is not bound, so the only way to find the file is to list the
    directories Lua can see and look for the name. Whichever listing contains it is the
    directory the photo mod will address.
    ]]
    -- Round two showed this takes one argument. An extension filter is the likeliest
    -- meaning for a listing helper, and a wrong guess costs one contained error.
    step(report, "listFilesInZomboidLuaDirectory('.png')", function()
        if type(listFilesInZomboidLuaDirectory) ~= "function" then return "absent" end
        local files = listFilesInZomboidLuaDirectory(".png")
        if files == nil then return "nil" end
        local out = {}
        for i = 0, math.min(files:size(), 60) - 1 do
            out[#out + 1] = tostring(files:get(i))
        end
        return table.concat(out, " ")
    end)

    report:add("")
    report:add("probe finished without poisoning the session")
    report:flush()
    print("photoprobe: wrote " .. CALLS_FILE)
end

-- ==========================================================================

--[[
Surface at boot, calls at game start.

The surface phase needs nothing but the main menu, so it answers "do these functions
exist" without loading a save. The call phase needs a world: getTextureFromSaveDir reads
from the current save directory, and at the main menu there is not one.

Both are exposed for re-running from the debug console, since the interesting failures
here are the ones that tell you what to try next.
]]
PhotoProbe = {
    surface = runSurface,
    calls = runCalls,
}

Events.OnGameBoot.Add(runSurface)
Events.OnGameStart.Add(runCalls)
