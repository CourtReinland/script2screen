#!/bin/bash
# ScriptToScreen Installer for macOS
# Installs Lua launcher to Resolve scripts dir (requires sudo)
# Installs Python package to user-writable location (no sudo needed)

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
RESOLVE_SCRIPTS="/Library/Application Support/Blackmagic Design/DaVinci Resolve/Fusion/Scripts/Utility"
USER_PKG_DIR="$HOME/Library/Application Support/ScriptToScreen"

echo "=================================="
echo " ScriptToScreen Installer"
echo "=================================="
echo ""

# Check if Resolve scripts directory exists
if [ ! -d "$RESOLVE_SCRIPTS" ]; then
    echo "Creating Resolve scripts directory (requires sudo)..."
    sudo mkdir -p "$RESOLVE_SCRIPTS"
fi

# Install Python dependencies
echo "Installing Python dependencies..."
pip3 install --user --break-system-packages pdfplumber requests Pillow 2>/dev/null || \
pip3 install --user pdfplumber requests Pillow 2>/dev/null || {
    echo "Warning: pip3 install failed. You may need to install dependencies manually:"
    echo "  pip3 install --break-system-packages pdfplumber requests Pillow"
    echo ""
}

# ── 1. Install Lua entry script (requires sudo for system /Library) ──
echo "Installing ScriptToScreen.lua to Resolve scripts dir..."
sudo cp "$SCRIPT_DIR/ScriptToScreen.lua" "$RESOLVE_SCRIPTS/"
sudo chown "$(whoami):staff" "$RESOLVE_SCRIPTS/ScriptToScreen.lua"
sudo chmod 755 "$RESOLVE_SCRIPTS/ScriptToScreen.lua"

# Also install Python entry point for external scripting
if [ -f "$SCRIPT_DIR/ScriptToScreen.py" ]; then
    sudo cp "$SCRIPT_DIR/ScriptToScreen.py" "$RESOLVE_SCRIPTS/"
    sudo chown "$(whoami):staff" "$RESOLVE_SCRIPTS/ScriptToScreen.py"
    sudo chmod 755 "$RESOLVE_SCRIPTS/ScriptToScreen.py"
fi

# ── 1b. Install standalone tool scripts to Edit scripts dir ──
EDIT_SCRIPTS="/Library/Application Support/Blackmagic Design/DaVinci Resolve/Fusion/Scripts/Edit"
echo "Installing standalone tools to $EDIT_SCRIPTS..."
sudo mkdir -p "$EDIT_SCRIPTS"
for script in STS_Common.lua STS_Reprompt_Image.lua STS_Reprompt_Video.lua STS_Generate_Audio.lua STS_Lip_Sync.lua; do
    if [ -f "$SCRIPT_DIR/$script" ]; then
        sudo cp "$SCRIPT_DIR/$script" "$EDIT_SCRIPTS/"
        sudo chown "$(whoami):staff" "$EDIT_SCRIPTS/$script"
        sudo chmod 755 "$EDIT_SCRIPTS/$script"
        echo "  [OK] $script"
    fi
done

# ── 2. Install Python package to user-writable location (no sudo) ──
echo "Installing script_to_screen package to $USER_PKG_DIR..."
mkdir -p "$USER_PKG_DIR"
rm -rf "$USER_PKG_DIR/script_to_screen"
cp -r "$SCRIPT_DIR/script_to_screen" "$USER_PKG_DIR/"
find "$USER_PKG_DIR/script_to_screen" -type d -name "__pycache__" -exec rm -rf {} + 2>/dev/null || true
chmod -R 755 "$USER_PKG_DIR/script_to_screen"

# ── 3. Also install to system Resolve dir (if sudo available) ──
echo "Installing script_to_screen package to Resolve scripts dir..."
sudo rm -rf "$RESOLVE_SCRIPTS/script_to_screen" 2>/dev/null || true
sudo cp -r "$SCRIPT_DIR/script_to_screen" "$RESOLVE_SCRIPTS/" 2>/dev/null || {
    echo "  Note: Could not install to system dir. Using user dir instead."
    echo "  The plugin will use: $USER_PKG_DIR/script_to_screen"
}
sudo find "$RESOLVE_SCRIPTS/script_to_screen" -type d -name "__pycache__" -exec rm -rf {} + 2>/dev/null || true
sudo chown -R "$(whoami):staff" "$RESOLVE_SCRIPTS/script_to_screen" 2>/dev/null || true
sudo chmod -R 755 "$RESOLVE_SCRIPTS/script_to_screen" 2>/dev/null || true

# Create config directory
mkdir -p "$HOME/.config/script_to_screen"

echo ""
echo "=================================="
echo " Installation complete!"
echo "=================================="
echo ""
echo "To use ScriptToScreen:"
echo "  1. Restart DaVinci Resolve Studio"
echo "  2. Go to Workspace > Scripts > ScriptToScreen"
echo ""
echo "Provider options:"
echo "  Cloud (API keys needed):"
echo "    - Freepik (images/video/lipsync): https://www.freepik.com/api"
echo "    - ElevenLabs (voice):             https://elevenlabs.io"
echo "  Local:"
echo "    - Flux Kontext (images): requires ComfyUI — ./start_comfyui.sh"
echo "    - LTX Video (video):     requires ComfyUI — ./start_comfyui.sh"
echo "    - Voicebox (voice):      requires Voicebox — ./start_voicebox.sh"
echo ""

# Verify installation
echo "Verification:"
echo "  Lua entry:  $(ls "$RESOLVE_SCRIPTS/ScriptToScreen.lua" 2>/dev/null && echo 'OK' || echo 'MISSING')"
echo "  User pkg:   $(ls "$USER_PKG_DIR/script_to_screen/__init__.py" 2>/dev/null && echo 'OK' || echo 'MISSING')"
echo ""
echo "Provider modules (user dir):"
for f in providers.py registry.py freepik_provider.py elevenlabs_provider.py \
         comfyui_client.py comfyui_provider.py comfyui_workflows.py \
         voicebox_client.py voicebox_provider.py; do
    if [ -f "$USER_PKG_DIR/script_to_screen/api/$f" ]; then
        echo "  [OK] api/$f"
    else
        echo "  [MISSING] api/$f"
    fi
done
