"""Wizard page definitions for the ScriptToScreen UI."""


def build_welcome_page(ui):
    """Step 1: Welcome & API Configuration."""
    return ui.VGroup({"ID": "WelcomePage"}, [
        ui.Label({
            "Text": "<h2>ScriptToScreen</h2>"
                    "<p>AI Filmmaking Plugin for DaVinci Resolve</p>",
            "Alignment": {"AlignHCenter": True},
            "StyleSheet": "padding: 10px;",
        }),

        ui.Label({"Text": "<b>API Configuration</b>", "StyleSheet": "padding-top: 15px;"}),

        # Freepik API Key
        ui.HGroup([
            ui.Label({"Text": "Freepik API Key:", "Weight": 0.25}),
            ui.LineEdit({
                "ID": "FreepikKey",
                "PlaceholderText": "Enter Freepik API key...",
                "EchoMode": "Password",
                "Weight": 0.45,
            }),
            ui.Button({"ID": "TestFreepik", "Text": "Test", "Weight": 0.15}),
            ui.Label({"ID": "FreepikStatus", "Text": "", "Weight": 0.15}),
        ]),

        # ElevenLabs API Key
        ui.HGroup([
            ui.Label({"Text": "ElevenLabs API Key:", "Weight": 0.25}),
            ui.LineEdit({
                "ID": "ElevenLabsKey",
                "PlaceholderText": "Enter ElevenLabs API key...",
                "EchoMode": "Password",
                "Weight": 0.45,
            }),
            ui.Button({"ID": "TestElevenLabs", "Text": "Test", "Weight": 0.15}),
            ui.Label({"ID": "ElevenLabsStatus", "Text": "", "Weight": 0.15}),
        ]),

        ui.Label({
            "Text": "<i>Get your Freepik API key at freepik.com/api<br>"
                    "Get your ElevenLabs API key at elevenlabs.io</i>",
            "StyleSheet": "color: gray; padding: 5px;",
        }),

        # Navigation
        ui.VGap(10),
        ui.HGroup([
            ui.Label({"Text": "", "Weight": 0.7}),
            ui.Button({"ID": "CancelBtn", "Text": "Cancel", "Weight": 0.15}),
            ui.Button({"ID": "NextBtn", "Text": "Next >", "Weight": 0.15}),
        ]),
    ])


def build_script_import_page(ui):
    """Step 2: Import Screenplay."""
    return ui.VGroup({"ID": "ScriptPage"}, [
        ui.Label({
            "Text": "<h3>Import Screenplay</h3>",
            "Alignment": {"AlignHCenter": True},
        }),

        ui.HGroup([
            ui.Label({"Text": "Script File:", "Weight": 0.15}),
            ui.LineEdit({
                "ID": "ScriptPath",
                "PlaceholderText": "Select PDF or .fountain file...",
                "ReadOnly": True,
                "Weight": 0.6,
            }),
            ui.Button({"ID": "BrowseScript", "Text": "Browse", "Weight": 0.12}),
            ui.Button({"ID": "ParseScript", "Text": "Parse", "Weight": 0.12}),
        ]),

        ui.Label({"ID": "ParseStatus", "Text": "", "StyleSheet": "padding: 5px;"}),

        # Parsed summary
        ui.Label({"Text": "<b>Screenplay Summary</b>", "StyleSheet": "padding-top: 10px;"}),
        ui.TextEdit({
            "ID": "ScriptSummary",
            "ReadOnly": True,
            "PlaceholderText": "Parse a screenplay to see the summary here...",
            "MinimumSize": [400, 200],
        }),

        # Scene list
        ui.Label({"Text": "<b>Scenes</b>", "StyleSheet": "padding-top: 10px;"}),
        ui.Tree({
            "ID": "SceneTree",
            "HeaderHidden": False,
            "MinimumSize": [400, 150],
        }),

        # Navigation
        ui.VGap(5),
        ui.HGroup([
            ui.Label({"Text": "", "Weight": 0.55}),
            ui.Button({"ID": "CancelBtn", "Text": "Cancel", "Weight": 0.15}),
            ui.Button({"ID": "BackBtn", "Text": "< Back", "Weight": 0.15}),
            ui.Button({"ID": "NextBtn", "Text": "Next >", "Weight": 0.15}),
        ]),
    ])


def build_character_setup_page(ui):
    """Step 3: Character Setup - assign reference images."""
    return ui.VGroup({"ID": "CharacterPage"}, [
        ui.Label({
            "Text": "<h3>Character Setup</h3>"
                    "<p>Assign a reference image for each character.</p>",
            "Alignment": {"AlignHCenter": True},
        }),

        # Character list with file browsers (dynamic, built at runtime)
        ui.Tree({
            "ID": "CharacterTree",
            "HeaderHidden": False,
            "MinimumSize": [500, 250],
        }),

        ui.HGroup([
            ui.Button({"ID": "BrowseCharImg", "Text": "Set Image for Selected", "Weight": 0.3}),
            ui.Button({"ID": "ClearCharImg", "Text": "Clear Image", "Weight": 0.2}),
            ui.Label({"Text": "", "Weight": 0.5}),
        ]),

        # Navigation
        ui.VGap(5),
        ui.HGroup([
            ui.Label({"Text": "", "Weight": 0.55}),
            ui.Button({"ID": "CancelBtn", "Text": "Cancel", "Weight": 0.15}),
            ui.Button({"ID": "BackBtn", "Text": "< Back", "Weight": 0.15}),
            ui.Button({"ID": "NextBtn", "Text": "Next >", "Weight": 0.15}),
        ]),
    ])


def build_style_page(ui):
    """Step 4: Style Reference."""
    return ui.VGroup({"ID": "StylePage"}, [
        ui.Label({
            "Text": "<h3>Style Reference</h3>"
                    "<p>Choose a style reference image and generation settings.</p>",
            "Alignment": {"AlignHCenter": True},
        }),

        ui.HGroup([
            ui.Label({"Text": "Style Image:", "Weight": 0.15}),
            ui.LineEdit({
                "ID": "StylePath",
                "PlaceholderText": "Select style reference image...",
                "ReadOnly": True,
                "Weight": 0.6,
            }),
            ui.Button({"ID": "BrowseStyle", "Text": "Browse", "Weight": 0.12}),
        ]),

        ui.Label({"Text": "<b>Generation Settings</b>", "StyleSheet": "padding-top: 15px;"}),

        ui.HGroup([
            ui.Label({"Text": "Model:", "Weight": 0.2}),
            ui.ComboBox({
                "ID": "ModelCombo",
                "Weight": 0.8,
            }),
        ]),

        ui.HGroup([
            ui.Label({"Text": "Aspect Ratio:", "Weight": 0.2}),
            ui.ComboBox({
                "ID": "AspectCombo",
                "Weight": 0.8,
            }),
        ]),

        ui.HGroup([
            ui.Label({"Text": "Creative Detail:", "Weight": 0.2}),
            ui.Slider({
                "ID": "DetailSlider",
                "Minimum": 0,
                "Maximum": 100,
                "Value": 33,
                "Weight": 0.6,
            }),
            ui.Label({"ID": "DetailValue", "Text": "33", "Weight": 0.2}),
        ]),

        # Navigation
        ui.VGap(10),
        ui.HGroup([
            ui.Label({"Text": "", "Weight": 0.55}),
            ui.Button({"ID": "CancelBtn", "Text": "Cancel", "Weight": 0.15}),
            ui.Button({"ID": "BackBtn", "Text": "< Back", "Weight": 0.15}),
            ui.Button({"ID": "NextBtn", "Text": "Next >", "Weight": 0.15}),
        ]),
    ])


def build_image_gen_page(ui):
    """Step 5: Image Generation."""
    return ui.VGroup({"ID": "ImageGenPage"}, [
        ui.Label({
            "Text": "<h3>Image Generation</h3>"
                    "<p>Review and generate start-frame images for each shot.</p>",
            "Alignment": {"AlignHCenter": True},
        }),

        # Shot list with prompts
        ui.Tree({
            "ID": "ImageTree",
            "HeaderHidden": False,
            "MinimumSize": [500, 200],
        }),

        # Edit prompt for selected shot
        ui.Label({"Text": "Prompt for selected shot:"}),
        ui.TextEdit({
            "ID": "ImagePrompt",
            "MinimumSize": [400, 60],
        }),
        ui.Button({"ID": "UpdatePrompt", "Text": "Update Prompt"}),

        ui.HGroup([
            ui.Button({"ID": "GenerateAllImages", "Text": "Generate All Images", "Weight": 0.3}),
            ui.Button({"ID": "RegenSelected", "Text": "Regenerate Selected", "Weight": 0.3}),
            ui.Label({"Text": "", "Weight": 0.4}),
        ]),

        # Progress
        ui.Label({"ID": "ImageProgress", "Text": "Ready"}),
        ui.Slider({
            "ID": "ImageProgressBar",
            "Minimum": 0, "Maximum": 100, "Value": 0, "Enabled": False,
        }),

        # Navigation
        ui.HGroup([
            ui.Label({"Text": "", "Weight": 0.55}),
            ui.Button({"ID": "CancelBtn", "Text": "Cancel", "Weight": 0.15}),
            ui.Button({"ID": "BackBtn", "Text": "< Back", "Weight": 0.15}),
            ui.Button({"ID": "NextBtn", "Text": "Next >", "Weight": 0.15}),
        ]),
    ])


def build_video_gen_page(ui):
    """Step 6: Video Generation."""
    return ui.VGroup({"ID": "VideoGenPage"}, [
        ui.Label({
            "Text": "<h3>Video Generation</h3>"
                    "<p>Generate videos from start-frame images.</p>",
            "Alignment": {"AlignHCenter": True},
        }),

        ui.Tree({
            "ID": "VideoTree",
            "HeaderHidden": False,
            "MinimumSize": [500, 200],
        }),

        ui.Label({"Text": "Motion prompt for selected shot:"}),
        ui.TextEdit({
            "ID": "MotionPrompt",
            "MinimumSize": [400, 60],
        }),

        ui.HGroup([
            ui.Label({"Text": "Duration (s):", "Weight": 0.15}),
            ui.SpinBox({
                "ID": "DurationSpin",
                "Minimum": 3,
                "Maximum": 15,
                "Value": 5,
                "Weight": 0.15,
            }),
            ui.Label({"Text": "", "Weight": 0.7}),
        ]),

        ui.HGroup([
            ui.Button({"ID": "GenerateAllVideos", "Text": "Generate All Videos", "Weight": 0.3}),
            ui.Button({"ID": "RegenVideoSelected", "Text": "Regenerate Selected", "Weight": 0.3}),
            ui.Label({"Text": "", "Weight": 0.4}),
        ]),

        ui.Label({"ID": "VideoProgress", "Text": "Ready"}),
        ui.Slider({
            "ID": "VideoProgressBar",
            "Minimum": 0, "Maximum": 100, "Value": 0, "Enabled": False,
        }),

        # Navigation
        ui.HGroup([
            ui.Label({"Text": "", "Weight": 0.55}),
            ui.Button({"ID": "CancelBtn", "Text": "Cancel", "Weight": 0.15}),
            ui.Button({"ID": "BackBtn", "Text": "< Back", "Weight": 0.15}),
            ui.Button({"ID": "NextBtn", "Text": "Next >", "Weight": 0.15}),
        ]),
    ])


def build_voice_setup_page(ui):
    """Step 7: Voice Setup - clone character voices."""
    return ui.VGroup({"ID": "VoicePage"}, [
        ui.Label({
            "Text": "<h3>Voice Setup</h3>"
                    "<p>Provide voice samples for each speaking character (1-2 min recommended).</p>",
            "Alignment": {"AlignHCenter": True},
        }),

        ui.Tree({
            "ID": "VoiceTree",
            "HeaderHidden": False,
            "MinimumSize": [500, 200],
        }),

        ui.HGroup([
            ui.Button({"ID": "BrowseVoiceSample", "Text": "Add Voice Sample", "Weight": 0.25}),
            ui.Button({"ID": "CloneVoice", "Text": "Clone Voice", "Weight": 0.2}),
            ui.Button({"ID": "TestVoice", "Text": "Test Voice", "Weight": 0.2}),
            ui.Label({"Text": "", "Weight": 0.35}),
        ]),

        ui.HGroup([
            ui.Label({"Text": "Existing Voice ID:", "Weight": 0.2}),
            ui.LineEdit({"ID": "ExistingVoiceId", "Weight": 0.5}),
            ui.Button({"ID": "UseExistingVoice", "Text": "Use", "Weight": 0.15}),
        ]),

        ui.Label({"ID": "VoiceProgress", "Text": "Ready"}),

        # Navigation
        ui.VGap(5),
        ui.HGroup([
            ui.Label({"Text": "", "Weight": 0.55}),
            ui.Button({"ID": "CancelBtn", "Text": "Cancel", "Weight": 0.15}),
            ui.Button({"ID": "BackBtn", "Text": "< Back", "Weight": 0.15}),
            ui.Button({"ID": "NextBtn", "Text": "Next >", "Weight": 0.15}),
        ]),
    ])


def build_dialogue_gen_page(ui):
    """Step 8: Dialogue Generation."""
    return ui.VGroup({"ID": "DialoguePage"}, [
        ui.Label({
            "Text": "<h3>Dialogue Generation</h3>"
                    "<p>Generate spoken audio for all dialogue lines.</p>",
            "Alignment": {"AlignHCenter": True},
        }),

        ui.Tree({
            "ID": "DialogueTree",
            "HeaderHidden": False,
            "MinimumSize": [500, 200],
        }),

        ui.HGroup([
            ui.Label({"Text": "Stability:", "Weight": 0.12}),
            ui.Slider({"ID": "StabilitySlider", "Minimum": 0, "Maximum": 100, "Value": 50, "Weight": 0.3}),
            ui.Label({"Text": "Similarity:", "Weight": 0.12}),
            ui.Slider({"ID": "SimilaritySlider", "Minimum": 0, "Maximum": 100, "Value": 75, "Weight": 0.3}),
        ]),

        ui.HGroup([
            ui.Button({"ID": "GenerateAllDialogue", "Text": "Generate All Dialogue", "Weight": 0.3}),
            ui.Button({"ID": "RegenDialogueSelected", "Text": "Regenerate Selected", "Weight": 0.3}),
            ui.Label({"Text": "", "Weight": 0.4}),
        ]),

        ui.Label({"ID": "DialogueProgress", "Text": "Ready"}),
        ui.Slider({
            "ID": "DialogueProgressBar",
            "Minimum": 0, "Maximum": 100, "Value": 0, "Enabled": False,
        }),

        # Navigation
        ui.HGroup([
            ui.Label({"Text": "", "Weight": 0.55}),
            ui.Button({"ID": "CancelBtn", "Text": "Cancel", "Weight": 0.15}),
            ui.Button({"ID": "BackBtn", "Text": "< Back", "Weight": 0.15}),
            ui.Button({"ID": "NextBtn", "Text": "Next >", "Weight": 0.15}),
        ]),
    ])


def build_lipsync_page(ui):
    """Step 9: Lip Sync."""
    return ui.VGroup({"ID": "LipSyncPage"}, [
        ui.Label({
            "Text": "<h3>Lip Sync</h3>"
                    "<p>Synchronize dialogue audio with video clips.</p>",
            "Alignment": {"AlignHCenter": True},
        }),

        ui.Label({
            "Text": "<i>Note: Lip-sync requires publicly accessible URLs for video/audio files.<br>"
                    "Files will be temporarily uploaded for processing.</i>",
            "StyleSheet": "color: gray;",
        }),

        ui.Tree({
            "ID": "LipSyncTree",
            "HeaderHidden": False,
            "MinimumSize": [500, 200],
        }),

        ui.HGroup([
            ui.Button({"ID": "SyncAll", "Text": "Sync All", "Weight": 0.25}),
            ui.Button({"ID": "SyncSelected", "Text": "Sync Selected", "Weight": 0.25}),
            ui.Label({"Text": "", "Weight": 0.5}),
        ]),

        ui.Label({"ID": "LipSyncProgress", "Text": "Ready"}),
        ui.Slider({
            "ID": "LipSyncProgressBar",
            "Minimum": 0, "Maximum": 100, "Value": 0, "Enabled": False,
        }),

        # Navigation
        ui.HGroup([
            ui.Label({"Text": "", "Weight": 0.55}),
            ui.Button({"ID": "CancelBtn", "Text": "Cancel", "Weight": 0.15}),
            ui.Button({"ID": "BackBtn", "Text": "< Back", "Weight": 0.15}),
            ui.Button({"ID": "NextBtn", "Text": "Next >", "Weight": 0.15}),
        ]),
    ])


def build_assembly_page(ui):
    """Step 10: Timeline Assembly."""
    return ui.VGroup({"ID": "AssemblyPage"}, [
        ui.Label({
            "Text": "<h3>Timeline Assembly</h3>"
                    "<p>Assemble all generated media into a DaVinci Resolve timeline.</p>",
            "Alignment": {"AlignHCenter": True},
        }),

        ui.HGroup([
            ui.Label({"Text": "Timeline Name:", "Weight": 0.2}),
            ui.LineEdit({
                "ID": "TimelineName",
                "Text": "ScriptToScreen Assembly",
                "Weight": 0.8,
            }),
        ]),

        ui.HGroup([
            ui.Label({"Text": "Resolution:", "Weight": 0.2}),
            ui.ComboBox({"ID": "ResolutionCombo", "Weight": 0.3}),
            ui.Label({"Text": "FPS:", "Weight": 0.1}),
            ui.ComboBox({"ID": "FPSCombo", "Weight": 0.3}),
        ]),

        # Assembly summary
        ui.Label({"Text": "<b>Assembly Summary</b>", "StyleSheet": "padding-top: 10px;"}),
        ui.TextEdit({
            "ID": "AssemblySummary",
            "ReadOnly": True,
            "MinimumSize": [400, 150],
        }),

        ui.HGroup([
            ui.Button({"ID": "AssembleTimeline", "Text": "Assemble Timeline", "Weight": 0.3}),
            ui.Label({"Text": "", "Weight": 0.7}),
        ]),

        ui.Label({"ID": "AssemblyProgress", "Text": "Ready"}),
        ui.Slider({
            "ID": "AssemblyProgressBar",
            "Minimum": 0, "Maximum": 100, "Value": 0, "Enabled": False,
        }),

        # Navigation
        ui.HGroup([
            ui.Label({"Text": "", "Weight": 0.55}),
            ui.Button({"ID": "CancelBtn", "Text": "Cancel", "Weight": 0.15}),
            ui.Button({"ID": "BackBtn", "Text": "< Back", "Weight": 0.15}),
            ui.Button({"ID": "FinishBtn", "Text": "Finish", "Weight": 0.15}),
        ]),
    ])
