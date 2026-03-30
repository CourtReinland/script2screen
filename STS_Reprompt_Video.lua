-- STS_Reprompt_Video.lua — Regenerate a video with an edited prompt
-- Access: Workspace > Scripts > Edit > STS_Reprompt_Video

local ui = fu.UIManager
local disp = bmd.UIDispatcher(ui)

local scriptDir = debug.getinfo(1, "S").source:match("@(.*[/\\])") or ""
-- Fallback: if scriptDir is empty, try the known Edit scripts location
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

-- Detect current timeline clip
local clipInfo = STS_getCurrentTimelineItem()
local prefillPrompt = ""
local prefillStartImage = ""
local prefillDuration = 5
local prefillShotKey = ""
local prefillProvider = config.videoProvider or "grok"

if clipInfo and clipInfo.status == "ok" then
    local stsFilename = STS_extractFilename(clipInfo.comments or "")
    if stsFilename then
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
                prefillPrompt = meta.data.prompt or ""
                prefillStartImage = meta.data.start_image_path or ""
                prefillShotKey = meta.data.shot_key or ""
                prefillProvider = meta.data.provider or prefillProvider
                local ps = meta.data.provider_settings or {}
                prefillDuration = ps.duration or prefillDuration
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
    Geometry = {200, 130, 620, 560},
}, {
    ui:VGroup{
        ui:Label{Text = "<h3>Reprompt Video</h3>", Alignment = {AlignHCenter = true}},
        ui:HGroup{
            ui:Label{Text = "Timeline Clip:", Weight = 0.2},
            ui:Label{ID = "ClipName", Text = (clipInfo and clipInfo.status == "ok") and clipInfo.name or "(none — place playhead on a clip)", Weight = 0.7},
            ui:Button{ID = "RefreshClip", Text = "Refresh", Weight = 0.1},
        },
        ui:HGroup{
            ui:Label{Text = "Shot Key:", Weight = 0.2},
            ui:LineEdit{ID = "ShotKey", Text = prefillShotKey, Weight = 0.8},
        },
        ui:Label{Text = "Motion Prompt:"},
        ui:TextEdit{ID = "PromptEdit", PlainText = prefillPrompt, MinimumSize = {100, 120}},
        ui:HGroup{
            ui:Label{Text = "Start Image:", Weight = 0.2},
            ui:LineEdit{ID = "StartImagePath", Text = prefillStartImage, Weight = 0.7},
            ui:Button{ID = "BrowseStartImg", Text = "...", Weight = 0.1},
        },
        ui:HGroup{
            ui:Label{Text = "Duration (sec):", Weight = 0.2},
            ui:SpinBox{ID = "Duration", Value = prefillDuration, Minimum = 2, Maximum = 15, Weight = 0.3},
            ui:HGap(0, Weight = 0.5),
        },
        ui:HGroup{
            ui:Label{Text = "Provider:", Weight = 0.2},
            ui:ComboBox{ID = "ProviderCombo", Weight = 0.8},
        },
        ui:VGap(5),
        ui:HGroup{
            ui:Button{ID = "Generate", Text = "Generate", Weight = 0.5},
            ui:Button{ID = "Cancel", Text = "Cancel", Weight = 0.5},
        },
        ui:Label{ID = "StatusLabel", Text = "Ready", StyleSheet = "color: #888;"},
    },
})

local itm = win:GetItems()
STS_populateProviderCombo(itm.ProviderCombo, STS_videoProviders, prefillProvider)

function win.On.STS_RepromptVid.Close(ev) disp:ExitLoop() end
function win.On.Cancel.Clicked(ev) disp:ExitLoop() end

function win.On.RefreshClip.Clicked(ev)
    clipInfo = STS_getCurrentTimelineItem()
    itm.ClipName.Text = (clipInfo and clipInfo.status == "ok") and clipInfo.name or "(none)"
end

function win.On.BrowseStartImg.Clicked(ev)
    local path = fu:RequestFile("Select Start Frame Image")
    if path and path ~= "" then itm.StartImagePath.Text = path end
end

function win.On.Generate.Clicked(ev)
    local prompt = itm.PromptEdit.PlainText
    if prompt == "" then
        itm.StatusLabel.Text = "Enter a motion prompt first!"
        itm.StatusLabel.StyleSheet = "color: red;"
        return
    end

    itm.StatusLabel.Text = "Generating video... (this may take a while)"
    itm.StatusLabel.StyleSheet = "color: #888;"

    local providerId = STS_getProviderIdFromCombo(itm.ProviderCombo, STS_videoProviders)
    local apiKey = STS_getProviderApiKey(config, providerId)
    local serverUrl = STS_getProviderServerUrl(config, providerId)

    local keyfile = os.tmpname()
    local kf = io.open(keyfile, "w")
    if kf then kf:write(apiKey); kf:close() end

    local safeOutput = outputDir:gsub("\\", "\\\\"):gsub('"', '\\"')
    local safeStartImg = itm.StartImagePath.Text:gsub("\\", "\\\\"):gsub('"', '\\"')

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
        .. '        server_url="' .. (serverUrl or ""):gsub('"', '\\"') .. '",\n'
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
    end
end

win:Show()
disp:RunLoop()
win:Hide()
