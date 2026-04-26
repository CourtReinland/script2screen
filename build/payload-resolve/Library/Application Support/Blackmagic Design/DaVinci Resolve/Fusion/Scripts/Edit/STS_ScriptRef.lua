-- STS_ScriptRef.lua — Floating script reference panel for the current shot
-- Access: Workspace > Scripts > Edit > STS_ScriptRef
-- Displays the screenplay scene text for whatever clip is selected in the media pool.

local ui = fu.UIManager
local disp = bmd.UIDispatcher(ui)

-- Load shared infrastructure
local scriptDir = debug.getinfo(1, "S").source:match("@(.*[/\\])") or ""
if scriptDir == "" then
    scriptDir = "/Library/Application Support/Blackmagic Design/DaVinci Resolve/Fusion/Scripts/Edit/"
end
dofile(scriptDir .. "STS_Common.lua")

if not STS_packageDir then
    print("[STS] Python package not found — cannot run ScriptRef")
    return
end

-- ============================================================
-- STATE
-- ============================================================

local projectSlug, projectName = STS_getResolveProjectSlug()
local outputDir = STS_getOutputDir(projectSlug)
local autoRefreshTimer = nil

-- ============================================================
-- UI
-- ============================================================

local win = disp:AddWindow({
    ID = "STS_ScriptRef",
    WindowTitle = "Script Reference",
    Geometry = {950, 100, 380, 500},
    WindowFlags = {Window = true, WindowStaysOnTopHint = true},
}, {
    ui:VGroup{
        ui:HGroup{
            ui:Label{ID = "ShotLabel", Text = "Shot: (none)", Weight = 0.6},
            ui:Button{ID = "RefreshBtn", Text = "Refresh", Weight = 0.2},
            ui:CheckBox{ID = "AutoRefresh", Text = "Auto", Weight = 0.2},
        },
        ui:Label{ID = "SceneHeading", Text = "", StyleSheet = "font-weight: bold; font-size: 14px; padding: 4px; background-color: #444;"},
        ui:TextEdit{ID = "ScriptText", ReadOnly = true, MinimumSize = {350, 350}, StyleSheet = "font-family: Courier; font-size: 12px;"},
        ui:Button{ID = "CloseBtn", Text = "Close"},
    },
})

local itm = win:GetItems()

-- ============================================================
-- SCRIPT REFERENCE LOGIC
-- ============================================================

function refreshScriptRef()
    -- Detect selected clip and extract shot_key
    local clipInfo = STS_getSelectedMediaPoolClip()
    if not clipInfo or clipInfo.status ~= "ok" then
        itm.ShotLabel.Text = "Shot: (no clip selected)"
        itm.SceneHeading.Text = ""
        itm.ScriptText.PlainText = "Select a clip in the media pool and click Refresh."
        return
    end

    -- Extract shot_key from clip name or STS comments
    local shotKey = nil
    local clipName = clipInfo.name or ""

    -- Try from STS comments first
    local stsFilename = STS_extractFilename(clipInfo.comments or "")
    if stsFilename then
        shotKey = stsFilename:match("^(s%d+_sh%d+)")
    end

    -- Fallback: try from clip name
    if not shotKey then
        shotKey = clipName:match("(s%d+_sh%d+)")
    end

    if not shotKey then
        itm.ShotLabel.Text = "Shot: " .. clipName
        itm.SceneHeading.Text = "(no shot key found)"
        itm.ScriptText.PlainText = "Could not extract shot key (s{N}_sh{N}) from clip.\n\nClip: " .. clipName
        return
    end

    itm.ShotLabel.Text = "Shot: " .. shotKey

    -- Parse scene index from shot_key
    local sceneIdx = tonumber(shotKey:match("^s(%d+)"))
    if not sceneIdx then
        itm.SceneHeading.Text = "(invalid shot key)"
        itm.ScriptText.PlainText = "Could not parse scene number from: " .. shotKey
        return
    end

    -- Load screenplay data via Python
    local safeOutput = outputDir:gsub("\\", "\\\\"):gsub('"', '\\"')
    local code = 'import traceback\n'
        .. 'try:\n'
        .. '    import os\n'
        .. '    pages_path = os.path.join("' .. safeOutput .. '", "screenplay_pages.json")\n'
        .. '    if not os.path.exists(pages_path):\n'
        .. '        print(json.dumps({"status":"error","error":"screenplay_pages.json not found. Parse the screenplay first."}))\n'
        .. '    else:\n'
        .. '        with open(pages_path, "r") as f:\n'
        .. '            sp_data = json.load(f)\n'
        .. '        scene_idx = ' .. tostring(sceneIdx) .. '\n'
        .. '        scenes = sp_data.get("scenes", [])\n'
        .. '        found = None\n'
        .. '        for s in scenes:\n'
        .. '            if s.get("index") == scene_idx:\n'
        .. '                found = s\n'
        .. '                break\n'
        .. '        if found:\n'
        .. '            # Format scene text\n'
        .. '            lines = []\n'
        .. '            lines.append(found.get("heading", ""))\n'
        .. '            lines.append("")\n'
        .. '            action = found.get("action", "").strip()\n'
        .. '            if action:\n'
        .. '                lines.append(action)\n'
        .. '                lines.append("")\n'
        .. '            for dl in found.get("dialogue_lines", []):\n'
        .. '                char = dl.get("character", "")\n'
        .. '                text = dl.get("text", "")\n'
        .. '                paren = dl.get("parenthetical", "")\n'
        .. '                lines.append("          " + char)\n'
        .. '                if paren:\n'
        .. '                    lines.append("      " + paren)\n'
        .. '                lines.append("    " + text)\n'
        .. '                lines.append("")\n'
        .. '            formatted = "\\n".join(lines)\n'
        .. '            print(json.dumps({"status":"ok","heading":found.get("heading",""),"text":formatted,"scene_index":scene_idx}))\n'
        .. '        else:\n'
        .. '            print(json.dumps({"status":"error","error":"Scene " + str(scene_idx) + " not found in screenplay data."}))\n'
        .. 'except Exception as e:\n'
        .. '    print(json.dumps({"status":"error","error":str(e),"trace":traceback.format_exc()}))\n'

    local result = STS_runPython(code)
    local jsonStr = result and result:match("(%{.+%})")
    if jsonStr then
        local data = STS_JSON.decode(jsonStr)
        if data and data.status == "ok" then
            itm.SceneHeading.Text = data.heading or ""
            itm.ScriptText.PlainText = data.text or ""
        else
            itm.SceneHeading.Text = "(error)"
            itm.ScriptText.PlainText = (data and data.error or "Unknown error") .. "\n\n" .. (data and data.trace or "")
        end
    else
        itm.SceneHeading.Text = "(error)"
        itm.ScriptText.PlainText = "Failed to load script data. Check console.\n\n" .. (result or "")
    end
end

-- ============================================================
-- EVENT HANDLERS
-- ============================================================

function win.On.STS_ScriptRef.Close(ev)
    if autoRefreshTimer then
        autoRefreshTimer:Stop()
        autoRefreshTimer = nil
    end
    disp:ExitLoop()
end

function win.On.CloseBtn.Clicked(ev)
    if autoRefreshTimer then
        autoRefreshTimer:Stop()
        autoRefreshTimer = nil
    end
    disp:ExitLoop()
end

function win.On.RefreshBtn.Clicked(ev)
    refreshScriptRef()
end

function win.On.AutoRefresh.Clicked(ev)
    if itm.AutoRefresh.Checked then
        -- Start a timer-based auto-refresh using Lua os.clock polling
        -- DaVinci Resolve Fusion UI doesn't have a built-in timer widget,
        -- so we use AddNotify with a timer approach
        if not autoRefreshTimer then
            autoRefreshTimer = disp:AddTimer("AutoRefreshTimer", 3000)
        end
    else
        if autoRefreshTimer then
            autoRefreshTimer:Stop()
            autoRefreshTimer = nil
        end
    end
end

-- Timer event handler for auto-refresh
function win.On.AutoRefreshTimer.Timeout(ev)
    refreshScriptRef()
end

-- ============================================================
-- RUN
-- ============================================================

-- Initial refresh
refreshScriptRef()

win:Show()
disp:RunLoop()
win:Hide()
