-- STS_Reprompt_Image.lua — Generate or regenerate an image
-- Access: Workspace > Scripts > Edit > STS_Reprompt_Image
--
-- Two modes in one window:
--   * Reprompt: a clip is selected in the media pool → prompt / style /
--     char-refs auto-populate from the manifest, "Generate" produces a
--     fresh take with whatever the user edits.
--   * Fresh:   no clip selected (or the user clicked "Clear"). The form
--     starts empty; "Generate" produces a brand-new image that imports
--     into the project bin alongside any existing ones.
-- The Generate button is the same in both cases — it just dispatches
-- the current form state. The Clear button below it wipes the form so
-- the user can leave reprompt mode without having to hand-edit fields.

local ui = fu.UIManager
local disp = bmd.UIDispatcher(ui)

-- Load shared infrastructure
local scriptDir = debug.getinfo(1, "S").source:match("@(.*[/\\])") or ""
if scriptDir == "" then
    scriptDir = "/Library/Application Support/Blackmagic Design/DaVinci Resolve/Fusion/Scripts/Edit/"
end
dofile(scriptDir .. "STS_Common.lua")

if not STS_packageDir then
    print("[STS] Python package not found — cannot run Reprompt Image")
    return
end

-- ============================================================
-- DETECT CURRENT STATE
-- ============================================================

local config = STS_loadConfig()
local projectSlug, projectName = STS_getResolveProjectSlug()
local outputDir = STS_getOutputDir(projectSlug)

-- Try to detect the selected clip and pre-fill from manifest
local clipInfo = STS_getSelectedMediaPoolClip()
local prefillPrompt = ""
local prefillStyleRef = ""
local prefillShotKey = ""
local prefillProvider = config.imageProvider or "grok"
-- Character refs: table of {name=..., path=...} entries
local charRefEntries = {}

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
                prefillStyleRef = meta.data.style_reference_path or ""
                prefillShotKey = meta.data.shot_key or ""
                prefillProvider = meta.data.provider or prefillProvider
                if meta.data.character_refs then
                    for name, path in pairs(meta.data.character_refs) do
                        table.insert(charRefEntries, {name = name, path = path})
                    end
                end
            end
        end
    end

    -- Also load character refs from the project manifest
    if #charRefEntries == 0 then
        local charResult = STS_runPython(
            'from script_to_screen.manifest import load_manifest\n'
            .. 'm = load_manifest("' .. projectSlug .. '")\n'
            .. 'chars = {}\n'
            .. 'for name, data in m.get("characters", {}).items():\n'
            .. '    ref = data.get("reference_image_path", "")\n'
            .. '    if ref:\n'
            .. '        chars[name] = ref\n'
            .. 'print(json.dumps({"status":"ok", "chars": chars}))\n'
        )
        local jStr = charResult and charResult:match("(%{.+%})")
        if jStr then
            local cData = STS_JSON.decode(jStr)
            if cData and cData.chars then
                for name, path in pairs(cData.chars) do
                    table.insert(charRefEntries, {name = name, path = path})
                end
            end
        end
    end
end

-- ============================================================
-- UI
-- ============================================================

local win = disp:AddWindow({
    ID = "STS_RepromptImg",
    WindowTitle = "ScriptToScreen — Generate / Reprompt Image",
    Geometry = {200, 100, 650, 660},
}, {
    ui:VGroup{
        ui:Label{Text = "<h3>Generate / Reprompt Image</h3>", Alignment = {AlignHCenter = true}},
        ui:Label{
            Text = "Reprompt a selected clip, or generate a fresh image with no clip selected. "
                .. "Click <b>Clear</b> below to wipe pre-filled fields and start fresh.",
            StyleSheet = "color: #aaa; padding-bottom: 4px;",
            WordWrap = true,
        },
        ui:HGroup{
            ui:Label{Text = "Selected Clip:", Weight = 0.15},
            ui:Label{ID = "ClipName", Text = (clipInfo and clipInfo.status == "ok") and clipInfo.name or "(none — select a clip first)", Weight = 0.75},
            ui:Button{ID = "RefreshClip", Text = "Refresh", Weight = 0.1},
        },
        ui:HGroup{
            ui:Label{Text = "Shot Key:", Weight = 0.15},
            ui:LineEdit{ID = "ShotKey", Text = prefillShotKey, Weight = 0.85},
        },
        ui:Label{Text = "Prompt:"},
        ui:TextEdit{ID = "PromptEdit", PlainText = prefillPrompt, MinimumSize = {100, 120}},
        ui:Label{Text = "<b>Style Reference:</b>"},
        ui:HGroup{
            ui:LineEdit{ID = "StyleRefPath", Text = prefillStyleRef, Weight = 0.85},
            ui:Button{ID = "BrowseStyleRef", Text = "...", Weight = 0.15},
        },
        ui:Label{Text = "<b>Character References:</b> (add up to 3)"},
        ui:Tree{ID = "CharRefTree", HeaderHidden = false, MinimumSize = {400, 80}},
        ui:HGroup{
            ui:Button{ID = "AddCharRef", Text = "Add Character Ref", Weight = 0.35},
            ui:Button{ID = "RemoveCharRef", Text = "Remove Selected", Weight = 0.35},
            ui:Label{Text = "", Weight = 0.3},
        },
        ui:HGroup{
            ui:Label{Text = "Provider:", Weight = 0.15},
            ui:ComboBox{ID = "ProviderCombo", Weight = 0.85},
        },
        ui:HGroup{
            ID = "ModelRow",
            ui:Label{Text = "Model:", Weight = 0.15},
            ui:ComboBox{ID = "ModelCombo", Weight = 0.85},
        },
        ui:VGap(5),
        ui:HGroup{
            ui:Button{ID = "Generate", Text = "Generate", Weight = 0.4},
            ui:Button{ID = "ClearForm", Text = "Clear / Start Fresh", Weight = 0.3},
            ui:Button{ID = "Cancel", Text = "Cancel", Weight = 0.3},
        },
        ui:Label{ID = "StatusLabel", Text = "Ready", StyleSheet = "color: #888;"},
    },
})

local itm = win:GetItems()

-- Setup character ref tree
local hdr = itm.CharRefTree:NewItem()
hdr.Text[0] = "Character"
hdr.Text[1] = "Reference Image"
itm.CharRefTree:SetHeaderItem(hdr)
itm.CharRefTree.ColumnCount = 2
itm.CharRefTree.ColumnWidth[0] = 120
itm.CharRefTree.ColumnWidth[1] = 350

-- Populate with pre-filled entries
for _, entry in ipairs(charRefEntries) do
    local item = itm.CharRefTree:NewItem()
    item.Text[0] = entry.name
    item.Text[1] = entry.path
    itm.CharRefTree:AddTopLevelItem(item)
end

STS_populateProviderCombo(itm.ProviderCombo, STS_imageProviders, prefillProvider)

-- Repopulate the Model combo to match the current provider. Hides the
-- whole row when the provider has no per-model choice (Grok, ComfyUI).
local function refreshModelCombo()
    local pid = STS_getProviderIdFromCombo(itm.ProviderCombo, STS_imageProviders)
    local choices = STS_getImageModelsForProvider(pid)
    itm.ModelCombo:Clear()
    if not choices then
        itm.ModelRow:SetMinimumSize({0, 0})
        itm.ModelRow.Hidden = true
        return
    end
    itm.ModelRow.Hidden = false
    local saved = (config[choices.configKey] or choices.default)
    local idx = 0
    for i, v in ipairs(choices.items) do
        itm.ModelCombo:AddItem(v)
        if v == saved then idx = i - 1 end
    end
    itm.ModelCombo.CurrentIndex = idx
end
refreshModelCombo()
function win.On.ProviderCombo.CurrentIndexChanged(ev) refreshModelCombo() end

-- ============================================================
-- EVENT HANDLERS
-- ============================================================

function win.On.STS_RepromptImg.Close(ev) disp:ExitLoop() end
function win.On.Cancel.Clicked(ev) disp:ExitLoop() end

function win.On.ClearForm.Clicked(ev)
    -- Wipe everything that could carry over from a reprompt, leaving the
    -- form ready for a brand-new generation. Clip-selection state stays
    -- visible so the user knows they're choosing to ignore it.
    itm.PromptEdit.PlainText = ""
    itm.StyleRefPath.Text = ""
    itm.ShotKey.Text = ""
    -- Drop every character ref row
    while itm.CharRefTree:TopLevelItemCount() > 0 do
        itm.CharRefTree:TakeTopLevelItem(0)
    end
    itm.StatusLabel.Text = "Form cleared — enter a fresh prompt and Generate."
    itm.StatusLabel.StyleSheet = "color: #888;"
end

function win.On.RefreshClip.Clicked(ev)
    clipInfo = STS_getSelectedMediaPoolClip()
    if clipInfo and clipInfo.status == "ok" then
        itm.ClipName.Text = clipInfo.name
        -- Re-lookup manifest
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
            local jStr = metaResult and metaResult:match("(%{.+%})")
            if jStr then
                local meta = STS_JSON.decode(jStr)
                if meta and meta.status == "ok" and meta.data then
                    itm.PromptEdit.PlainText = meta.data.prompt or ""
                    itm.StyleRefPath.Text = meta.data.style_reference_path or ""
                    itm.ShotKey.Text = meta.data.shot_key or ""
                end
            end
        end
    else
        itm.ClipName.Text = "(none)"
    end
end

function win.On.BrowseStyleRef.Clicked(ev)
    local path = fu:RequestFile("Select Style Reference Image")
    if path and path ~= "" then itm.StyleRefPath.Text = path end
end

function win.On.AddCharRef.Clicked(ev)
    local path = fu:RequestFile("Select Character Reference Image")
    if path and path ~= "" then
        -- Ask for character name (use filename stem as default)
        local basename = path:match("([^/]+)$") or "Character"
        local name = basename:match("^(.-)_") or basename:match("^(.-)%.") or "Character"
        local item = itm.CharRefTree:NewItem()
        item.Text[0] = name:upper()
        item.Text[1] = path
        itm.CharRefTree:AddTopLevelItem(item)
    end
end

function win.On.RemoveCharRef.Clicked(ev)
    local selected = itm.CharRefTree:CurrentItem()
    if selected then
        itm.CharRefTree:TakeTopLevelItem(itm.CharRefTree:IndexOfTopLevelItem(selected))
    end
end

function win.On.Generate.Clicked(ev)
    local prompt = itm.PromptEdit.PlainText
    if prompt == "" then
        itm.StatusLabel.Text = "Enter a prompt first!"
        itm.StatusLabel.StyleSheet = "color: red;"
        return
    end

    itm.StatusLabel.Text = "Generating image..."
    itm.StatusLabel.StyleSheet = "color: #888;"

    local providerId = STS_getProviderIdFromCombo(itm.ProviderCombo, STS_imageProviders)
    local apiKey = STS_getProviderApiKey(config, providerId)
    local serverUrl = STS_getProviderServerUrl(config, providerId)
    local shotKey = itm.ShotKey.Text
    local styleRef = itm.StyleRefPath.Text

    -- Build character refs JSON from the tree
    local charRefParts = {}
    local topCount = itm.CharRefTree:TopLevelItemCount()
    for i = 0, topCount - 1 do
        local treeItem = itm.CharRefTree:TopLevelItem(i)
        if treeItem then
            local name = treeItem.Text[0] or ""
            local path = treeItem.Text[1] or ""
            if name ~= "" and path ~= "" then
                local safeName = name:gsub('"', '\\"')
                local safePath = path:gsub("\\", "\\\\"):gsub('"', '\\"')
                table.insert(charRefParts, '"' .. safeName .. '":"' .. safePath .. '"')
            end
        end
    end
    local charRefsJson = "{" .. table.concat(charRefParts, ",") .. "}"

    -- Write API key to temp file
    local keyfile = os.tmpname()
    local kf = io.open(keyfile, "w")
    if kf then kf:write(apiKey); kf:close() end

    local safeOutput = outputDir:gsub("\\", "\\\\"):gsub('"', '\\"')
    local safeStyleRef = styleRef:gsub("\\", "\\\\"):gsub('"', '\\"')
    local safeServerUrl = (serverUrl or ""):gsub("\\", "\\\\"):gsub('"', '\\"')

    -- Selected model from the per-provider Model combo, with sensible
    -- per-provider routing into the right reprompt_image() kwarg.
    local chosenModel = itm.ModelCombo.CurrentText or ""
    local extraModelKwargs = ""
    if providerId == "freepik" then
        -- For freepik, the Model combo selects the API endpoint id;
        -- the Mystic style stays at the saved config value.
        extraModelKwargs = '        freepik_image_api="' .. chosenModel .. '",\n'
    elseif providerId == "openai" then
        extraModelKwargs = '        openai_model="' .. chosenModel .. '",\n'
    elseif providerId == "gemini" then
        extraModelKwargs = '        gemini_model="' .. chosenModel .. '",\n'
    end

    local code = 'import traceback\n'
        .. 'try:\n'
        .. '    from script_to_screen.standalone import reprompt_image\n'
        .. '    api_key = open("' .. keyfile .. '").read().strip()\n'
        .. '    char_refs = json.loads(\'' .. charRefsJson:gsub("'", "\\'") .. '\')\n'
        .. '    result = reprompt_image(\n'
        .. '        prompt=' .. STS_JSON.encode(prompt) .. ',\n'
        .. '        provider_id="' .. providerId .. '",\n'
        .. '        api_key=api_key,\n'
        .. '        output_dir="' .. safeOutput .. '",\n'
        .. '        project_slug="' .. projectSlug .. '",\n'
        .. '        style_reference_path="' .. safeStyleRef .. '",\n'
        .. '        character_ref_paths=char_refs,\n'
        .. '        model="' .. (config.model or "realism") .. '",\n'
        .. '        aspect_ratio="' .. (config.aspectRatio or "widescreen_16_9") .. '",\n'
        .. '        creative_detailing=' .. tostring(config.detailing or 33) .. ',\n'
        .. '        server_url="' .. safeServerUrl .. '",\n'
        .. '        shot_key="' .. (shotKey or ""):gsub('"', '\\"') .. '",\n'
        .. extraModelKwargs
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
            local importResult = STS_importAndTag(data.file_path, "Images")
            itm.StatusLabel.Text = "Image generated! " .. (data.filename or "")
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
