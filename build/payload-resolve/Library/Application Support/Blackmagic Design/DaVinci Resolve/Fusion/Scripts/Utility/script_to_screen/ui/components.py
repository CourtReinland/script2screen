"""Reusable UI components for the Fusion UI Manager wizard."""


def file_browse_row(ui, layout, label_text, button_id, path_id, filter_str="*.*"):
    """Add a file browser row: Label | Path display | Browse button."""
    layout.update({
        f"{path_id}_label": ui.Label({
            "Text": label_text,
            "Weight": 0.3,
        }),
        f"{path_id}": ui.LineEdit({
            "PlaceholderText": "Select file...",
            "ReadOnly": True,
            "Weight": 0.5,
        }),
        f"{button_id}": ui.Button({
            "Text": "Browse",
            "Weight": 0.2,
        }),
    })


def api_key_row(ui, layout, label_text, key_id, test_button_id, status_id):
    """Add an API key input row with test button."""
    layout.update({
        f"{key_id}_label": ui.Label({
            "Text": label_text,
            "Weight": 0.2,
        }),
        f"{key_id}": ui.LineEdit({
            "PlaceholderText": "Enter API key...",
            "EchoMode": "Password",
            "Weight": 0.4,
        }),
        f"{test_button_id}": ui.Button({
            "Text": "Test",
            "Weight": 0.15,
        }),
        f"{status_id}": ui.Label({
            "Text": "",
            "Weight": 0.15,
        }),
    })


def progress_bar_row(ui, layout, bar_id, label_id):
    """Add a progress bar with status label."""
    layout.update({
        f"{label_id}": ui.Label({
            "Text": "Ready",
            "Alignment": {"AlignHCenter": True},
        }),
        f"{bar_id}": ui.Slider({
            "Minimum": 0,
            "Maximum": 100,
            "Value": 0,
            "Enabled": False,
        }),
    })


def section_header(ui, layout, text, element_id):
    """Add a bold section header."""
    layout.update({
        element_id: ui.Label({
            "Text": f"<b>{text}</b>",
            "Alignment": {"AlignHCenter": True},
            "StyleSheet": "font-size: 14px; padding: 8px 0;",
        }),
    })


def nav_buttons(ui, layout, back_id="BackBtn", next_id="NextBtn", cancel_id="CancelBtn"):
    """Add navigation buttons at bottom of wizard page."""
    layout.update({
        "NavSpacer": ui.Label({"Text": "", "Weight": 0.5}),
        cancel_id: ui.Button({"Text": "Cancel", "Weight": 0.15}),
        back_id: ui.Button({"Text": "< Back", "Weight": 0.15}),
        next_id: ui.Button({"Text": "Next >", "Weight": 0.15}),
    })
