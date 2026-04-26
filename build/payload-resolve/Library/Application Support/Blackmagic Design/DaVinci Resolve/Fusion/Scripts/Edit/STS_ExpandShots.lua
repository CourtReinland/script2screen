-- STS_ExpandShots.lua — LLM-based shot expansion (SORA-style coverage)
-- Access: Workspace > Scripts > Edit > STS_ExpandShots
-- Takes a parsed screenplay and uses an LLM to add reaction shots, inserts,
-- cutaways, and alternate angles. Outputs a new .fountain file.

local ui = fu.UIManager
local disp = bmd.UIDispatcher(ui)

-- Load shared infrastructure
local scriptDir = debug.getinfo(1, "S").source:match("@(.*[/\\])") or ""
if scriptDir == "" then
    scriptDir = "/Library/Application Support/Blackmagic Design/DaVinci Resolve/Fusion/Scripts/Edit/"
end
dofile(scriptDir .. "STS_Common.lua")

if not STS_packageDir then
    print("[STS] Python package not found — cannot run ExpandShots")
    return
end

-- ============================================================
-- DETECT CURRENT STATE
-- ============================================================

local config = STS_loadConfig()
local projectSlug, projectName = STS_getResolveProjectSlug()
local outputDir = STS_getOutputDir(projectSlug)

-- Pre-fill script path from last wizard session if available
local prefillScriptPath = config.lastScriptPath or ""

-- ============================================================
-- STYLE PRESETS
-- ============================================================

local stylePresets = {
    "Conservative (reactions + inserts only)",
    "Standard (reactions + inserts + alternate angles)",
    "Aggressive (full coverage rewrite)",
}

local styleMap = {
    "conservative",
    "standard",
    "aggressive",
}

-- ============================================================
-- UI
-- ============================================================

local win = disp:AddWindow({
    ID = "STS_ExpandShots",
    WindowTitle = "ScriptToScreen — Shot Expander (Experimental)",
    Geometry = {200, 120, 700, 480},
}, {
    ui:VGroup{
        Spacing = 8,
        ui:Label{
            Text = "<h3>LLM Shot Expansion</h3>",
            Alignment = {AlignHCenter = true},
        },
        ui:Label{
            Text = "Adds reaction shots, inserts, cutaways, and alternate angles to your script.",
            StyleSheet = "color: #888; font-style: italic;",
            Alignment = {AlignHCenter = true},
        },
        ui:VGap(5),

        -- Script file picker
        ui:HGroup{
            ui:Label{Text = "Script File:", Weight = 0.18},
            ui:LineEdit{
                ID = "ScriptPath",
                Text = prefillScriptPath,
                PlaceholderText = "Select .pdf or .fountain file...",
                Weight = 0.7,
            },
            ui:Button{ID = "BrowseScript", Text = "...", Weight = 0.1},
        },

        -- Style dropdown
        ui:HGroup{
            ui:Label{Text = "Expansion Style:", Weight = 0.18},
            ui:ComboBox{ID = "StyleCombo", Weight = 0.82},
        },

        -- Expansion ratio slider (0-200% in steps of 10%)
        ui:HGroup{
            ui:Label{Text = "Extra Shots:", Weight = 0.18},
            ui:Slider{
                ID = "RatioSlider",
                Integer = true,
                Minimum = 0,
                Maximum = 200,
                Value = 50,
                Weight = 0.65,
            },
            ui:Label{ID = "RatioLabel", Text = "+50%", Weight = 0.17, Alignment = {AlignHCenter = true}},
        },

        -- Provider info
        ui:HGroup{
            ui:Label{Text = "LLM Provider:", Weight = 0.18},
            ui:Label{Text = "Grok (xAI) — uses your existing Grok API key", Weight = 0.82, StyleSheet = "color: #888;"},
        },

        ui:VGap(5),

        -- Status / result
        ui:TextEdit{
            ID = "StatusBox",
            ReadOnly = true,
            PlaceholderText = "Ready. Select a script and click Expand Shots.",
            Weight = 1.0,
        },

        ui:VGap(5),

        -- Buttons
        ui:HGroup{
            ui:Button{ID = "ExpandBtn", Text = "Expand Shots", Weight = 0.5},
            ui:Button{ID = "CancelBtn", Text = "Close", Weight = 0.5},
        },
    },
})

local itm = win:GetItems()

-- Populate style combo
for _, label in ipairs(stylePresets) do
    itm.StyleCombo:AddItem(label)
end
itm.StyleCombo.CurrentIndex = 1  -- default to Standard

-- ============================================================
-- EVENT HANDLERS
-- ============================================================

function win.On.STS_ExpandShots.Close(ev) disp:ExitLoop() end
function win.On.CancelBtn.Clicked(ev) disp:ExitLoop() end

function win.On.BrowseScript.Clicked(ev)
    local path = fu:RequestFile("Select screenplay file")
    if path and path ~= "" then
        itm.ScriptPath.Text = path
    end
end

function win.On.RatioSlider.ValueChanged(ev)
    itm.RatioLabel.Text = "+" .. tostring(itm.RatioSlider.Value) .. "%"
end

function win.On.ExpandBtn.Clicked(ev)
    local scriptPath = itm.ScriptPath.Text
    if scriptPath == "" then
        itm.StatusBox.PlainText = "Error: Please select a script file first."
        itm.StatusBox.StyleSheet = "color: red;"
        return
    end

    -- Get Grok API key
    local apiKey = config.providers.grok and config.providers.grok.apiKey or ""
    if apiKey == "" then
        itm.StatusBox.PlainText = "Error: Grok API key not set. Configure it in the main wizard (Step 1)."
        itm.StatusBox.StyleSheet = "color: red;"
        return
    end

    -- Get style and ratio
    local styleIdx = itm.StyleCombo.CurrentIndex + 1  -- Lua 1-indexed
    local style = styleMap[styleIdx] or "standard"
    local ratio = itm.RatioSlider.Value / 100.0  -- convert percent to float

    itm.StatusBox.PlainText = "Expanding shots with Grok LLM...\nStyle: " .. style .. "\nExtra shots target: " .. tostring(itm.RatioSlider.Value) .. "%\n\nThis may take 10-30 seconds per scene..."
    itm.StatusBox.StyleSheet = "color: #888;"

    -- Write API key to temp file so we don't embed it in generated Python
    local keyfile = os.tmpname()
    local kf = io.open(keyfile, "w")
    if kf then kf:write(apiKey); kf:close() end

    local safeScript = scriptPath:gsub("\\", "\\\\"):gsub('"', '\\"')
    local safeOutput = outputDir:gsub("\\", "\\\\"):gsub('"', '\\"')
    local safeSlug = (projectSlug or ""):gsub('"', '\\"')

    local code = 'import traceback\n'
        .. 'try:\n'
        .. '    from script_to_screen.standalone import expand_shots_standalone\n'
        .. '    api_key = open("' .. keyfile .. '").read().strip()\n'
        .. '    result = expand_shots_standalone(\n'
        .. '        script_path="' .. safeScript .. '",\n'
        .. '        api_key=api_key,\n'
        .. '        project_slug="' .. safeSlug .. '",\n'
        .. '        expansion_ratio=' .. tostring(ratio) .. ',\n'
        .. '        style="' .. style .. '",\n'
        .. '        output_dir="' .. safeOutput .. '",\n'
        .. '        provider_id="grok",\n'
        .. '    )\n'
        .. '    print(json.dumps(result))\n'
        .. 'except Exception as e:\n'
        .. '    print(json.dumps({"status":"error","error":str(e),"trace":traceback.format_exc()}))\n'

    local result = STS_runPython(code)
    os.remove(keyfile)

    local jsonStr = result and result:match("(%{.+%})")
    if not jsonStr then
        itm.StatusBox.PlainText = "Error: No JSON output from Python.\n\nRaw output:\n" .. tostring(result)
        itm.StatusBox.StyleSheet = "color: red;"
        return
    end

    local data = STS_JSON.decode(jsonStr)
    if not data then
        itm.StatusBox.PlainText = "Error: Could not parse JSON response.\n\nRaw: " .. jsonStr
        itm.StatusBox.StyleSheet = "color: red;"
        return
    end

    if data.status == "ok" then
        local msg = "\xE2\x9C\x93 Shot expansion complete!\n\n"
        msg = msg .. "Original shots: " .. tostring(data.original_count) .. "\n"
        msg = msg .. "Expanded shots: " .. tostring(data.expanded_count) .. "\n"
        msg = msg .. "Added: " .. tostring(data.added_count) .. " new shots\n"
        msg = msg .. "Style: " .. tostring(data.style) .. "\n\n"
        msg = msg .. "Output file:\n" .. tostring(data.screenplay_path) .. "\n\n"
        msg = msg .. "Next steps:\n"
        msg = msg .. "1. Open the main ScriptToScreen wizard\n"
        msg = msg .. "2. Go to Step 2 (Import Screenplay)\n"
        msg = msg .. "3. Select the expanded .fountain file above\n"
        msg = msg .. "4. Parse, then continue through image/video generation"
        itm.StatusBox.PlainText = msg
        itm.StatusBox.StyleSheet = "color: #4a4;"

        -- Save the expanded script path to config for convenience
        if data.screenplay_path then
            config.lastExpandedScript = data.screenplay_path
            STS_saveConfig(config)
        end
    else
        local msg = "Error: " .. tostring(data.error or "Unknown error")
        if data.trace then
            msg = msg .. "\n\nTrace:\n" .. tostring(data.trace)
        end
        itm.StatusBox.PlainText = msg
        itm.StatusBox.StyleSheet = "color: red;"
    end
end

-- ============================================================
-- RUN
-- ============================================================

win:Show()
disp:RunLoop()
win:Hide()
