-- STS_Common.lua — Shared infrastructure for ScriptToScreen standalone tools
-- Loaded via dofile() by each STS_*.lua script

-- ============================================================
-- GLOBALS (set by calling script before dofile)
-- ============================================================
-- ui, disp must be set by the calling script:
--   local ui = fu.UIManager
--   local disp = bmd.UIDispatcher(ui)

local homeDir = os.getenv("HOME") or "/Users/capricorn"
STS_homeDir = homeDir
STS_userPackageDir = homeDir .. "/Library/Application Support/ScriptToScreen/"
STS_outputBaseDir = homeDir .. "/Library/Application Support/ScriptToScreen/projects"

-- ============================================================
-- MINIMAL JSON DECODER/ENCODER
-- ============================================================

STS_JSON = {}

function STS_JSON.decode(str)
    if not str or str == "" then return nil end
    str = str:match("^%s*(.-)%s*$")
    if str == "" then return nil end
    local pos = 1
    local function ch() return str:sub(pos, pos) end
    local function skip_ws()
        while pos <= #str and str:sub(pos, pos):match("[ \t\n\r]") do pos = pos + 1 end
    end
    local parse_value
    local function parse_string()
        pos = pos + 1
        local parts = {}
        while pos <= #str do
            local c = str:sub(pos, pos)
            if c == '"' then pos = pos + 1; return table.concat(parts)
            elseif c == '\\' then
                pos = pos + 1; c = str:sub(pos, pos)
                if c == 'n' then table.insert(parts, '\n')
                elseif c == 't' then table.insert(parts, '\t')
                elseif c == '"' then table.insert(parts, '"')
                elseif c == '\\' then table.insert(parts, '\\')
                elseif c == '/' then table.insert(parts, '/')
                elseif c == 'u' then pos = pos + 4; table.insert(parts, '?')
                else table.insert(parts, c) end
            else table.insert(parts, c) end
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
        pos = pos + 1; skip_ws()
        local obj = {}
        if ch() == '}' then pos = pos + 1; return obj end
        while true do
            skip_ws()
            if ch() ~= '"' then break end
            local key = parse_string(); skip_ws()
            if ch() == ':' then pos = pos + 1 end; skip_ws()
            obj[key] = parse_value(); skip_ws()
            if ch() == ',' then pos = pos + 1
            elseif ch() == '}' then pos = pos + 1; return obj
            else break end
        end
        return obj
    end
    local function parse_array()
        pos = pos + 1; skip_ws()
        local arr = {}
        if ch() == ']' then pos = pos + 1; return arr end
        while true do
            skip_ws(); table.insert(arr, parse_value()); skip_ws()
            if ch() == ',' then pos = pos + 1
            elseif ch() == ']' then pos = pos + 1; return arr
            else break end
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

function STS_JSON.encode(val)
    if val == nil then return "null" end
    local t = type(val)
    if t == "string" then
        return '"' .. val:gsub('\\', '\\\\'):gsub('"', '\\"'):gsub('\n', '\\n'):gsub('\r', '\\r'):gsub('\t', '\\t') .. '"'
    elseif t == "number" then return tostring(val)
    elseif t == "boolean" then return val and "true" or "false"
    elseif t == "table" then
        if #val > 0 or next(val) == nil then
            local isArray = true
            for k in pairs(val) do if type(k) ~= "number" then isArray = false; break end end
            if isArray then
                local items = {}
                for _, v in ipairs(val) do table.insert(items, STS_JSON.encode(v)) end
                return "[" .. table.concat(items, ",") .. "]"
            end
        end
        local items = {}
        for k, v in pairs(val) do
            table.insert(items, '"' .. tostring(k) .. '":' .. STS_JSON.encode(v))
        end
        return "{" .. table.concat(items, ",") .. "}"
    end
    return "null"
end

-- ============================================================
-- FILE UTILITIES
-- ============================================================

function STS_fileExists(path)
    local f = io.open(path, "r")
    if f then f:close(); return true end
    return false
end

-- ============================================================
-- PYTHON BRIDGE
-- ============================================================

-- Locate the Python package
STS_packageDir = nil
local searchPaths = {
    STS_userPackageDir,
    "/Library/Application Support/Blackmagic Design/DaVinci Resolve/Fusion/Scripts/Utility/",
}
for _, dir in ipairs(searchPaths) do
    if STS_fileExists(dir .. "script_to_screen/__init__.py") then
        STS_packageDir = dir
        break
    end
end

-- Locate Python interpreter
local venvPython = STS_userPackageDir .. "venv/bin/python3"
STS_pythonCmd = "python3"
if STS_fileExists(venvPython) then
    STS_pythonCmd = '"' .. venvPython .. '"'
end

function STS_runPython(code)
    local tmpfile = os.tmpname() .. ".py"
    local f = io.open(tmpfile, "w")
    if not f then return nil, "Cannot create temp file" end

    local preamble = "import sys, os, json\n"
        .. 'sys.path.insert(0, "/Library/Application Support/Blackmagic Design/DaVinci Resolve/Developer/Scripting/Modules")\n'
        .. 'sys.path.insert(0, "' .. (STS_packageDir or STS_userPackageDir) .. '")\n'
        .. "\n"

    f:write(preamble .. code)
    f:close()

    local outfile = os.tmpname()
    local cmd = STS_pythonCmd .. ' "' .. tmpfile .. '" > "' .. outfile .. '" 2>&1'
    os.execute(cmd)

    local out = io.open(outfile, "r")
    local result = ""
    if out then result = out:read("*a"); out:close() end
    os.remove(tmpfile)
    os.remove(outfile)
    return result
end

-- ============================================================
-- CONFIG
-- ============================================================

STS_configPath = STS_userPackageDir .. "config.json"

function STS_loadConfig()
    local config = {
        imageProvider = "freepik",
        videoProvider = "freepik",
        voiceProvider = "elevenlabs",
        providers = {
            freepik    = { apiKey = "" },
            elevenlabs = { apiKey = "" },
            grok       = { apiKey = "" },
            comfyui    = { serverUrl = "http://127.0.0.1:8188" },
            voicebox   = { serverUrl = "http://127.0.0.1:17493" },
        },
        model = "realism",
        aspectRatio = "widescreen_16_9",
        detailing = 33,
    }
    local f = io.open(STS_configPath, "r")
    if f then
        local raw = f:read("*a"); f:close()
        local saved = STS_JSON.decode(raw)
        if saved then
            config.imageProvider = saved.imageProvider or config.imageProvider
            config.videoProvider = saved.videoProvider or config.videoProvider
            config.voiceProvider = saved.voiceProvider or config.voiceProvider
            config.model = saved.model or config.model
            config.aspectRatio = saved.aspectRatio or config.aspectRatio
            config.detailing = saved.detailing or config.detailing
            config.episodeNumber = saved.episodeNumber or ""
            config.episodeTitle = saved.episodeTitle or ""
            if saved.providers then
                for pid, pdata in pairs(saved.providers) do
                    if config.providers[pid] then
                        for k, v in pairs(pdata) do config.providers[pid][k] = v end
                    else
                        config.providers[pid] = pdata
                    end
                end
            end
        end
    end
    return config
end

function STS_saveConfig(config)
    local f = io.open(STS_configPath, "w")
    if f then f:write(STS_JSON.encode(config)); f:close() end
end

-- ============================================================
-- PROVIDER LISTS
-- ============================================================

STS_imageProviders = {
    {id = "freepik",      name = "Freepik (Cloud — Mystic, Flux, Seedream, etc.)"},
    {id = "openai",       name = "OpenAI (Cloud — gpt-image, dall-e)"},
    {id = "gemini",       name = "Google Gemini / Imagen (Cloud)"},
    {id = "grok",         name = "Grok Imagine (Cloud)"},
    {id = "comfyui_flux", name = "Flux Kontext (Local ComfyUI)"},
}

STS_videoProviders = {
    {id = "freepik",      name = "Freepik (Cloud — Kling, Seedance, MiniMax, Wan)"},
    {id = "openai",       name = "OpenAI Sora (Cloud)"},
    {id = "grok",         name = "Grok Imagine Video (Cloud)"},
    {id = "comfyui_ltx",  name = "LTX 2.3 (Local ComfyUI)"},
}

STS_voiceProviders = {
    {id = "mlx_audio",    name = "MLX-Audio Kokoro (Local, Fast)"},
    {id = "voicebox",     name = "Voicebox (Local, Slow)"},
    {id = "elevenlabs",   name = "ElevenLabs (Cloud)"},
}

STS_lipsyncProviders = {
    {id = "kling",        name = "Kling AI Lip Sync (Direct API)"},
    {id = "freepik",      name = "Kling via Freepik (Cloud)"},
}

-- ============================================================
-- PER-PROVIDER MODEL LISTS
-- ============================================================
-- Single source of truth, mirrored from the matching constants in
-- script_to_screen/api/*_client.py and script_to_screen/config.py.
-- The standalone tools (Reprompt Image / Video, Generate Audio) read
-- these to populate their Model dropdown when the user picks a
-- provider, so a fresh-mode generation doesn't have to inherit the
-- wizard's last-saved model choice.

-- Freepik image-API endpoints. Each value is the FreepikImageProvider's
-- ``freepik_image_api`` kwarg.
STS_freepikImageApis = {
    "mystic", "flux-dev", "flux-pro-v1-1",
    "flux-2-pro", "flux-2-turbo", "flux-2-klein",
    "flux-kontext-pro", "hyperflux",
    "seedream-4", "seedream-v4-5", "z-image-turbo", "runway",
}

-- OpenAI image gen models. gpt-image-1 is default — gpt-image-2 needs
-- org verification.
STS_openaiImageModels = {"gpt-image-1", "gpt-image-2", "dall-e-3", "dall-e-2"}

-- Google AI Studio image-gen models (Gemini multimodal + Imagen).
-- Order matches gemini_image_client.SUPPORTED_MODELS (recommended-first).
STS_geminiImageModels = {
    "gemini-2.5-flash-image",
    "gemini-3.1-flash-image-preview",
    "gemini-3-pro-image-preview",
    "imagen-4.0-generate-001",
    "imagen-4.0-ultra-generate-001",
    "imagen-4.0-fast-generate-001",
}

-- Display labels for the Gemini combo. The Nano Banana family doesn't
-- self-identify in its model id, so users picking from the dropdown
-- don't recognize which is which without the colloquial name. Labels
-- include the full id so the user still sees what the API receives.
STS_geminiLabelById = {
    ["gemini-2.5-flash-image"]         = "gemini-2.5-flash-image (standard Nano Banana)",
    ["gemini-3.1-flash-image-preview"] = "gemini-3.1-flash-image-preview (Nano Banana 2)",
    ["gemini-3-pro-image-preview"]     = "gemini-3-pro-image-preview (Nano Banana Pro)",
    ["imagen-4.0-generate-001"]        = "imagen-4.0-generate-001 (Imagen 4 standard)",
    ["imagen-4.0-ultra-generate-001"]  = "imagen-4.0-ultra-generate-001 (Imagen 4 ultra)",
    ["imagen-4.0-fast-generate-001"]   = "imagen-4.0-fast-generate-001 (Imagen 4 fast)",
}
function STS_geminiIdToLabel(id) return STS_geminiLabelById[id] or id end
function STS_geminiLabelToId(lbl)
    if not lbl or lbl == "" then return "gemini-2.5-flash-image" end
    return (lbl:match("^([^%s]+)") or lbl)
end

-- Freepik video-API endpoints, mirrors VIDEO_ENDPOINTS in freepik_client.
STS_freepikVideoModels = {
    "kling-v3-omni", "kling-v2-5-pro", "kling-v2-6-pro", "kling-o1-pro",
    "seedance-pro-1080p", "minimax-hailuo-2-3", "wan-v2-6-1080p",
}

-- OpenAI Sora variants.
STS_openaiVideoModels = {"sora-2", "sora-1"}

-- Returns the list of model ids the standalone tool should show for a
-- given (category, provider) combination, plus the config key the
-- saved value lives under, plus a sensible default. Returns nil when
-- the provider has no per-model choice (Grok, ComfyUI), so callers can
-- hide the Model row entirely.
function STS_getImageModelsForProvider(providerId)
    if providerId == "freepik" then
        return {items = STS_freepikImageApis, configKey = "freepikImageApi", default = "mystic"}
    elseif providerId == "openai" then
        return {items = STS_openaiImageModels, configKey = "openaiModel", default = "gpt-image-1"}
    elseif providerId == "gemini" then
        return {items = STS_geminiImageModels, configKey = "geminiModel", default = "gemini-2.5-flash-image"}
    end
    return nil
end

function STS_getVideoModelsForProvider(providerId)
    if providerId == "freepik" then
        return {items = STS_freepikVideoModels, configKey = "videoModel", default = "kling-v3-omni"}
    elseif providerId == "openai" then
        return {items = STS_openaiVideoModels, configKey = "openaiVideoModel", default = "sora-2"}
    end
    return nil
end

-- ============================================================
-- RESOLVE HELPERS
-- ============================================================

function STS_getProviderApiKey(config, providerId)
    if config.providers[providerId] then
        return config.providers[providerId].apiKey or ""
    end
    return ""
end

function STS_getProviderServerUrl(config, providerId)
    if config.providers[providerId] then
        return config.providers[providerId].serverUrl or ""
    end
    return ""
end

function STS_getResolveProjectSlug()
    local result = STS_runPython(
        'try:\n'
        .. '    import DaVinciResolveScript as dvr\n'
        .. '    resolve = dvr.scriptapp("Resolve")\n'
        .. '    pm = resolve.GetProjectManager()\n'
        .. '    proj = pm.GetCurrentProject()\n'
        .. '    import re\n'
        .. '    name = proj.GetName() if proj else "default"\n'
        .. '    slug = re.sub(r"[^\\w\\-]", "_", name).strip("_").lower() or "default"\n'
        .. '    print(json.dumps({"name": name, "slug": slug}))\n'
        .. 'except Exception as e:\n'
        .. '    print(json.dumps({"name": "default", "slug": "default", "error": str(e)}))\n'
    )
    local jsonStr = result and result:match("(%{.+%})")
    if jsonStr then
        local data = STS_JSON.decode(jsonStr)
        if data then return data.slug or "default", data.name or "default" end
    end
    return "default", "default"
end

function STS_getOutputDir(projectSlug)
    local dir = STS_outputBaseDir .. "/" .. (projectSlug or "default")
    os.execute('mkdir -p "' .. dir .. '"')
    return dir
end

function STS_getSelectedMediaPoolClip()
    local result = STS_runPython(
        'try:\n'
        .. '    import DaVinciResolveScript as dvr\n'
        .. '    resolve = dvr.scriptapp("Resolve")\n'
        .. '    proj = resolve.GetProjectManager().GetCurrentProject()\n'
        .. '    mp = proj.GetMediaPool()\n'
        .. '    selected = mp.GetSelectedClips()\n'
        .. '    if selected and len(selected) > 0:\n'
        .. '        clip = selected[0]\n'
        .. '        meta = clip.GetMetadata() or {}\n'
        .. '        props = clip.GetClipProperty() or {}\n'
        .. '        print(json.dumps({"status":"ok", "name": clip.GetName(), "file_path": props.get("File Path",""), "comments": meta.get("Comments","")}))\n'
        .. '    else:\n'
        .. '        print(json.dumps({"status":"none"}))\n'
        .. 'except Exception as e:\n'
        .. '    print(json.dumps({"status":"error", "error": str(e)}))\n'
    )
    local jsonStr = result and result:match("(%{.+%})")
    if jsonStr then return STS_JSON.decode(jsonStr) end
    return {status = "error", error = "Failed to query media pool"}
end

function STS_getCurrentTimelineItem()
    local result = STS_runPython(
        'try:\n'
        .. '    import DaVinciResolveScript as dvr\n'
        .. '    resolve = dvr.scriptapp("Resolve")\n'
        .. '    proj = resolve.GetProjectManager().GetCurrentProject()\n'
        .. '    tl = proj.GetCurrentTimeline()\n'
        .. '    if tl:\n'
        .. '        item = tl.GetCurrentVideoItem()\n'
        .. '        if item:\n'
        .. '            mpi = item.GetMediaPoolItem()\n'
        .. '            meta = mpi.GetMetadata() if mpi else {}\n'
        .. '            props = mpi.GetClipProperty() if mpi else {}\n'
        .. '            print(json.dumps({"status":"ok", "name": mpi.GetName() if mpi else "", "file_path": props.get("File Path",""), "comments": (meta or {}).get("Comments","")}))\n'
        .. '        else:\n'
        .. '            print(json.dumps({"status":"none", "error":"No clip at playhead"}))\n'
        .. '    else:\n'
        .. '        print(json.dumps({"status":"none", "error":"No timeline open"}))\n'
        .. 'except Exception as e:\n'
        .. '    print(json.dumps({"status":"error", "error": str(e)}))\n'
    )
    local jsonStr = result and result:match("(%{.+%})")
    if jsonStr then return STS_JSON.decode(jsonStr) end
    return {status = "error", error = "Failed to query timeline"}
end

-- Extract STS filename from Comments metadata
function STS_extractFilename(comments)
    if not comments or comments == "" then return nil end
    local filename = comments:match("^STS:(.+)$")
    return filename
end

-- Build episode prefix from saved config
function STS_buildEpisodePrefix()
    local config = STS_loadConfig()
    local num = config.episodeNumber or ""
    local title = config.episodeTitle or ""
    if num == "" and title == "" then return "" end
    local sanitizedTitle = (title or ""):gsub("[^%w]", "")
    if num ~= "" and sanitizedTitle ~= "" then
        return "Ep" .. num .. "-" .. sanitizedTitle
    elseif num ~= "" then
        return "Ep" .. num
    else
        return sanitizedTitle
    end
end

-- Import a single file to the media pool and tag it with STS metadata
-- Uses scene-based bin structure: ScriptToScreen/{episodePrefix}/S{N}/{targetBinName}
function STS_importAndTag(filePath, targetBinName)
    local basename = filePath:match("([^/]+)$") or ""
    local shotKey = basename:match("^(s%d+_sh%d+)") or ""
    local epPrefix = STS_buildEpisodePrefix()
    local sceneNum = ""
    if shotKey ~= "" then
        sceneNum = shotKey:match("^s(%d+)") or ""
    end

    local safeFilePath = filePath:gsub("\\", "\\\\"):gsub('"', '\\"')
    local safeEpPrefix = epPrefix:gsub('"', '\\"')
    local safeBinName = (targetBinName or ""):gsub('"', '\\"')

    local result = STS_runPython(
        'try:\n'
        .. '    import os, re\n'
        .. '    import DaVinciResolveScript as dvr\n'
        .. '    resolve = dvr.scriptapp("Resolve")\n'
        .. '    proj = resolve.GetProjectManager().GetCurrentProject()\n'
        .. '    mp = proj.GetMediaPool()\n'
        .. '    root = mp.GetRootFolder()\n'
        .. '    def find_or_create(parent, name):\n'
        .. '        for f in (parent.GetSubFolders() or {}).values():\n'
        .. '            if f.GetName() == name: return f\n'
        .. '        return mp.AddSubFolder(parent, name)\n'
        .. '    sts_bin = find_or_create(root, "ScriptToScreen")\n'
        .. '    target = sts_bin\n'
        .. '    ep_prefix = "' .. safeEpPrefix .. '"\n'
        .. '    scene_num = "' .. sceneNum .. '"\n'
        .. '    bin_name = "' .. safeBinName .. '"\n'
        .. '    if ep_prefix:\n'
        .. '        target = find_or_create(target, ep_prefix)\n'
        .. '    if scene_num:\n'
        .. '        target = find_or_create(target, "S" + scene_num)\n'
        .. '    if bin_name:\n'
        .. '        target = find_or_create(target, bin_name)\n'
        .. '    mp.SetCurrentFolder(target)\n'
        .. '    items = mp.ImportMedia(["' .. safeFilePath .. '"])\n'
        .. '    if items and len(items) > 0:\n'
        .. '        filename = os.path.basename("' .. safeFilePath .. '")\n'
        .. '        items[0].SetMetadata("Comments", "STS:" + filename)\n'
        .. '        print(json.dumps({"status":"ok", "name": items[0].GetName()}))\n'
        .. '    else:\n'
        .. '        print(json.dumps({"status":"error", "error":"Import failed"}))\n'
        .. 'except Exception as e:\n'
        .. '    import traceback\n'
        .. '    print(json.dumps({"status":"error", "error": str(e), "trace": traceback.format_exc()}))\n'
    )
    local jsonStr = result and result:match("(%{.+%})")
    if jsonStr then return STS_JSON.decode(jsonStr) end
    return {status = "error", error = "Import failed"}
end

-- Populate a ComboBox from a provider list, selecting the saved ID
function STS_populateProviderCombo(comboWidget, providerList, savedId)
    comboWidget:Clear()
    local selectedIdx = 0
    for i, p in ipairs(providerList) do
        comboWidget:AddItem(p.name)
        if p.id == savedId then selectedIdx = i - 1 end
    end
    comboWidget.CurrentIndex = selectedIdx
end

function STS_getProviderIdFromCombo(comboWidget, providerList)
    local idx = (comboWidget.CurrentIndex or 0) + 1
    return providerList[idx] and providerList[idx].id or providerList[1].id
end
