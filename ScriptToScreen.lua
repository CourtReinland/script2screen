-- ScriptToScreen - AI Filmmaking Plugin for DaVinci Resolve Studio
-- Native Lua launcher with Python bridge for API calls and pipeline orchestration

-- ============================================================
-- GLOBALS AND SETUP
-- ============================================================

local ui = fu.UIManager
local disp = bmd.UIDispatcher(ui)

-- Detect script directory (where this .lua file lives)
local scriptDir = debug.getinfo(1, "S").source:match("@(.*[/\\])") or ""
if scriptDir == "" then
    scriptDir = "/Library/Application Support/Blackmagic Design/DaVinci Resolve/Fusion/Scripts/Utility/"
end

-- Additional search path for Python package (user-writable location)
local homeDir = os.getenv("HOME") or "/Users/capricorn"
local userPackageDir = homeDir .. "/Library/Application Support/ScriptToScreen/"

-- ============================================================
-- MINIMAL JSON DECODER
-- ============================================================

local JSON = {}

function JSON.decode(str)
    if not str or str == "" then return nil end
    str = str:match("^%s*(.-)%s*$")
    if str == "" then return nil end

    local pos = 1

    local function ch()
        return str:sub(pos, pos)
    end

    local function skip_ws()
        while pos <= #str and str:sub(pos, pos):match("[ \t\n\r]") do
            pos = pos + 1
        end
    end

    local parse_value -- forward declaration

    local function parse_string()
        pos = pos + 1 -- skip opening "
        local parts = {}
        while pos <= #str do
            local c = str:sub(pos, pos)
            if c == '"' then
                pos = pos + 1
                return table.concat(parts)
            elseif c == '\\' then
                pos = pos + 1
                c = str:sub(pos, pos)
                if c == 'n' then table.insert(parts, '\n')
                elseif c == 't' then table.insert(parts, '\t')
                elseif c == '"' then table.insert(parts, '"')
                elseif c == '\\' then table.insert(parts, '\\')
                elseif c == '/' then table.insert(parts, '/')
                elseif c == 'b' then table.insert(parts, '\b')
                elseif c == 'f' then table.insert(parts, '\f')
                elseif c == 'r' then table.insert(parts, '\r')
                elseif c == 'u' then
                    -- Skip unicode escape (4 hex digits)
                    pos = pos + 4
                    table.insert(parts, '?')
                else table.insert(parts, c)
                end
            else
                table.insert(parts, c)
            end
            pos = pos + 1
        end
        return table.concat(parts)
    end

    local function parse_number()
        local start = pos
        if ch() == '-' then pos = pos + 1 end
        while pos <= #str and str:sub(pos, pos):match("%d") do pos = pos + 1 end
        if pos <= #str and ch() == '.' then
            pos = pos + 1
            while pos <= #str and str:sub(pos, pos):match("%d") do pos = pos + 1 end
        end
        if pos <= #str and str:sub(pos, pos):match("[eE]") then
            pos = pos + 1
            if pos <= #str and str:sub(pos, pos):match("[%+%-]") then pos = pos + 1 end
            while pos <= #str and str:sub(pos, pos):match("%d") do pos = pos + 1 end
        end
        return tonumber(str:sub(start, pos - 1))
    end

    local function parse_object()
        pos = pos + 1 -- skip {
        skip_ws()
        local obj = {}
        if ch() == '}' then pos = pos + 1; return obj end
        while true do
            skip_ws()
            if ch() ~= '"' then break end
            local key = parse_string()
            skip_ws()
            if ch() == ':' then pos = pos + 1 end
            skip_ws()
            obj[key] = parse_value()
            skip_ws()
            if ch() == ',' then pos = pos + 1
            elseif ch() == '}' then pos = pos + 1; return obj
            else break
            end
        end
        return obj
    end

    local function parse_array()
        pos = pos + 1 -- skip [
        skip_ws()
        local arr = {}
        if ch() == ']' then pos = pos + 1; return arr end
        while true do
            skip_ws()
            table.insert(arr, parse_value())
            skip_ws()
            if ch() == ',' then pos = pos + 1
            elseif ch() == ']' then pos = pos + 1; return arr
            else break
            end
        end
        return arr
    end

    parse_value = function()
        skip_ws()
        local c = ch()
        if c == '"' then return parse_string()
        elseif c == '{' then return parse_object()
        elseif c == '[' then return parse_array()
        elseif c == 't' then pos = pos + 4; return true
        elseif c == 'f' then pos = pos + 5; return false
        elseif c == 'n' then pos = pos + 4; return nil
        elseif c == '-' or c:match("%d") then return parse_number()
        end
        return nil
    end

    local ok, result = pcall(parse_value)
    if ok then return result end
    return nil
end

function JSON.encode(val)
    if val == nil then return "null" end
    local t = type(val)
    if t == "string" then
        return '"' .. val:gsub('\\', '\\\\'):gsub('"', '\\"'):gsub('\n', '\\n'):gsub('\r', '\\r'):gsub('\t', '\\t') .. '"'
    elseif t == "number" then
        return tostring(val)
    elseif t == "boolean" then
        return val and "true" or "false"
    elseif t == "table" then
        -- Check if array or object
        if #val > 0 or next(val) == nil then
            -- Treat as array if has numeric keys
            local isArray = true
            for k, _ in pairs(val) do
                if type(k) ~= "number" then isArray = false; break end
            end
            if isArray then
                local items = {}
                for _, v in ipairs(val) do
                    table.insert(items, JSON.encode(v))
                end
                return "[" .. table.concat(items, ",") .. "]"
            end
        end
        -- Object
        local items = {}
        for k, v in pairs(val) do
            table.insert(items, '"' .. tostring(k) .. '":' .. JSON.encode(v))
        end
        return "{" .. table.concat(items, ",") .. "}"
    end
    return "null"
end

-- ============================================================
-- UTILITY
-- ============================================================

local function fileExists(path)
    local f = io.open(path, "r")
    if f then f:close() return true end
    return false
end

-- ============================================================
-- PYTHON BRIDGE
-- ============================================================

-- Forward declaration: packageDir will be set by PACKAGE CHECK section below
local packageDir = nil

-- Use the venv Python if available, otherwise fall back to system python3
local venvPython = homeDir .. "/Library/Application Support/ScriptToScreen/venv/bin/python3"
local pythonCmd = "python3"  -- default fallback
if fileExists(venvPython) then
    pythonCmd = '"' .. venvPython .. '"'
end

local function runPython(code)
    local tmpfile = os.tmpname() .. ".py"
    local f = io.open(tmpfile, "w")
    if not f then return nil, "Cannot create temp file" end

    -- Build preamble using concatenation (avoids string.format % issues)
    -- Order matters: last insert(0,...) wins position 0.
    -- packageDir (user-writable, has ALL provider files) must come LAST
    -- so it takes priority over scriptDir (system dir, may be stale).
    -- Only add the user package dir (packageDir) and Resolve scripting modules.
    -- Do NOT add scriptDir — it may contain a stale root-owned script_to_screen/
    -- package that shadows the up-to-date user-writable package.
    local preamble = "import sys, os, json\n"
        .. 'sys.path.insert(0, "/Library/Application Support/Blackmagic Design/DaVinci Resolve/Developer/Scripting/Modules")\n'
        .. 'sys.path.insert(0, "' .. (packageDir or userPackageDir) .. '")\n'
        .. "\n"

    f:write(preamble .. code)
    f:close()

    -- Save a copy of the generated script for debugging
    local dbg = io.open("/tmp/sts_last_script.py", "w")
    if dbg then dbg:write(preamble .. code); dbg:close() end

    -- Execute and capture output
    local outfile = os.tmpname()
    local cmd = pythonCmd .. ' "' .. tmpfile .. '" > "' .. outfile .. '" 2>&1'
    os.execute(cmd)

    local out = io.open(outfile, "r")
    local result = ""
    if out then
        result = out:read("*a")
        out:close()
    end

    -- Save output for debugging
    local dbgOut = io.open("/tmp/sts_last_output.txt", "w")
    if dbgOut then dbgOut:write(result or ""); dbgOut:close() end

    os.remove(tmpfile)
    os.remove(outfile)

    return result
end

-- ============================================================
-- PACKAGE CHECK
-- ============================================================

-- Find the Python package in one of the search locations (sets packageDir declared above)
-- User-writable location is checked first so updates take effect without needing sudo
local searchPaths = {
    userPackageDir,                -- User-writable ~/Library/Application Support/ScriptToScreen/
    scriptDir,                     -- Same dir as .lua file (system-level Resolve scripts)
}
for _, dir in ipairs(searchPaths) do
    if fileExists(dir .. "script_to_screen/__init__.py") then
        packageDir = dir
        break
    end
end

if not packageDir then
    local errWin = disp:AddWindow({
        ID = "ErrWin",
        WindowTitle = "ScriptToScreen - Error",
        Geometry = {300, 300, 500, 180},
    }, {
        ui:VGroup{
            ui:Label{
                Text = "Cannot find script_to_screen Python package.<br><br>"
                    .. "Searched in:<br>"
                    .. "<i>" .. scriptDir .. "</i><br>"
                    .. "<i>" .. userPackageDir .. "</i><br><br>"
                    .. "Please re-run install.sh",
                Alignment = {AlignHCenter = true},
                WordWrap = true,
            },
            ui:Button{ID = "ErrOK", Text = "OK"},
        },
    })
    function errWin.On.ErrWin.Close(ev) disp:ExitLoop() end
    function errWin.On.ErrOK.Clicked(ev) disp:ExitLoop() end
    errWin:Show()
    disp:RunLoop()
    errWin:Hide()
    return
end

-- Quick check: is Python3 available?
local pythonOK = false
do
    local testResult = runPython('print("PYTHON_OK")')
    if testResult and testResult:find("PYTHON_OK") then
        pythonOK = true
    end
end

if not pythonOK then
    local errWin = disp:AddWindow({
        ID = "ErrPy",
        WindowTitle = "ScriptToScreen - Python Error",
        Geometry = {300, 300, 480, 160},
    }, {
        ui:VGroup{
            ui:Label{
                Text = "Python3 is not available or not working.<br><br>"
                    .. "ScriptToScreen requires Python 3 with pdfplumber, requests, and Pillow.<br>"
                    .. "Please install them: <i>pip3 install pdfplumber requests Pillow</i>",
                Alignment = {AlignHCenter = true},
                WordWrap = true,
            },
            ui:Button{ID = "ErrOK2", Text = "OK"},
        },
    })
    function errWin.On.ErrPy.Close(ev) disp:ExitLoop() end
    function errWin.On.ErrOK2.Clicked(ev) disp:ExitLoop() end
    errWin:Show()
    disp:RunLoop()
    errWin:Hide()
    return
end

-- ============================================================
-- STATE
-- ============================================================

local STEPS = {"Welcome", "Script", "Characters", "Style", "Images", "Videos", "Voices", "Dialogue", "LipSync", "Assembly"}
local currentStep = 1

local config = {
    -- Provider selections
    imageProvider = "freepik",        -- "freepik" or "comfyui_flux"
    videoProvider = "freepik",        -- "freepik" or "comfyui_ltx"
    voiceProvider = "elevenlabs",     -- "elevenlabs" or "voicebox"
    lipsyncProvider = "freepik",      -- "freepik" (Kling lip sync)
    -- Per-provider credentials
    providers = {
        freepik    = { apiKey = "" },
        elevenlabs = { apiKey = "" },
        grok       = { apiKey = "" },
        comfyui    = { serverUrl = "http://127.0.0.1:8188" },
        voicebox   = { serverUrl = "http://127.0.0.1:17493" },
        kling      = { apiKey = "" },
    },
    -- Legacy (kept for backward compat)
    freepikKey = "",
    elevenlabsKey = "",
    -- Generation settings
    model = "realism",
    aspectRatio = "widescreen_16_9",
    detailing = 33,
    -- Episode info
    episodeNumber = "",
    episodeTitle = "",
}

local screenplayData = nil -- parsed screenplay (Lua table from JSON)
local characterImages = {} -- characterName -> imagePath
local characterVoices = {} -- characterName -> voiceId
local generatedImages = {} -- shotKey -> imagePath
local generatedVideos = {} -- shotKey -> videoPath
local generatedAudio = {}  -- dialogueKey -> audioPath
local lipSyncedVideos = {} -- shotKey -> videoPath

-- Derive project slug from current Resolve project name
local projectSlug = "default"
do
    local project = resolve and resolve:GetProjectManager() and resolve:GetProjectManager():GetCurrentProject()
    if project then
        local pname = project:GetName() or "default"
        projectSlug = pname:gsub("[^%w%-]", "_"):gsub("^_+", ""):gsub("_+$", ""):lower()
        if projectSlug == "" then projectSlug = "default" end
    end
end
local outputDir = homeDir .. "/Library/Application Support/ScriptToScreen/projects/" .. projectSlug
os.execute('mkdir -p "' .. outputDir .. '/images"')
os.execute('mkdir -p "' .. outputDir .. '/videos"')
os.execute('mkdir -p "' .. outputDir .. '/audio"')
os.execute('mkdir -p "' .. outputDir .. '/lipsync"')

-- Load saved config
local configDir = homeDir .. "/Library/Application Support/ScriptToScreen"
local configPath = configDir .. "/config.json"
do
    local f = io.open(configPath, "r")
    if f then
        local content = f:read("*a")
        f:close()
        local saved = JSON.decode(content)
        if saved then
            -- Provider selections
            config.imageProvider = saved.imageProvider or "freepik"
            config.videoProvider = saved.videoProvider or "freepik"
            config.voiceProvider = saved.voiceProvider or "elevenlabs"
            config.lipsyncProvider = saved.lipsyncProvider or "freepik"
            -- Provider credentials
            if saved.providers then
                if saved.providers.freepik then
                    config.providers.freepik.apiKey = saved.providers.freepik.apiKey or ""
                end
                if saved.providers.elevenlabs then
                    config.providers.elevenlabs.apiKey = saved.providers.elevenlabs.apiKey or ""
                end
                if saved.providers.comfyui then
                    config.providers.comfyui.serverUrl = saved.providers.comfyui.serverUrl or "http://127.0.0.1:8188"
                end
                if saved.providers.grok then
                    config.providers.grok.apiKey = saved.providers.grok.apiKey or ""
                end
                if saved.providers.kling then
                    config.providers.kling.apiKey = saved.providers.kling.apiKey or ""
                end
                if saved.providers.voicebox then
                    config.providers.voicebox.serverUrl = saved.providers.voicebox.serverUrl or "http://127.0.0.1:17493"
                end
            end
            -- Migrate legacy keys
            if saved.freepikKey and saved.freepikKey ~= "" and config.providers.freepik.apiKey == "" then
                config.providers.freepik.apiKey = saved.freepikKey
            end
            if saved.elevenlabsKey and saved.elevenlabsKey ~= "" and config.providers.elevenlabs.apiKey == "" then
                config.providers.elevenlabs.apiKey = saved.elevenlabsKey
            end
            -- Legacy fields (kept for compat)
            config.freepikKey = config.providers.freepik.apiKey
            config.elevenlabsKey = config.providers.elevenlabs.apiKey
            -- Generation settings
            config.model = saved.model or "realism"
            config.aspectRatio = saved.aspectRatio or "widescreen_16_9"
            config.detailing = saved.detailing or 33
            config.episodeNumber = saved.episodeNumber or ""
            config.episodeTitle = saved.episodeTitle or ""
        end
    end
end

local function saveConfig()
    os.execute('mkdir -p "' .. configDir .. '"')
    -- Keep legacy keys in sync
    config.freepikKey = config.providers.freepik.apiKey
    config.elevenlabsKey = config.providers.elevenlabs.apiKey
    local f = io.open(configPath, "w")
    if f then
        f:write(JSON.encode(config))
        f:close()
    end
end

-- ============================================================
-- MAIN WIZARD WINDOW
-- ============================================================

local win = disp:AddWindow({
    ID = "STS_Main",
    WindowTitle = "ScriptToScreen - AI Filmmaking",
    Geometry = {100, 20, 750, 900},
}, {
    ui:VGroup{
        -- Step indicator + Episode info (combined into one row)
        ui:HGroup{
            StyleSheet = "background-color: #333; padding: 4px;",
            ui:Label{
                ID = "StepLabel",
                Text = "<b>Step 1/10</b>",
                StyleSheet = "font-size: 12px; color: #ddd; padding-right: 10px;",
                Weight = 0.2,
            },
            ui:Label{Text = "Ep:", StyleSheet = "color: #999;", Weight = 0.04},
            ui:LineEdit{ID = "EpisodeNumber", PlaceholderText = "#", Weight = 0.06},
            ui:Label{Text = "Title:", StyleSheet = "color: #999;", Weight = 0.05},
            ui:LineEdit{ID = "EpisodeTitle", PlaceholderText = "Episode Title", Weight = 0.65},
        },

        -- Page stack (10 pages)
        ui:Stack{
            ID = "PageStack",

            -- ========================
            -- PAGE 0: Welcome & API Config
            -- ========================
            ui:VGroup{
                ID = "WelcomePage",
                ui:Label{
                    Text = "<h3>ScriptToScreen</h3>"
                        .. "<p style='font-size:11px'>AI Filmmaking — screenplay to timeline</p>",
                    Alignment = {AlignHCenter = true},
                    StyleSheet = "padding: 4px;",
                },

                -- Image Provider
                ui:Label{Text = "<b>Image Generation</b>", StyleSheet = "padding-top: 10px;"},
                ui:HGroup{
                    ui:Label{Text = "Provider:", Weight = 0.15},
                    ui:ComboBox{ID = "ImageProviderCombo", Weight = 0.35},
                    ui:LineEdit{ID = "ImageApiKey", PlaceholderText = "API key...", EchoMode = "Password", Weight = 0.3},
                    ui:Button{ID = "TestImageProvider", Text = "Test", Weight = 0.1},
                    ui:Label{ID = "ImageProviderStatus", Text = "", Weight = 0.1},
                },
                ui:HGroup{
                    ui:Label{Text = "Server URL:", Weight = 0.15},
                    ui:LineEdit{ID = "ImageServerUrl", Text = "http://127.0.0.1:8188", Weight = 0.65},
                    ui:Label{Text = "", Weight = 0.2},
                },

                -- Video Provider
                ui:Label{Text = "<b>Video Generation</b>", StyleSheet = "padding-top: 8px;"},
                ui:HGroup{
                    ui:Label{Text = "Provider:", Weight = 0.15},
                    ui:ComboBox{ID = "VideoProviderCombo", Weight = 0.35},
                    ui:LineEdit{ID = "VideoApiKey", PlaceholderText = "API key...", EchoMode = "Password", Weight = 0.3},
                    ui:Button{ID = "TestVideoProvider", Text = "Test", Weight = 0.1},
                    ui:Label{ID = "VideoProviderStatus", Text = "", Weight = 0.1},
                },
                ui:HGroup{
                    ui:Label{Text = "Server URL:", Weight = 0.15},
                    ui:LineEdit{ID = "VideoServerUrl", Text = "http://127.0.0.1:8188", Weight = 0.65},
                    ui:Label{Text = "", Weight = 0.2},
                },

                -- Voice Provider
                ui:Label{Text = "<b>Voice Generation</b>", StyleSheet = "padding-top: 8px;"},
                ui:HGroup{
                    ui:Label{Text = "Provider:", Weight = 0.15},
                    ui:ComboBox{ID = "VoiceProviderCombo", Weight = 0.35},
                    ui:LineEdit{ID = "VoiceApiKey", PlaceholderText = "API key...", EchoMode = "Password", Weight = 0.3},
                    ui:Button{ID = "TestVoiceProvider", Text = "Test", Weight = 0.1},
                    ui:Label{ID = "VoiceProviderStatus", Text = "", Weight = 0.1},
                },
                ui:HGroup{
                    ui:Label{Text = "Server URL:", Weight = 0.15},
                    ui:LineEdit{ID = "VoiceServerUrl", Text = "http://127.0.0.1:17493", Weight = 0.65},
                    ui:Label{Text = "", Weight = 0.2},
                },

                -- Lip Sync Provider
                ui:Label{Text = "<b>Lip Sync</b>", StyleSheet = "padding-top: 8px;"},
                ui:HGroup{
                    ui:Label{Text = "Provider:", Weight = 0.15},
                    ui:ComboBox{ID = "LipSyncProviderCombo", Weight = 0.35},
                    ui:LineEdit{ID = "LipSyncApiKey", PlaceholderText = "access_key:secret_key", EchoMode = "Password", Weight = 0.3},
                    ui:Button{ID = "TestLipSyncProvider", Text = "Test", Weight = 0.1},
                    ui:Label{ID = "LipSyncProviderStatus", Text = "", Weight = 0.1},
                },

                ui:Label{
                    ID = "PythonStatusLabel",
                    Text = pythonOK and "Python3: OK" or "<span style='color:red'>Python3: NOT FOUND</span>",
                    StyleSheet = "padding: 2px; color: gray; font-size: 10px;",
                },
                ui:HGroup{
                    ui:Label{Text = "", Weight = 0.7},
                    ui:Button{ID = "CancelBtn", Text = "Cancel", Weight = 0.15},
                    ui:Button{ID = "NextBtn", Text = "Next >", Weight = 0.15},
                },
            },

            -- ========================
            -- PAGE 1: Import Screenplay
            -- ========================
            ui:VGroup{
                ID = "ScriptPage",
                ui:Label{Text = "<h3>Import Screenplay</h3>", Alignment = {AlignHCenter = true}},
                ui:HGroup{
                    ui:Label{Text = "Script File:", Weight = 0.12},
                    ui:LineEdit{ID = "ScriptPath", PlaceholderText = "Select PDF or .fountain file...", ReadOnly = true, Weight = 0.58},
                    ui:Button{ID = "BrowseScript", Text = "Browse", Weight = 0.15},
                    ui:Button{ID = "ParseScript", Text = "Parse", Weight = 0.15},
                },
                ui:Label{ID = "ParseStatus", Text = "", StyleSheet = "padding: 5px;"},
                ui:Label{Text = "<b>Screenplay Summary</b>", StyleSheet = "padding-top: 8px;"},
                ui:TextEdit{ID = "ScriptSummary", ReadOnly = true, PlaceholderText = "Parse a screenplay to see summary...", MinimumSize = {400, 180}},
                ui:VGap(0, 0.5),
                ui:HGroup{
                    ui:Label{Text = "", Weight = 0.55},
                    ui:Button{ID = "CancelBtn2", Text = "Cancel", Weight = 0.15},
                    ui:Button{ID = "BackBtn2", Text = "< Back", Weight = 0.15},
                    ui:Button{ID = "NextBtn2", Text = "Next >", Weight = 0.15},
                },
            },

            -- ========================
            -- PAGE 2: Character Setup
            -- ========================
            ui:VGroup{
                ID = "CharPage",
                ui:Label{Text = "<h3>Character Setup</h3><p>Assign a reference image for each character.</p>", Alignment = {AlignHCenter = true}},
                ui:Tree{ID = "CharTree", HeaderHidden = false, MinimumSize = {500, 250}},
                ui:HGroup{
                    ui:Button{ID = "BrowseCharImg", Text = "Set Image for Selected", Weight = 0.3},
                    ui:Button{ID = "ClearCharImg", Text = "Clear", Weight = 0.15},
                    ui:Label{Text = "", Weight = 0.55},
                },
                ui:VGap(0, 0.5),
                ui:HGroup{
                    ui:Label{Text = "", Weight = 0.55},
                    ui:Button{ID = "CancelBtn3", Text = "Cancel", Weight = 0.15},
                    ui:Button{ID = "BackBtn3", Text = "< Back", Weight = 0.15},
                    ui:Button{ID = "NextBtn3", Text = "Next >", Weight = 0.15},
                },
            },

            -- ========================
            -- PAGE 3: Style Reference
            -- ========================
            ui:VGroup{
                ID = "StylePage",
                ui:Label{Text = "<h3>Style Reference</h3><p>Choose a style reference image and generation settings.</p>", Alignment = {AlignHCenter = true}},
                ui:HGroup{
                    ui:Label{Text = "Style Image:", Weight = 0.15},
                    ui:LineEdit{ID = "StylePath", PlaceholderText = "Select style reference image...", ReadOnly = true, Weight = 0.6},
                    ui:Button{ID = "BrowseStyle", Text = "Browse", Weight = 0.12},
                    ui:Button{ID = "ClearStyle", Text = "Clear", Weight = 0.12},
                },
                ui:Label{Text = "<b>Generation Settings</b>", StyleSheet = "padding-top: 10px;"},
                ui:HGroup{
                    ui:Label{Text = "Model:", Weight = 0.2},
                    ui:ComboBox{ID = "ModelCombo", Weight = 0.8},
                },
                ui:HGroup{
                    ui:Label{Text = "Aspect Ratio:", Weight = 0.2},
                    ui:ComboBox{ID = "AspectCombo", Weight = 0.8},
                },
                ui:HGroup{
                    ui:Label{Text = "Creative Detail:", Weight = 0.2},
                    ui:Slider{ID = "DetailSlider", Minimum = 0, Maximum = 100, Value = 33, Weight = 0.6},
                    ui:Label{ID = "DetailValue", Text = "33", Weight = 0.2},
                },
                ui:VGap(0, 1),
                ui:HGroup{
                    ui:Label{Text = "", Weight = 0.55},
                    ui:Button{ID = "CancelBtn4", Text = "Cancel", Weight = 0.15},
                    ui:Button{ID = "BackBtn4", Text = "< Back", Weight = 0.15},
                    ui:Button{ID = "NextBtn4", Text = "Next >", Weight = 0.15},
                },
            },

            -- ========================
            -- PAGE 4: Image Generation
            -- ========================
            ui:VGroup{
                ID = "ImageGenPage",
                ui:Label{Text = "<h3>Image Generation</h3><p>Generate start-frame images for each shot.</p>", Alignment = {AlignHCenter = true}},
                ui:Tree{ID = "ImageTree", HeaderHidden = false, MinimumSize = {500, 150}},
                ui:Label{Text = "Prompt for selected shot:"},
                ui:TextEdit{ID = "ImagePrompt", MinimumSize = {400, 50}},
                ui:HGroup{
                    ui:Button{ID = "GenAllImages", Text = "Generate All Images", Weight = 0.3},
                    ui:Button{ID = "RegenImage", Text = "Regenerate Selected", Weight = 0.3},
                    ui:Label{Text = "", Weight = 0.4},
                },
                ui:Label{ID = "ImageProgress", Text = "Ready"},
                ui:VGap(0, 0.5),
                ui:HGroup{
                    ui:Label{Text = "", Weight = 0.55},
                    ui:Button{ID = "CancelBtn5", Text = "Cancel", Weight = 0.15},
                    ui:Button{ID = "BackBtn5", Text = "< Back", Weight = 0.15},
                    ui:Button{ID = "NextBtn5", Text = "Next >", Weight = 0.15},
                },
            },

            -- ========================
            -- PAGE 5: Video Generation
            -- ========================
            ui:VGroup{
                ID = "VideoGenPage",
                ui:Label{Text = "<h3>Video Generation</h3><p>Generate videos from start-frame images.</p>", Alignment = {AlignHCenter = true}},
                ui:Tree{ID = "VideoTree", HeaderHidden = false, MinimumSize = {500, 150}},
                ui:HGroup{
                    ui:Label{Text = "Duration (s):", Weight = 0.15},
                    ui:SpinBox{ID = "DurationSpin", Minimum = 3, Maximum = 15, Value = 5, Weight = 0.15},
                    ui:Label{Text = "Motion prompt:", Weight = 0.1},
                    ui:LineEdit{ID = "MotionPrompt", PlaceholderText = "Auto-filled from action", Weight = 0.6},
                },
                ui:HGroup{
                    ui:Button{ID = "GenAllVideos", Text = "Generate All Videos", Weight = 0.3},
                    ui:Button{ID = "RegenVideo", Text = "Regenerate Selected", Weight = 0.3},
                    ui:Label{Text = "", Weight = 0.4},
                },
                ui:Label{ID = "VideoProgress", Text = "Ready"},
                ui:VGap(0, 0.5),
                ui:HGroup{
                    ui:Label{Text = "", Weight = 0.55},
                    ui:Button{ID = "CancelBtn6", Text = "Cancel", Weight = 0.15},
                    ui:Button{ID = "BackBtn6", Text = "< Back", Weight = 0.15},
                    ui:Button{ID = "NextBtn6", Text = "Next >", Weight = 0.15},
                },
            },

            -- ========================
            -- PAGE 6: Voice Setup
            -- ========================
            ui:VGroup{
                ID = "VoicePage",
                ui:Label{Text = "<h3>Voice Setup</h3><p>Provide voice samples for each speaking character.</p>", Alignment = {AlignHCenter = true}},
                ui:Tree{ID = "VoiceTree", HeaderHidden = false, MinimumSize = {500, 200}},
                ui:HGroup{
                    ui:Button{ID = "BrowseVoice", Text = "Add Voice Sample", Weight = 0.25},
                    ui:Button{ID = "CloneVoice", Text = "Clone Voice", Weight = 0.2},
                    ui:Button{ID = "TestVoice", Text = "Test", Weight = 0.15},
                    ui:Label{Text = "", Weight = 0.4},
                },
                ui:Label{ID = "VoiceProgress", Text = "Ready"},
                ui:VGap(0, 0.5),
                ui:HGroup{
                    ui:Label{Text = "", Weight = 0.55},
                    ui:Button{ID = "CancelBtn7", Text = "Cancel", Weight = 0.15},
                    ui:Button{ID = "BackBtn7", Text = "< Back", Weight = 0.15},
                    ui:Button{ID = "NextBtn7", Text = "Next >", Weight = 0.15},
                },
            },

            -- ========================
            -- PAGE 7: Dialogue Generation
            -- ========================
            ui:VGroup{
                ID = "DialoguePage",
                ui:Label{Text = "<h3>Dialogue Generation</h3><p>Generate spoken audio for all dialogue lines.</p>", Alignment = {AlignHCenter = true}},
                ui:Tree{ID = "DialogueTree", HeaderHidden = false, MinimumSize = {500, 200}},
                ui:HGroup{
                    ui:Button{ID = "GenAllDialogue", Text = "Generate All Dialogue", Weight = 0.3},
                    ui:Button{ID = "RegenDialogue", Text = "Regenerate Selected", Weight = 0.3},
                    ui:Label{Text = "", Weight = 0.4},
                },
                ui:Label{ID = "DialogueProgress", Text = "Ready"},
                ui:VGap(0, 0.5),
                ui:HGroup{
                    ui:Label{Text = "", Weight = 0.55},
                    ui:Button{ID = "CancelBtn8", Text = "Cancel", Weight = 0.15},
                    ui:Button{ID = "BackBtn8", Text = "< Back", Weight = 0.15},
                    ui:Button{ID = "NextBtn8", Text = "Next >", Weight = 0.15},
                },
            },

            -- ========================
            -- PAGE 8: Lip Sync
            -- ========================
            ui:VGroup{
                ID = "LipSyncPage",
                ui:Label{Text = "<h3>Lip Sync</h3><p>Synchronize dialogue audio with video clips.</p>", Alignment = {AlignHCenter = true}},
                ui:Tree{ID = "LipSyncTree", HeaderHidden = false, MinimumSize = {500, 200}},
                ui:HGroup{
                    ui:Button{ID = "SyncAll", Text = "Sync All", Weight = 0.25},
                    ui:Button{ID = "RegenSync", Text = "Regenerate Selected", Weight = 0.3},
                    ui:Label{Text = "", Weight = 0.45},
                },
                ui:Label{ID = "LipSyncProgress", Text = "Ready"},
                ui:VGap(0, 0.5),
                ui:HGroup{
                    ui:Label{Text = "", Weight = 0.55},
                    ui:Button{ID = "CancelBtn9", Text = "Cancel", Weight = 0.15},
                    ui:Button{ID = "BackBtn9", Text = "< Back", Weight = 0.15},
                    ui:Button{ID = "NextBtn9", Text = "Next >", Weight = 0.15},
                },
            },

            -- ========================
            -- PAGE 9: Timeline Assembly
            -- ========================
            ui:VGroup{
                ID = "AssemblyPage",
                ui:Label{Text = "<h3>Timeline Assembly</h3><p>Assemble all generated media into a Resolve timeline.</p>", Alignment = {AlignHCenter = true}},
                ui:HGroup{
                    ui:Label{Text = "Timeline Name:", Weight = 0.2},
                    ui:LineEdit{ID = "TimelineName", Text = "ScriptToScreen Assembly", Weight = 0.8},
                },
                ui:HGroup{
                    ui:Label{Text = "Resolution:", Weight = 0.2},
                    ui:ComboBox{ID = "ResCombo", Weight = 0.3},
                    ui:Label{Text = "FPS:", Weight = 0.1},
                    ui:ComboBox{ID = "FPSCombo", Weight = 0.3},
                    ui:Label{Text = "", Weight = 0.1},
                },
                ui:Label{Text = "<b>Assembly Preview</b>", StyleSheet = "padding-top: 8px;"},
                ui:TextEdit{ID = "AssemblySummary", ReadOnly = true, MinimumSize = {400, 150}},
                ui:HGroup{
                    ui:Button{ID = "AssembleBtn", Text = "Assemble Timeline", Weight = 0.3},
                    ui:Label{Text = "", Weight = 0.7},
                },
                ui:Label{ID = "AssemblyProgress", Text = "Ready"},
                ui:VGap(0, 0.5),
                ui:HGroup{
                    ui:Label{Text = "", Weight = 0.55},
                    ui:Button{ID = "CancelBtn10", Text = "Cancel", Weight = 0.15},
                    ui:Button{ID = "BackBtn10", Text = "< Back", Weight = 0.15},
                    ui:Button{ID = "FinishBtn", Text = "Finish", Weight = 0.15},
                },
            },
        },
    },
})

local itm = win:GetItems()

-- ============================================================
-- INITIALIZE COMBO BOXES
-- ============================================================

-- Provider combo boxes (id -> display name mappings)
local imageProviders = {
    {id = "freepik",      name = "Freepik Mystic (Cloud)"},
    {id = "grok",         name = "Grok Imagine (Cloud)"},
    {id = "comfyui_flux", name = "Flux Kontext (Local ComfyUI)"},
}
local videoProviders = {
    {id = "freepik",      name = "Kling 3 Omni (Cloud via Freepik)"},
    {id = "grok",         name = "Grok Imagine Video (Cloud)"},
    {id = "comfyui_ltx",  name = "LTX 2.3 (Local ComfyUI)"},
}
local voiceProviders = {
    {id = "mlx_audio",    name = "MLX-Audio Kokoro (Local, Fast)"},
    {id = "elevenlabs",   name = "ElevenLabs (Cloud)"},
    {id = "voicebox",     name = "Voicebox (Local, Slow)"},
}
local lipsyncProviders = {
    {id = "kling",        name = "Kling AI (Direct API)"},
    {id = "freepik",      name = "Kling Lip Sync (via Freepik)"},
}

for _, p in ipairs(imageProviders) do itm.ImageProviderCombo:AddItem(p.name) end
for _, p in ipairs(videoProviders) do itm.VideoProviderCombo:AddItem(p.name) end
for _, p in ipairs(voiceProviders) do itm.VoiceProviderCombo:AddItem(p.name) end
for _, p in ipairs(lipsyncProviders) do itm.LipSyncProviderCombo:AddItem(p.name) end

-- Helper: get provider ID from combo index
local function getImageProviderId(idx) return imageProviders[(idx or 0) + 1] and imageProviders[(idx or 0) + 1].id or "freepik" end
local function getVideoProviderId(idx) return videoProviders[(idx or 0) + 1] and videoProviders[(idx or 0) + 1].id or "freepik" end
local function getVoiceProviderId(idx) return voiceProviders[(idx or 0) + 1] and voiceProviders[(idx or 0) + 1].id or "elevenlabs" end
local function getLipSyncProviderId(idx) return lipsyncProviders[(idx or 0) + 1] and lipsyncProviders[(idx or 0) + 1].id or "freepik" end

-- Helper: set combo to match saved provider ID
local function setComboToProvider(combo, providers, targetId)
    for i, p in ipairs(providers) do
        if p.id == targetId then
            combo.CurrentIndex = i - 1
            return
        end
    end
    combo.CurrentIndex = 0
end

-- Helper: update field visibility based on provider type
local function updateImageProviderFields()
    local id = getImageProviderId(itm.ImageProviderCombo.CurrentIndex)
    local isCloud = (id == "freepik" or id == "grok")
    itm.ImageApiKey.Enabled = isCloud
    itm.ImageServerUrl.Enabled = not isCloud
    if id == "freepik" then
        itm.ImageApiKey.PlaceholderText = "Freepik API key..."
        itm.ImageApiKey.Text = config.providers.freepik.apiKey or ""
    elseif id == "grok" then
        itm.ImageApiKey.PlaceholderText = "xAI API key..."
        itm.ImageApiKey.Text = config.providers.grok.apiKey or ""
    else
        itm.ImageApiKey.PlaceholderText = "(not needed)"
        itm.ImageApiKey.Text = ""
    end
end

local function updateVideoProviderFields()
    local id = getVideoProviderId(itm.VideoProviderCombo.CurrentIndex)
    local isCloud = (id == "freepik" or id == "grok")
    itm.VideoApiKey.Enabled = isCloud
    itm.VideoServerUrl.Enabled = not isCloud
    if id == "freepik" then
        itm.VideoApiKey.PlaceholderText = "Freepik API key..."
        itm.VideoApiKey.Text = config.providers.freepik.apiKey or ""
    elseif id == "grok" then
        itm.VideoApiKey.PlaceholderText = "xAI API key..."
        itm.VideoApiKey.Text = config.providers.grok.apiKey or ""
    else
        itm.VideoApiKey.PlaceholderText = "(not needed)"
        itm.VideoApiKey.Text = ""
    end
end

local function updateVoiceProviderFields()
    local id = getVoiceProviderId(itm.VoiceProviderCombo.CurrentIndex)
    local isCloud = (id == "elevenlabs")
    itm.VoiceApiKey.Enabled = isCloud
    itm.VoiceApiKey.PlaceholderText = isCloud and "ElevenLabs API key..." or "(not needed)"
    itm.VoiceServerUrl.Enabled = not isCloud
    if isCloud then
        itm.VoiceApiKey.Text = config.providers.elevenlabs.apiKey or ""
    else
        itm.VoiceApiKey.Text = ""
    end
end

local function updateLipSyncProviderFields()
    local id = getLipSyncProviderId(itm.LipSyncProviderCombo.CurrentIndex)
    if id == "kling" then
        itm.LipSyncApiKey.PlaceholderText = "access_key:secret_key"
        itm.LipSyncApiKey.Text = config.providers.kling and config.providers.kling.apiKey or ""
    else
        itm.LipSyncApiKey.PlaceholderText = "Freepik API key..."
        itm.LipSyncApiKey.Text = config.providers.freepik.apiKey or ""
    end
end

-- Initialize provider combos from saved config
setComboToProvider(itm.ImageProviderCombo, imageProviders, config.imageProvider)
setComboToProvider(itm.VideoProviderCombo, videoProviders, config.videoProvider)
setComboToProvider(itm.VoiceProviderCombo, voiceProviders, config.voiceProvider)
setComboToProvider(itm.LipSyncProviderCombo, lipsyncProviders, config.lipsyncProvider)

-- Set server URL fields
itm.ImageServerUrl.Text = config.providers.comfyui.serverUrl
itm.VideoServerUrl.Text = config.providers.comfyui.serverUrl
itm.VoiceServerUrl.Text = config.providers.voicebox and config.providers.voicebox.serverUrl or "http://127.0.0.1:17493"

-- Initialize episode fields
itm.EpisodeNumber.Text = config.episodeNumber or ""
itm.EpisodeTitle.Text = config.episodeTitle or ""

-- Initialize field visibility
updateImageProviderFields()
updateVideoProviderFields()
updateVoiceProviderFields()
updateLipSyncProviderFields()

-- Style page combos
itm.ModelCombo:AddItem("realism")
itm.ModelCombo:AddItem("fluid")
itm.ModelCombo:AddItem("zen")
itm.ModelCombo:AddItem("flexible")
itm.ModelCombo:AddItem("super_real")

itm.AspectCombo:AddItem("widescreen_16_9")
itm.AspectCombo:AddItem("classic_4_3")
itm.AspectCombo:AddItem("square_1_1")

itm.ResCombo:AddItem("1920x1080")
itm.ResCombo:AddItem("3840x2160")
itm.ResCombo:AddItem("1280x720")

itm.FPSCombo:AddItem("24")
itm.FPSCombo:AddItem("25")
itm.FPSCombo:AddItem("30")

-- ============================================================
-- NAVIGATION
-- ============================================================

local function showStep(step)
    currentStep = step
    itm.PageStack.CurrentIndex = step - 1
    itm.StepLabel.Text = string.format("<b>%d/%d: %s</b>", step, #STEPS, STEPS[step])
    -- When entering Assembly (step 10), set timeline name from episode info
    if step == 10 then
        local epNum = config.episodeNumber or ""
        local epTitle = config.episodeTitle or ""
        if epNum ~= "" or epTitle ~= "" then
            local tlName = ""
            if epNum ~= "" and epTitle ~= "" then
                tlName = "Ep" .. epNum .. " - " .. epTitle
            elseif epNum ~= "" then
                tlName = "Ep" .. epNum
            else
                tlName = epTitle
            end
            itm.TimelineName.Text = tlName
        end
    end
end

local function onNext()
    -- Save config when leaving step 1
    if currentStep == 1 then
        -- Save provider selections
        config.imageProvider = getImageProviderId(itm.ImageProviderCombo.CurrentIndex)
        config.videoProvider = getVideoProviderId(itm.VideoProviderCombo.CurrentIndex)
        config.voiceProvider = getVoiceProviderId(itm.VoiceProviderCombo.CurrentIndex)
        -- Save credentials
        local imgId = config.imageProvider
        if imgId == "freepik" then
            config.providers.freepik.apiKey = itm.ImageApiKey.Text
        elseif imgId == "grok" then
            config.providers.grok.apiKey = itm.ImageApiKey.Text
        end
        local vidId = config.videoProvider
        if vidId == "freepik" then
            config.providers.freepik.apiKey = itm.VideoApiKey.Text
        elseif vidId == "grok" then
            config.providers.grok.apiKey = itm.VideoApiKey.Text
        end
        local voiceId = config.voiceProvider
        if voiceId == "elevenlabs" then
            config.providers.elevenlabs.apiKey = itm.VoiceApiKey.Text
        end
        -- Save lip sync provider
        config.lipsyncProvider = getLipSyncProviderId(itm.LipSyncProviderCombo.CurrentIndex)
        local lsKey = itm.LipSyncApiKey.Text
        if lsKey ~= "" then
            if config.lipsyncProvider == "kling" then
                config.providers.kling.apiKey = lsKey
            else
                config.providers.freepik.apiKey = lsKey
            end
        end
        -- Save server URLs
        config.providers.comfyui.serverUrl = itm.ImageServerUrl.Text
        config.providers.voicebox.serverUrl = itm.VoiceServerUrl.Text
        -- Save episode info
        config.episodeNumber = itm.EpisodeNumber.Text or ""
        config.episodeTitle = itm.EpisodeTitle.Text or ""
        saveConfig()
    end
    if currentStep < #STEPS then
        showStep(currentStep + 1)
    end
end

local function onBack()
    if currentStep > 1 then
        showStep(currentStep - 1)
    end
end

local function onClose()
    disp:ExitLoop()
end

-- ============================================================
-- EVENT HANDLERS: Navigation buttons (explicit for Fusion UI compatibility)
-- ============================================================

-- Cancel buttons
function win.On.CancelBtn.Clicked(ev) onClose() end
function win.On.CancelBtn2.Clicked(ev) onClose() end
function win.On.CancelBtn3.Clicked(ev) onClose() end
function win.On.CancelBtn4.Clicked(ev) onClose() end
function win.On.CancelBtn5.Clicked(ev) onClose() end
function win.On.CancelBtn6.Clicked(ev) onClose() end
function win.On.CancelBtn7.Clicked(ev) onClose() end
function win.On.CancelBtn8.Clicked(ev) onClose() end
function win.On.CancelBtn9.Clicked(ev) onClose() end
function win.On.CancelBtn10.Clicked(ev) onClose() end

-- Back buttons
function win.On.BackBtn2.Clicked(ev) onBack() end
function win.On.BackBtn3.Clicked(ev) onBack() end
function win.On.BackBtn4.Clicked(ev) onBack() end
function win.On.BackBtn5.Clicked(ev) onBack() end
function win.On.BackBtn6.Clicked(ev) onBack() end
function win.On.BackBtn7.Clicked(ev) onBack() end
function win.On.BackBtn8.Clicked(ev) onBack() end
function win.On.BackBtn9.Clicked(ev) onBack() end
function win.On.BackBtn10.Clicked(ev) onBack() end

-- Next buttons
function win.On.NextBtn.Clicked(ev) onNext() end
function win.On.NextBtn2.Clicked(ev) onNext() end
function win.On.NextBtn3.Clicked(ev) onNext() end
function win.On.NextBtn4.Clicked(ev) onNext() end
function win.On.NextBtn5.Clicked(ev) onNext() end
function win.On.NextBtn6.Clicked(ev) onNext() end
function win.On.NextBtn7.Clicked(ev) onNext() end
function win.On.NextBtn8.Clicked(ev) onNext() end
function win.On.NextBtn9.Clicked(ev) onNext() end

-- Finish & Close
function win.On.FinishBtn.Clicked(ev) onClose() end
function win.On.STS_Main.Close(ev) onClose() end

-- ============================================================
-- STEP 1: Provider Combo Change Handlers
-- ============================================================

function win.On.ImageProviderCombo.CurrentIndexChanged(ev)
    updateImageProviderFields()
end

function win.On.VideoProviderCombo.CurrentIndexChanged(ev)
    updateVideoProviderFields()
end

function win.On.VoiceProviderCombo.CurrentIndexChanged(ev)
    updateVoiceProviderFields()
end

function win.On.LipSyncProviderCombo.CurrentIndexChanged(ev)
    updateLipSyncProviderFields()
end

-- ============================================================
-- STEP 1: Provider Connection Tests (generic via registry)
-- ============================================================

-- Generic provider test: writes key to temp file (avoids string escaping),
-- uses registry to create + test the provider
local function testProvider(providerId, apiKey, serverUrl, statusLabel)
    statusLabel.Text = "Testing..."
    statusLabel.StyleSheet = "color: #888;"

    -- Write API key to temp file to avoid escaping issues
    local keyfile = os.tmpname()
    local kf = io.open(keyfile, "w")
    if kf then
        kf:write(apiKey or "")
        kf:close()
    end

    local safeUrl = (serverUrl or ""):gsub("\\", "\\\\"):gsub('"', '\\"')

    local code = 'import json\n'
        .. 'try:\n'
        .. '    from script_to_screen.api.registry import create_image_provider, create_video_provider, create_voice_provider, create_lipsync_provider\n'
        .. '    key = open("' .. keyfile .. '").read().strip()\n'
        .. '    pid = "' .. providerId .. '"\n'
        .. '    # Try each category until one works\n'
        .. '    provider = None\n'
        .. '    for factory_name, factory_fn in [\n'
        .. '        ("image", create_image_provider),\n'
        .. '        ("video", create_video_provider),\n'
        .. '        ("voice", create_voice_provider),\n'
        .. '        ("lipsync", create_lipsync_provider),\n'
        .. '    ]:\n'
        .. '        try:\n'
        .. '            provider = factory_fn(pid, api_key=key, server_url="' .. safeUrl .. '")\n'
        .. '            break\n'
        .. '        except ValueError:\n'
        .. '            continue\n'
        .. '    if provider is None:\n'
        .. '        print("RESULT:FAIL Unknown provider: " + pid)\n'
        .. '    else:\n'
        .. '        ok, msg = provider.test_connection_details()\n'
        .. '        if ok:\n'
        .. '            print("RESULT:OK " + msg)\n'
        .. '        else:\n'
        .. '            print("RESULT:FAIL " + msg)\n'
        .. 'except Exception as e:\n'
        .. '    print("RESULT:FAIL " + str(e))\n'

    local result = runPython(code)
    os.remove(keyfile)

    if result and result:find("RESULT:OK") then
        local msg = result:match("RESULT:OK (.+)") or "Connected"
        statusLabel.Text = msg:sub(1, 30)
        statusLabel.StyleSheet = "color: green; font-weight: bold;"
        return true
    else
        local msg = result and result:match("RESULT:FAIL (.+)") or "No response"
        statusLabel.Text = (msg or "Failed"):sub(1, 35)
        statusLabel.StyleSheet = "color: red; font-weight: bold;"
        return false
    end
end

function win.On.TestImageProvider.Clicked(ev)
    local pid = getImageProviderId(itm.ImageProviderCombo.CurrentIndex)
    local key = (itm.ImageApiKey.Text or ""):match("^%s*(.-)%s*$")
    local url = itm.ImageServerUrl.Text or ""
    -- For cloud providers, require API key
    if (pid == "freepik" or pid == "grok") and key == "" then
        itm.ImageProviderStatus.Text = "No key"
        itm.ImageProviderStatus.StyleSheet = "color: orange;"
        return
    end
    if testProvider(pid, key, url, itm.ImageProviderStatus) then
        if pid == "freepik" then
            config.providers.freepik.apiKey = key
        elseif pid == "grok" then
            config.providers.grok.apiKey = key
        end
        config.providers.comfyui.serverUrl = url
        config.imageProvider = pid
        saveConfig()
    end
end

function win.On.TestVideoProvider.Clicked(ev)
    local pid = getVideoProviderId(itm.VideoProviderCombo.CurrentIndex)
    local key = (itm.VideoApiKey.Text or ""):match("^%s*(.-)%s*$")
    local url = itm.VideoServerUrl.Text or ""
    if (pid == "freepik" or pid == "grok") and key == "" then
        itm.VideoProviderStatus.Text = "No key"
        itm.VideoProviderStatus.StyleSheet = "color: orange;"
        return
    end
    if testProvider(pid, key, url, itm.VideoProviderStatus) then
        if pid == "freepik" then
            config.providers.freepik.apiKey = key
        elseif pid == "grok" then
            config.providers.grok.apiKey = key
        end
        config.providers.comfyui.serverUrl = url
        config.videoProvider = pid
        saveConfig()
    end
end

function win.On.TestVoiceProvider.Clicked(ev)
    local pid = getVoiceProviderId(itm.VoiceProviderCombo.CurrentIndex)
    local key = (itm.VoiceApiKey.Text or ""):match("^%s*(.-)%s*$")
    local url = itm.VoiceServerUrl.Text or ""
    -- For cloud providers, require API key
    if pid == "elevenlabs" and key == "" then
        itm.VoiceProviderStatus.Text = "No key"
        itm.VoiceProviderStatus.StyleSheet = "color: orange;"
        return
    end
    if testProvider(pid, key, url, itm.VoiceProviderStatus) then
        if pid == "elevenlabs" then
            config.providers.elevenlabs.apiKey = key
        end
        config.providers.voicebox.serverUrl = url
        config.voiceProvider = pid
        saveConfig()
    end
end

function win.On.TestLipSyncProvider.Clicked(ev)
    local pid = getLipSyncProviderId(itm.LipSyncProviderCombo.CurrentIndex)
    local key = (itm.LipSyncApiKey.Text or ""):match("^%s*(.-)%s*$")
    if key == "" then
        itm.LipSyncProviderStatus.Text = "No key"
        itm.LipSyncProviderStatus.StyleSheet = "color: orange;"
        return
    end
    if testProvider(pid, key, "", itm.LipSyncProviderStatus) then
        if pid == "kling" then
            config.providers.kling.apiKey = key
        else
            config.providers.freepik.apiKey = key
        end
        config.lipsyncProvider = pid
        saveConfig()
    end
end

-- ============================================================
-- STEP 2: Script Import & Parsing
-- ============================================================

function win.On.BrowseScript.Clicked(ev)
    local path = fu:RequestFile("Select Screenplay")
    if path and path ~= "" then
        itm.ScriptPath.Text = path
    end
end

function win.On.ParseScript.Clicked(ev)
    local path = itm.ScriptPath.Text
    if path == "" then
        itm.ParseStatus.Text = "Please select a file first."
        itm.ParseStatus.StyleSheet = "color: orange;"
        return
    end

    itm.ParseStatus.Text = "Parsing screenplay..."
    itm.ParseStatus.StyleSheet = "color: #888;"

    -- Escape backslashes and quotes in path for Python string literal
    local safePath = path:gsub("\\", "\\\\"):gsub('"', '\\"')

    local code = 'import json, traceback\n'
        .. 'try:\n'
        .. '    script_path = "' .. safePath .. '"\n'
        .. '    if script_path.lower().endswith(".pdf"):\n'
        .. '        from script_to_screen.parsing.pdf_parser import parse_pdf\n'
        .. '        screenplay = parse_pdf(script_path)\n'
        .. '    elif script_path.lower().endswith(".fountain"):\n'
        .. '        from script_to_screen.parsing.fountain_parser import parse_fountain\n'
        .. '        screenplay = parse_fountain(script_path)\n'
        .. '    else:\n'
        .. '        print(json.dumps({"error": "Unsupported file format. Use .pdf or .fountain"}))\n'
        .. '        exit()\n'
        .. '    data = {\n'
        .. '        "title": screenplay.title,\n'
        .. '        "scene_count": screenplay.scene_count,\n'
        .. '        "total_shots": screenplay.total_shots,\n'
        .. '        "total_dialogue": screenplay.total_dialogue_lines,\n'
        .. '        "characters": {},\n'
        .. '        "scenes": []\n'
        .. '    }\n'
        .. '    for name, char in screenplay.characters.items():\n'
        .. '        data["characters"][name] = {"lines": char.dialogue_count}\n'
        .. '    for scene in screenplay.scenes:\n'
        .. '        shot_list = []\n'
        .. '        for si, shot in enumerate(scene.shots):\n'
        .. '            shot_list.append({\n'
        .. '                "index": si,\n'
        .. '                "shot_type": shot.shot_type,\n'
        .. '                "description": shot.description,\n'
        .. '                "characters": shot.characters_present,\n'
        .. '                "prompt_prefix": shot.prompt_prefix,\n'
        .. '            })\n'
        .. '        dialogue_list = []\n'
        .. '        for dl in scene.dialogue:\n'
        .. '            dialogue_list.append({"character": dl.character, "text": dl.text, "parenthetical": dl.parenthetical or ""})\n'
        .. '        s = {\n'
        .. '            "index": scene.index,\n'
        .. '            "heading": scene.heading,\n'
        .. '            "action": scene.action_description,\n'
        .. '            "shot_count": len(scene.shots),\n'
        .. '            "shots": shot_list,\n'
        .. '            "dialogue": len(scene.dialogue),\n'
        .. '            "dialogue_lines": dialogue_list,\n'
        .. '            "characters": scene.characters_in_scene,\n'
        .. '        }\n'
        .. '        data["scenes"].append(s)\n'
        .. '    # Save raw pages and full screenplay data to JSON for ScriptRef\n'
        .. '    import os\n'
        .. '    output_dir = "' .. outputDir:gsub("\\", "\\\\"):gsub('"', '\\"') .. '"\n'
        .. '    os.makedirs(output_dir, exist_ok=True)\n'
        .. '    pages_path = os.path.join(output_dir, "screenplay_pages.json")\n'
        .. '    pages_data = {"pages": screenplay.raw_pages, "title": screenplay.title, "scenes": data["scenes"]}\n'
        .. '    with open(pages_path, "w") as pf:\n'
        .. '        pf.write(json.dumps(pages_data, indent=2))\n'
        .. '    print(json.dumps(data))\n'
        .. 'except Exception as e:\n'
        .. '    print(json.dumps({"error": str(e), "trace": traceback.format_exc()}))\n'

    local result = runPython(code)

    if result and result ~= "" then
        -- Find the JSON line (skip any warnings/import messages)
        local jsonStr = result:match("(%{.+%})")
        if jsonStr then
            local data = JSON.decode(jsonStr)
            if data and data.error then
                itm.ParseStatus.Text = "Error: " .. data.error
                itm.ParseStatus.StyleSheet = "color: red;"
                itm.ScriptSummary.PlainText = data.trace or data.error
            elseif data then
                screenplayData = data
                itm.ParseStatus.Text = "Parsed successfully!"
                itm.ParseStatus.StyleSheet = "color: green; font-weight: bold;"

                -- Build summary text
                local summary = "Title: " .. (data.title or "Unknown") .. "\n"
                    .. "Scenes: " .. tostring(data.scene_count or 0) .. "\n"
                    .. "Total Shots: " .. tostring(data.total_shots or 0) .. "\n"
                    .. "Total Dialogue Lines: " .. tostring(data.total_dialogue or 0) .. "\n"
                    .. "\nCharacters:\n"
                if data.characters then
                    for name, info in pairs(data.characters) do
                        summary = summary .. "  - " .. name .. " (" .. tostring(info.lines) .. " lines)\n"
                    end
                end
                summary = summary .. "\nScenes:\n"
                if data.scenes then
                    for _, scene in ipairs(data.scenes) do
                        summary = summary .. "  " .. tostring(scene.index) .. ". " .. (scene.heading or "") .. "\n"
                            .. "     Shots: " .. tostring(scene.shot_count or #(scene.shots or {})) .. " | Dialogue: " .. tostring(scene.dialogue) .. "\n"
                    end
                end
                itm.ScriptSummary.PlainText = summary

                -- Populate character tree for Step 3
                populateCharacterTree(data)
            else
                itm.ParseStatus.Text = "Could not parse result"
                itm.ParseStatus.StyleSheet = "color: red;"
                itm.ScriptSummary.PlainText = result
            end
        else
            itm.ParseStatus.Text = "Parse failed"
            itm.ParseStatus.StyleSheet = "color: red;"
            itm.ScriptSummary.PlainText = result
        end
    else
        itm.ParseStatus.Text = "Parse failed - no output"
        itm.ParseStatus.StyleSheet = "color: red;"
    end
end

-- ============================================================
-- STEP 3: Character Setup
-- ============================================================

function populateCharacterTree(data)
    if not data or not data.characters then return end

    local hdr = itm.CharTree:NewItem()
    hdr.Text[0] = "Character"
    hdr.Text[1] = "Lines"
    hdr.Text[2] = "Reference Image"
    itm.CharTree:SetHeaderItem(hdr)
    itm.CharTree.ColumnCount = 3
    itm.CharTree.ColumnWidth[0] = 150
    itm.CharTree.ColumnWidth[1] = 60
    itm.CharTree.ColumnWidth[2] = 300

    itm.CharTree:Clear()
    for name, info in pairs(data.characters) do
        local item = itm.CharTree:NewItem()
        item.Text[0] = name
        item.Text[1] = tostring(info.lines)
        item.Text[2] = characterImages[name] or "(none)"
        itm.CharTree:AddTopLevelItem(item)
    end
end

function win.On.BrowseCharImg.Clicked(ev)
    local selected = itm.CharTree:CurrentItem()
    if not selected then return end
    local charName = selected.Text[0]
    local path = fu:RequestFile("Select Reference Image for " .. charName)
    if path and path ~= "" then
        characterImages[charName] = path
        selected.Text[2] = path
    end
end

function win.On.ClearCharImg.Clicked(ev)
    local selected = itm.CharTree:CurrentItem()
    if not selected then return end
    local charName = selected.Text[0]
    characterImages[charName] = nil
    selected.Text[2] = "(none)"
end

-- ============================================================
-- STEP 4: Style Reference
-- ============================================================

function win.On.BrowseStyle.Clicked(ev)
    local path = fu:RequestFile("Select Style Reference Image")
    if path and path ~= "" then
        itm.StylePath.Text = path
    end
end

function win.On.ClearStyle.Clicked(ev)
    itm.StylePath.Text = ""
end

function win.On.DetailSlider.ValueChanged(ev)
    itm.DetailValue.Text = tostring(itm.DetailSlider.Value)
end

-- ============================================================
-- STEP 5: Image Generation
-- ============================================================

function win.On.GenAllImages.Clicked(ev)
    local imgPid = config.imageProvider
    -- Check provider is configured
    if imgPid == "freepik" and (config.providers.freepik.apiKey or "") == "" then
        itm.ImageProgress.Text = "Set Freepik API key first (Step 1)!"
        itm.ImageProgress.StyleSheet = "color: red;"
        return
    end
    if imgPid == "grok" and (config.providers.grok.apiKey or "") == "" then
        itm.ImageProgress.Text = "Set xAI API key first (Step 1)!"
        itm.ImageProgress.StyleSheet = "color: red;"
        return
    end
    if not screenplayData then
        itm.ImageProgress.Text = "Parse a screenplay first (Step 2)!"
        itm.ImageProgress.StyleSheet = "color: red;"
        return
    end

    itm.ImageProgress.Text = "Generating images... (this may take several minutes)"
    itm.ImageProgress.StyleSheet = "color: #888;"

    local safePath = itm.ScriptPath.Text:gsub("\\", "\\\\"):gsub('"', '\\"')
    local safeStyle = itm.StylePath.Text:gsub("\\", "\\\\"):gsub('"', '\\"')
    local safeOutput = outputDir:gsub("\\", "\\\\"):gsub('"', '\\"')
    local model = itm.ModelCombo.CurrentText or "realism"
    local aspect = itm.AspectCombo.CurrentText or "widescreen_16_9"
    local detail = itm.DetailSlider.Value or 33

    -- Resolve the API key for the selected image provider
    local imgApiKey = ""
    if imgPid == "freepik" then
        imgApiKey = config.providers.freepik.apiKey or ""
    elseif imgPid == "grok" then
        imgApiKey = config.providers.grok.apiKey or ""
    end

    -- Write API key to temp file
    local keyfile = os.tmpname()
    local kf = io.open(keyfile, "w")
    if kf then kf:write(imgApiKey); kf:close() end

    local safeServerUrl = (config.providers.comfyui.serverUrl or ""):gsub("\\", "\\\\"):gsub('"', '\\"')

    -- Build character images JSON
    local charImgParts = {}
    for name, imgPath in pairs(characterImages) do
        local safeName = name:gsub('"', '\\"')
        local safeImg = imgPath:gsub("\\", "\\\\"):gsub('"', '\\"')
        table.insert(charImgParts, '"' .. safeName .. '":"' .. safeImg .. '"')
    end
    local charImgJson = "{" .. table.concat(charImgParts, ",") .. "}"

    -- Derive project slug for manifest recording
    local projectSlugCode = 'import re\n'
        .. 'try:\n'
        .. '    import DaVinciResolveScript as dvr\n'
        .. '    _resolve = dvr.scriptapp("Resolve")\n'
        .. '    _pname = _resolve.GetProjectManager().GetCurrentProject().GetName()\n'
        .. '    project_slug = re.sub(r"[^\\w\\-]", "_", _pname).strip("_").lower() or "default"\n'
        .. 'except: project_slug = "default"\n'

    local code = 'import json, traceback, os\n'
        .. projectSlugCode
        .. 'try:\n'
        .. '    from script_to_screen.parsing.pdf_parser import parse_pdf\n'
        .. '    from script_to_screen.parsing.fountain_parser import parse_fountain\n'
        .. '    from script_to_screen.api.registry import create_image_provider\n'
        .. '    from script_to_screen.pipeline.image_gen import generate_images_for_screenplay\n'
        .. '    from script_to_screen.config import GenerationDefaults\n'
        .. '    from script_to_screen.manifest import update_character\n'
        .. '    script_path = "' .. safePath .. '"\n'
        .. '    if script_path.lower().endswith(".pdf"):\n'
        .. '        screenplay = parse_pdf(script_path)\n'
        .. '    else:\n'
        .. '        screenplay = parse_fountain(script_path)\n'
        .. '    char_images = json.loads(\'' .. charImgJson:gsub("'", "\\'") .. '\')\n'
        .. '    for name, path in char_images.items():\n'
        .. '        if name in screenplay.characters:\n'
        .. '            screenplay.characters[name].reference_image_path = path\n'
        .. '            update_character(project_slug, name, reference_image_path=path)\n'
        .. '    api_key = open("' .. keyfile .. '").read().strip()\n'
        .. '    provider = create_image_provider(\n'
        .. '        "' .. imgPid .. '",\n'
        .. '        api_key=api_key,\n'
        .. '        server_url="' .. safeServerUrl .. '",\n'
        .. '        model="' .. model .. '",\n'
        .. '    )\n'
        .. '    defaults = GenerationDefaults(\n'
        .. '        freepik_model="' .. model .. '",\n'
        .. '        aspect_ratio="' .. aspect .. '",\n'
        .. '        creative_detailing=' .. tostring(detail) .. '\n'
        .. '    )\n'
        .. '    style_path = "' .. safeStyle .. '" if "' .. safeStyle .. '" else None\n'
        .. '    results = generate_images_for_screenplay(\n'
        .. '        screenplay, provider, "' .. safeOutput .. '",\n'
        .. '        style_reference_path=style_path,\n'
        .. '        defaults=defaults,\n'
        .. '        project_slug=project_slug,\n'
        .. '    )\n'
        .. '    errs = results.pop("_errors", [])\n'
        .. '    total = screenplay.total_shots\n'
        .. '    print(json.dumps({"status": "ok", "count": len(results), "paths": results, "errors": errs, "total_shots": total}))\n'
        .. 'except Exception as e:\n'
        .. '    print(json.dumps({"status": "error", "error": str(e), "trace": traceback.format_exc()}))\n'

    local result = runPython(code)
    os.remove(keyfile)

    local jsonStr = result and result:match("(%{.+%})")
    if jsonStr then
        local data = JSON.decode(jsonStr)
        if data and data.status == "ok" then
            generatedImages = data.paths or {}
            local count = data.count or 0
            local totalShots = data.total_shots or 0
            local errs = data.errors or {}
            if count > 0 then
                -- Import generated images to Resolve media pool (episode/scene bins)
                local importMsg = ""
                local importOk, importErr = pcall(function()
                    local project = resolve:GetProjectManager():GetCurrentProject()
                    if project then
                        local mp = project:GetMediaPool()
                        local rootF = mp:GetRootFolder()
                        -- Find or create ScriptToScreen bin
                        local stsBin2 = nil
                        for _, folder in pairs(rootF:GetSubFolders() or {}) do
                            if folder:GetName() == "ScriptToScreen" then stsBin2 = folder; break end
                        end
                        if not stsBin2 then stsBin2 = mp:AddSubFolder(rootF, "ScriptToScreen") end
                        -- Helper to find or create a sub-bin
                        local function findOrCreate(parent, name)
                            if not parent then return nil end
                            for _, f in pairs(parent:GetSubFolders() or {}) do
                                if f:GetName() == name then return f end
                            end
                            return mp:AddSubFolder(parent, name)
                        end
                        -- Import one-at-a-time, routing to episode/scene bins
                        local epPfx = buildEpisodePrefix()
                        local importCount = 0
                        for shotKey, imgPath in pairs(generatedImages) do
                            if type(imgPath) == "string" then
                                -- Build bin path: ScriptToScreen/{epPrefix}/S{N}/Images
                                local targetBin = stsBin2
                                if epPfx ~= "" then
                                    targetBin = findOrCreate(targetBin, epPfx)
                                end
                                local sNum = tonumber((shotKey or ""):match("^s(%d+)")) or 0
                                targetBin = findOrCreate(targetBin, "S" .. tostring(sNum))
                                targetBin = findOrCreate(targetBin, "Images")
                                if targetBin then mp:SetCurrentFolder(targetBin) end
                                local items = mp:ImportMedia({imgPath}) or {}
                                for _, item in ipairs(items) do
                                    local basename = imgPath:match("([^/]+)$") or ""
                                    pcall(function() item:SetMetadata("Comments", "STS:" .. basename) end)
                                end
                                importCount = importCount + #items
                            end
                        end
                        importMsg = " (" .. tostring(importCount) .. " added to bin)"
                    end
                end)
                if not importOk then
                    print("[ScriptToScreen] Bin import warning: " .. tostring(importErr))
                end

                itm.ImageProgress.Text = "Generated " .. tostring(count) .. " of " .. tostring(totalShots) .. " images!" .. importMsg
                if #errs > 0 then
                    itm.ImageProgress.Text = itm.ImageProgress.Text .. " (" .. tostring(#errs) .. " failed)"
                    itm.ImageProgress.StyleSheet = "color: orange; font-weight: bold;"
                else
                    itm.ImageProgress.StyleSheet = "color: green; font-weight: bold;"
                end
            elseif totalShots > 0 then
                -- Had shots but all failed
                local firstErr = errs[1] or "Unknown error"
                itm.ImageProgress.Text = "All " .. tostring(totalShots) .. " images failed: " .. firstErr
                itm.ImageProgress.StyleSheet = "color: red;"
            else
                itm.ImageProgress.Text = "No shots found in screenplay"
                itm.ImageProgress.StyleSheet = "color: red;"
            end
        else
            itm.ImageProgress.Text = "Error: " .. (data and data.error or "Unknown")
            itm.ImageProgress.StyleSheet = "color: red;"
            -- Show traceback in console
            if data and data.trace then
                print("[ScriptToScreen] " .. data.trace)
            end
        end
    else
        itm.ImageProgress.Text = "Failed — raw output: " .. tostring(result or ""):sub(1, 100)
        itm.ImageProgress.StyleSheet = "color: red;"
    end
end

-- ImageTree selection → show the EXACT prompt that Python's build_image_prompt produces
-- Also checks the manifest for the previously-used prompt if the image was already generated
function win.On.ImageTree.ItemClicked(ev)
    local item = ev.item or itm.ImageTree:CurrentItem()
    if not item then return end

    local sceneIdx = tonumber(item.Text[0]) or 0
    local shotIdx = tonumber(item.Text[1]) or 1
    local shotKey = "s" .. tostring(sceneIdx) .. "_sh" .. tostring(shotIdx - 1)

    -- First check manifest for the stored prompt from last generation
    local manifestPrompt = nil
    if projectSlug and projectSlug ~= "" then
        local mResult = runPython(
            'from script_to_screen.manifest import lookup_by_shot_key\n'
            .. 'entry = lookup_by_shot_key("' .. projectSlug .. '", "' .. shotKey .. '", "image")\n'
            .. 'if entry and entry.get("prompt"):\n'
            .. '    print(json.dumps({"found": True, "prompt": entry["prompt"]}))\n'
            .. 'else:\n'
            .. '    print(json.dumps({"found": False}))\n'
        )
        local jStr = mResult and mResult:match("(%{.+%})")
        if jStr then
            local mData = JSON.decode(jStr)
            if mData and mData.found then
                manifestPrompt = mData.prompt
            end
        end
    end

    -- Build the live prompt from Python (uses the exact same build_image_prompt function)
    local safePath = itm.ScriptPath.Text:gsub("\\", "\\\\"):gsub('"', '\\"')
    if safePath ~= "" then
        local result = runPython(
            'from script_to_screen.parsing.pdf_parser import parse_pdf\n'
            .. 'from script_to_screen.parsing.fountain_parser import parse_fountain\n'
            .. 'from script_to_screen.pipeline.image_gen import build_image_prompt\n'
            .. 'path = "' .. safePath .. '"\n'
            .. 'sp = parse_pdf(path) if path.lower().endswith(".pdf") else parse_fountain(path)\n'
            .. 'si = ' .. tostring(sceneIdx) .. '\n'
            .. 'shi = ' .. tostring(shotIdx - 1) .. '\n'
            .. 'for scene in sp.scenes:\n'
            .. '    if scene.index == si:\n'
            .. '        if shi < len(scene.shots):\n'
            .. '            prompt = build_image_prompt(scene.shots[shi], scene, sp, shot_idx=shi)\n'
            .. '            print(json.dumps({"prompt": prompt}))\n'
            .. '            break\n'
        )
        local jStr = result and result:match("(%{.+%})")
        if jStr then
            local data = JSON.decode(jStr)
            if data and data.prompt then
                local display = data.prompt
                if manifestPrompt then
                    display = "[Last used prompt]:\n" .. manifestPrompt .. "\n\n[Current prompt]:\n" .. data.prompt
                end
                itm.ImagePrompt.PlainText = display
                return
            end
        end
    end

    -- Fallback: show manifest prompt only
    if manifestPrompt then
        itm.ImagePrompt.PlainText = "[Last used prompt]:\n" .. manifestPrompt
    else
        itm.ImagePrompt.PlainText = "(select a shot to preview prompt)"
    end
end

-- ============================================================
-- STEP 6: Video Generation
-- ============================================================

function win.On.GenAllVideos.Clicked(ev)
    local vidPid = config.videoProvider
    if vidPid == "freepik" and (config.providers.freepik.apiKey or "") == "" then
        itm.VideoProgress.Text = "Set Freepik API key first (Step 1)!"
        itm.VideoProgress.StyleSheet = "color: red;"
        return
    end
    if vidPid == "grok" and (config.providers.grok.apiKey or "") == "" then
        itm.VideoProgress.Text = "Set xAI API key first (Step 1)!"
        itm.VideoProgress.StyleSheet = "color: red;"
        return
    end

    itm.VideoProgress.Text = "Generating videos... (this will take a while)"
    itm.VideoProgress.StyleSheet = "color: #888;"

    local safePath = itm.ScriptPath.Text:gsub("\\", "\\\\"):gsub('"', '\\"')
    local safeOutput = outputDir:gsub("\\", "\\\\"):gsub('"', '\\"')
    local duration = itm.DurationSpin.Value or 5

    -- Resolve the API key for the selected video provider
    local vidApiKey = ""
    if vidPid == "freepik" then
        vidApiKey = config.providers.freepik.apiKey or ""
    elseif vidPid == "grok" then
        vidApiKey = config.providers.grok.apiKey or ""
    end

    -- Write API key to temp file
    local keyfile = os.tmpname()
    local kf = io.open(keyfile, "w")
    if kf then kf:write(vidApiKey); kf:close() end

    local safeServerUrl = (config.providers.comfyui.serverUrl or ""):gsub("\\", "\\\\"):gsub('"', '\\"')

    local code = 'import json, traceback, time, os, glob, re\n'
        .. 'try:\n'
        .. '    from script_to_screen.parsing.pdf_parser import parse_pdf\n'
        .. '    from script_to_screen.parsing.fountain_parser import parse_fountain\n'
        .. '    from script_to_screen.api.registry import create_video_provider\n'
        .. '    from script_to_screen.pipeline.video_gen import generate_videos_for_screenplay\n'
        .. '    script_path = "' .. safePath .. '"\n'
        .. '    if script_path.lower().endswith(".pdf"):\n'
        .. '        screenplay = parse_pdf(script_path)\n'
        .. '    else:\n'
        .. '        screenplay = parse_fountain(script_path)\n'
        .. '    api_key = open("' .. keyfile .. '").read().strip()\n'
        .. '    provider = create_video_provider(\n'
        .. '        "' .. vidPid .. '",\n'
        .. '        api_key=api_key,\n'
        .. '        server_url="' .. safeServerUrl .. '",\n'
        .. '    )\n'
        .. '    # Build image_paths from generated images dir\n'
        .. '    image_dir = "' .. safeOutput .. '/images"\n'
        .. '    image_paths = {}\n'
        .. '    for f in sorted(glob.glob(os.path.join(image_dir, "*.png")) + glob.glob(os.path.join(image_dir, "*.jpg"))):\n'
        .. '        basename = os.path.splitext(os.path.basename(f))[0]\n'
        .. '        m = re.match(r"(s\\d+_sh\\d+)", basename)\n'
        .. '        if m:\n'
        .. '            key = m.group(1)\n'
        .. '            image_paths[key] = f  # latest file per shot wins\n'
        .. '    results = generate_videos_for_screenplay(\n'
        .. '        screenplay, provider, image_paths,\n'
        .. '        "' .. safeOutput .. '",\n'
        .. '        project_slug="' .. projectSlug .. '",\n'
        .. '    )\n'
        .. '    errs = results.pop("_errors", [])\n'
        .. '    print(json.dumps({"status": "ok", "count": len(results), "paths": results, "errors": errs, "image_count": len(image_paths)}))\n'
        .. 'except Exception as e:\n'
        .. '    print(json.dumps({"status": "error", "error": str(e), "trace": traceback.format_exc()}))\n'

    local result = runPython(code)
    os.remove(keyfile)

    local jsonStr = result and result:match("(%{.+%})")
    if jsonStr then
        local data = JSON.decode(jsonStr)
        if data and data.status == "ok" then
            generatedVideos = data.paths or {}
            local count = data.count or 0
            local errs = data.errors or {}
            local imgCount = data.image_count or 0
            if count > 0 then
                -- Import generated videos to episode/scene bins
                local importMsg = ""
                local importOk, importErr = pcall(function()
                    local project = resolve:GetProjectManager():GetCurrentProject()
                    if project then
                        local mp = project:GetMediaPool()
                        local rootF = mp:GetRootFolder()
                        local stsBin2 = nil
                        for _, folder in pairs(rootF:GetSubFolders() or {}) do
                            if folder:GetName() == "ScriptToScreen" then stsBin2 = folder; break end
                        end
                        if not stsBin2 then stsBin2 = mp:AddSubFolder(rootF, "ScriptToScreen") end
                        local function findOrCreate(parent, name)
                            if not parent then return nil end
                            for _, f in pairs(parent:GetSubFolders() or {}) do
                                if f:GetName() == name then return f end
                            end
                            return mp:AddSubFolder(parent, name)
                        end
                        local epPfx = buildEpisodePrefix()
                        local importCount = 0
                        for shotKey, vidPath in pairs(generatedVideos) do
                            if type(vidPath) == "string" then
                                local targetBin = stsBin2
                                if epPfx ~= "" then
                                    targetBin = findOrCreate(targetBin, epPfx)
                                end
                                local sNum = tonumber((shotKey or ""):match("^s(%d+)")) or 0
                                targetBin = findOrCreate(targetBin, "S" .. tostring(sNum))
                                targetBin = findOrCreate(targetBin, "Videos")
                                if targetBin then mp:SetCurrentFolder(targetBin) end
                                local items = mp:ImportMedia({vidPath}) or {}
                                for _, item in ipairs(items) do
                                    local basename = vidPath:match("([^/]+)$") or ""
                                    pcall(function() item:SetMetadata("Comments", "STS:" .. basename) end)
                                end
                                importCount = importCount + #items
                            end
                        end
                        importMsg = " (" .. tostring(importCount) .. " added to bin)"
                    end
                end)
                if not importOk then
                    print("[ScriptToScreen] Video import warning: " .. tostring(importErr))
                end

                itm.VideoProgress.Text = "Generated " .. tostring(count) .. " videos!" .. importMsg
                if #errs > 0 then
                    itm.VideoProgress.Text = itm.VideoProgress.Text .. " (" .. tostring(#errs) .. " failed)"
                    itm.VideoProgress.StyleSheet = "color: orange; font-weight: bold;"
                else
                    itm.VideoProgress.StyleSheet = "color: green; font-weight: bold;"
                end
            elseif #errs > 0 then
                itm.VideoProgress.Text = "All " .. tostring(#errs) .. " videos failed: " .. errs[1]
                itm.VideoProgress.StyleSheet = "color: red;"
            else
                itm.VideoProgress.Text = "No videos generated (found " .. tostring(imgCount) .. " images)"
                itm.VideoProgress.StyleSheet = "color: red;"
            end
        else
            itm.VideoProgress.Text = "Error: " .. (data and data.error or "Unknown")
            itm.VideoProgress.StyleSheet = "color: red;"
            if data and data.trace then
                print("[ScriptToScreen] " .. data.trace)
            end
        end
    else
        itm.VideoProgress.Text = "Failed — raw: " .. tostring(result or ""):sub(1, 200)
        itm.VideoProgress.StyleSheet = "color: red;"
    end
end

-- ============================================================
-- STEP 7: Voice Cloning
-- ============================================================

function win.On.BrowseVoice.Clicked(ev)
    local selected = itm.VoiceTree:CurrentItem()
    if not selected then
        itm.VoiceProgress.Text = "Select a character first"
        return
    end
    local path = fu:RequestFile("Select Voice Sample Audio")
    if path and path ~= "" then
        selected.Text[2] = path
    end
end

function win.On.CloneVoice.Clicked(ev)
    local voicePid = config.voiceProvider
    if voicePid == "elevenlabs" and (config.providers.elevenlabs.apiKey or "") == "" then
        itm.VoiceProgress.Text = "Set voice provider API key first (Step 1)!"
        itm.VoiceProgress.StyleSheet = "color: red;"
        return
    end
    local selected = itm.VoiceTree:CurrentItem()
    if not selected then
        itm.VoiceProgress.Text = "Select a character first"
        return
    end
    local charName = selected.Text[0]
    local samplePath = selected.Text[2]
    if not samplePath or samplePath == "" or samplePath == "(none)" then
        itm.VoiceProgress.Text = "Add a voice sample first"
        return
    end

    -- Validate the voice sample is an actual audio file (not a directory)
    local sampleAttr = bmd.fileexists(samplePath)
    if not sampleAttr then
        itm.VoiceProgress.Text = "Voice sample file not found: " .. samplePath:match("[^/]+$")
        itm.VoiceProgress.StyleSheet = "color: red;"
        return
    end
    -- Check extension is an audio format
    local ext = samplePath:lower():match("%.([^%.]+)$") or ""
    local audioExts = {wav=1, mp3=1, m4a=1, aac=1, ogg=1, flac=1, webm=1, opus=1}
    if not audioExts[ext] then
        itm.VoiceProgress.Text = "Not an audio file (." .. ext .. "). Use .wav, .mp3, .m4a, etc."
        itm.VoiceProgress.StyleSheet = "color: red;"
        return
    end

    itm.VoiceProgress.Text = "Cloning voice for " .. charName .. "..."
    itm.VoiceProgress.StyleSheet = "color: #888;"

    local safeSample = samplePath:gsub("\\", "\\\\"):gsub('"', '\\"')
    local safeName = charName:gsub('"', '\\"')

    -- Write API key to temp file
    local keyfile = os.tmpname()
    local kf = io.open(keyfile, "w")
    local voiceKey = voicePid == "elevenlabs" and (config.providers.elevenlabs.apiKey or "") or ""
    if kf then kf:write(voiceKey); kf:close() end

    local voiceServerUrl = (config.providers.voicebox.serverUrl or "http://127.0.0.1:17493"):gsub("\\", "\\\\"):gsub('"', '\\"')

    local code = 'import json, traceback\n'
        .. 'try:\n'
        .. '    from script_to_screen.api.registry import create_voice_provider\n'
        .. '    api_key = open("' .. keyfile .. '").read().strip()\n'
        .. '    provider = create_voice_provider("' .. voicePid .. '", api_key=api_key, server_url="' .. voiceServerUrl .. '")\n'
        .. '    voice_id = provider.clone_voice("' .. safeName .. '", ["' .. safeSample .. '"])\n'
        .. '    print(json.dumps({"status": "ok", "voice_id": voice_id}))\n'
        .. 'except Exception as e:\n'
        .. '    print(json.dumps({"status": "error", "error": str(e)}))\n'

    local result = runPython(code)
    os.remove(keyfile)

    local jsonStr = result and result:match("(%{.+%})")
    if jsonStr then
        local data = JSON.decode(jsonStr)
        if data and data.status == "ok" then
            characterVoices[charName] = data.voice_id
            selected.Text[3] = data.voice_id
            itm.VoiceProgress.Text = "Voice cloned for " .. charName .. "!"
            itm.VoiceProgress.StyleSheet = "color: green; font-weight: bold;"
        else
            itm.VoiceProgress.Text = "Error: " .. (data and data.error or "Unknown")
            itm.VoiceProgress.StyleSheet = "color: red;"
        end
    else
        itm.VoiceProgress.Text = "Clone failed"
        itm.VoiceProgress.StyleSheet = "color: red;"
    end
end

-- ============================================================
-- STEP 8: Dialogue Generation
-- ============================================================

function win.On.GenAllDialogue.Clicked(ev)
    local voicePid = config.voiceProvider
    if voicePid == "elevenlabs" and (config.providers.elevenlabs.apiKey or "") == "" then
        itm.DialogueProgress.Text = "Set voice provider API key first (Step 1)!"
        itm.DialogueProgress.StyleSheet = "color: red;"
        return
    end
    if not screenplayData then
        itm.DialogueProgress.Text = "Parse a screenplay first!"
        itm.DialogueProgress.StyleSheet = "color: red;"
        return
    end

    itm.DialogueProgress.Text = "Generating dialogue audio..."
    itm.DialogueProgress.StyleSheet = "color: #888;"

    local safePath = itm.ScriptPath.Text:gsub("\\", "\\\\"):gsub('"', '\\"')
    local safeOutput = outputDir:gsub("\\", "\\\\"):gsub('"', '\\"')

    -- Build voice IDs JSON
    local voiceParts = {}
    for name, vid in pairs(characterVoices) do
        table.insert(voiceParts, '"' .. name:gsub('"', '\\"') .. '":"' .. vid .. '"')
    end
    local voiceJson = "{" .. table.concat(voiceParts, ",") .. "}"

    -- Write API key to temp file
    local keyfile = os.tmpname()
    local kf = io.open(keyfile, "w")
    local voiceKey = voicePid == "elevenlabs" and (config.providers.elevenlabs.apiKey or "") or ""
    if kf then kf:write(voiceKey); kf:close() end

    local voiceServerUrl = (config.providers.voicebox.serverUrl or "http://127.0.0.1:17493"):gsub("\\", "\\\\"):gsub('"', '\\"')

    local code = 'import json, traceback\n'
        .. 'try:\n'
        .. '    from script_to_screen.parsing.pdf_parser import parse_pdf\n'
        .. '    from script_to_screen.parsing.fountain_parser import parse_fountain\n'
        .. '    from script_to_screen.api.registry import create_voice_provider\n'
        .. '    from script_to_screen.pipeline.voice_gen import generate_dialogue_audio\n'
        .. '    script_path = "' .. safePath .. '"\n'
        .. '    if script_path.lower().endswith(".pdf"):\n'
        .. '        screenplay = parse_pdf(script_path)\n'
        .. '    else:\n'
        .. '        screenplay = parse_fountain(script_path)\n'
        .. '    voice_ids = json.loads(\'' .. voiceJson:gsub("'", "\\'") .. '\')\n'
        .. '    for name, vid in voice_ids.items():\n'
        .. '        if name in screenplay.characters:\n'
        .. '            screenplay.characters[name].voice_id = vid\n'
        .. '    api_key = open("' .. keyfile .. '").read().strip()\n'
        .. '    provider = create_voice_provider("' .. voicePid .. '", api_key=api_key, server_url="' .. voiceServerUrl .. '")\n'
        .. '    results = generate_dialogue_audio(screenplay, provider, "' .. safeOutput .. '/audio")\n'
        .. '    print(json.dumps({"status": "ok", "count": len(results), "paths": results}))\n'
        .. 'except Exception as e:\n'
        .. '    print(json.dumps({"status": "error", "error": str(e), "trace": traceback.format_exc()}))\n'

    local result = runPython(code)
    os.remove(keyfile)

    local jsonStr = result and result:match("(%{.+%})")
    if jsonStr then
        local data = JSON.decode(jsonStr)
        if data and data.status == "ok" then
            generatedAudio = data.paths or {}
            itm.DialogueProgress.Text = "Generated " .. tostring(data.count) .. " dialogue clips!"
            itm.DialogueProgress.StyleSheet = "color: green; font-weight: bold;"
        else
            itm.DialogueProgress.Text = "Error: " .. (data and data.error or "Unknown")
            itm.DialogueProgress.StyleSheet = "color: red;"
        end
    else
        itm.DialogueProgress.Text = "Failed. Check console."
        itm.DialogueProgress.StyleSheet = "color: red;"
    end
end

-- ============================================================
-- STEP 9: Lip Sync
-- ============================================================

function win.On.SyncAll.Clicked(ev)
    -- Lip-sync requires API credentials
    local lsPid = config.lipsyncProvider or "kling"
    local lsKey = ""
    if lsPid == "kling" then
        lsKey = config.providers.kling and config.providers.kling.apiKey or ""
    else
        lsKey = config.providers.freepik.apiKey or ""
    end
    if lsKey == "" then
        itm.LipSyncProgress.Text = "Set Lip Sync API key first (Step 1)!"
        itm.LipSyncProgress.StyleSheet = "color: red;"
        return
    end

    itm.LipSyncProgress.Text = "Running lip sync... (this takes a while)"
    itm.LipSyncProgress.StyleSheet = "color: #888;"

    local safeOutput = outputDir:gsub("\\", "\\\\"):gsub('"', '\\"')

    -- Write API key to temp file
    local keyfile = os.tmpname()
    local kf = io.open(keyfile, "w")
    if kf then kf:write(lsKey); kf:close() end

    local code = 'import json, traceback, os, glob, re\n'
        .. 'try:\n'
        .. '    from script_to_screen.api.registry import create_lipsync_provider\n'
        .. '    from script_to_screen.pipeline.lipsync import generate_lipsync_for_shots\n'
        .. '    from script_to_screen.parsing.screenplay_model import Screenplay\n'
        .. '    video_dir = "' .. safeOutput .. '/videos"\n'
        .. '    audio_dir = "' .. safeOutput .. '/audio"\n'
        .. '    api_key = open("' .. keyfile .. '").read().strip()\n'
        .. '    provider = create_lipsync_provider("' .. lsPid .. '", api_key=api_key)\n'
        .. '    def _shot_key(filepath):\n'
        .. '        bn = os.path.splitext(os.path.basename(filepath))[0]\n'
        .. '        m = re.match(r"(s\\d+_sh\\d+)", bn)\n'
        .. '        return m.group(1) if m else bn\n'
        .. '    videos = sorted(glob.glob(os.path.join(video_dir, "*.mp4")))\n'
        .. '    audios = sorted(glob.glob(os.path.join(audio_dir, "*.mp3")) + glob.glob(os.path.join(audio_dir, "*.wav")))\n'
        .. '    video_paths = {_shot_key(v): v for v in videos}\n'
        .. '    audio_paths = {_shot_key(a): a for a in audios}\n'
        .. '    screenplay = Screenplay(title="lipsync")\n'
        .. '    results = generate_lipsync_for_shots(\n'
        .. '        screenplay, provider, video_paths, audio_paths, "' .. safeOutput .. '"\n'
        .. '    )\n'
        .. '    print(json.dumps({"status": "ok", "count": len(results)}))\n'
        .. 'except Exception as e:\n'
        .. '    print(json.dumps({"status": "error", "error": str(e), "trace": traceback.format_exc()}))\n'

    local result = runPython(code)
    local jsonStr = result and result:match("(%{.+%})")
    if jsonStr then
        local data = JSON.decode(jsonStr)
        if data and data.status == "ok" then
            itm.LipSyncProgress.Text = "Lip-synced " .. tostring(data.count) .. " clips!"
            itm.LipSyncProgress.StyleSheet = "color: green; font-weight: bold;"
        else
            itm.LipSyncProgress.Text = "Error: " .. (data and data.error or "Unknown")
            itm.LipSyncProgress.StyleSheet = "color: red;"
        end
    else
        itm.LipSyncProgress.Text = "Failed. Check console."
        itm.LipSyncProgress.StyleSheet = "color: red;"
    end
end

-- ============================================================
-- STEP 10: Timeline Assembly (uses Resolve API directly via Lua)
-- ============================================================

function win.On.AssembleBtn.Clicked(ev)
    itm.AssemblyProgress.Text = "Assembling timeline..."
    itm.AssemblyProgress.StyleSheet = "color: #888;"

    local project = resolve:GetProjectManager():GetCurrentProject()
    if not project then
        itm.AssemblyProgress.Text = "No project open!"
        itm.AssemblyProgress.StyleSheet = "color: red;"
        return
    end

    local mediaPool = project:GetMediaPool()
    local timelineName = itm.TimelineName.Text
    if timelineName == "" then timelineName = "ScriptToScreen Assembly" end

    -- Create or find the ScriptToScreen bin
    local rootFolder = mediaPool:GetRootFolder()
    local stsBin = nil
    local subFolders = rootFolder:GetSubFolders()
    for _, folder in pairs(subFolders) do
        if folder:GetName() == "ScriptToScreen" then
            stsBin = folder
            break
        end
    end
    if not stsBin then
        stsBin = mediaPool:AddSubFolder(rootFolder, "ScriptToScreen")
    end
    if stsBin then
        mediaPool:SetCurrentFolder(stsBin)
    end

    -- Collect all media files
    local imageDir = outputDir .. "/images"
    local lipsyncDir = outputDir .. "/lipsync"
    local videoDir = outputDir .. "/videos"
    local audioDir = outputDir .. "/audio"

    local imageFiles = {}
    local videoFiles = {}
    local audioFiles = {}

    local function collectFiles(dir, ext, targetTable)
        local handle = io.popen('ls -1 "' .. dir .. '"/' .. ext .. ' 2>/dev/null | sort')
        if handle then
            for line in handle:lines() do
                if line ~= "" then
                    table.insert(targetTable, line)
                end
            end
            handle:close()
        end
    end

    -- Collect images (start frames)
    collectFiles(imageDir, "*.png", imageFiles)
    collectFiles(imageDir, "*.jpg", imageFiles)
    collectFiles(imageDir, "*.jpeg", imageFiles)

    -- Collect videos (prefer lipsync, fall back to videos)
    collectFiles(lipsyncDir, "*.mp4", videoFiles)
    if #videoFiles == 0 then
        collectFiles(videoDir, "*.mp4", videoFiles)
    end

    -- Collect audio (check both the dialogue_audio subdirectory and the main audio dir)
    local dialogueAudioDir = audioDir .. "/dialogue_audio"
    collectFiles(dialogueAudioDir, "*.wav", audioFiles)
    collectFiles(dialogueAudioDir, "*.mp3", audioFiles)
    collectFiles(audioDir, "*.wav", audioFiles)
    collectFiles(audioDir, "*.mp3", audioFiles)

    if #videoFiles == 0 and #imageFiles == 0 then
        itm.AssemblyProgress.Text = "No media files found to assemble."
        itm.AssemblyProgress.StyleSheet = "color: red;"
        return
    end

    -- Import images to "ScriptToScreen/Images" sub-bin
    -- NOTE: Import one-at-a-time to prevent Resolve from detecting them as
    -- an image sequence (s0_sh0.png, s0_sh1.png → "s0_sh[0-N].png").
    local importedImages = {}
    if #imageFiles > 0 then
        local imgBin = nil
        local stsSubFolders = stsBin and stsBin:GetSubFolders() or {}
        for _, folder in pairs(stsSubFolders) do
            if folder:GetName() == "Images" then
                imgBin = folder
                break
            end
        end
        if not imgBin and stsBin then
            imgBin = mediaPool:AddSubFolder(stsBin, "Images")
        end
        if imgBin then
            mediaPool:SetCurrentFolder(imgBin)
        end
        -- Import each image individually to avoid sequence detection
        for _, imgPath in ipairs(imageFiles) do
            local items = mediaPool:ImportMedia({imgPath}) or {}
            for _, item in ipairs(items) do
                table.insert(importedImages, item)
            end
        end
        -- Return to main STS bin
        if stsBin then
            mediaPool:SetCurrentFolder(stsBin)
        end
    end

    -- Import videos and audio to main ScriptToScreen bin
    local allClipFiles = {}
    for _, f in ipairs(videoFiles) do table.insert(allClipFiles, f) end
    for _, f in ipairs(audioFiles) do table.insert(allClipFiles, f) end

    local importedClips = {}
    if #allClipFiles > 0 then
        importedClips = mediaPool:ImportMedia(allClipFiles) or {}
    end

    local totalImported = #importedImages + #importedClips

    -- Create timeline — use a unique name if the default already exists
    local actualTimelineName = timelineName
    local timeline = mediaPool:CreateEmptyTimeline(actualTimelineName)
    if not timeline then
        -- Timeline name likely exists; append timestamp to make unique
        local ts = os.date("%Y%m%d_%H%M%S")
        actualTimelineName = timelineName .. " " .. ts
        timeline = mediaPool:CreateEmptyTimeline(actualTimelineName)
    end

    if not timeline then
        itm.AssemblyProgress.Text = "Could not create timeline. Try a different name."
        itm.AssemblyProgress.StyleSheet = "color: red;"
        return
    end

    project:SetCurrentTimeline(timeline)

    -- Append clips to timeline (wrapped in pcall for safety)
    local appendCount = 0
    local appendOk, appendErr = pcall(function()
        if #importedClips > 0 then
            -- Try appending all clips at once (more reliable)
            local result = mediaPool:AppendToTimeline(importedClips)
            if result and #result > 0 then
                appendCount = #result
            else
                -- Fallback: append one at a time
                for _, clip in ipairs(importedClips) do
                    if clip then
                        local ok = mediaPool:AppendToTimeline({clip})
                        if ok and #ok > 0 then appendCount = appendCount + 1 end
                    end
                end
            end
        end

        -- If nothing was appended (clips already in pool from prior import),
        -- re-import to a fresh sub-bin to get new media pool items
        if appendCount == 0 and #videoFiles > 0 then
            local freshBin = mediaPool:AddSubFolder(stsBin, "Assembly_" .. os.date("%H%M%S"))
            if freshBin then
                mediaPool:SetCurrentFolder(freshBin)
                local freshClips = mediaPool:ImportMedia(videoFiles) or {}
                if #freshClips > 0 then
                    local result = mediaPool:AppendToTimeline(freshClips)
                    if result and #result > 0 then
                        appendCount = #result
                    end
                end
            end
        end
    end)
    if not appendOk then
        itm.AssemblyProgress.Text = "Warning: " .. tostring(appendErr)
        itm.AssemblyProgress.StyleSheet = "color: orange;"
    end

    itm.AssemblyProgress.Text = "Timeline '" .. actualTimelineName .. "' created with " .. tostring(appendCount) .. " clips!"
    itm.AssemblyProgress.StyleSheet = "color: green; font-weight: bold;"

    -- Update summary
    local summary = "Timeline: " .. actualTimelineName .. "\n"
        .. "Image files in bin: " .. tostring(#imageFiles) .. "\n"
        .. "Video clips: " .. tostring(#videoFiles) .. "\n"
        .. "Audio clips: " .. tostring(#audioFiles) .. "\n"
        .. "Clips on timeline: " .. tostring(appendCount)
    itm.AssemblySummary.PlainText = summary
end

-- ============================================================
-- POPULATE TREES WHEN ENTERING STEPS
-- ============================================================

local function populateImageTree()
    if not screenplayData or not screenplayData.scenes then return end

    local hdr = itm.ImageTree:NewItem()
    hdr.Text[0] = "Scene"
    hdr.Text[1] = "Shot"
    hdr.Text[2] = "Type"
    hdr.Text[3] = "Description"
    hdr.Text[4] = "Status"
    itm.ImageTree:SetHeaderItem(hdr)
    itm.ImageTree.ColumnCount = 5
    itm.ImageTree.ColumnWidth[0] = 60
    itm.ImageTree.ColumnWidth[1] = 40
    itm.ImageTree.ColumnWidth[2] = 60
    itm.ImageTree.ColumnWidth[3] = 300
    itm.ImageTree.ColumnWidth[4] = 80

    itm.ImageTree:Clear()
    for _, scene in ipairs(screenplayData.scenes) do
        local shots = scene.shots or {}
        for _, shot in ipairs(shots) do
            local item = itm.ImageTree:NewItem()
            item.Text[0] = tostring(scene.index)
            item.Text[1] = tostring((shot.index or 0) + 1)
            item.Text[2] = shot.shot_type or ""
            -- Truncate long descriptions for display
            local desc = shot.description or ""
            if #desc > 80 then desc = desc:sub(1, 77) .. "..." end
            item.Text[3] = desc
            -- Check if image already generated
            local key = tostring(scene.index) .. "_" .. tostring(shot.index or 0)
            item.Text[4] = generatedImages[key] and "Done" or "Pending"
            itm.ImageTree:AddTopLevelItem(item)
        end
    end
end

local function populateVideoTree()
    if not screenplayData or not screenplayData.scenes then return end

    local hdr = itm.VideoTree:NewItem()
    hdr.Text[0] = "Scene"
    hdr.Text[1] = "Shot"
    hdr.Text[2] = "Description"
    hdr.Text[3] = "Image"
    hdr.Text[4] = "Status"
    itm.VideoTree:SetHeaderItem(hdr)
    itm.VideoTree.ColumnCount = 5
    itm.VideoTree.ColumnWidth[0] = 60
    itm.VideoTree.ColumnWidth[1] = 40
    itm.VideoTree.ColumnWidth[2] = 260
    itm.VideoTree.ColumnWidth[3] = 80
    itm.VideoTree.ColumnWidth[4] = 80

    itm.VideoTree:Clear()
    for _, scene in ipairs(screenplayData.scenes) do
        local shots = scene.shots or {}
        for _, shot in ipairs(shots) do
            local item = itm.VideoTree:NewItem()
            item.Text[0] = tostring(scene.index)
            item.Text[1] = tostring((shot.index or 0) + 1)
            local desc = shot.description or ""
            if #desc > 70 then desc = desc:sub(1, 67) .. "..." end
            item.Text[2] = desc
            local key = tostring(scene.index) .. "_" .. tostring(shot.index or 0)
            item.Text[3] = generatedImages[key] and "Yes" or "No"
            item.Text[4] = generatedVideos[key] and "Done" or "Pending"
            itm.VideoTree:AddTopLevelItem(item)
        end
    end
end

local function populateVoiceTree()
    if not screenplayData or not screenplayData.characters then return end

    local hdr = itm.VoiceTree:NewItem()
    hdr.Text[0] = "Character"
    hdr.Text[1] = "Lines"
    hdr.Text[2] = "Voice Sample"
    hdr.Text[3] = "Voice ID"
    itm.VoiceTree:SetHeaderItem(hdr)
    itm.VoiceTree.ColumnCount = 4
    itm.VoiceTree.ColumnWidth[0] = 140
    itm.VoiceTree.ColumnWidth[1] = 50
    itm.VoiceTree.ColumnWidth[2] = 250
    itm.VoiceTree.ColumnWidth[3] = 150

    itm.VoiceTree:Clear()
    for name, info in pairs(screenplayData.characters) do
        if info.lines and info.lines > 0 then
            local item = itm.VoiceTree:NewItem()
            item.Text[0] = name
            item.Text[1] = tostring(info.lines)
            item.Text[2] = "(none)"
            item.Text[3] = characterVoices[name] or ""
            itm.VoiceTree:AddTopLevelItem(item)
        end
    end
end

-- Override onNext to populate trees when entering certain steps
local _origOnNext = onNext
onNext = function()
    local nextStep = currentStep + 1
    if nextStep == 5 then  -- Entering Images (Step 5)
        populateImageTree()
    elseif nextStep == 6 then  -- Entering Videos (Step 6)
        populateVideoTree()
    elseif nextStep == 7 then  -- Entering Voice Setup (Step 7)
        populateVoiceTree()
    end
    _origOnNext()
end

-- Re-wire Next buttons to use the overridden onNext
function win.On.NextBtn.Clicked(ev) onNext() end
function win.On.NextBtn2.Clicked(ev) onNext() end
function win.On.NextBtn3.Clicked(ev) onNext() end
function win.On.NextBtn4.Clicked(ev) onNext() end
function win.On.NextBtn5.Clicked(ev) onNext() end
function win.On.NextBtn6.Clicked(ev) onNext() end
function win.On.NextBtn7.Clicked(ev) onNext() end
function win.On.NextBtn8.Clicked(ev) onNext() end
function win.On.NextBtn9.Clicked(ev) onNext() end

-- ============================================================
-- SHOW AND RUN
-- ============================================================

showStep(1)
win:Show()
disp:RunLoop()
win:Hide()
