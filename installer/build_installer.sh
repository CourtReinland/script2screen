#!/bin/bash
# ============================================================================
# Build ScriptToScreen macOS Installer (.pkg inside .dmg)
#
# Uses macOS native `pkgbuild` + `productbuild` to create a proper .pkg
# installer. This avoids ALL the Gatekeeper/osascript issues that broke
# the previous .app-based approach.
#
# The .pkg installer:
#   - Copies Lua scripts to /Library/.../DaVinci Resolve/Fusion/Scripts/
#   - Copies Python package to ~/Library/Application Support/ScriptToScreen/
#   - Runs a postinstall script for Homebrew/Python/venv/pip setup
#
# Usage: ./build_installer.sh [VERSION]
#   e.g.: ./build_installer.sh 1.1.0
# ============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
VERSION="${1:-1.1.0}"

BUILD_DIR="$PROJECT_DIR/build"
DIST_DIR="$PROJECT_DIR/dist"
PKG_ID="com.scripttoscreensts.pkg"

echo "============================================"
echo " Building ScriptToScreen Installer v$VERSION"
echo " Format: .pkg (native macOS installer)"
echo "============================================"
echo ""

# Clean previous build
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR" "$DIST_DIR"

# ============================================================================
# Stage 1: Prepare payload directories
# ============================================================================

echo "[1/5] Staging payload..."

# Payload A: Resolve system scripts (/Library/...)
RESOLVE_ROOT="$BUILD_DIR/payload-resolve"
UTIL_DIR="$RESOLVE_ROOT/Library/Application Support/Blackmagic Design/DaVinci Resolve/Fusion/Scripts/Utility"
EDIT_DIR="$RESOLVE_ROOT/Library/Application Support/Blackmagic Design/DaVinci Resolve/Fusion/Scripts/Edit"

mkdir -p "$UTIL_DIR" "$EDIT_DIR"

# Main wizard
cp "$PROJECT_DIR/ScriptToScreen.lua" "$UTIL_DIR/"
cp "$PROJECT_DIR/ScriptToScreen.py" "$UTIL_DIR/" 2>/dev/null || true

# Standalone tools
for script in STS_Common.lua STS_Reprompt_Image.lua STS_Reprompt_Video.lua \
              STS_Generate_Audio.lua STS_Lip_Sync.lua STS_ReframeShot.lua \
              STS_ScriptRef.lua STS_Toolbar.lua STS_ExpandShots.lua; do
    if [ -f "$PROJECT_DIR/$script" ]; then
        cp "$PROJECT_DIR/$script" "$EDIT_DIR/"
    fi
done

# Python package also in Utility dir (some plugins look here)
cp -r "$PROJECT_DIR/script_to_screen" "$UTIL_DIR/"
find "$UTIL_DIR/script_to_screen" -type d -name "__pycache__" -exec rm -rf {} + 2>/dev/null || true

# Payload B: User-space files (~/ via postinstall, but we stage for reference)
USER_ROOT="$BUILD_DIR/payload-user"
USER_STS_DIR="$USER_ROOT/Library/Application Support/ScriptToScreen"
mkdir -p "$USER_STS_DIR"

# Python package for user dir
cp -r "$PROJECT_DIR/script_to_screen" "$USER_STS_DIR/"
find "$USER_STS_DIR/script_to_screen" -type d -name "__pycache__" -exec rm -rf {} + 2>/dev/null || true

echo "  Payload staged:"
echo "    Utility scripts: $(ls "$UTIL_DIR"/*.lua 2>/dev/null | wc -l | tr -d ' ') files"
echo "    Edit scripts: $(ls "$EDIT_DIR"/*.lua 2>/dev/null | wc -l | tr -d ' ') files"

# ============================================================================
# Stage 2: Prepare scripts directory for the pkg
# ============================================================================

echo "[2/5] Preparing install scripts..."

SCRIPTS_DIR="$BUILD_DIR/scripts"
mkdir -p "$SCRIPTS_DIR"

cp "$SCRIPT_DIR/postinstall" "$SCRIPTS_DIR/postinstall"
chmod +x "$SCRIPTS_DIR/postinstall"

# ============================================================================
# Stage 3: Build component .pkg files
# ============================================================================

echo "[3/5] Building component packages..."

# Component A: Resolve system scripts (installs to /Library/)
pkgbuild \
    --root "$RESOLVE_ROOT" \
    --identifier "${PKG_ID}.resolve-scripts" \
    --version "$VERSION" \
    --scripts "$SCRIPTS_DIR" \
    --install-location "/" \
    "$BUILD_DIR/resolve-scripts.pkg"

# Component B: User-space Python package (installs to ~/Library/)
pkgbuild \
    --root "$USER_ROOT" \
    --identifier "${PKG_ID}.user-package" \
    --version "$VERSION" \
    --install-location "$HOME" \
    "$BUILD_DIR/user-package.pkg"

# ============================================================================
# Stage 4: Create distribution.xml for productbuild
# ============================================================================

echo "[4/5] Building product installer..."

cat > "$BUILD_DIR/distribution.xml" <<DISTXML
<?xml version="1.0" encoding="utf-8"?>
<installer-gui-script minSpecVersion="2">
    <title>ScriptToScreen v${VERSION}</title>
    <welcome>
        <html-content><![CDATA[
<html><body style="font-family: -apple-system, Helvetica; padding: 20px;">
<h2>ScriptToScreen v${VERSION}</h2>
<p>AI Filmmaking Plugin for DaVinci Resolve</p>
<p>This installer will set up:</p>
<ul>
<li><b>ScriptToScreen wizard</b> + all standalone tools in DaVinci Resolve</li>
<li><b>Python virtual environment</b> with AI packages</li>
<li><b>MLX-Audio</b> for local voice synthesis (Apple Silicon)</li>
<li><b>Homebrew</b> and <b>ffmpeg</b> if not already installed</li>
</ul>
<p style="color: #666; font-size: 0.9em;">
After installation, restart DaVinci Resolve and go to<br/>
<b>Workspace &rarr; Scripts &rarr; ScriptToScreen</b>
</p>
<p style="color: #666; font-size: 0.85em;">
Install log: ~/Library/Logs/ScriptToScreen/install.log
</p>
</body></html>
        ]]></html-content>
    </welcome>
    <conclusion>
        <html-content><![CDATA[
<html><body style="font-family: -apple-system, Helvetica; padding: 20px;">
<h2>Installation Complete!</h2>
<p><b>Next steps:</b></p>
<ol>
<li>Restart DaVinci Resolve</li>
<li>Go to <b>Workspace &rarr; Scripts &rarr; ScriptToScreen</b></li>
<li>Configure your API keys in the wizard's Step 1:
    <ul>
    <li>Grok (xAI) &mdash; <a href="https://x.ai">x.ai</a></li>
    <li>ElevenLabs &mdash; <a href="https://elevenlabs.io">elevenlabs.io</a></li>
    <li>Kling AI &mdash; <a href="https://klingai.com">klingai.com</a></li>
    </ul>
</li>
</ol>
<p style="color: #666; font-size: 0.85em;">
If something didn't work, check the log at:<br/>
~/Library/Logs/ScriptToScreen/install.log
</p>
</body></html>
        ]]></html-content>
    </conclusion>
    <options customize="never" require-scripts="false"/>
    <choices-outline>
        <line choice="default">
            <line choice="resolve-scripts"/>
            <line choice="user-package"/>
        </line>
    </choices-outline>
    <choice id="default"/>
    <choice id="resolve-scripts" visible="false">
        <pkg-ref id="${PKG_ID}.resolve-scripts"/>
    </choice>
    <choice id="user-package" visible="false">
        <pkg-ref id="${PKG_ID}.user-package"/>
    </choice>
    <pkg-ref id="${PKG_ID}.resolve-scripts" version="${VERSION}" onConclusion="none">resolve-scripts.pkg</pkg-ref>
    <pkg-ref id="${PKG_ID}.user-package" version="${VERSION}" onConclusion="none">user-package.pkg</pkg-ref>
</installer-gui-script>
DISTXML

# Build the final product .pkg
FINAL_PKG="$DIST_DIR/ScriptToScreen-${VERSION}.pkg"
productbuild \
    --distribution "$BUILD_DIR/distribution.xml" \
    --package-path "$BUILD_DIR" \
    --version "$VERSION" \
    "$FINAL_PKG"

echo "  Product package: $FINAL_PKG"

# ============================================================================
# Stage 5: Create DMG containing the .pkg + README + uninstaller
# ============================================================================

echo "[5/5] Building DMG..."

DMG_STAGING="$BUILD_DIR/dmg_staging"
mkdir -p "$DMG_STAGING"

cp "$FINAL_PKG" "$DMG_STAGING/"

# Uninstaller (simple .app wrapper around the uninstall script)
UNINSTALL_APP="$DMG_STAGING/Uninstall ScriptToScreen.app"
mkdir -p "$UNINSTALL_APP/Contents/MacOS"
cat > "$UNINSTALL_APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
    <key>CFBundleName</key><string>Uninstall ScriptToScreen</string>
    <key>CFBundleIdentifier</key><string>com.scripttoscreensts.uninstaller</string>
    <key>CFBundleVersion</key><string>1.0</string>
    <key>CFBundleExecutable</key><string>uninstall</string>
    <key>CFBundlePackageType</key><string>APPL</string>
</dict></plist>
PLIST
cp "$SCRIPT_DIR/uninstall" "$UNINSTALL_APP/Contents/MacOS/uninstall"
chmod +x "$UNINSTALL_APP/Contents/MacOS/uninstall"

# README
cat > "$DMG_STAGING/README.txt" <<README
ScriptToScreen v${VERSION} — AI Filmmaking Plugin for DaVinci Resolve

INSTALL:
  Double-click "ScriptToScreen-${VERSION}.pkg"

AFTER INSTALL:
  1. Restart DaVinci Resolve
  2. Workspace > Scripts > ScriptToScreen
  3. Configure API keys in the wizard

UNINSTALL:
  Double-click "Uninstall ScriptToScreen"
  (Your project files are preserved)

TROUBLESHOOTING:
  Check ~/Library/Logs/ScriptToScreen/install.log
README

DMG_PATH="$DIST_DIR/ScriptToScreen-Installer-${VERSION}.dmg"
hdiutil create \
    -volname "ScriptToScreen ${VERSION}" \
    -srcfolder "$DMG_STAGING" \
    -ov \
    -format UDZO \
    "$DMG_PATH"

# Clean up staging
rm -rf "$DMG_STAGING"

echo ""
echo "============================================"
echo " Build complete!"
echo "============================================"
echo ""
echo " .pkg installer: $FINAL_PKG"
echo " DMG:            $DMG_PATH"
echo " Size:           $(du -h "$DMG_PATH" | cut -f1)"
echo ""
echo " To test: open \"$DMG_PATH\""
echo ""
