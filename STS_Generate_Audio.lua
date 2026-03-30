-- STS_Generate_Audio.lua — Standalone TTS audio generation
-- Access: Workspace > Scripts > Edit > STS_Generate_Audio

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

-- Load saved voices from manifest
local savedVoices = {}
local voiceNames = {}
do
    local result = STS_runPython(
        'from script_to_screen.manifest import get_project_voices\n'
        .. 'voices = get_project_voices("' .. projectSlug .. '")\n'
        .. 'print(json.dumps({"status":"ok", "voices": voices}))\n'
    )
    local jsonStr = result and result:match("(%{.+%})")
    if jsonStr then
        local data = STS_JSON.decode(jsonStr)
        if data and data.voices then
            savedVoices = data.voices
            for name in pairs(savedVoices) do
                table.insert(voiceNames, name)
            end
            table.sort(voiceNames)
        end
    end
end

-- ============================================================
-- UI
-- ============================================================

local win = disp:AddWindow({
    ID = "STS_GenAudio",
    WindowTitle = "ScriptToScreen — Generate Audio",
    Geometry = {200, 150, 620, 520},
}, {
    ui:VGroup{
        ui:Label{Text = "<h3>Generate Audio (TTS)</h3>", Alignment = {AlignHCenter = true}},
        ui:Label{Text = "Text to speak:"},
        ui:TextEdit{ID = "TextEdit", PlainText = "", MinimumSize = {100, 100}},
        ui:HGroup{
            ui:Label{Text = "Voice:", Weight = 0.15},
            ui:ComboBox{ID = "VoiceCombo", Weight = 0.75},
            ui:Button{ID = "RefreshVoices", Text = "↻", Weight = 0.1},
        },
        ui:Label{Text = "<b>— or clone a new voice —</b>", Alignment = {AlignHCenter = true}},
        ui:HGroup{
            ui:Label{Text = "Voice Name:", Weight = 0.15},
            ui:LineEdit{ID = "NewVoiceName", PlaceholderText = "e.g. AIDEN", Weight = 0.35},
            ui:Button{ID = "BrowseSample", Text = "Audio Sample...", Weight = 0.3},
            ui:Label{ID = "SamplePath", Text = "(none)", Weight = 0.2},
        },
        ui:HGroup{
            ui:Button{ID = "CloneVoice", Text = "Clone Voice", Weight = 0.3},
            ui:HGap(0, Weight = 0.7),
        },
        ui:HGroup{
            ui:Label{Text = "Provider:", Weight = 0.15},
            ui:ComboBox{ID = "ProviderCombo", Weight = 0.85},
        },
        ui:VGap(5),
        ui:HGroup{
            ui:Button{ID = "Generate", Text = "Generate Audio", Weight = 0.5},
            ui:Button{ID = "Cancel", Text = "Cancel", Weight = 0.5},
        },
        ui:Label{ID = "StatusLabel", Text = "Ready", StyleSheet = "color: #888;"},
    },
})

local itm = win:GetItems()

-- Populate voice combo
local function populateVoiceCombo()
    itm.VoiceCombo:Clear()
    if #voiceNames == 0 then
        itm.VoiceCombo:AddItem("(no voices — clone one below)")
    else
        for _, name in ipairs(voiceNames) do
            itm.VoiceCombo:AddItem(name)
        end
    end
end
populateVoiceCombo()

STS_populateProviderCombo(itm.ProviderCombo, STS_voiceProviders, config.voiceProvider or "voicebox")

-- Track sample path
local sampleFilePath = ""

function win.On.STS_GenAudio.Close(ev) disp:ExitLoop() end
function win.On.Cancel.Clicked(ev) disp:ExitLoop() end

function win.On.BrowseSample.Clicked(ev)
    local path = fu:RequestFile("Select Voice Sample Audio")
    if path and path ~= "" then
        sampleFilePath = path
        -- Show just the filename
        local basename = path:match("([^/]+)$") or path
        itm.SamplePath.Text = basename
    end
end

function win.On.RefreshVoices.Clicked(ev)
    local result = STS_runPython(
        'from script_to_screen.manifest import get_project_voices\n'
        .. 'voices = get_project_voices("' .. projectSlug .. '")\n'
        .. 'print(json.dumps({"status":"ok", "voices": voices}))\n'
    )
    local jsonStr = result and result:match("(%{.+%})")
    if jsonStr then
        local data = STS_JSON.decode(jsonStr)
        if data and data.voices then
            savedVoices = data.voices
            voiceNames = {}
            for name in pairs(savedVoices) do table.insert(voiceNames, name) end
            table.sort(voiceNames)
            populateVoiceCombo()
        end
    end
end

function win.On.CloneVoice.Clicked(ev)
    local name = itm.NewVoiceName.Text
    if name == "" then
        itm.StatusLabel.Text = "Enter a voice name first"
        itm.StatusLabel.StyleSheet = "color: red;"
        return
    end
    if sampleFilePath == "" then
        itm.StatusLabel.Text = "Select an audio sample first"
        itm.StatusLabel.StyleSheet = "color: red;"
        return
    end

    itm.StatusLabel.Text = "Cloning voice..."
    itm.StatusLabel.StyleSheet = "color: #888;"

    local providerId = STS_getProviderIdFromCombo(itm.ProviderCombo, STS_voiceProviders)
    local apiKey = STS_getProviderApiKey(config, providerId)
    local serverUrl = STS_getProviderServerUrl(config, providerId)

    local keyfile = os.tmpname()
    local kf = io.open(keyfile, "w")
    if kf then kf:write(apiKey); kf:close() end

    local safeSample = sampleFilePath:gsub("\\", "\\\\"):gsub('"', '\\"')

    local code = 'import traceback\n'
        .. 'try:\n'
        .. '    from script_to_screen.standalone import clone_voice_standalone\n'
        .. '    api_key = open("' .. keyfile .. '").read().strip()\n'
        .. '    result = clone_voice_standalone(\n'
        .. '        name="' .. name:gsub('"', '\\"') .. '",\n'
        .. '        audio_paths=["' .. safeSample .. '"],\n'
        .. '        provider_id="' .. providerId .. '",\n'
        .. '        api_key=api_key,\n'
        .. '        project_slug="' .. projectSlug .. '",\n'
        .. '        server_url="' .. (serverUrl or ""):gsub('"', '\\"') .. '",\n'
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
            -- Add to voice list
            savedVoices[name] = {voice_id = data.voice_id}
            table.insert(voiceNames, name)
            table.sort(voiceNames)
            populateVoiceCombo()
            -- Select the new voice
            for i, vn in ipairs(voiceNames) do
                if vn == name then itm.VoiceCombo.CurrentIndex = i - 1; break end
            end
            itm.StatusLabel.Text = "Voice cloned: " .. name .. " (ID: " .. (data.voice_id or "?") .. ")"
            itm.StatusLabel.StyleSheet = "color: green; font-weight: bold;"
        else
            itm.StatusLabel.Text = "Clone failed: " .. (data and data.error or "Unknown")
            itm.StatusLabel.StyleSheet = "color: red;"
        end
    else
        itm.StatusLabel.Text = "Failed — check console"
        itm.StatusLabel.StyleSheet = "color: red;"
    end
end

function win.On.Generate.Clicked(ev)
    local text = itm.TextEdit.PlainText
    if text == "" then
        itm.StatusLabel.Text = "Enter text to speak!"
        itm.StatusLabel.StyleSheet = "color: red;"
        return
    end

    if #voiceNames == 0 then
        itm.StatusLabel.Text = "Clone a voice first!"
        itm.StatusLabel.StyleSheet = "color: red;"
        return
    end

    local voiceIdx = (itm.VoiceCombo.CurrentIndex or 0) + 1
    local selectedVoiceName = voiceNames[voiceIdx]
    if not selectedVoiceName or not savedVoices[selectedVoiceName] then
        itm.StatusLabel.Text = "Select a valid voice"
        itm.StatusLabel.StyleSheet = "color: red;"
        return
    end

    local voiceId = savedVoices[selectedVoiceName].voice_id

    itm.StatusLabel.Text = "Generating audio..."
    itm.StatusLabel.StyleSheet = "color: #888;"

    local providerId = STS_getProviderIdFromCombo(itm.ProviderCombo, STS_voiceProviders)
    local apiKey = STS_getProviderApiKey(config, providerId)
    local serverUrl = STS_getProviderServerUrl(config, providerId)

    local keyfile = os.tmpname()
    local kf = io.open(keyfile, "w")
    if kf then kf:write(apiKey); kf:close() end

    local safeOutput = outputDir:gsub("\\", "\\\\"):gsub('"', '\\"')

    local code = 'import traceback\n'
        .. 'try:\n'
        .. '    from script_to_screen.standalone import generate_audio_standalone\n'
        .. '    api_key = open("' .. keyfile .. '").read().strip()\n'
        .. '    result = generate_audio_standalone(\n'
        .. '        text=' .. STS_JSON.encode(text) .. ',\n'
        .. '        voice_id="' .. voiceId:gsub('"', '\\"') .. '",\n'
        .. '        provider_id="' .. providerId .. '",\n'
        .. '        api_key=api_key,\n'
        .. '        output_dir="' .. safeOutput .. '",\n'
        .. '        project_slug="' .. projectSlug .. '",\n'
        .. '        character_name="' .. selectedVoiceName:gsub('"', '\\"') .. '",\n'
        .. '        server_url="' .. (serverUrl or ""):gsub('"', '\\"') .. '",\n'
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
            STS_importAndTag(data.file_path, "Audio")
            itm.StatusLabel.Text = "Audio generated! " .. (data.filename or "")
            itm.StatusLabel.StyleSheet = "color: green; font-weight: bold;"
        else
            itm.StatusLabel.Text = "Error: " .. (data and data.error or "Unknown")
            itm.StatusLabel.StyleSheet = "color: red;"
        end
    else
        itm.StatusLabel.Text = "Failed — check console"
        itm.StatusLabel.StyleSheet = "color: red;"
    end
end

win:Show()
disp:RunLoop()
win:Hide()
