-- STS_Toolbar.lua — Persistent floating toolbar for ScriptToScreen tools
-- Access: Workspace > Scripts > Edit > STS_Toolbar
-- Launch once, stays open, one-click access to all STS tools.

local ui = fu.UIManager
local disp = bmd.UIDispatcher(ui)

local scriptDir = debug.getinfo(1, "S").source:match("@(.*[/\\])") or ""
if scriptDir == "" then
    scriptDir = "/Library/Application Support/Blackmagic Design/DaVinci Resolve/Fusion/Scripts/Edit/"
end

-- Path to the main wizard and standalone scripts
local utilityDir = "/Library/Application Support/Blackmagic Design/DaVinci Resolve/Fusion/Scripts/Utility/"

-- ============================================================
-- UI — compact floating toolbar
-- ============================================================

local win = disp:AddWindow({
    ID = "STS_Toolbar",
    WindowTitle = "STS Tools",
    Geometry = {20, 100, 180, 420},
    WindowFlags = {Window = true, WindowStaysOnTopHint = true},
}, {
    ui:VGroup{
        StyleSheet = "QPushButton { padding: 6px; font-size: 12px; text-align: left; } QLabel { font-size: 11px; }",

        ui:Label{Text = "<b>ScriptToScreen</b>", Alignment = {AlignHCenter = true}, StyleSheet = "padding: 4px; background-color: #333; color: #ddd;"},

        ui:Label{Text = "Main", StyleSheet = "color: #888; padding-top: 6px;"},
        ui:Button{ID = "LaunchWizard", Text = "🎬 Full Wizard"},

        ui:Label{Text = "Reprompt", StyleSheet = "color: #888; padding-top: 6px;"},
        ui:Button{ID = "LaunchRepromptImage", Text = "🖼 Reprompt Image"},
        ui:Button{ID = "LaunchRepromptVideo", Text = "🎥 Reprompt Video"},

        ui:Label{Text = "Generate", StyleSheet = "color: #888; padding-top: 6px;"},
        ui:Button{ID = "LaunchAudio", Text = "🔊 Generate Audio"},
        ui:Button{ID = "LaunchLipSync", Text = "👄 Lip Sync"},
        ui:Button{ID = "LaunchReframe", Text = "📐 Reframe Shot"},

        ui:Label{Text = "Reference", StyleSheet = "color: #888; padding-top: 6px;"},
        ui:Button{ID = "LaunchScriptRef", Text = "📄 Script Reference"},

        ui:VGap(5),
        ui:Button{ID = "CloseToolbar", Text = "Close", StyleSheet = "background-color: #555;"},
    },
})

-- ============================================================
-- LAUNCH HELPERS
-- ============================================================

-- Each button launches a script via dofile in a coroutine-like fashion.
-- Since Resolve's Lua is single-threaded, we use comp:Execute() to
-- run the script in Fusion's context (which creates its own event loop).

local function launchScript(path)
    if not comp then
        -- If we're not in Fusion context, try direct dofile
        -- (This blocks the toolbar until the launched script closes)
        pcall(dofile, path)
    else
        -- Use comp:Execute to run in parallel (non-blocking)
        comp:Execute('dofile("' .. path:gsub('"', '\\"') .. '")')
    end
end

-- ============================================================
-- EVENT HANDLERS
-- ============================================================

function win.On.STS_Toolbar.Close(ev) disp:ExitLoop() end
function win.On.CloseToolbar.Clicked(ev) disp:ExitLoop() end

function win.On.LaunchWizard.Clicked(ev)
    launchScript(utilityDir .. "ScriptToScreen.lua")
end

function win.On.LaunchRepromptImage.Clicked(ev)
    launchScript(scriptDir .. "STS_Reprompt_Image.lua")
end

function win.On.LaunchRepromptVideo.Clicked(ev)
    launchScript(scriptDir .. "STS_Reprompt_Video.lua")
end

function win.On.LaunchAudio.Clicked(ev)
    launchScript(scriptDir .. "STS_Generate_Audio.lua")
end

function win.On.LaunchLipSync.Clicked(ev)
    launchScript(scriptDir .. "STS_Lip_Sync.lua")
end

function win.On.LaunchReframe.Clicked(ev)
    launchScript(scriptDir .. "STS_ReframeShot.lua")
end

function win.On.LaunchScriptRef.Clicked(ev)
    launchScript(scriptDir .. "STS_ScriptRef.lua")
end

-- ============================================================
-- RUN
-- ============================================================

win:Show()
disp:RunLoop()
win:Hide()
