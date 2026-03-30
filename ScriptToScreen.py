#!/usr/bin/env python3
"""
ScriptToScreen - AI Filmmaking Plugin for DaVinci Resolve Studio

Turns a Hollywood-formatted screenplay into a fully edited video with
AI-generated visuals, voice acting, and lip-synced dialogue.
"""

import sys
import os

# Add the script directory to Python path so our package can be found
script_dir = os.path.dirname(os.path.abspath(__file__))
if script_dir not in sys.path:
    sys.path.insert(0, script_dir)

# ── Resolve injects 'fusion' and 'bmd' as globals when run from the menu ──
# We use them directly — no import needed.

from script_to_screen.ui.wizard import ScriptToScreenWizard

wizard = ScriptToScreenWizard(fusion)  # noqa: F821 — 'fusion' is injected by Resolve
wizard.run()
