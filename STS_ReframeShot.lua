-- STS_ReframeShot.lua — Reframe a shot image using AI camera angle manipulation
-- Access: Workspace > Scripts > Edit > STS_ReframeShot
-- Uses HuggingFace Spaces Gradio API (Qwen-Image-Edit) for camera angle changes

local ui = fu.UIManager
local disp = bmd.UIDispatcher(ui)

-- Load shared infrastructure
local scriptDir = debug.getinfo(1, "S").source:match("@(.*[/\\])") or ""
if scriptDir == "" then
    scriptDir = "/Library/Application Support/Blackmagic Design/DaVinci Resolve/Fusion/Scripts/Edit/"
end
dofile(scriptDir .. "STS_Common.lua")

if not STS_packageDir then
    print("[STS] Python package not found — cannot run ReframeShot")
    return
end

-- ============================================================
-- DETECT CURRENT STATE
-- ============================================================

local config = STS_loadConfig()
local projectSlug, projectName = STS_getResolveProjectSlug()
local outputDir = STS_getOutputDir(projectSlug)

-- Detect selected clip
local clipInfo = STS_getSelectedMediaPoolClip()
local prefillImagePath = ""
local prefillShotKey = ""

if clipInfo and clipInfo.status == "ok" then
    prefillImagePath = clipInfo.file_path or ""
    -- Try to extract shot key from filename
    local basename = (clipInfo.name or ""):match("^(s%d+_sh%d+)") or ""
    if basename ~= "" then
        prefillShotKey = basename
    end
    -- Also try from STS comments
    local stsFilename = STS_extractFilename(clipInfo.comments or "")
    if stsFilename then
        local sk = stsFilename:match("^(s%d+_sh%d+)")
        if sk then prefillShotKey = sk end
    end
end

-- ============================================================
-- ANGLE PRESETS
-- ============================================================

local anglePresets = {
    "Front View",
    "Left Side (45\xC2\xB0)",
    "Right Side (45\xC2\xB0)",
    "Top Down",
    "Low Angle",
    "Wide Angle",
    "Close Up",
    "Back View",
    "Move Forward",
}

-- ============================================================
-- UI
-- ============================================================

local win = disp:AddWindow({
    ID = "STS_ReframeShot",
    WindowTitle = "ScriptToScreen — Reframe Shot",
    Geometry = {200, 100, 550, 420},
}, {
    ui:VGroup{
        ui:Label{Text = "<h3>Reframe Shot (Camera Angle)</h3>", Alignment = {AlignHCenter = true}},
        ui:HGroup{
            ui:Label{Text = "Selected Clip:", Weight = 0.15},
            ui:Label{ID = "ClipName", Text = (clipInfo and clipInfo.status == "ok") and clipInfo.name or "(none — select a clip first)", Weight = 0.75},
            ui:Button{ID = "RefreshClip", Text = "Refresh", Weight = 0.1},
        },
        ui:HGroup{
            ui:Label{Text = "Image Path:", Weight = 0.15},
            ui:LineEdit{ID = "ImagePath", Text = prefillImagePath, Weight = 0.7},
            ui:Button{ID = "BrowseImage", Text = "...", Weight = 0.15},
        },
        ui:HGroup{
            ui:Label{Text = "Shot Key:", Weight = 0.15},
            ui:LineEdit{ID = "ShotKey", Text = prefillShotKey, Weight = 0.85},
        },
        ui:VGap(5),
        ui:Label{Text = "<b>Camera Angle Preset:</b>"},
        ui:ComboBox{ID = "AnglePreset"},
        ui:VGap(5),
        ui:Label{Text = "<b>Custom Prompt:</b> (overrides preset if non-empty)"},
        ui:TextEdit{ID = "CustomPrompt", PlainText = "", MinimumSize = {100, 60}},
        ui:Label{Text = "<i>Use Chinese camera commands for best results, e.g. \"\xE5\xB0\x86\xE9\x95\x9C\xE5\xA4\xB4\xE5\x90\x91\xE5\xB7\xA6\xE6\x97\x8B\xE8\xBD\xAC90\xE5\xBA\xA6\"</i>", StyleSheet = "color: #888; font-size: 11px;"},
        ui:VGap(10),
        ui:HGroup{
            ui:Button{ID = "Generate", Text = "Generate", Weight = 0.5},
            ui:Button{ID = "Cancel", Text = "Cancel", Weight = 0.5},
        },
        ui:Label{ID = "StatusLabel", Text = "Ready", StyleSheet = "color: #888;"},
    },
})

local itm = win:GetItems()

-- Populate angle preset combo
for _, preset in ipairs(anglePresets) do
    itm.AnglePreset:AddItem(preset)
end
itm.AnglePreset.CurrentIndex = 0

-- ============================================================
-- EVENT HANDLERS
-- ============================================================

function win.On.STS_ReframeShot.Close(ev) disp:ExitLoop() end
function win.On.Cancel.Clicked(ev) disp:ExitLoop() end

function win.On.RefreshClip.Clicked(ev)
    clipInfo = STS_getSelectedMediaPoolClip()
    if clipInfo and clipInfo.status == "ok" then
        itm.ClipName.Text = clipInfo.name
        itm.ImagePath.Text = clipInfo.file_path or ""
        local basename = (clipInfo.name or ""):match("^(s%d+_sh%d+)") or ""
        if basename ~= "" then
            itm.ShotKey.Text = basename
        end
        local stsFilename = STS_extractFilename(clipInfo.comments or "")
        if stsFilename then
            local sk = stsFilename:match("^(s%d+_sh%d+)")
            if sk then itm.ShotKey.Text = sk end
        end
    else
        itm.ClipName.Text = "(none)"
    end
end

function win.On.BrowseImage.Clicked(ev)
    local path = fu:RequestFile("Select Source Image")
    if path and path ~= "" then itm.ImagePath.Text = path end
end

function win.On.Generate.Clicked(ev)
    local imagePath = itm.ImagePath.Text
    if imagePath == "" then
        itm.StatusLabel.Text = "Select an image first!"
        itm.StatusLabel.StyleSheet = "color: red;"
        return
    end

    itm.StatusLabel.Text = "Reframing image (this may take a moment)..."
    itm.StatusLabel.StyleSheet = "color: #888;"

    local angleIdx = itm.AnglePreset.CurrentIndex + 1
    local anglePreset = anglePresets[angleIdx] or "Front View"
    local customPrompt = itm.CustomPrompt.PlainText or ""
    local shotKey = itm.ShotKey.Text or ""

    local safeImagePath = imagePath:gsub("\\", "\\\\"):gsub('"', '\\"')
    local safeOutput = (outputDir .. "/images"):gsub("\\", "\\\\"):gsub('"', '\\"')
    local safeCustomPrompt = customPrompt:gsub("\\", "\\\\"):gsub('"', '\\"'):gsub("\n", " ")

    local code = 'import traceback\n'
        .. 'try:\n'
        .. '    from script_to_screen.api.reframe_client import reframe_image\n'
        .. '    result = reframe_image(\n'
        .. '        image_path="' .. safeImagePath .. '",\n'
        .. '        angle_preset=' .. STS_JSON.encode(anglePreset) .. ',\n'
        .. '        custom_prompt="' .. safeCustomPrompt .. '",\n'
        .. '        output_dir="' .. safeOutput .. '",\n'
        .. '        shot_key="' .. (shotKey or ""):gsub('"', '\\"') .. '",\n'
        .. '    )\n'
        .. '    print(json.dumps(result))\n'
        .. 'except Exception as e:\n'
        .. '    print(json.dumps({"status":"error","error":str(e),"trace":traceback.format_exc()}))\n'

    local result = STS_runPython(code)

    local jsonStr = result and result:match("(%{.+%})")
    if jsonStr then
        local data = STS_JSON.decode(jsonStr)
        if data and data.status == "ok" then
            local importResult = STS_importAndTag(data.file_path, "Images")
            itm.StatusLabel.Text = "Reframed! " .. (data.filename or "")
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
