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

    -- Execute and capture output.
    -- ``-u`` forces Python to unbuffer stdout/stderr so long-running ops
    -- (image polling, video polling, lip-sync polling) emit progress lines
    -- live. ``tee`` duplicates them to BOTH the temp file (so Lua can read
    -- the JSON result at the end) AND the parent stdout, where Resolve's
    -- Console window shows them as they happen — critical for diagnosing
    -- silent hangs.
    local outfile = os.tmpname()
    local cmd = pythonCmd .. ' -u "' .. tmpfile .. '" 2>&1 | tee "' .. outfile .. '"'
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

local STEPS = {"Welcome", "Script", "Characters", "Style", "Review Images", "Images", "Review Videos", "Videos", "Voices", "Dialogue", "LipSync", "Assembly"}
local currentStep = 1

local config = {
    -- Provider selections
    imageProvider = "freepik",        -- "freepik" | "grok" | "openai" | "comfyui_flux"
    videoProvider = "freepik",        -- "freepik" | "grok" | "comfyui_ltx"
    voiceProvider = "elevenlabs",     -- "elevenlabs" | "voicebox" | "mlx_audio"
    lipsyncProvider = "freepik",      -- "freepik" (Kling lip sync) | "kling"
    -- Per-provider credentials
    providers = {
        freepik    = { apiKey = "", webhookKey = "" },  -- webhookKey stored for future use
        elevenlabs = { apiKey = "" },
        grok       = { apiKey = "" },
        openai     = { apiKey = "" },
        comfyui    = { serverUrl = "http://127.0.0.1:8188" },
        voicebox   = { serverUrl = "http://127.0.0.1:17493" },
        kling      = { apiKey = "" },
    },
    -- Legacy (kept for backward compat)
    freepikKey = "",
    elevenlabsKey = "",
    -- Generation settings (image — cross-provider)
    model = "realism",                -- Freepik Mystic style sub-model
    aspectRatio = "widescreen_16_9",
    detailing = 33,
    -- Which Freepik image API to dispatch to. See IMAGE_ENDPOINTS in
    -- freepik_client.py — mystic / flux-* / seedream-* / hyperflux /
    -- z-image-turbo / runway. Defaults to "mystic" so existing configs
    -- keep working unchanged.
    freepikImageApi = "mystic",
    -- Freepik Mystic per-model options (only honored when freepikImageApi == "mystic")
    freepikEngine = "automatic",      -- automatic | magnific_sparkle | magnific_illusio | magnific_sharpy
    freepikResolution = "2k",         -- 1k | 2k | 4k
    freepikStructureStrength = 50,    -- 0-100
    -- OpenAI gpt-image-2 per-model options
    openaiQuality = "auto",           -- low | medium | high | auto
    openaiSize = "auto",              -- 1024x1024 | 1536x1024 | 1024x1536 | auto
    openaiOutputFormat = "png",       -- png | jpeg | webp
    openaiBackground = "auto",        -- transparent | opaque | auto
    -- Video generation settings
    videoModel = "kling-v3-omni",     -- see freepik_client.VIDEO_ENDPOINTS
    videoCfgScale = 0.5,              -- 0.0-1.0
    videoNegativePrompt = "",
    -- Episode info
    episodeNumber = "",
    episodeTitle = "",
}

local screenplayData = nil -- parsed screenplay (Lua table from JSON)
local characterImages = {} -- characterName -> imagePath
local characterVoices = {} -- characterName -> voiceId
local generatedImages = {} -- shotKey (s{N}_sh{M}) -> imagePath
local failedImages = {}    -- shotKey (s{N}_sh{M}) -> error message
local generatedVideos = {} -- shotKey -> videoPath
local generatedAudio = {}  -- dialogueKey -> audioPath
local lipSyncedVideos = {} -- shotKey -> videoPath

-- Prompt review state (Step 5 Review Images + Step 7 Review Videos).
-- Overrides live in memory and win at generation time (passed as
-- custom_prompts=). Approval flags are advisory — they track whether the
-- user has explicitly confirmed the prompt for that shot.
local autoImagePrompts = {}       -- shotKey -> auto-generated prompt (from build_all_image_prompts)
local imagePromptOverrides = {}   -- shotKey -> user-edited prompt (missing = use auto)
local imagePromptApproved = {}    -- shotKey -> true when approved by user
local autoVideoPrompts = {}       -- shotKey -> auto-generated motion prompt
local videoPromptOverrides = {}   -- shotKey -> user-edited motion prompt
local videoPromptApproved = {}    -- shotKey -> true when approved

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

-- Build episode prefix from config (e.g. "Ep1-Origins")
local function buildEpisodePrefix()
    local num = config.episodeNumber or ""
    local title = config.episodeTitle or ""
    if num == "" and title == "" then return "" end
    local sanitizedTitle = title:gsub("[^%w]", "")
    if num ~= "" and sanitizedTitle ~= "" then
        return "Ep" .. num .. "-" .. sanitizedTitle
    elseif num ~= "" then
        return "Ep" .. num
    else
        return sanitizedTitle
    end
end

-- Load saved config
local configDir = homeDir .. "/Library/Application Support/ScriptToScreen"
local configPath = configDir .. "/config.json"
-- Global character library: persists character reference images across projects.
-- Keyed by normalized (uppercase, trimmed) character name so recurring
-- characters in episodic shows auto-populate their ref image.
local charLibraryPath = configDir .. "/character_library.json"
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
                    config.providers.freepik.webhookKey = saved.providers.freepik.webhookKey or ""
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
                if saved.providers.openai then
                    config.providers.openai.apiKey = saved.providers.openai.apiKey or ""
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
            -- Generation settings (image)
            config.model = saved.model or "realism"
            config.aspectRatio = saved.aspectRatio or "widescreen_16_9"
            config.detailing = saved.detailing or 33
            -- Which Freepik image API to dispatch to (mystic / flux-* / seedream-* / etc.)
            config.freepikImageApi = saved.freepikImageApi or "mystic"
            -- Freepik Mystic per-model options (only honored when freepikImageApi == "mystic")
            config.freepikEngine = saved.freepikEngine or "automatic"
            config.freepikResolution = saved.freepikResolution or "2k"
            config.freepikStructureStrength = saved.freepikStructureStrength or 50
            -- OpenAI gpt-image-2 per-model options
            config.openaiQuality = saved.openaiQuality or "auto"
            config.openaiSize = saved.openaiSize or "auto"
            config.openaiOutputFormat = saved.openaiOutputFormat or "png"
            config.openaiBackground = saved.openaiBackground or "auto"
            -- Video generation
            config.videoModel = saved.videoModel or "kling-v3-omni"
            config.videoCfgScale = saved.videoCfgScale or 0.5
            config.videoNegativePrompt = saved.videoNegativePrompt or ""
            -- Provider selections (ensure defaults if missing)
            config.imageProvider = saved.imageProvider or config.imageProvider
            config.videoProvider = saved.videoProvider or config.videoProvider
            config.voiceProvider = saved.voiceProvider or config.voiceProvider
            config.lipsyncProvider = saved.lipsyncProvider or config.lipsyncProvider
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
-- GLOBAL CHARACTER LIBRARY (recurring character refs across projects)
-- ============================================================

-- In-memory mirror of character_library.json. Keyed by normalized name.
-- Schema per entry: {reference_image_path=..., last_updated=..., source_project=...}
local characterLibrary = {}

-- Normalize a character name so "Aiden", "AIDEN ", and "aiden" all map
-- to the same library key.
local function normCharName(name)
    if type(name) ~= "string" then return "" end
    local n = name:gsub("^%s+", ""):gsub("%s+$", "")
    return n:upper()
end

local function loadCharacterLibrary()
    characterLibrary = {}
    local f = io.open(charLibraryPath, "r")
    if not f then return end
    local raw = f:read("*a")
    f:close()
    if not raw or raw == "" then return end

    local ok, parsed = pcall(JSON.decode, raw)
    if not ok or type(parsed) ~= "table" then
        print("[ScriptToScreen] Character library parse failed; starting fresh")
        return
    end
    local chars = parsed.characters
    if type(chars) == "table" then
        for name, entry in pairs(chars) do
            if type(entry) == "table" and type(entry.reference_image_path) == "string" then
                characterLibrary[normCharName(name)] = {
                    display_name = entry.display_name or name,
                    reference_image_path = entry.reference_image_path,
                    last_updated = entry.last_updated or "",
                    source_project = entry.source_project or "",
                }
            end
        end
    end
end

local function saveCharacterLibrary()
    os.execute('mkdir -p "' .. configDir .. '"')
    local out = {
        version = 1,
        characters = {},
    }
    for key, entry in pairs(characterLibrary) do
        out.characters[key] = entry
    end
    local f = io.open(charLibraryPath, "w")
    if f then
        f:write(JSON.encode(out))
        f:close()
    end
end

-- Upsert a character into the library. Called when the user picks or
-- changes a reference image in Step 3.
local function updateCharacterLibrary(name, imagePath)
    if not name or name == "" then return end
    local key = normCharName(name)
    local proj = (config.episodeTitle or "") .. (config.episodeNumber ~= "" and (" " .. config.episodeNumber) or "")
    characterLibrary[key] = {
        display_name = name,
        reference_image_path = imagePath,
        last_updated = os.date("!%Y-%m-%dT%H:%M:%SZ"),
        source_project = proj,
    }
    saveCharacterLibrary()
end

-- Look up a character's reference image. Returns (path, entry) or (nil, nil).
-- If the stored file no longer exists, returns nil so we don't populate
-- stale paths.
local function lookupCharacterLibrary(name)
    local key = normCharName(name)
    local entry = characterLibrary[key]
    if not entry then return nil, nil end
    local p = entry.reference_image_path
    if not p or p == "" then return nil, nil end
    local f = io.open(p, "r")
    if f then
        f:close()
        return p, entry
    end
    -- File missing — keep the entry but return nil so the UI shows (none)
    return nil, entry
end

loadCharacterLibrary()

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
                -- Freepik webhook key (optional — stored for future webhook integration)
                ui:HGroup{
                    ui:Label{Text = "Freepik Webhook Key:", Weight = 0.22, StyleSheet = "color: #888; font-size: 10px;"},
                    ui:LineEdit{ID = "FreepikWebhookKey", PlaceholderText = "(optional, for future use)", EchoMode = "Password", Weight = 0.58},
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
                -- Freepik image API (which endpoint/model to hit).
                -- Hidden when image provider isn't Freepik.
                ui:HGroup{
                    ID = "FreepikApiRow",
                    ui:Label{Text = "Freepik Model:", Weight = 0.2},
                    ui:ComboBox{ID = "FreepikApiCombo", Weight = 0.8},
                },
                -- Mystic style sub-selector (renamed from generic "Model").
                -- Only relevant when freepikApi == "mystic".
                ui:HGroup{
                    ID = "MysticStyleRow",
                    ui:Label{Text = "Mystic Style:", Weight = 0.2},
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

                -- Freepik Mystic per-model options (shown only when API == mystic)
                ui:HGroup{
                    ID = "FreepikEngineRow",
                    ui:Label{Text = "Engine (Mystic):", Weight = 0.2},
                    ui:ComboBox{ID = "FreepikEngineCombo", Weight = 0.8},
                },
                ui:HGroup{
                    ID = "FreepikResolutionRow",
                    ui:Label{Text = "Resolution (Mystic):", Weight = 0.2},
                    ui:ComboBox{ID = "FreepikResolutionCombo", Weight = 0.8},
                },
                ui:HGroup{
                    ID = "FreepikStructureRow",
                    ui:Label{Text = "Structure (Mystic):", Weight = 0.2},
                    ui:Slider{ID = "FreepikStructureSlider", Minimum = 0, Maximum = 100, Value = 50, Weight = 0.6},
                    ui:Label{ID = "FreepikStructureValue", Text = "50", Weight = 0.2},
                },

                -- OpenAI gpt-image-2 per-model options (shown only when imageProvider == "openai")
                ui:HGroup{
                    ID = "OpenAIQualityRow",
                    ui:Label{Text = "Quality (OpenAI):", Weight = 0.2},
                    ui:ComboBox{ID = "OpenAIQualityCombo", Weight = 0.8},
                },
                ui:HGroup{
                    ID = "OpenAISizeRow",
                    ui:Label{Text = "Size (OpenAI):", Weight = 0.2},
                    ui:ComboBox{ID = "OpenAISizeCombo", Weight = 0.8},
                },
                ui:HGroup{
                    ID = "OpenAIFormatRow",
                    ui:Label{Text = "Format (OpenAI):", Weight = 0.2},
                    ui:ComboBox{ID = "OpenAIFormatCombo", Weight = 0.8},
                },
                ui:HGroup{
                    ID = "OpenAIBgRow",
                    ui:Label{Text = "Background (OpenAI):", Weight = 0.2},
                    ui:ComboBox{ID = "OpenAIBgCombo", Weight = 0.8},
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
            -- PAGE 5: Review Image Prompts
            -- ========================
            ui:VGroup{
                ID = "ReviewImagesPage",
                ui:Label{
                    Text = "<h3>Review Image Prompts</h3><p>Inspect and edit the prompt for each shot before generation. Unedited shots will use the auto prompt.</p>",
                    Alignment = {AlignHCenter = true},
                },
                ui:HGroup{
                    ui:Label{ID = "ImageReviewStatus", Text = "0 of 0 approved", Weight = 0.5},
                    ui:Button{ID = "ImageApproveAll", Text = "Approve All", Weight = 0.25},
                    ui:Button{ID = "ImageRefreshAuto", Text = "Refresh Auto Prompts", Weight = 0.25},
                },
                ui:Tree{ID = "ImageReviewTree", HeaderHidden = false, MinimumSize = {500, 180}},
                ui:Label{Text = "Prompt for selected shot (edit freely):"},
                ui:TextEdit{ID = "ImageReviewEdit", MinimumSize = {400, 90}},
                ui:HGroup{
                    ui:Button{ID = "ImageSaveEdit", Text = "Save Edit", Weight = 0.33},
                    ui:Button{ID = "ImageResetAuto", Text = "Reset to Auto", Weight = 0.33},
                    ui:Button{ID = "ImageApproveOne", Text = "Approve This Shot", Weight = 0.34},
                },
                ui:VGap(0, 0.5),
                ui:HGroup{
                    ui:Label{Text = "", Weight = 0.55},
                    ui:Button{ID = "CancelBtn5", Text = "Cancel", Weight = 0.15},
                    ui:Button{ID = "BackBtn5", Text = "< Back", Weight = 0.15},
                    ui:Button{ID = "NextBtn5", Text = "Next >", Weight = 0.15},
                },
            },

            -- ========================
            -- PAGE 6: Image Generation
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
                    ui:Button{ID = "RetryFailedImages", Text = "Retry Failed", Weight = 0.3, Enabled = false},
                    ui:Label{Text = "", Weight = 0.1},
                },
                ui:Label{ID = "ImageProgress", Text = "Ready"},
                ui:VGap(0, 0.5),
                ui:HGroup{
                    ui:Label{Text = "", Weight = 0.55},
                    ui:Button{ID = "CancelBtn7", Text = "Cancel", Weight = 0.15},
                    ui:Button{ID = "BackBtn7", Text = "< Back", Weight = 0.15},
                    ui:Button{ID = "NextBtn7", Text = "Next >", Weight = 0.15},
                },
            },

            -- ========================
            -- PAGE 7: Review Video Prompts
            -- ========================
            ui:VGroup{
                ID = "ReviewVideosPage",
                ui:Label{
                    Text = "<h3>Review Video Motion Prompts</h3><p>Inspect and edit the motion prompt for each shot before generation. Unedited shots will use the auto prompt.</p>",
                    Alignment = {AlignHCenter = true},
                },
                ui:HGroup{
                    ui:Label{ID = "VideoReviewStatus", Text = "0 of 0 approved", Weight = 0.5},
                    ui:Button{ID = "VideoApproveAll", Text = "Approve All", Weight = 0.25},
                    ui:Button{ID = "VideoRefreshAuto", Text = "Refresh Auto Prompts", Weight = 0.25},
                },
                ui:Tree{ID = "VideoReviewTree", HeaderHidden = false, MinimumSize = {500, 180}},
                ui:Label{Text = "Motion prompt for selected shot (edit freely):"},
                ui:TextEdit{ID = "VideoReviewEdit", MinimumSize = {400, 90}},
                ui:HGroup{
                    ui:Button{ID = "VideoSaveEdit", Text = "Save Edit", Weight = 0.33},
                    ui:Button{ID = "VideoResetAuto", Text = "Reset to Auto", Weight = 0.33},
                    ui:Button{ID = "VideoApproveOne", Text = "Approve This Shot", Weight = 0.34},
                },
                ui:VGap(0, 0.5),
                ui:HGroup{
                    ui:Label{Text = "", Weight = 0.55},
                    ui:Button{ID = "CancelBtn6", Text = "Cancel", Weight = 0.15},
                    ui:Button{ID = "BackBtn6", Text = "< Back", Weight = 0.15},
                    ui:Button{ID = "NextBtn6", Text = "Next >", Weight = 0.15},
                },
            },

            -- ========================
            -- PAGE 8: Video Generation
            -- ========================
            ui:VGroup{
                ID = "VideoGenPage",
                ui:Label{Text = "<h3>Video Generation</h3><p>Generate videos from start-frame images.</p>", Alignment = {AlignHCenter = true}},
                ui:Tree{ID = "VideoTree", HeaderHidden = false, MinimumSize = {500, 150}},
                ui:HGroup{
                    ui:Label{Text = "Video Model:", Weight = 0.15},
                    ui:ComboBox{ID = "VideoModelCombo", Weight = 0.85},
                },
                ui:HGroup{
                    ui:Label{Text = "Duration (s):", Weight = 0.15},
                    ui:SpinBox{ID = "DurationSpin", Minimum = 3, Maximum = 15, Value = 5, Weight = 0.15},
                    ui:Label{Text = "CFG:", Weight = 0.08},
                    ui:Slider{ID = "VideoCfgSlider", Minimum = 0, Maximum = 100, Value = 50, Weight = 0.42},
                    ui:Label{ID = "VideoCfgValue", Text = "0.50", Weight = 0.2},
                },
                ui:HGroup{
                    ui:Label{Text = "Motion prompt:", Weight = 0.15},
                    ui:LineEdit{ID = "MotionPrompt", PlaceholderText = "Auto-filled from action", Weight = 0.85},
                },
                ui:HGroup{
                    ui:Label{Text = "Negative prompt:", Weight = 0.15},
                    ui:LineEdit{ID = "VideoNegativePrompt", PlaceholderText = "(optional) blurry, low-quality, watermark...", Weight = 0.85},
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
                    ui:Button{ID = "CancelBtn8", Text = "Cancel", Weight = 0.15},
                    ui:Button{ID = "BackBtn8", Text = "< Back", Weight = 0.15},
                    ui:Button{ID = "NextBtn8", Text = "Next >", Weight = 0.15},
                },
            },

            -- ========================
            -- PAGE 6: Voice Setup
            -- ========================
            ui:VGroup{
                ID = "VoicePage",
                ui:Label{Text = "<h3>Voice Setup</h3><p>Assign voices to characters from cloud library or clone from samples.</p>", Alignment = {AlignHCenter = true}},
                ui:Tree{ID = "VoiceTree", HeaderHidden = false, MinimumSize = {500, 120}},
                ui:HGroup{
                    ui:Label{Text = "Assign Voice:", Weight = 0.12},
                    ui:ComboBox{ID = "VoiceAssignCombo", Weight = 0.55},
                    ui:Button{ID = "AssignVoice", Text = "Assign to Selected", Weight = 0.2},
                    ui:Button{ID = "FetchCloudVoices", Text = "Fetch Voices", Weight = 0.13},
                },
                ui:HGroup{
                    ui:Button{ID = "BrowseVoice", Text = "Add Sample", Weight = 0.2},
                    ui:Button{ID = "CloneVoice", Text = "Clone Voice", Weight = 0.2},
                    ui:Button{ID = "TestVoice", Text = "Test", Weight = 0.1},
                    ui:Label{Text = "", Weight = 0.5},
                },
                ui:HGroup{
                    ui:Label{Text = "TTS Model:", Weight = 0.12},
                    ui:ComboBox{ID = "TTSModelCombo", Weight = 0.88},
                },
                ui:Label{ID = "VoiceProgress", Text = "Ready"},
                ui:VGap(0, 0.5),
                ui:HGroup{
                    ui:Label{Text = "", Weight = 0.55},
                    ui:Button{ID = "CancelBtn9", Text = "Cancel", Weight = 0.15},
                    ui:Button{ID = "BackBtn9", Text = "< Back", Weight = 0.15},
                    ui:Button{ID = "NextBtn9", Text = "Next >", Weight = 0.15},
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
                    ui:Button{ID = "CancelBtn10", Text = "Cancel", Weight = 0.15},
                    ui:Button{ID = "BackBtn10", Text = "< Back", Weight = 0.15},
                    ui:Button{ID = "NextBtn10", Text = "Next >", Weight = 0.15},
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
                    ui:Button{ID = "CancelBtn11", Text = "Cancel", Weight = 0.15},
                    ui:Button{ID = "BackBtn11", Text = "< Back", Weight = 0.15},
                    ui:Button{ID = "NextBtn11", Text = "Next >", Weight = 0.15},
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
                    ui:Button{ID = "CancelBtn12", Text = "Cancel", Weight = 0.15},
                    ui:Button{ID = "BackBtn12", Text = "< Back", Weight = 0.15},
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
    {id = "openai",       name = "GPT Image 2 (OpenAI)"},
    {id = "comfyui_flux", name = "Flux Kontext (Local ComfyUI)"},
}
local videoProviders = {
    {id = "freepik",      name = "Freepik (Cloud — Kling, Seedance, MiniMax, Wan)"},
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
    local isCloud = (id == "freepik" or id == "grok" or id == "openai")
    itm.ImageApiKey.Enabled = isCloud
    itm.ImageServerUrl.Enabled = not isCloud
    if id == "freepik" then
        itm.ImageApiKey.PlaceholderText = "Freepik API key..."
        itm.ImageApiKey.Text = config.providers.freepik.apiKey or ""
    elseif id == "grok" then
        itm.ImageApiKey.PlaceholderText = "xAI API key..."
        itm.ImageApiKey.Text = config.providers.grok.apiKey or ""
    elseif id == "openai" then
        itm.ImageApiKey.PlaceholderText = "OpenAI API key (sk-...)..."
        itm.ImageApiKey.Text = config.providers.openai and config.providers.openai.apiKey or ""
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
-- Freepik webhook key (optional, for future use)
if itm.FreepikWebhookKey then
    itm.FreepikWebhookKey.Text = (config.providers.freepik and config.providers.freepik.webhookKey) or ""
end

-- Initialize episode fields
itm.EpisodeNumber.Text = config.episodeNumber or ""
itm.EpisodeTitle.Text = config.episodeTitle or ""

-- Initialize field visibility
updateImageProviderFields()
updateVideoProviderFields()
updateVoiceProviderFields()
updateLipSyncProviderFields()

-- Style page combos
-- Freepik image API selector. Each entry is {id, displayName}. The id is
-- what's sent to the backend; the display name is human-friendly.
local freepikImageApis = {
    {id = "mystic",           name = "Mystic (default — multiple styles)"},
    {id = "flux-2-pro",       name = "Flux 2 Pro"},
    {id = "flux-2-turbo",     name = "Flux 2 Turbo (faster)"},
    {id = "flux-2-klein",     name = "Flux 2 Klein"},
    {id = "flux-pro-v1-1",    name = "Flux Pro v1.1"},
    {id = "flux-dev",         name = "Flux Dev"},
    {id = "flux-kontext-pro", name = "Flux Kontext Pro"},
    {id = "hyperflux",        name = "Hyperflux"},
    {id = "seedream-4",       name = "Seedream 4"},
    {id = "seedream-v4-5",    name = "Seedream 4.5 (latest)"},
    {id = "z-image-turbo",    name = "Z-Image Turbo"},
    {id = "runway",           name = "RunWay Text-to-Image"},
}
for _, api in ipairs(freepikImageApis) do
    itm.FreepikApiCombo:AddItem(api.name)
end

-- Mystic style sub-selector (only shown when freepikApi == "mystic")
local mysticStyles = {"realism", "fluid", "zen", "flexible", "super_real", "editorial_portraits"}
for _, s in ipairs(mysticStyles) do itm.ModelCombo:AddItem(s) end

itm.AspectCombo:AddItem("widescreen_16_9")
itm.AspectCombo:AddItem("classic_4_3")
itm.AspectCombo:AddItem("square_1_1")

-- Helper: set a combo box to a value by matching against a known list.
-- Fusion UI's `Count` is a method (not a field), so we iterate the values
-- list the caller already built when populating the combo.
local function setComboToValue(combo, values, value)
    if type(values) ~= "table" then return end
    for i, v in ipairs(values) do
        if v == value then
            combo.CurrentIndex = i - 1
            return
        end
    end
    combo.CurrentIndex = 0
end

-- Freepik Mystic per-model combos
local freepikEngines = {"automatic", "magnific_sparkle", "magnific_illusio", "magnific_sharpy"}
for _, v in ipairs(freepikEngines) do itm.FreepikEngineCombo:AddItem(v) end
local freepikResolutions = {"1k", "2k", "4k"}
for _, v in ipairs(freepikResolutions) do itm.FreepikResolutionCombo:AddItem(v) end

-- OpenAI gpt-image-2 per-model combos
local openaiQualities = {"auto", "low", "medium", "high"}
for _, v in ipairs(openaiQualities) do itm.OpenAIQualityCombo:AddItem(v) end
local openaiSizes = {"auto", "1024x1024", "1536x1024", "1024x1536"}
for _, v in ipairs(openaiSizes) do itm.OpenAISizeCombo:AddItem(v) end
local openaiFormats = {"png", "jpeg", "webp"}
for _, v in ipairs(openaiFormats) do itm.OpenAIFormatCombo:AddItem(v) end
local openaiBackgrounds = {"auto", "opaque", "transparent"}
for _, v in ipairs(openaiBackgrounds) do itm.OpenAIBgCombo:AddItem(v) end

-- Initialize per-model option values from config
setComboToValue(itm.FreepikEngineCombo, freepikEngines, config.freepikEngine)
setComboToValue(itm.FreepikResolutionCombo, freepikResolutions, config.freepikResolution)
itm.FreepikStructureSlider.Value = config.freepikStructureStrength or 50
itm.FreepikStructureValue.Text = tostring(itm.FreepikStructureSlider.Value)

-- Helper: find display name for a freepik API id (and vice versa).
local function freepikApiIdToName(id)
    for _, a in ipairs(freepikImageApis) do
        if a.id == id then return a.name end
    end
    return freepikImageApis[1].name
end
local function freepikApiNameToId(name)
    for _, a in ipairs(freepikImageApis) do
        if a.name == name then return a.id end
    end
    return "mystic"
end

-- Restore Freepik API selection from config
do
    local savedApi = config.freepikImageApi or "mystic"
    local names = {}
    for _, a in ipairs(freepikImageApis) do table.insert(names, a.name) end
    setComboToValue(itm.FreepikApiCombo, names, freepikApiIdToName(savedApi))
end
setComboToValue(itm.OpenAIQualityCombo, openaiQualities, config.openaiQuality)
setComboToValue(itm.OpenAISizeCombo, openaiSizes, config.openaiSize)
setComboToValue(itm.OpenAIFormatCombo, openaiFormats, config.openaiOutputFormat)
setComboToValue(itm.OpenAIBgCombo, openaiBackgrounds, config.openaiBackground)

-- Video model selector (Step 8)
local videoModels = {
    "kling-v3-omni",
    "kling-v2-5-pro",
    "kling-v2-6-pro",
    "kling-o1-pro",
    "seedance-pro-1080p",
    "minimax-hailuo-2-3",
    "wan-v2-6-1080p",
}
for _, vm in ipairs(videoModels) do
    itm.VideoModelCombo:AddItem(vm)
end
setComboToValue(itm.VideoModelCombo, videoModels, config.videoModel or "kling-v3-omni")

-- Video CFG slider (0-100 UI → 0.0-1.0 API). Store as float in config.
itm.VideoCfgSlider.Value = math.floor((config.videoCfgScale or 0.5) * 100 + 0.5)
itm.VideoCfgValue.Text = string.format("%.2f", (itm.VideoCfgSlider.Value or 50) / 100.0)

-- Video negative prompt
itm.VideoNegativePrompt.Text = config.videoNegativePrompt or ""

-- Show/hide provider-specific option rows based on image provider AND
-- the selected Freepik image API. The Mystic-specific rows (style, engine,
-- resolution, structure) only matter when freepikImageApi == "mystic" —
-- the other Freepik APIs (Flux, Seedream, Hyperflux, etc.) ignore them.
-- Fusion has no Visible property on HGroup in every Resolve version — we
-- toggle Hidden + Enabled.
local function refreshProviderControls()
    local pid = config.imageProvider or "freepik"
    local isFreepik = (pid == "freepik")
    local isOpenAI  = (pid == "openai")

    -- Which Freepik API is currently selected (only meaningful when isFreepik).
    local apiId = "mystic"
    if isFreepik and itm.FreepikApiCombo then
        apiId = freepikApiNameToId(itm.FreepikApiCombo.CurrentText or "") or "mystic"
    end
    local isMystic = isFreepik and apiId == "mystic"

    local function setRow(row, on)
        if not row then return end
        pcall(function() row.Hidden = not on end)
        pcall(function() row.Enabled = on end)
    end
    -- Freepik API picker visible only for Freepik image provider
    setRow(itm.FreepikApiRow,        isFreepik)
    -- Mystic-only options visible only when API == mystic
    setRow(itm.MysticStyleRow,       isMystic)
    setRow(itm.FreepikEngineRow,     isMystic)
    setRow(itm.FreepikResolutionRow, isMystic)
    setRow(itm.FreepikStructureRow,  isMystic)
    -- OpenAI options
    setRow(itm.OpenAIQualityRow,     isOpenAI)
    setRow(itm.OpenAISizeRow,        isOpenAI)
    setRow(itm.OpenAIFormatRow,      isOpenAI)
    setRow(itm.OpenAIBgRow,          isOpenAI)
end

-- Re-run visibility logic when the user picks a different Freepik API.
function win.On.FreepikApiCombo.CurrentIndexChanged(ev)
    local name = itm.FreepikApiCombo.CurrentText or ""
    config.freepikImageApi = freepikApiNameToId(name)
    saveConfig()
    refreshProviderControls()
end

refreshProviderControls()

itm.ResCombo:AddItem("1920x1080")
itm.ResCombo:AddItem("3840x2160")
itm.ResCombo:AddItem("1280x720")

itm.FPSCombo:AddItem("24")
itm.FPSCombo:AddItem("25")
itm.FPSCombo:AddItem("30")

-- ============================================================
-- NAVIGATION
-- ============================================================

-- Forward-declare populateReviewTree so showStep can call it before the
-- real definition appears below (Lua locals aren't visible to code that
-- parsed earlier in the same chunk).
local populateReviewTree

local function showStep(step)
    currentStep = step
    itm.PageStack.CurrentIndex = step - 1
    itm.StepLabel.Text = string.format("<b>%d/%d: %s</b>", step, #STEPS, STEPS[step])
    -- When entering Review Images (step 5) or Review Videos (step 7),
    -- ensure the review tree is populated from the current screenplay.
    if step == 5 and screenplayData then
        pcall(populateReviewTree, "image")
    elseif step == 7 and screenplayData then
        pcall(populateReviewTree, "video")
    end
    -- When entering Assembly (step 12), set timeline name from episode info
    if step == 12 then
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
        elseif imgId == "openai" then
            config.providers.openai.apiKey = itm.ImageApiKey.Text
        end
        local vidId = config.videoProvider
        if vidId == "freepik" then
            config.providers.freepik.apiKey = itm.VideoApiKey.Text
        elseif vidId == "grok" then
            config.providers.grok.apiKey = itm.VideoApiKey.Text
        end
        -- Freepik webhook key (always saved when present, independent of provider)
        if itm.FreepikWebhookKey and itm.FreepikWebhookKey.Text then
            config.providers.freepik.webhookKey = itm.FreepikWebhookKey.Text
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

    -- Save Step 4 (Style + generation settings) on Next
    if currentStep == 4 then
        config.model = itm.ModelCombo.CurrentText or "realism"
        config.aspectRatio = itm.AspectCombo.CurrentText or "widescreen_16_9"
        config.detailing = itm.DetailSlider.Value or 33
        -- Freepik image API selection (mystic / flux-* / seedream-* / etc.)
        config.freepikImageApi = freepikApiNameToId(itm.FreepikApiCombo.CurrentText or "")
        -- Freepik Mystic per-model options
        config.freepikEngine = itm.FreepikEngineCombo.CurrentText or "automatic"
        config.freepikResolution = itm.FreepikResolutionCombo.CurrentText or "2k"
        config.freepikStructureStrength = itm.FreepikStructureSlider.Value or 50
        -- OpenAI gpt-image-2 per-model options
        config.openaiQuality = itm.OpenAIQualityCombo.CurrentText or "auto"
        config.openaiSize = itm.OpenAISizeCombo.CurrentText or "auto"
        config.openaiOutputFormat = itm.OpenAIFormatCombo.CurrentText or "png"
        config.openaiBackground = itm.OpenAIBgCombo.CurrentText or "auto"
        saveConfig()
    end

    -- Save Step 8 (Video generation settings) on Next — was Step 6 before review pages
    if currentStep == 8 then
        config.videoModel = itm.VideoModelCombo.CurrentText or "kling-v3-omni"
        config.videoCfgScale = (itm.VideoCfgSlider.Value or 50) / 100.0
        config.videoNegativePrompt = itm.VideoNegativePrompt.Text or ""
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
function win.On.CancelBtn11.Clicked(ev) onClose() end
function win.On.CancelBtn12.Clicked(ev) onClose() end

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
function win.On.BackBtn11.Clicked(ev) onBack() end
function win.On.BackBtn12.Clicked(ev) onBack() end

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
function win.On.NextBtn10.Clicked(ev) onNext() end
function win.On.NextBtn11.Clicked(ev) onNext() end

-- Finish & Close
function win.On.FinishBtn.Clicked(ev) onClose() end
function win.On.STS_Main.Close(ev) onClose() end

-- ============================================================
-- STEP 1: Provider Combo Change Handlers
-- ============================================================

function win.On.ImageProviderCombo.CurrentIndexChanged(ev)
    updateImageProviderFields()
    -- Record the new choice so refreshProviderControls() can react before Next is pressed
    config.imageProvider = getImageProviderId(itm.ImageProviderCombo.CurrentIndex)
    pcall(refreshProviderControls)
end

function win.On.FreepikStructureSlider.ValueChanged(ev)
    itm.FreepikStructureValue.Text = tostring(itm.FreepikStructureSlider.Value)
end

function win.On.VideoCfgSlider.ValueChanged(ev)
    itm.VideoCfgValue.Text = string.format("%.2f", (itm.VideoCfgSlider.Value or 50) / 100.0)
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
    if (pid == "freepik" or pid == "grok" or pid == "openai") and key == "" then
        itm.ImageProviderStatus.Text = "No key"
        itm.ImageProviderStatus.StyleSheet = "color: orange;"
        return
    end
    if testProvider(pid, key, url, itm.ImageProviderStatus) then
        if pid == "freepik" then
            config.providers.freepik.apiKey = key
        elseif pid == "grok" then
            config.providers.grok.apiKey = key
        elseif pid == "openai" then
            config.providers.openai.apiKey = key
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
        .. '            dialogue_list.append({"character": dl.character, "text": dl.text, "shot_index": dl.shot_index, "parenthetical": dl.parenthetical or ""})\n'
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

                -- Save script path for standalone tools
                config.lastScriptPath = itm.ScriptPath.Text
                saveConfig()

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
    local libraryHits = 0
    for name, info in pairs(data.characters) do
        local item = itm.CharTree:NewItem()
        item.Text[0] = name
        item.Text[1] = tostring(info.lines)

        -- If the user hasn't set a ref image for this character yet in
        -- this project, try the global library for recurring characters.
        if not characterImages[name] or characterImages[name] == "" then
            local libPath, libEntry = lookupCharacterLibrary(name)
            if libPath then
                characterImages[name] = libPath
                libraryHits = libraryHits + 1
            end
        end

        local currentPath = characterImages[name]
        if currentPath and currentPath ~= "" then
            -- Check if this came from the library and tag it visually
            local libPath = lookupCharacterLibrary(name)
            if libPath == currentPath then
                item.Text[2] = currentPath .. "  (from library)"
            else
                item.Text[2] = currentPath
            end
        else
            item.Text[2] = "(none)"
        end

        itm.CharTree:AddTopLevelItem(item)
    end

    if libraryHits > 0 then
        print(string.format("[ScriptToScreen] Auto-loaded %d character reference(s) from library", libraryHits))
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
        -- Persist to the global library so future projects with the same
        -- character name auto-populate this ref image.
        updateCharacterLibrary(charName, path)
        print(string.format("[ScriptToScreen] Saved '%s' to character library", charName))
    end
end

-- Clear removes the ref image from THIS project only.
-- The library entry is kept so other projects can still use it.
-- (Users who want to remove from the library can overwrite with a new image.)
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
    if imgPid == "openai" and (config.providers.openai and config.providers.openai.apiKey or "") == "" then
        itm.ImageProgress.Text = "Set OpenAI API key first (Step 1)!"
        itm.ImageProgress.StyleSheet = "color: red;"
        return
    end
    if not screenplayData then
        itm.ImageProgress.Text = "Parse a screenplay first (Step 2)!"
        itm.ImageProgress.StyleSheet = "color: red;"
        return
    end

    itm.ImageProgress.Text = "Generating images... watch Workspace > Console for live polling progress."
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
    elseif imgPid == "openai" then
        imgApiKey = config.providers.openai and config.providers.openai.apiKey or ""
    end

    -- Persist the latest Step 4 picks into config before Python reads them
    config.model = model
    config.aspectRatio = aspect
    config.detailing = detail
    config.freepikImageApi = freepikApiNameToId(itm.FreepikApiCombo.CurrentText or "")
    config.freepikEngine = itm.FreepikEngineCombo.CurrentText or config.freepikEngine
    config.freepikResolution = itm.FreepikResolutionCombo.CurrentText or config.freepikResolution
    config.freepikStructureStrength = itm.FreepikStructureSlider.Value or config.freepikStructureStrength
    config.openaiQuality = itm.OpenAIQualityCombo.CurrentText or config.openaiQuality
    config.openaiSize = itm.OpenAISizeCombo.CurrentText or config.openaiSize
    config.openaiOutputFormat = itm.OpenAIFormatCombo.CurrentText or config.openaiOutputFormat
    config.openaiBackground = itm.OpenAIBgCombo.CurrentText or config.openaiBackground
    saveConfig()

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
        .. '        creative_detailing=' .. tostring(detail) .. ',\n'
        .. '        freepik_image_api="' .. (config.freepikImageApi or "mystic") .. '",\n'
        .. '        freepik_engine="' .. (config.freepikEngine or "automatic") .. '",\n'
        .. '        freepik_resolution="' .. (config.freepikResolution or "2k") .. '",\n'
        .. '        freepik_structure_strength=' .. tostring(config.freepikStructureStrength or 50) .. ',\n'
        .. '        openai_quality="' .. (config.openaiQuality or "auto") .. '",\n'
        .. '        openai_size="' .. (config.openaiSize or "auto") .. '",\n'
        .. '        openai_output_format="' .. (config.openaiOutputFormat or "png") .. '",\n'
        .. '        openai_background="' .. (config.openaiBackground or "auto") .. '",\n'
        .. '    )\n'
        .. '    style_path = "' .. safeStyle .. '" if "' .. safeStyle .. '" else None\n'
        .. '    custom_prompts = json.loads(\'' .. overridesJson("image"):gsub("'", "\\'") .. '\')\n'
        .. '    results = generate_images_for_screenplay(\n'
        .. '        screenplay, provider, "' .. safeOutput .. '",\n'
        .. '        style_reference_path=style_path,\n'
        .. '        defaults=defaults,\n'
        .. '        custom_prompts=custom_prompts or None,\n'
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

            -- Parse error strings ("s{N}_sh{M}: <msg>") into failedImages map
            -- so we can show them in the tree and retry them in one click.
            failedImages = {}
            for _, errStr in ipairs(errs) do
                local sk, msg = tostring(errStr):match("^(s%d+_sh%d+):%s*(.*)$")
                if sk then
                    failedImages[sk] = (msg and msg ~= "") and msg or "Unknown error"
                end
            end
            -- Any previously-failed shot that now has a successful path is cleared
            for sk, _ in pairs(generatedImages) do
                failedImages[sk] = nil
            end
            -- Refresh the tree so users can see Failed/Done badges + retry count
            pcall(populateImageTree)
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

-- Retry Failed: loops through every failed shot and regenerates it, one at a time.
-- Successes populate generatedImages and are removed from failedImages.
-- The tree refreshes after each attempt so progress is visible.
function win.On.RetryFailedImages.Clicked(ev)
    -- Collect failed shot keys (s0_sh0 format) up front so we don't
    -- mutate the table while iterating.
    local failedList = {}
    for sk, _ in pairs(failedImages) do
        table.insert(failedList, sk)
    end
    table.sort(failedList)

    if #failedList == 0 then
        itm.ImageProgress.Text = "No failed images to retry."
        itm.ImageProgress.StyleSheet = "color: #888;"
        return
    end

    -- Validate provider + API key (same checks as Generate All Images)
    local imgPid = config.imageProvider
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

    -- Disable the button while running so users don't double-click
    itm.RetryFailedImages.Enabled = false

    local safePath = itm.ScriptPath.Text:gsub("\\", "\\\\"):gsub('"', '\\"')
    local safeStyle = itm.StylePath.Text:gsub("\\", "\\\\"):gsub('"', '\\"')
    local safeOutput = outputDir:gsub("\\", "\\\\"):gsub('"', '\\"')
    local model = itm.ModelCombo.CurrentText or "realism"
    local aspect = itm.AspectCombo.CurrentText or "widescreen_16_9"
    local detail = itm.DetailSlider.Value or 33

    local imgApiKey = ""
    if imgPid == "freepik" then
        imgApiKey = config.providers.freepik.apiKey or ""
    elseif imgPid == "grok" then
        imgApiKey = config.providers.grok.apiKey or ""
    elseif imgPid == "openai" then
        imgApiKey = config.providers.openai and config.providers.openai.apiKey or ""
    end
    local keyfile = os.tmpname()
    local kf = io.open(keyfile, "w")
    if kf then kf:write(imgApiKey); kf:close() end

    local safeServerUrl = (config.providers.comfyui.serverUrl or ""):gsub("\\", "\\\\"):gsub('"', '\\"')

    -- Build character image refs JSON (same as main gen)
    local charImgParts = {}
    for name, imgPath in pairs(characterImages) do
        local safeName = name:gsub('"', '\\"')
        local safeImg = imgPath:gsub("\\", "\\\\"):gsub('"', '\\"')
        table.insert(charImgParts, '"' .. safeName .. '":"' .. safeImg .. '"')
    end
    local charImgJson = "{" .. table.concat(charImgParts, ",") .. "}"

    -- Serialize the list of failed shot_keys as JSON
    local failedKeysParts = {}
    for _, sk in ipairs(failedList) do
        table.insert(failedKeysParts, '"' .. sk .. '"')
    end
    local failedKeysJson = "[" .. table.concat(failedKeysParts, ",") .. "]"

    local total = #failedList
    itm.ImageProgress.Text = "Retrying " .. tostring(total) .. " failed images..."
    itm.ImageProgress.StyleSheet = "color: #888;"

    -- Derive project slug (same pattern as GenAllImages)
    local projectSlugCode = 'import re\n'
        .. 'try:\n'
        .. '    import DaVinciResolveScript as dvr\n'
        .. '    _resolve = dvr.scriptapp("Resolve")\n'
        .. '    _pname = _resolve.GetProjectManager().GetCurrentProject().GetName()\n'
        .. '    project_slug = re.sub(r"[^\\w\\-]", "_", _pname).strip("_").lower() or "default"\n'
        .. 'except: project_slug = "default"\n'

    -- Python batch: walks the screenplay, filters to failed_keys, reuses
    -- build_image_prompt + regenerate_single_image, returns per-shot results.
    local code = 'import json, traceback, os, uuid\n'
        .. projectSlugCode
        .. 'try:\n'
        .. '    from script_to_screen.parsing.pdf_parser import parse_pdf\n'
        .. '    from script_to_screen.parsing.fountain_parser import parse_fountain\n'
        .. '    from script_to_screen.api.registry import create_image_provider\n'
        .. '    from script_to_screen.pipeline.image_gen import build_image_prompt, regenerate_single_image\n'
        .. '    from script_to_screen.config import GenerationDefaults\n'
        .. '    from script_to_screen.manifest import update_character, record_generated_image\n'
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
        .. '    provider = create_image_provider("' .. imgPid .. '",\n'
        .. '        api_key=api_key,\n'
        .. '        server_url="' .. safeServerUrl .. '",\n'
        .. '        model="' .. model .. '")\n'
        .. '    defaults = GenerationDefaults(\n'
        .. '        freepik_model="' .. model .. '",\n'
        .. '        aspect_ratio="' .. aspect .. '",\n'
        .. '        creative_detailing=' .. tostring(detail) .. ',\n'
        .. '        freepik_image_api="' .. (config.freepikImageApi or "mystic") .. '",\n'
        .. '        freepik_engine="' .. (config.freepikEngine or "automatic") .. '",\n'
        .. '        freepik_resolution="' .. (config.freepikResolution or "2k") .. '",\n'
        .. '        freepik_structure_strength=' .. tostring(config.freepikStructureStrength or 50) .. ',\n'
        .. '        openai_quality="' .. (config.openaiQuality or "auto") .. '",\n'
        .. '        openai_size="' .. (config.openaiSize or "auto") .. '",\n'
        .. '        openai_output_format="' .. (config.openaiOutputFormat or "png") .. '",\n'
        .. '        openai_background="' .. (config.openaiBackground or "auto") .. '")\n'
        .. '    style_path = "' .. safeStyle .. '" if "' .. safeStyle .. '" else None\n'
        .. '    failed_keys = set(json.loads(\'' .. failedKeysJson:gsub("'", "\\'") .. '\'))\n'
        .. '    custom_prompts = json.loads(\'' .. overridesJson("image"):gsub("'", "\\'") .. '\')\n'
        .. '    paths = {}\n'
        .. '    errors = []\n'
        .. '    for scene in screenplay.scenes:\n'
        .. '        for si, shot in enumerate(scene.shots):\n'
        .. '            sk = f"s{scene.index}_sh{si}"\n'
        .. '            if sk not in failed_keys: continue\n'
        .. '            try:\n'
        .. '                # Use user-edited prompt if one exists for this shot\n'
        .. '                if sk in custom_prompts and custom_prompts[sk]:\n'
        .. '                    prompt = custom_prompts[sk]\n'
        .. '                else:\n'
        .. '                    prompt = build_image_prompt(shot, scene, screenplay, shot_idx=si)\n'
        .. '                char_refs = {}\n'
        .. '                for c in shot.characters_present:\n'
        .. '                    ch = screenplay.characters.get(c)\n'
        .. '                    if ch and ch.reference_image_path:\n'
        .. '                        char_refs[c] = ch.reference_image_path\n'
        .. '                prompt = provider.build_prompt(prompt, char_refs)\n'
        .. '                actual = regenerate_single_image(sk, prompt, provider, "' .. safeOutput .. '",\n'
        .. '                    style_reference_path=style_path, defaults=defaults)\n'
        .. '                if actual:\n'
        .. '                    paths[sk] = actual\n'
        .. '                    try:\n'
        .. '                        record_generated_image(\n'
        .. '                            project_slug=project_slug,\n'
        .. '                            filename=os.path.basename(actual),\n'
        .. '                            file_path=actual,\n'
        .. '                            shot_key=sk,\n'
        .. '                            prompt=prompt,\n'
        .. '                            provider=type(provider).__name__,\n'
        .. '                            provider_settings={"model": "' .. model .. '", "aspect_ratio": "' .. aspect .. '"},\n'
        .. '                            style_reference_path=style_path or "",\n'
        .. '                            character_refs=char_refs)\n'
        .. '                    except Exception: pass\n'
        .. '                else:\n'
        .. '                    errors.append(f"{sk}: retry returned no image")\n'
        .. '            except Exception as e:\n'
        .. '                errors.append(f"{sk}: {e}")\n'
        .. '    print(json.dumps({"status": "ok", "paths": paths, "errors": errors,\n'
        .. '        "attempted": len(failed_keys), "recovered": len(paths)}))\n'
        .. 'except Exception as e:\n'
        .. '    print(json.dumps({"status": "error", "error": str(e), "trace": traceback.format_exc()}))\n'

    local result = runPython(code)
    os.remove(keyfile)

    local jsonStr = result and result:match("(%{.+%})")
    if not jsonStr then
        itm.ImageProgress.Text = "Retry failed — raw output: " .. tostring(result or ""):sub(1, 100)
        itm.ImageProgress.StyleSheet = "color: red;"
        itm.RetryFailedImages.Enabled = true
        return
    end

    local data = JSON.decode(jsonStr)
    if not data or data.status ~= "ok" then
        itm.ImageProgress.Text = "Retry error: " .. ((data and data.error) or "Unknown")
        itm.ImageProgress.StyleSheet = "color: red;"
        if data and data.trace then print("[ScriptToScreen] " .. data.trace) end
        itm.RetryFailedImages.Enabled = true
        return
    end

    -- Merge recovered paths into generatedImages and remove from failedImages
    local recovered = 0
    for sk, path in pairs(data.paths or {}) do
        generatedImages[sk] = path
        failedImages[sk] = nil
        recovered = recovered + 1
    end
    -- Record remaining errors with their new messages
    for _, errStr in ipairs(data.errors or {}) do
        local sk, msg = tostring(errStr):match("^(s%d+_sh%d+):%s*(.*)$")
        if sk and not generatedImages[sk] then
            failedImages[sk] = (msg and msg ~= "") and msg or "Unknown error"
        end
    end

    -- Import recovered images into the media pool (reuses the same bin logic)
    local importMsg = ""
    local importOk, importErr = pcall(function()
        local project = resolve:GetProjectManager():GetCurrentProject()
        if project and recovered > 0 then
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
            for shotKey, imgPath in pairs(data.paths or {}) do
                if type(imgPath) == "string" then
                    local targetBin = stsBin2
                    if epPfx ~= "" then targetBin = findOrCreate(targetBin, epPfx) end
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
        print("[ScriptToScreen] Retry bin import warning: " .. tostring(importErr))
    end

    -- Refresh tree to reflect new Done/Failed states
    pcall(populateImageTree)

    -- Summarize
    local stillFailed = 0
    for _ in pairs(failedImages) do stillFailed = stillFailed + 1 end
    local msg = "Retry: recovered " .. tostring(recovered) .. " of " .. tostring(total) .. "!" .. importMsg
    if stillFailed > 0 then
        msg = msg .. " (" .. tostring(stillFailed) .. " still failing)"
        itm.ImageProgress.StyleSheet = "color: orange; font-weight: bold;"
    else
        itm.ImageProgress.StyleSheet = "color: green; font-weight: bold;"
    end
    itm.ImageProgress.Text = msg
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

    -- Persist Step 6 picks into config before Python reads them
    config.videoModel = itm.VideoModelCombo.CurrentText or "kling-v3-omni"
    config.videoCfgScale = (itm.VideoCfgSlider.Value or 50) / 100.0
    config.videoNegativePrompt = itm.VideoNegativePrompt.Text or ""
    saveConfig()

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
    local safeNegative = (config.videoNegativePrompt or ""):gsub("\\", "\\\\"):gsub('"', '\\"')

    local code = 'import json, traceback, time, os, glob, re\n'
        .. 'try:\n'
        .. '    from script_to_screen.parsing.pdf_parser import parse_pdf\n'
        .. '    from script_to_screen.parsing.fountain_parser import parse_fountain\n'
        .. '    from script_to_screen.api.registry import create_video_provider\n'
        .. '    from script_to_screen.pipeline.video_gen import generate_videos_for_screenplay\n'
        .. '    from script_to_screen.config import GenerationDefaults\n'
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
        .. '    defaults = GenerationDefaults(\n'
        .. '        video_model="' .. (config.videoModel or "kling-v3-omni") .. '",\n'
        .. '        video_cfg_scale=' .. tostring(config.videoCfgScale or 0.5) .. ',\n'
        .. '        video_negative_prompt="' .. safeNegative .. '",\n'
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
        .. '    custom_prompts = json.loads(\'' .. overridesJson("video"):gsub("'", "\\'") .. '\')\n'
        .. '    results = generate_videos_for_screenplay(\n'
        .. '        screenplay, provider, image_paths,\n'
        .. '        "' .. safeOutput .. '",\n'
        .. '        defaults=defaults,\n'
        .. '        custom_prompts=custom_prompts or None,\n'
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

-- Storage for fetched cloud voices (name -> voice_id)
local availableCloudVoices = {}  -- {displayName -> voice_id}

-- Fetch voices from ElevenLabs and populate the Assign Voice dropdown
function win.On.FetchCloudVoices.Clicked(ev)
    local voicePid = config.voiceProvider
    if voicePid ~= "elevenlabs" then
        itm.VoiceProgress.Text = "Select ElevenLabs as voice provider first (Step 1)"
        itm.VoiceProgress.StyleSheet = "color: orange;"
        return
    end
    local apiKey = config.providers.elevenlabs.apiKey or ""
    if apiKey == "" then
        itm.VoiceProgress.Text = "Set ElevenLabs API key first (Step 1)"
        itm.VoiceProgress.StyleSheet = "color: red;"
        return
    end
    itm.VoiceProgress.Text = "Fetching voices..."
    itm.VoiceProgress.StyleSheet = "color: #888;"

    local keyfile = os.tmpname()
    local kf = io.open(keyfile, "w")
    if kf then kf:write(apiKey); kf:close() end

    local code = 'import json\n'
        .. 'try:\n'
        .. '    import requests\n'
        .. '    key = open("' .. keyfile .. '").read().strip()\n'
        .. '    r = requests.get("https://api.elevenlabs.io/v1/voices", headers={"xi-api-key": key}, timeout=15)\n'
        .. '    r.raise_for_status()\n'
        .. '    voices = [{"name": v["name"], "voice_id": v["voice_id"], "gender": v.get("labels",{}).get("gender","")} for v in r.json().get("voices", [])]\n'
        .. '    r2 = requests.get("https://api.elevenlabs.io/v1/models", headers={"xi-api-key": key}, timeout=15)\n'
        .. '    r2.raise_for_status()\n'
        .. '    models = [{"id": m["model_id"], "name": m["name"]} for m in r2.json()]\n'
        .. '    print(json.dumps({"status": "ok", "voices": voices, "models": models}))\n'
        .. 'except Exception as e:\n'
        .. '    print(json.dumps({"status": "error", "error": str(e)}))\n'

    local result = runPython(code)
    os.remove(keyfile)

    local jsonStr = result and result:match("(%{.+%})")
    if jsonStr then
        local data = JSON.decode(jsonStr)
        if data and data.status == "ok" then
            -- Populate the Assign Voice dropdown (NOT the character tree)
            local cloudVoices = data.voices or {}
            itm.VoiceAssignCombo:Clear()
            availableCloudVoices = {}
            for _, v in ipairs(cloudVoices) do
                local displayName = v.name
                if v.gender and v.gender ~= "" then displayName = displayName .. " (" .. v.gender .. ")" end
                itm.VoiceAssignCombo:AddItem(displayName)
                availableCloudVoices[displayName] = v.voice_id
            end
            -- Populate TTS model combo
            local models = data.models or {}
            itm.TTSModelCombo:Clear()
            for _, m in ipairs(models) do
                itm.TTSModelCombo:AddItem(m.name .. " (" .. m.id .. ")")
            end
            for i, m in ipairs(models) do
                if m.id == "eleven_multilingual_v2" then
                    itm.TTSModelCombo.CurrentIndex = i - 1
                    break
                end
            end
            itm.VoiceProgress.Text = tostring(#cloudVoices) .. " voices loaded — select a character, pick a voice, click Assign"
            itm.VoiceProgress.StyleSheet = "color: green;"
        else
            itm.VoiceProgress.Text = "Error: " .. (data and data.error or "Unknown")
            itm.VoiceProgress.StyleSheet = "color: red;"
        end
    else
        itm.VoiceProgress.Text = "Failed to fetch voices"
        itm.VoiceProgress.StyleSheet = "color: red;"
    end
end

-- Assign the selected cloud voice to the selected character
function win.On.AssignVoice.Clicked(ev)
    local selected = itm.VoiceTree:CurrentItem()
    if not selected then
        itm.VoiceProgress.Text = "Select a character from the list first"
        itm.VoiceProgress.StyleSheet = "color: orange;"
        return
    end

    local voiceIdx = itm.VoiceAssignCombo.CurrentIndex
    local voiceCount = 0
    -- Count items in combo to validate
    for displayName, _ in pairs(availableCloudVoices) do
        voiceCount = voiceCount + 1
    end
    if voiceCount == 0 then
        itm.VoiceProgress.Text = "Fetch voices first (click 'Fetch Voices')"
        itm.VoiceProgress.StyleSheet = "color: orange;"
        return
    end

    -- Get the selected voice name from the combo text
    local voiceName = itm.VoiceAssignCombo.CurrentText or ""
    local voiceId = availableCloudVoices[voiceName]
    if not voiceId then
        itm.VoiceProgress.Text = "Select a voice from the dropdown"
        itm.VoiceProgress.StyleSheet = "color: orange;"
        return
    end

    -- Assign to the selected character
    local charName = selected.Text[0]
    selected.Text[2] = voiceName  -- Show voice name in Voice Sample column
    selected.Text[3] = voiceId    -- Store voice_id
    characterVoices[charName] = voiceId

    itm.VoiceProgress.Text = charName .. " → " .. voiceName
    itm.VoiceProgress.StyleSheet = "color: green; font-weight: bold;"
end

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
            local count = data.count or 0
            if count > 0 then
                -- Import audio to episode/scene bins
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
                        for shotKey, audPath in pairs(generatedAudio) do
                            if type(audPath) == "string" then
                                local targetBin = stsBin2
                                if epPfx ~= "" then
                                    targetBin = findOrCreate(targetBin, epPfx)
                                end
                                local sNum = tonumber((shotKey or ""):match("^s(%d+)")) or 0
                                targetBin = findOrCreate(targetBin, "S" .. tostring(sNum))
                                targetBin = findOrCreate(targetBin, "Audio")
                                if targetBin then mp:SetCurrentFolder(targetBin) end
                                local items = mp:ImportMedia({audPath}) or {}
                                for _, item in ipairs(items) do
                                    local basename = audPath:match("([^/]+)$") or ""
                                    pcall(function() item:SetMetadata("Comments", "STS:" .. basename) end)
                                end
                                importCount = importCount + #items
                            end
                        end
                        importMsg = " (" .. tostring(importCount) .. " added to bin)"
                    end
                end)
                if not importOk then
                    print("[ScriptToScreen] Audio import warning: " .. tostring(importErr))
                end
                itm.DialogueProgress.Text = "Generated " .. tostring(count) .. " dialogue clips!" .. importMsg
            else
                itm.DialogueProgress.Text = "Generated 0 dialogue clips"
            end
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

    itm.LipSyncProgress.Text = "Merging dialogue audio per shot..."
    itm.LipSyncProgress.StyleSheet = "color: #888;"

    local safeOutput = outputDir:gsub("\\", "\\\\"):gsub('"', '\\"')

    -- Write API key to temp file (reused across all calls)
    local keyfile = os.tmpname()
    local kf = io.open(keyfile, "w")
    if kf then kf:write(lsKey); kf:close() end

    -- Step 1: Merge per-line audio files into one per shot, then discover pairs
    -- This handles shots with multiple dialogue lines (e.g. AIDEN then ALIYAH)
    -- by concatenating them in script order before sending to lip sync.
    local discoverCode = 'import json, os, glob, re\n'
        .. 'try:\n'
        .. '    from script_to_screen.pipeline.audio_merge import merge_shot_audio\n'
        .. '    video_dir = "' .. safeOutput .. '/videos"\n'
        .. '    audio_dir = "' .. safeOutput .. '/audio"\n'
        .. '    dialogue_dir = os.path.join(audio_dir, "dialogue_audio")\n'
        .. '    merged_dir = os.path.join(audio_dir, "merged")\n'
        .. '    # Merge per-line audio files into combined per-shot files\n'
        .. '    merged = {}\n'
        .. '    if os.path.isdir(dialogue_dir):\n'
        .. '        merged = merge_shot_audio(dialogue_dir, merged_dir)\n'
        .. '    merge_count = len(merged)\n'
        .. '    def _shot_key(filepath):\n'
        .. '        bn = os.path.splitext(os.path.basename(filepath))[0]\n'
        .. '        m = re.match(r"(s\\d+_sh\\d+)", bn)\n'
        .. '        return m.group(1) if m else None\n'
        .. '    videos = sorted(glob.glob(os.path.join(video_dir, "*.mp4")))\n'
        .. '    video_map = {}\n'
        .. '    for v in videos:\n'
        .. '        sk = _shot_key(v)\n'
        .. '        if sk: video_map[sk] = v\n'
        .. '    # Build audio map: prefer merged > dialogue_audio > audio root\n'
        .. '    audio_map = {}\n'
        .. '    # First: merged files (highest priority)\n'
        .. '    for sk, path in merged.items():\n'
        .. '        audio_map[sk] = path\n'
        .. '    # Then: individual dialogue_audio files (only if not already merged)\n'
        .. '    for a in sorted(glob.glob(os.path.join(dialogue_dir, "*.wav")) + glob.glob(os.path.join(dialogue_dir, "*.mp3"))):\n'
        .. '        sk = _shot_key(a)\n'
        .. '        if sk and sk not in audio_map: audio_map[sk] = a\n'
        .. '    # Then: root audio dir\n'
        .. '    for a in sorted(glob.glob(os.path.join(audio_dir, "*.wav")) + glob.glob(os.path.join(audio_dir, "*.mp3"))):\n'
        .. '        sk = _shot_key(a)\n'
        .. '        if sk and sk not in audio_map: audio_map[sk] = a\n'
        .. '    pairs = []\n'
        .. '    for sk in sorted(video_map.keys()):\n'
        .. '        if sk in audio_map:\n'
        .. '            pairs.append({"shot_key": sk, "video": video_map[sk], "audio": audio_map[sk]})\n'
        .. '    print(json.dumps({"status": "ok", "pairs": pairs, "video_count": len(video_map), "audio_count": len(audio_map), "merged_count": merge_count}))\n'
        .. 'except Exception as e:\n'
        .. '    import traceback\n'
        .. '    print(json.dumps({"status": "error", "error": str(e), "trace": traceback.format_exc()}))\n'

    local discResult = runPython(discoverCode)
    local discJson = discResult and discResult:match("(%{.+%})")
    if not discJson then
        itm.LipSyncProgress.Text = "Failed to scan files. Check console."
        itm.LipSyncProgress.StyleSheet = "color: red;"
        os.remove(keyfile)
        return
    end

    local discData = JSON.decode(discJson)
    if not discData or discData.status ~= "ok" then
        itm.LipSyncProgress.Text = "Scan error: " .. (discData and discData.error or "Unknown")
        itm.LipSyncProgress.StyleSheet = "color: red;"
        os.remove(keyfile)
        return
    end

    local pairs = discData.pairs or {}
    local mergedCount = discData.merged_count or 0
    if #pairs == 0 then
        itm.LipSyncProgress.Text = "No matching video/audio pairs found (videos: " .. tostring(discData.video_count) .. ", audio: " .. tostring(discData.audio_count) .. ")"
        itm.LipSyncProgress.StyleSheet = "color: orange;"
        os.remove(keyfile)
        return
    end

    if mergedCount > 0 then
        print("[ScriptToScreen] Merged " .. tostring(mergedCount) .. " shot audio files from individual dialogue lines")
    end

    -- Step 2: Lip-sync each pair individually using the standalone function
    -- (same proven approach as STS_Lip_Sync.lua standalone tool)
    local syncCount = 0
    local failCount = 0
    local serverUrl = ""
    if lsPid == "kling" then
        serverUrl = config.providers.kling and config.providers.kling.serverUrl or ""
    end

    for i, pair in ipairs(pairs) do
        local shotKey = pair.shot_key
        local vidPath = pair.video:gsub("\\", "\\\\"):gsub('"', '\\"')
        local audPath = pair.audio:gsub("\\", "\\\\"):gsub('"', '\\"')

        itm.LipSyncProgress.Text = "Lip-syncing " .. shotKey .. " (" .. tostring(i) .. "/" .. tostring(#pairs) .. ")..."
        itm.LipSyncProgress.StyleSheet = "color: #888;"

        local code = 'import traceback\n'
            .. 'try:\n'
            .. '    from script_to_screen.standalone import generate_lipsync_standalone\n'
            .. '    api_key = open("' .. keyfile .. '").read().strip()\n'
            .. '    result = generate_lipsync_standalone(\n'
            .. '        video_path="' .. vidPath .. '",\n'
            .. '        audio_path="' .. audPath .. '",\n'
            .. '        provider_id="' .. lsPid .. '",\n'
            .. '        api_key=api_key,\n'
            .. '        output_dir="' .. safeOutput .. '",\n'
            .. '        project_slug="' .. (projectSlug or ""):gsub('"', '\\"') .. '",\n'
            .. '        server_url="' .. serverUrl:gsub('"', '\\"') .. '",\n'
            .. '        shot_key="' .. shotKey .. '",\n'
            .. '    )\n'
            .. '    print(json.dumps(result))\n'
            .. 'except Exception as e:\n'
            .. '    print(json.dumps({"status":"error","error":str(e),"trace":traceback.format_exc()}))\n'

        local result = runPython(code)
        local jsonStr = result and result:match("(%{.+%})")
        if jsonStr then
            local data = JSON.decode(jsonStr)
            if data and data.status == "ok" then
                syncCount = syncCount + 1
                print("[ScriptToScreen] Lip-synced " .. shotKey .. " → " .. (data.filename or ""))
            else
                failCount = failCount + 1
                print("[ScriptToScreen] Lip-sync FAILED for " .. shotKey .. ": " .. (data and data.error or "unknown"))
                if data and data.trace then print(data.trace) end
            end
        else
            failCount = failCount + 1
            print("[ScriptToScreen] Lip-sync FAILED for " .. shotKey .. ": no output")
            if result then print(result) end
        end
    end

    os.remove(keyfile)

    if syncCount > 0 then
        local msg = "Lip-synced " .. tostring(syncCount) .. " of " .. tostring(#pairs) .. " clips!"
        if failCount > 0 then
            msg = msg .. " (" .. tostring(failCount) .. " failed)"
        end
        itm.LipSyncProgress.Text = msg
        itm.LipSyncProgress.StyleSheet = "color: green; font-weight: bold;"
    else
        itm.LipSyncProgress.Text = "All " .. tostring(#pairs) .. " clips failed. Check console."
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
    local videoFileList = {}
    local audioFileList = {}

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

    -- Collect ALL original videos first, then overlay with lip-synced versions
    local origVideoFiles = {}
    local lipsyncVideoFiles = {}
    collectFiles(videoDir, "*.mp4", origVideoFiles)
    collectFiles(lipsyncDir, "*.mp4", lipsyncVideoFiles)

    -- Collect audio: prefer merged > dialogue_audio > audio root
    local mergedAudioDir = audioDir .. "/merged"
    local dialogueAudioDir = audioDir .. "/dialogue_audio"
    collectFiles(mergedAudioDir, "*.wav", audioFileList)
    collectFiles(mergedAudioDir, "*.mp3", audioFileList)
    collectFiles(dialogueAudioDir, "*.wav", audioFileList)
    collectFiles(dialogueAudioDir, "*.mp3", audioFileList)
    collectFiles(audioDir, "*.wav", audioFileList)
    collectFiles(audioDir, "*.mp3", audioFileList)

    if #origVideoFiles == 0 and #lipsyncVideoFiles == 0 and #imageFiles == 0 then
        itm.AssemblyProgress.Text = "No media files found to assemble."
        itm.AssemblyProgress.StyleSheet = "color: red;"
        return
    end

    -- ---------------------------------------------------------------
    -- Build shot-key-indexed maps for video and audio files
    -- ---------------------------------------------------------------
    local function extractShotKey(filepath)
        local basename = filepath:match("([^/]+)$") or ""
        local key = basename:match("(s%d+_sh%d+)")
        return key
    end

    -- Map shot_key -> video: start with originals, then overlay lip-synced
    local videoByKey = {}
    for _, vf in ipairs(origVideoFiles) do
        local sk = extractShotKey(vf)
        if sk then videoByKey[sk] = vf end
    end
    -- Lip-synced versions override originals where available
    local lipsyncedKeys = {}  -- track which shots have lip-synced video (with embedded audio)
    for _, vf in ipairs(lipsyncVideoFiles) do
        local sk = extractShotKey(vf)
        if sk then
            videoByKey[sk] = vf
            lipsyncedKeys[sk] = true
        end
    end

    -- Map shot_key -> audio file path (first match wins — merged has priority
    -- because merged files are collected first above)
    local audioByKey = {}
    for _, af in ipairs(audioFileList) do
        local sk = extractShotKey(af)
        if sk and not audioByKey[sk] then
            audioByKey[sk] = af
        end
    end

    -- Build ordered shot key list from ALL videos (sorted)
    local orderedKeys = {}
    for sk, _ in pairs(videoByKey) do
        table.insert(orderedKeys, sk)
    end
    table.sort(orderedKeys)

    -- Import images to "ScriptToScreen/Images" sub-bin
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
        for _, imgPath in ipairs(imageFiles) do
            local items = mediaPool:ImportMedia({imgPath}) or {}
            for _, item in ipairs(items) do
                table.insert(importedImages, item)
            end
        end
        if stsBin then
            mediaPool:SetCurrentFolder(stsBin)
        end
    end

    -- ---------------------------------------------------------------
    -- Import video and audio files, mapping by shot key
    -- ---------------------------------------------------------------
    -- Import each video individually so we can track which item is which
    local videoItemByKey = {}
    for _, sk in ipairs(orderedKeys) do
        local vpath = videoByKey[sk]
        local items = mediaPool:ImportMedia({vpath}) or {}
        if #items > 0 then
            videoItemByKey[sk] = items[1]
        end
    end

    -- Import each audio individually
    local audioItemByKey = {}
    for sk, apath in pairs(audioByKey) do
        local items = mediaPool:ImportMedia({apath}) or {}
        if #items > 0 then
            audioItemByKey[sk] = items[1]
        end
    end

    -- Create timeline
    local actualTimelineName = timelineName
    local timeline = mediaPool:CreateEmptyTimeline(actualTimelineName)
    if not timeline then
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

    -- ---------------------------------------------------------------
    -- Append clips in shot-key order
    -- Lip-synced clips: full video+audio (Kling bakes audio into the MP4)
    -- Non-dialogue clips: video only (no embedded audio to include)
    -- Standalone merged audio files stay in the bin for reference
    -- ---------------------------------------------------------------
    local appendCount = 0
    local lipsyncAppendCount = 0
    local appendOk, appendErr = pcall(function()
        for _, sk in ipairs(orderedKeys) do
            local videoItem = videoItemByKey[sk]

            if videoItem then
                if lipsyncedKeys[sk] then
                    -- Lip-synced clip: append with BOTH video and audio
                    -- (Kling already embedded the dialogue audio into the MP4)
                    local vResult = mediaPool:AppendToTimeline({videoItem})
                    if vResult and #vResult > 0 then
                        appendCount = appendCount + 1
                        lipsyncAppendCount = lipsyncAppendCount + 1
                    end
                else
                    -- Non-dialogue clip: append video only
                    local vResult = mediaPool:AppendToTimeline({{
                        mediaPoolItem = videoItem,
                        mediaType = 1,
                        trackIndex = 1,
                    }})
                    if vResult and #vResult > 0 then
                        appendCount = appendCount + 1
                    end
                end
            end
        end

        -- Fallback: if dict-style append failed, try simple append
        if appendCount == 0 and #orderedKeys > 0 then
            local allVideoItems = {}
            for _, sk in ipairs(orderedKeys) do
                if videoItemByKey[sk] then
                    table.insert(allVideoItems, videoItemByKey[sk])
                end
            end
            if #allVideoItems > 0 then
                local result = mediaPool:AppendToTimeline(allVideoItems)
                if result and #result > 0 then
                    appendCount = #result
                end
            end
        end
    end)
    if not appendOk then
        itm.AssemblyProgress.Text = "Warning: " .. tostring(appendErr)
        itm.AssemblyProgress.StyleSheet = "color: orange;"
    end

    itm.AssemblyProgress.Text = "Timeline '" .. actualTimelineName .. "' created with " .. tostring(appendCount) .. " clips (" .. tostring(lipsyncAppendCount) .. " lip-synced)!"
    itm.AssemblyProgress.StyleSheet = "color: green; font-weight: bold;"

    -- Update summary
    local summary = "Timeline: " .. actualTimelineName .. "\n"
        .. "Image files in bin: " .. tostring(#imageFiles) .. "\n"
        .. "Total clips: " .. tostring(appendCount) .. "\n"
        .. "Lip-synced (with dialogue): " .. tostring(lipsyncAppendCount) .. "\n"
        .. "Video-only (no dialogue): " .. tostring(appendCount - lipsyncAppendCount) .. "\n"
        .. "Total shot keys: " .. tostring(#orderedKeys)
    itm.AssemblySummary.PlainText = summary
end

-- ============================================================
-- PROMPT REVIEW PAGES (Step 5 Images, Step 7 Videos)
-- ============================================================

-- Serialize the screenplay path into a form suitable for Python string literals.
local function safePyString(s)
    return (s or ""):gsub("\\", "\\\\"):gsub('"', '\\"')
end

-- Load auto prompts for every shot via a single Python call.
-- Fills either autoImagePrompts or autoVideoPrompts depending on `kind`.
local function loadAutoPrompts(kind)
    if not screenplayData then return end
    local path = itm.ScriptPath and itm.ScriptPath.Text or ""
    if path == "" then return end

    local safePath = safePyString(path)
    local fn = (kind == "image") and "build_all_image_prompts" or "build_all_motion_prompts"
    local mod = (kind == "image") and "image_gen" or "video_gen"

    local code = 'import json, traceback\n'
        .. 'try:\n'
        .. '    from script_to_screen.parsing.pdf_parser import parse_pdf\n'
        .. '    from script_to_screen.parsing.fountain_parser import parse_fountain\n'
        .. '    from script_to_screen.pipeline.' .. mod .. ' import ' .. fn .. '\n'
        .. '    p = "' .. safePath .. '"\n'
        .. '    if p.lower().endswith(".pdf"):\n'
        .. '        sp = parse_pdf(p)\n'
        .. '    else:\n'
        .. '        sp = parse_fountain(p)\n'
        .. '    print(json.dumps({"status":"ok","prompts":' .. fn .. '(sp)}))\n'
        .. 'except Exception as e:\n'
        .. '    print(json.dumps({"status":"error","error":str(e),"trace":traceback.format_exc()}))\n'

    local result = runPython(code)
    local jsonStr = result and result:match("(%{.+%})")
    if not jsonStr then return end
    local data = JSON.decode(jsonStr)
    if not data or data.status ~= "ok" or type(data.prompts) ~= "table" then return end

    if kind == "image" then
        autoImagePrompts = data.prompts
    else
        autoVideoPrompts = data.prompts
    end
end

-- Compute what will actually be sent at generation time for a shot:
-- user override if set, otherwise the auto prompt. Empty string if neither exists.
local function effectivePromptFor(kind, shotKey)
    local overrides = (kind == "image") and imagePromptOverrides or videoPromptOverrides
    local autos = (kind == "image") and autoImagePrompts or autoVideoPrompts
    if overrides[shotKey] ~= nil then return overrides[shotKey] end
    return autos[shotKey] or ""
end

local function approvedCount(kind)
    local approved = (kind == "image") and imagePromptApproved or videoPromptApproved
    local n = 0
    for _, v in pairs(approved) do if v then n = n + 1 end end
    return n
end

-- Update status label and tree row badges for the given review kind.
local function refreshReviewStatus(kind)
    if not screenplayData or not screenplayData.scenes then return end
    local tree = (kind == "image") and itm.ImageReviewTree or itm.VideoReviewTree
    local statusLbl = (kind == "image") and itm.ImageReviewStatus or itm.VideoReviewStatus
    local overrides = (kind == "image") and imagePromptOverrides or videoPromptOverrides
    local approved = (kind == "image") and imagePromptApproved or videoPromptApproved

    local total = 0
    for _, scene in ipairs(screenplayData.scenes) do
        total = total + #(scene.shots or {})
    end
    statusLbl.Text = tostring(approvedCount(kind)) .. " of " .. tostring(total) .. " approved"
end

-- Populate a review tree with one row per shot.
-- (Assigns to the forward-declared `populateReviewTree` so `showStep`
-- above can reach it.)
populateReviewTree = function(kind)
    if not screenplayData or not screenplayData.scenes then return end
    local tree = (kind == "image") and itm.ImageReviewTree or itm.VideoReviewTree
    local overrides = (kind == "image") and imagePromptOverrides or videoPromptOverrides
    local approved = (kind == "image") and imagePromptApproved or videoPromptApproved

    -- Build auto prompts if we don't have them yet
    local autos = (kind == "image") and autoImagePrompts or autoVideoPrompts
    local hasAutos = false
    for _ in pairs(autos) do hasAutos = true; break end
    if not hasAutos then loadAutoPrompts(kind) end

    local hdr = tree:NewItem()
    hdr.Text[0] = "Scene"
    hdr.Text[1] = "Shot"
    hdr.Text[2] = "Type"
    hdr.Text[3] = "State"
    hdr.Text[4] = "Prompt preview"
    tree:SetHeaderItem(hdr)
    tree.ColumnCount = 5
    tree.ColumnWidth[0] = 60
    tree.ColumnWidth[1] = 40
    tree.ColumnWidth[2] = 50
    tree.ColumnWidth[3] = 90
    tree.ColumnWidth[4] = 500

    tree:Clear()
    for _, scene in ipairs(screenplayData.scenes) do
        for _, shot in ipairs(scene.shots or {}) do
            local shotKey = "s" .. tostring(scene.index) .. "_sh" .. tostring(shot.index or 0)
            local item = tree:NewItem()
            item.Text[0] = tostring(scene.index)
            item.Text[1] = tostring((shot.index or 0) + 1)
            item.Text[2] = shot.shot_type or ""
            local edited = (overrides[shotKey] ~= nil)
            local ok = approved[shotKey] == true
            local state = "Auto"
            if edited and ok then state = "Edited \xE2\x9C\x93"
            elseif edited then state = "Edited"
            elseif ok then state = "\xE2\x9C\x93 Approved" end
            item.Text[3] = state
            local preview = effectivePromptFor(kind, shotKey)
            if #preview > 120 then preview = preview:sub(1, 117) .. "..." end
            item.Text[4] = preview
            -- Color hint: green approved, orange edited, default otherwise
            pcall(function()
                if ok then
                    item.TextColor[3] = {R = 0.4, G = 0.85, B = 0.4, A = 1}
                elseif edited then
                    item.TextColor[3] = {R = 0.95, G = 0.65, B = 0.35, A = 1}
                end
            end)
            tree:AddTopLevelItem(item)
        end
    end

    refreshReviewStatus(kind)
end

-- Get the shot_key for the currently-selected tree row.
local function selectedShotKey(kind)
    local tree = (kind == "image") and itm.ImageReviewTree or itm.VideoReviewTree
    local item = tree:CurrentItem()
    if not item then return nil end
    local sceneIdx = tonumber(item.Text[0])
    local shotDisplay = tonumber(item.Text[1])
    if not sceneIdx or not shotDisplay then return nil end
    return "s" .. tostring(sceneIdx) .. "_sh" .. tostring(shotDisplay - 1)
end

-- Row click → populate the TextEdit with the effective prompt (override > auto).
function win.On.ImageReviewTree.ItemClicked(ev)
    local sk = selectedShotKey("image")
    if not sk then return end
    itm.ImageReviewEdit.PlainText = effectivePromptFor("image", sk)
end
function win.On.VideoReviewTree.ItemClicked(ev)
    local sk = selectedShotKey("video")
    if not sk then return end
    itm.VideoReviewEdit.PlainText = effectivePromptFor("video", sk)
end

-- Save Edit: persist current TextEdit content as override; mark approved.
function win.On.ImageSaveEdit.Clicked(ev)
    local sk = selectedShotKey("image")
    if not sk then return end
    imagePromptOverrides[sk] = itm.ImageReviewEdit.PlainText or ""
    imagePromptApproved[sk] = true
    populateReviewTree("image")
end
function win.On.VideoSaveEdit.Clicked(ev)
    local sk = selectedShotKey("video")
    if not sk then return end
    videoPromptOverrides[sk] = itm.VideoReviewEdit.PlainText or ""
    videoPromptApproved[sk] = true
    populateReviewTree("video")
end

-- Reset to Auto: drop override and approval for this shot.
function win.On.ImageResetAuto.Clicked(ev)
    local sk = selectedShotKey("image")
    if not sk then return end
    imagePromptOverrides[sk] = nil
    imagePromptApproved[sk] = nil
    itm.ImageReviewEdit.PlainText = autoImagePrompts[sk] or ""
    populateReviewTree("image")
end
function win.On.VideoResetAuto.Clicked(ev)
    local sk = selectedShotKey("video")
    if not sk then return end
    videoPromptOverrides[sk] = nil
    videoPromptApproved[sk] = nil
    itm.VideoReviewEdit.PlainText = autoVideoPrompts[sk] or ""
    populateReviewTree("video")
end

-- Approve This Shot: mark the current shot approved without changing its text.
function win.On.ImageApproveOne.Clicked(ev)
    local sk = selectedShotKey("image")
    if not sk then return end
    imagePromptApproved[sk] = true
    populateReviewTree("image")
end
function win.On.VideoApproveOne.Clicked(ev)
    local sk = selectedShotKey("video")
    if not sk then return end
    videoPromptApproved[sk] = true
    populateReviewTree("video")
end

-- Approve All: mark every shot approved.
function win.On.ImageApproveAll.Clicked(ev)
    if not screenplayData then return end
    for _, scene in ipairs(screenplayData.scenes) do
        for _, shot in ipairs(scene.shots or {}) do
            local sk = "s" .. tostring(scene.index) .. "_sh" .. tostring(shot.index or 0)
            imagePromptApproved[sk] = true
        end
    end
    populateReviewTree("image")
end
function win.On.VideoApproveAll.Clicked(ev)
    if not screenplayData then return end
    for _, scene in ipairs(screenplayData.scenes) do
        for _, shot in ipairs(scene.shots or {}) do
            local sk = "s" .. tostring(scene.index) .. "_sh" .. tostring(shot.index or 0)
            videoPromptApproved[sk] = true
        end
    end
    populateReviewTree("video")
end

-- Refresh Auto Prompts: re-call Python to rebuild autos (useful after
-- editing character refs, changing model, etc.).
function win.On.ImageRefreshAuto.Clicked(ev)
    autoImagePrompts = {}
    loadAutoPrompts("image")
    populateReviewTree("image")
end
function win.On.VideoRefreshAuto.Clicked(ev)
    autoVideoPrompts = {}
    loadAutoPrompts("video")
    populateReviewTree("video")
end

-- Serialize overrides to a JSON string payload for custom_prompts= passthrough.
-- Only includes explicitly-edited shots; auto prompts are left to the backend.
local function overridesJson(kind)
    local overrides = (kind == "image") and imagePromptOverrides or videoPromptOverrides
    local parts = {}
    for k, v in pairs(overrides) do
        local safeK = k:gsub('"', '\\"')
        local safeV = v:gsub("\\", "\\\\"):gsub('"', '\\"'):gsub("\n", "\\n"):gsub("\r", "")
        table.insert(parts, '"' .. safeK .. '":"' .. safeV .. '"')
    end
    return "{" .. table.concat(parts, ",") .. "}"
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
            -- Python-format shot key (matches generatedImages / failedImages keys)
            local shotKey = "s" .. tostring(scene.index) .. "_sh" .. tostring(shot.index or 0)
            if generatedImages[shotKey] then
                item.Text[4] = "Done"
                pcall(function() item.TextColor[4] = {R = 0.4, G = 0.85, B = 0.4, A = 1} end)
            elseif failedImages[shotKey] then
                item.Text[4] = "Failed"
                pcall(function() item.TextColor[4] = {R = 0.95, G = 0.35, B = 0.35, A = 1} end)
            else
                item.Text[4] = "Pending"
            end
            itm.ImageTree:AddTopLevelItem(item)
        end
    end
    -- Update the Retry Failed button label with count (if button exists yet)
    pcall(function()
        local n = 0
        for _ in pairs(failedImages) do n = n + 1 end
        if n > 0 then
            itm.RetryFailedImages.Text = "Retry Failed (" .. tostring(n) .. ")"
            itm.RetryFailedImages.Enabled = true
        else
            itm.RetryFailedImages.Text = "Retry Failed"
            itm.RetryFailedImages.Enabled = false
        end
    end)
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

local function populateDialogueTree()
    if not screenplayData or not screenplayData.scenes then return end

    local hdr = itm.DialogueTree:NewItem()
    hdr.Text[0] = "Scene"
    hdr.Text[1] = "Shot"
    hdr.Text[2] = "Character"
    hdr.Text[3] = "Dialogue"
    itm.DialogueTree:SetHeaderItem(hdr)
    itm.DialogueTree.ColumnCount = 4
    itm.DialogueTree.ColumnWidth[0] = 50
    itm.DialogueTree.ColumnWidth[1] = 50
    itm.DialogueTree.ColumnWidth[2] = 100
    itm.DialogueTree.ColumnWidth[3] = 350

    itm.DialogueTree:Clear()
    for _, scene in ipairs(screenplayData.scenes) do
        local dlLines = scene.dialogue_lines or scene.dialogue or {}
        if type(dlLines) == "number" then
            -- dialogue is just a count, not the actual lines
        else
            for _, dl in ipairs(dlLines) do
                local item = itm.DialogueTree:NewItem()
                item.Text[0] = tostring(scene.index or 0)
                item.Text[1] = tostring(dl.shot_index or 0)
                item.Text[2] = dl.character or ""
                local text = dl.text or ""
                if #text > 60 then text = text:sub(1, 57) .. "..." end
                item.Text[3] = text
                itm.DialogueTree:AddTopLevelItem(item)
            end
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
    elseif nextStep == 8 then  -- Entering Dialogue Generation (Step 8)
        populateDialogueTree()
    end
    _origOnNext()
end

-- Re-wire Next buttons to use the overridden onNext
function win.On.NextBtn.Clicked(ev) onNext() end
function win.On.NextBtn2.Clicked(ev) onNext() end
function win.On.NextBtn3.Clicked(ev) onNext() end
function win.On.NextBtn4.Clicked(ev) onNext() end
function win.On.NextBtn7.Clicked(ev) onNext() end
function win.On.NextBtn8.Clicked(ev) onNext() end
function win.On.NextBtn9.Clicked(ev) onNext() end
function win.On.NextBtn10.Clicked(ev) onNext() end
function win.On.NextBtn11.Clicked(ev) onNext() end

-- ============================================================
-- SHOW AND RUN
-- ============================================================

showStep(1)
win:Show()
disp:RunLoop()
win:Hide()
