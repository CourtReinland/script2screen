-- STS_Reprompt_Video.lua — Regenerate a video with an edited prompt
-- Access: Workspace > Scripts > Edit > STS_Reprompt_Video

local ui = fu.UIManager
local disp = bmd.UIDispatcher(ui)

local scriptDir = debug.getinfo(1, "S").source:match("@(.*[/\\])") or ""
if scriptDir == "" then
    scriptDir = "/Library/Application Support/Blackmagic Design/DaVinci Resolve/Fusion/Scripts/Edit/"
end
dofile(scriptDir .. "STS_Common.lua")

if not STS_packageDir then
    print("[STS] Python package not found"); return
end

local config = STS_loadConfig()
local projectSlug, projectName = STS_getResolveProjectSlug()
local outputDir = STS_getOutputDir(projectSlug)

-- ============================================================
-- DETECT CURRENT CLIP (media pool selection first — that's what the user clicked)
-- ============================================================

local clipInfo = STS_getSelectedMediaPoolClip()
if not clipInfo or clipInfo.status ~= "ok" or (clipInfo.comments or "") == "" then
    -- Fallback: try timeline playhead
    clipInfo = STS_getCurrentTimelineItem()
end

local prefillPrompt = ""
local prefillStartImage = ""
local prefillDuration = 5
local prefillShotKey = ""
local prefillProvider = config.videoProvider or "grok"

-- Map manifest provider class names to registry IDs
local providerNameToId = {
    GrokVideoProvider = "grok",
    FreepikVideoProvider = "freepik",
    ComfyUILTXVideoProvider = "comfyui_ltx",
}

local function lookupManifest(stsFilename)
    if not stsFilename or stsFilename == "" then return end
    local metaResult = STS_runPython(
        'from script_to_screen.manifest import lookup_by_filename\n'
        .. 'entry = lookup_by_filename("' .. projectSlug .. '", "' .. stsFilename .. '")\n'
        .. 'if entry:\n'
        .. '    print(json.dumps({"status":"ok", "data": entry}))\n'
        .. 'else:\n'
        .. '    print(json.dumps({"status":"not_found"}))\n'
    )
    local jsonStr = metaResult and metaResult:match("(%{.+%})")
    if jsonStr then
        local meta = STS_JSON.decode(jsonStr)
        if meta and meta.status == "ok" and meta.data then
            return meta.data
        end
    end
    return nil
end

if clipInfo and clipInfo.status == "ok" then
    local clipName = clipInfo.name or ""
    local stsFilename = STS_extractFilename(clipInfo.comments or "")

    -- Extract shot key from filename (s0_sh0_hash.mp4 → s0_sh0)
    local shotKeyFromName = clipName:match("^(s%d+_sh%d+)")
    if not shotKeyFromName and stsFilename then
        shotKeyFromName = stsFilename:match("^(s%d+_sh%d+)")
    end
    if shotKeyFromName then
        prefillShotKey = shotKeyFromName
    end

    -- Try manifest lookup first
    local meta = lookupManifest(stsFilename)
    if meta then
        prefillPrompt = meta.prompt or ""
        prefillStartImage = meta.start_image_path or ""
        prefillShotKey = meta.shot_key or prefillShotKey
        local ps = meta.provider_settings or {}
        prefillDuration = ps.duration or prefillDuration
        local rawProvider = meta.provider or ""
        prefillProvider = providerNameToId[rawProvider] or rawProvider
        if prefillProvider == "" then prefillProvider = config.videoProvider or "grok" end
    end

    -- If no prompt found in manifest, build one from the screenplay + find start image
    if prefillPrompt == "" and prefillShotKey ~= "" then
        local buildResult = STS_runPython(
            'import os, glob, re\n'
            .. 'from script_to_screen.manifest import load_manifest\n'
            .. 'm = load_manifest("' .. projectSlug .. '")\n'
            .. '# Find the screenplay path from config or last used\n'
            .. 'script_path = ""\n'
            .. 'for fn, e in m.get("generated_media", {}).items():\n'
            .. '    if e.get("type") == "image":\n'
            .. '        # Get the image path to find the project dir\n'
            .. '        fp = e.get("file_path", "")\n'
            .. '        if fp:\n'
            .. '            proj_dir = os.path.dirname(os.path.dirname(fp))\n'
            .. '            break\n'
            .. '# Find the latest start image for this shot key\n'
            .. 'shot_key = "' .. prefillShotKey .. '"\n'
            .. 'img_dir = "' .. outputDir:gsub("\\", "\\\\"):gsub('"', '\\"') .. '/images"\n'
            .. 'latest_img = ""\n'
            .. 'for f in sorted(glob.glob(os.path.join(img_dir, "*.jpg")) + glob.glob(os.path.join(img_dir, "*.png"))):\n'
            .. '    bn = os.path.splitext(os.path.basename(f))[0]\n'
            .. '    m2 = re.match(r"(s\\d+_sh\\d+)", bn)\n'
            .. '    if m2 and m2.group(1) == shot_key:\n'
            .. '        latest_img = f\n'
            .. '# Build the video prompt from the screenplay\n'
            .. 'prompt = ""\n'
            .. 'try:\n'
            .. '    from script_to_screen.parsing.pdf_parser import parse_pdf\n'
            .. '    from script_to_screen.pipeline.video_gen import build_motion_prompt\n'
            .. '    # Try to find the script path\n'
            .. '    import json as j2\n'
            .. '    cfg_path = os.path.expanduser("~/Library/Application Support/ScriptToScreen/config.json")\n'
            .. '    if os.path.isfile(cfg_path):\n'
            .. '        with open(cfg_path) as cf: cc = j2.load(cf)\n'
            .. '        sp = cc.get("lastScriptPath", "")\n'
            .. '        if not sp or not os.path.isfile(sp):\n'
            .. '            sp = "/Users/capricorn/Desktop/TestFiles/Test_Script.pdf"\n'
            .. '    else: sp = "/Users/capricorn/Desktop/TestFiles/Test_Script.pdf"\n'
            .. '    if os.path.isfile(sp):\n'
            .. '        screenplay = parse_pdf(sp)\n'
            .. '        parts = shot_key.split("_sh")\n'
            .. '        si = int(parts[0][1:])\n'
            .. '        shi = int(parts[1])\n'
            .. '        for scene in screenplay.scenes:\n'
            .. '            if scene.index == si and shi < len(scene.shots):\n'
            .. '                prompt = build_motion_prompt(scene.shots[shi], scene)\n'
            .. '                break\n'
            .. 'except: pass\n'
            .. 'print(json.dumps({"prompt": prompt, "start_image": latest_img}))\n'
        )
        local jStr = buildResult and buildResult:match("(%{.+%})")
        if jStr then
            local bData = STS_JSON.decode(jStr)
            if bData then
                if bData.prompt and bData.prompt ~= "" then
                    prefillPrompt = bData.prompt
                end
                if bData.start_image and bData.start_image ~= "" then
                    prefillStartImage = bData.start_image
                end
            end
        end
    end
end

-- ============================================================
-- UI
-- ============================================================

local win = disp:AddWindow({
    ID = "STS_RepromptVid",
    WindowTitle = "ScriptToScreen — Reprompt Video",
    Geometry = {200, 100, 650, 600},
}, {
    ui:VGroup{
        ui:Label{Text = "<h3>Reprompt Video</h3>", Alignment = {AlignHCenter = true}},
        ui:HGroup{
            ui:Label{Text = "Selected Clip:", Weight = 0.15},
            ui:Label{ID = "ClipName", Text = (clipInfo and clipInfo.status == "ok") and clipInfo.name or "(none — select a video clip or place playhead)", Weight = 0.75},
            ui:Button{ID = "RefreshClip", Text = "Refresh", Weight = 0.1},
        },
        ui:HGroup{
            ui:Label{Text = "Shot Key:", Weight = 0.15},
            ui:LineEdit{ID = "ShotKey", Text = prefillShotKey, Weight = 0.85},
        },
        ui:Label{Text = "Video Prompt (include full dialogue in quotes for video gen):"},
        ui:TextEdit{ID = "PromptEdit", PlainText = prefillPrompt, MinimumSize = {100, 140}},
        ui:Label{Text = "<b>Start Frame Image:</b>"},
        ui:HGroup{
            ui:LineEdit{ID = "StartImagePath", Text = prefillStartImage, Weight = 0.85},
            ui:Button{ID = "BrowseStartImg", Text = "...", Weight = 0.15},
        },
        ui:HGroup{
            ui:Label{Text = "Duration (sec):", Weight = 0.15},
            ui:SpinBox{ID = "Duration", Value = prefillDuration, Minimum = 2, Maximum = 15, Weight = 0.25},
            ui:Label{Text = "", Weight = 0.6},
        },
        ui:HGroup{
            ui:Label{Text = "Provider:", Weight = 0.15},
            ui:ComboBox{ID = "ProviderCombo", Weight = 0.85},
        },
        ui:VGap(5),
        ui:HGroup{
            ui:Button{ID = "Generate", Text = "Generate Video", Weight = 0.5},
            ui:Button{ID = "Cancel", Text = "Cancel", Weight = 0.5},
        },
        ui:Label{ID = "StatusLabel", Text = "Ready", StyleSheet = "color: #888;"},
    },
})

local itm = win:GetItems()
STS_populateProviderCombo(itm.ProviderCombo, STS_videoProviders, prefillProvider)

-- ============================================================
-- EVENT HANDLERS
-- ============================================================

function win.On.STS_RepromptVid.Close(ev) disp:ExitLoop() end
function win.On.Cancel.Clicked(ev) disp:ExitLoop() end

function win.On.RefreshClip.Clicked(ev)
    -- Try media pool selection first (what the user clicked), then timeline
    clipInfo = STS_getSelectedMediaPoolClip()
    if not clipInfo or clipInfo.status ~= "ok" or (clipInfo.comments or "") == "" then
        clipInfo = STS_getCurrentTimelineItem()
    end
    if clipInfo and clipInfo.status == "ok" then
        itm.ClipName.Text = clipInfo.name or "(none)"
        local stsFilename = STS_extractFilename(clipInfo.comments or "")
        local meta = lookupManifest(stsFilename)
        if meta then
            itm.PromptEdit.PlainText = meta.prompt or ""
            itm.StartImagePath.Text = meta.start_image_path or ""
            itm.ShotKey.Text = meta.shot_key or ""
            local ps = meta.provider_settings or {}
            if ps.duration then itm.Duration.Value = ps.duration end
        end
    else
        itm.ClipName.Text = "(none)"
    end
end

function win.On.BrowseStartImg.Clicked(ev)
    local path = fu:RequestFile("Select Start Frame Image")
    if path and path ~= "" then itm.StartImagePath.Text = path end
end

function win.On.Generate.Clicked(ev)
    local prompt = itm.PromptEdit.PlainText
    if prompt == "" then
        itm.StatusLabel.Text = "Enter a video prompt first!"
        itm.StatusLabel.StyleSheet = "color: red;"
        return
    end

    itm.StatusLabel.Text = "Generating video... (this may take 30-60 seconds)"
    itm.StatusLabel.StyleSheet = "color: #888;"

    local providerId = STS_getProviderIdFromCombo(itm.ProviderCombo, STS_videoProviders)
    local apiKey = STS_getProviderApiKey(config, providerId)
    local serverUrl = STS_getProviderServerUrl(config, providerId)

    local keyfile = os.tmpname()
    local kf = io.open(keyfile, "w")
    if kf then kf:write(apiKey); kf:close() end

    local safeOutput = outputDir:gsub("\\", "\\\\"):gsub('"', '\\"')
    local safeStartImg = itm.StartImagePath.Text:gsub("\\", "\\\\"):gsub('"', '\\"')
    local safeServerUrl = (serverUrl or ""):gsub("\\", "\\\\"):gsub('"', '\\"')

    local code = 'import traceback\n'
        .. 'try:\n'
        .. '    from script_to_screen.standalone import reprompt_video\n'
        .. '    api_key = open("' .. keyfile .. '").read().strip()\n'
        .. '    result = reprompt_video(\n'
        .. '        prompt=' .. STS_JSON.encode(prompt) .. ',\n'
        .. '        provider_id="' .. providerId .. '",\n'
        .. '        api_key=api_key,\n'
        .. '        output_dir="' .. safeOutput .. '",\n'
        .. '        project_slug="' .. projectSlug .. '",\n'
        .. '        start_image_path="' .. safeStartImg .. '",\n'
        .. '        duration=' .. tostring(itm.Duration.Value) .. ',\n'
        .. '        server_url="' .. safeServerUrl .. '",\n'
        .. '        shot_key="' .. (itm.ShotKey.Text or ""):gsub('"', '\\"') .. '",\n'
        .. '    )\n'
        .. '    print(json.dumps(result))\n'
        .. 'except Exception as e:\n'
        .. '    print(json.dumps({"status":"error","error":str(e),"trace":traceback.format_exc()}))\n'

    local result = STS_runPython(code)
    os.remove(keyfile)

    local jsonStr = result and result:match("(%{.+%})")
    if jsonStr then
        local data = STS_JSON.decode(jsonStr)
        if data and data.status == "ok" then
            STS_importAndTag(data.file_path, "Videos")
            itm.StatusLabel.Text = "Video generated! " .. (data.filename or "")
            itm.StatusLabel.StyleSheet = "color: green; font-weight: bold;"
        else
            itm.StatusLabel.Text = "Error: " .. (data and data.error or "Unknown")
            itm.StatusLabel.StyleSheet = "color: red;"
            if data and data.trace then print("[STS] " .. data.trace) end
        end
    else
        itm.StatusLabel.Text = "Failed — check console"
        itm.StatusLabel.StyleSheet = "color: red;"
        if result then print("[STS] Raw: " .. result:sub(1, 500)) end
    end
end

-- ============================================================
-- RUN
-- ============================================================

win:Show()
disp:RunLoop()
win:Hide()
