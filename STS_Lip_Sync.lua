-- STS_Lip_Sync.lua — Standalone lip sync tool
-- Access: Workspace > Scripts > Edit > STS_Lip_Sync

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

-- Detect current clip for video source (media pool selection first, then timeline)
local clipInfo = STS_getSelectedMediaPoolClip()
if not clipInfo or clipInfo.status ~= "ok" or (clipInfo.comments or "") == "" then
    clipInfo = STS_getCurrentTimelineItem()
end

local videoFilePath = ""
local prefillAudioPath = ""
local prefillShotKey = ""

if clipInfo and clipInfo.status == "ok" then
    videoFilePath = clipInfo.file_path or ""
    local clipName = clipInfo.name or ""
    local stsFilename = STS_extractFilename(clipInfo.comments or "")

    -- Extract shot key from filename
    local shotKeyFromName = clipName:match("^(s%d+_sh%d+)")
    if not shotKeyFromName and stsFilename then
        shotKeyFromName = stsFilename:match("^(s%d+_sh%d+)")
    end
    if shotKeyFromName then
        prefillShotKey = shotKeyFromName
    end

    -- Find matching audio file using shot_key pattern
    if prefillShotKey ~= "" then
        local audioResult = STS_runPython(
            'import os, glob, re\n'
            .. 'try:\n'
            .. '    shot_key = "' .. prefillShotKey .. '"\n'
            .. '    audio_dir = "' .. outputDir:gsub("\\", "\\\\"):gsub('"', '\\"') .. '/audio"\n'
            .. '    dialogue_dir = os.path.join(audio_dir, "dialogue_audio")\n'
            .. '    merged_dir = os.path.join(audio_dir, "merged")\n'
            .. '    found = ""\n'
            .. '    # Search in merged/ first, then dialogue_audio/, then audio/\n'
            .. '    for search_dir in [merged_dir, dialogue_dir, audio_dir]:\n'
            .. '        if not os.path.isdir(search_dir): continue\n'
            .. '        for f in sorted(glob.glob(os.path.join(search_dir, "*.wav")) + glob.glob(os.path.join(search_dir, "*.mp3")), reverse=True):\n'
            .. '            bn = os.path.basename(f)\n'
            .. '            m = re.match(r"(s\\d+_sh\\d+)", bn)\n'
            .. '            if m and m.group(1) == shot_key:\n'
            .. '                found = f\n'
            .. '                break\n'
            .. '        if found: break\n'
            .. '    print(json.dumps({"status":"ok", "audio_path": found}))\n'
            .. 'except Exception as e:\n'
            .. '    print(json.dumps({"status":"error", "error": str(e)}))\n'
        )
        local jStr = audioResult and audioResult:match("(%{.+%})")
        if jStr then
            local aData = STS_JSON.decode(jStr)
            if aData and aData.status == "ok" and aData.audio_path and aData.audio_path ~= "" then
                prefillAudioPath = aData.audio_path
            end
        end
    end
end

-- ============================================================
-- UI
-- ============================================================

local win = disp:AddWindow({
    ID = "STS_LipSync",
    WindowTitle = "ScriptToScreen — Lip Sync",
    Geometry = {200, 180, 620, 400},
}, {
    ui:VGroup{
        ui:Label{Text = "<h3>Lip Sync Video</h3>", Alignment = {AlignHCenter = true}},
        ui:HGroup{
            ui:Label{Text = "Video Clip:", Weight = 0.15},
            ui:LineEdit{ID = "VideoPath", Text = videoFilePath, Weight = 0.7},
            ui:Button{ID = "BrowseVideo", Text = "...", Weight = 0.075},
            ui:Button{ID = "UseTimeline", Text = "Timeline", Weight = 0.075},
        },
        ui:HGroup{
            ui:Label{Text = "Audio Source:", Weight = 0.15},
            ui:LineEdit{ID = "AudioPath", Text = prefillAudioPath, PlaceholderText = "Select audio file...", Weight = 0.75},
            ui:Button{ID = "BrowseAudio", Text = "...", Weight = 0.1},
        },
        ui:HGroup{
            ui:Label{Text = "Provider:", Weight = 0.15},
            ui:ComboBox{ID = "ProviderCombo", Weight = 0.85},
        },
        ui:VGap(10),
        ui:HGroup{
            ui:Button{ID = "Generate", Text = "Generate Lip Sync", Weight = 0.5},
            ui:Button{ID = "Cancel", Text = "Cancel", Weight = 0.5},
        },
        ui:Label{ID = "StatusLabel", Text = (prefillShotKey ~= "" and ("Detected: " .. prefillShotKey) or "Ready — select a video clip and audio file"), StyleSheet = "color: #888;"},
    },
})

local itm = win:GetItems()
STS_populateProviderCombo(itm.ProviderCombo, STS_lipsyncProviders, "kling")

function win.On.STS_LipSync.Close(ev) disp:ExitLoop() end
function win.On.Cancel.Clicked(ev) disp:ExitLoop() end

function win.On.BrowseVideo.Clicked(ev)
    local path = fu:RequestFile("Select Video File")
    if path and path ~= "" then itm.VideoPath.Text = path end
end

function win.On.BrowseAudio.Clicked(ev)
    local path = fu:RequestFile("Select Audio File")
    if path and path ~= "" then itm.AudioPath.Text = path end
end

function win.On.UseTimeline.Clicked(ev)
    clipInfo = STS_getCurrentTimelineItem()
    if clipInfo and clipInfo.status == "ok" and clipInfo.file_path ~= "" then
        itm.VideoPath.Text = clipInfo.file_path
        itm.StatusLabel.Text = "Loaded: " .. clipInfo.name
        itm.StatusLabel.StyleSheet = "color: #888;"
    else
        itm.StatusLabel.Text = "No clip at playhead"
        itm.StatusLabel.StyleSheet = "color: orange;"
    end
end

function win.On.Generate.Clicked(ev)
    local vidPath = itm.VideoPath.Text
    local audPath = itm.AudioPath.Text

    if vidPath == "" then
        itm.StatusLabel.Text = "Select a video file!"
        itm.StatusLabel.StyleSheet = "color: red;"
        return
    end
    if audPath == "" then
        itm.StatusLabel.Text = "Select an audio file!"
        itm.StatusLabel.StyleSheet = "color: red;"
        return
    end

    itm.StatusLabel.Text = "Generating lip sync... (this may take several minutes)"
    itm.StatusLabel.StyleSheet = "color: #888;"

    local providerId = STS_getProviderIdFromCombo(itm.ProviderCombo, STS_lipsyncProviders)
    local apiKey = STS_getProviderApiKey(config, providerId)
    local serverUrl = STS_getProviderServerUrl(config, providerId)

    local keyfile = os.tmpname()
    local kf = io.open(keyfile, "w")
    if kf then kf:write(apiKey); kf:close() end

    local safeOutput = outputDir:gsub("\\", "\\\\"):gsub('"', '\\"')
    local safeVid = vidPath:gsub("\\", "\\\\"):gsub('"', '\\"')
    local safeAud = audPath:gsub("\\", "\\\\"):gsub('"', '\\"')

    local code = 'import traceback\n'
        .. 'try:\n'
        .. '    from script_to_screen.standalone import generate_lipsync_standalone\n'
        .. '    api_key = open("' .. keyfile .. '").read().strip()\n'
        .. '    result = generate_lipsync_standalone(\n'
        .. '        video_path="' .. safeVid .. '",\n'
        .. '        audio_path="' .. safeAud .. '",\n'
        .. '        provider_id="' .. providerId .. '",\n'
        .. '        api_key=api_key,\n'
        .. '        output_dir="' .. safeOutput .. '",\n'
        .. '        project_slug="' .. projectSlug .. '",\n'
        .. '        server_url="' .. (serverUrl or ""):gsub('"', '\\"') .. '",\n'
        .. '        shot_key="' .. (prefillShotKey or ""):gsub('"', '\\"') .. '",\n'
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
            STS_importAndTag(data.file_path, "LipSync")
            itm.StatusLabel.Text = "Lip sync complete! " .. (data.filename or "")
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
