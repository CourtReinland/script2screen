#!/bin/bash
# ============================================================================
# Build ScriptToScreen macOS Installer (.app + .dmg)
#
# Usage: ./build_installer.sh [--version 1.0.0]
#
# Creates:
#   build/Install ScriptToScreen.app
#   build/Uninstall ScriptToScreen.app
#   dist/ScriptToScreen-Installer-{version}.dmg
# ============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
VERSION="${1:-1.0.0}"
VERSION="${VERSION#--version }"

BUILD_DIR="$PROJECT_DIR/build"
DIST_DIR="$PROJECT_DIR/dist"
APP_NAME="Install ScriptToScreen"
UNINSTALL_APP_NAME="Uninstall ScriptToScreen"
DMG_NAME="ScriptToScreen-Installer-${VERSION}"

echo "============================================"
echo " Building ScriptToScreen Installer v$VERSION"
echo "============================================"
echo ""

# Clean previous build
rm -rf "$BUILD_DIR" "$DIST_DIR"
mkdir -p "$BUILD_DIR" "$DIST_DIR"

# ============================================================================
# Build the Installer .app
# ============================================================================

echo "[1/5] Creating installer .app bundle..."

APP_DIR="$BUILD_DIR/$APP_NAME.app"
mkdir -p "$APP_DIR/Contents/MacOS"
mkdir -p "$APP_DIR/Contents/Resources/payload"

# Copy Info.plist (update version)
sed "s/1.0.0/$VERSION/g" "$SCRIPT_DIR/Info.plist" > "$APP_DIR/Contents/Info.plist"

# Copy installer script
cp "$SCRIPT_DIR/install" "$APP_DIR/Contents/MacOS/install"
chmod +x "$APP_DIR/Contents/MacOS/install"

# Copy MLX requirements
cp "$SCRIPT_DIR/requirements-mlx.txt" "$APP_DIR/Contents/Resources/"

# ── Copy payload (source files) ──
echo "[2/5] Copying payload files..."

# Main Lua scripts
cp "$PROJECT_DIR/ScriptToScreen.lua" "$APP_DIR/Contents/Resources/payload/"
cp "$PROJECT_DIR/ScriptToScreen.py" "$APP_DIR/Contents/Resources/payload/" 2>/dev/null || true

# Standalone tools
for script in STS_Common.lua STS_Reprompt_Image.lua STS_Reprompt_Video.lua \
              STS_Generate_Audio.lua STS_Lip_Sync.lua STS_ReframeShot.lua \
              STS_ScriptRef.lua STS_Toolbar.lua STS_ExpandShots.lua; do
    if [ -f "$PROJECT_DIR/$script" ]; then
        cp "$PROJECT_DIR/$script" "$APP_DIR/Contents/Resources/payload/"
    fi
done

# Python package
cp -r "$PROJECT_DIR/script_to_screen" "$APP_DIR/Contents/Resources/payload/"
# Clean __pycache__
find "$APP_DIR/Contents/Resources/payload/script_to_screen" -type d -name "__pycache__" -exec rm -rf {} + 2>/dev/null || true

# Requirements
cp "$PROJECT_DIR/requirements.txt" "$APP_DIR/Contents/Resources/payload/" 2>/dev/null || true

# ── Generate app icon ──
echo "[3/5] Generating app icon..."

# Create a simple icon using Python/Pillow or sips
ICON_DIR="$APP_DIR/Contents/Resources/AppIcon.iconset"
mkdir -p "$ICON_DIR"

# Generate icon PNGs using Python
python3 -c "
from PIL import Image, ImageDraw, ImageFont
import os

sizes = [16, 32, 64, 128, 256, 512, 1024]
icon_dir = '$ICON_DIR'

for size in sizes:
    img = Image.new('RGBA', (size, size), (0, 0, 0, 0))
    draw = ImageDraw.Draw(img)

    # Background: dark rounded rectangle
    margin = max(1, size // 16)
    r = max(2, size // 5)
    draw.rounded_rectangle([margin, margin, size-margin, size-margin], radius=r, fill=(30, 30, 40, 255))

    # Film strip bars
    bar_h = max(1, size // 8)
    draw.rectangle([margin, margin, size-margin, margin + bar_h], fill=(60, 60, 80, 255))
    draw.rectangle([margin, size-margin-bar_h, size-margin, size-margin], fill=(60, 60, 80, 255))

    # Sprocket holes
    hole_size = max(1, size // 20)
    for i in range(4):
        x = margin + (size - 2*margin) * (i + 0.5) / 4
        draw.ellipse([x-hole_size, margin+bar_h//4-hole_size, x+hole_size, margin+bar_h//4+hole_size], fill=(30, 30, 40, 255))
        draw.ellipse([x-hole_size, size-margin-bar_h//4-hole_size, x+hole_size, size-margin-bar_h//4+hole_size], fill=(30, 30, 40, 255))

    # Center text
    if size >= 64:
        fs = max(8, size // 6)
        try:
            font = ImageFont.truetype('/System/Library/Fonts/Helvetica.ttc', fs)
        except:
            font = ImageFont.load_default()
        text = 'STS'
        bbox = draw.textbbox((0, 0), text, font=font)
        tw, th = bbox[2] - bbox[0], bbox[3] - bbox[1]
        draw.text(((size-tw)//2, (size-th)//2 - size//20), text, fill=(120, 200, 255, 255), font=font)

        # Subtitle
        if size >= 128:
            fs2 = max(6, size // 14)
            try:
                font2 = ImageFont.truetype('/System/Library/Fonts/Helvetica.ttc', fs2)
            except:
                font2 = ImageFont.load_default()
            sub = 'AI Film'
            bbox2 = draw.textbbox((0, 0), sub, font=font2)
            sw = bbox2[2] - bbox2[0]
            draw.text(((size-sw)//2, (size+th)//2 + size//20), sub, fill=(180, 180, 200, 255), font=font2)

    # Save at both 1x and 2x
    img.save(os.path.join(icon_dir, f'icon_{size}x{size}.png'))
    if size <= 512:
        img.save(os.path.join(icon_dir, f'icon_{size//2}x{size//2}@2x.png'))
" 2>/dev/null || {
    echo "  Warning: Could not generate icon (Pillow not available). Using placeholder."
    # Create minimal placeholder icons
    for size in 16 32 128 256 512; do
        sips -z $size $size /System/Library/CoreServices/CoreTypes.bundle/Contents/Resources/GenericApplicationIcon.icns --out "$ICON_DIR/icon_${size}x${size}.png" 2>/dev/null || true
    done
}

# Convert iconset to icns
iconutil -c icns "$ICON_DIR" -o "$APP_DIR/Contents/Resources/AppIcon.icns" 2>/dev/null || {
    echo "  Warning: Could not create icns file"
}
rm -rf "$ICON_DIR"

# ============================================================================
# Build the Uninstaller .app
# ============================================================================

echo "[4/5] Creating uninstaller .app..."

UNINSTALL_DIR="$BUILD_DIR/$UNINSTALL_APP_NAME.app"
mkdir -p "$UNINSTALL_DIR/Contents/MacOS"
mkdir -p "$UNINSTALL_DIR/Contents/Resources"

# Uninstaller Info.plist
cat > "$UNINSTALL_DIR/Contents/Info.plist" << 'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>Uninstall ScriptToScreen</string>
    <key>CFBundleIdentifier</key>
    <string>com.scripttoscreensts.uninstaller</string>
    <key>CFBundleVersion</key>
    <string>1.0.0</string>
    <key>CFBundleExecutable</key>
    <string>uninstall</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
PLIST

cp "$SCRIPT_DIR/uninstall" "$UNINSTALL_DIR/Contents/MacOS/uninstall"
chmod +x "$UNINSTALL_DIR/Contents/MacOS/uninstall"

# ============================================================================
# Build DMG
# ============================================================================

echo "[5/5] Building DMG..."

DMG_TEMP="$BUILD_DIR/dmg_staging"
mkdir -p "$DMG_TEMP"
cp -r "$APP_DIR" "$DMG_TEMP/"
cp -r "$UNINSTALL_DIR" "$DMG_TEMP/"

# Add a README
cat > "$DMG_TEMP/README.txt" << 'README'
ScriptToScreen — AI Filmmaking Plugin for DaVinci Resolve

INSTALLATION:
  Double-click "Install ScriptToScreen" to begin.

AFTER INSTALLATION:
  1. Restart DaVinci Resolve
  2. Go to Workspace > Scripts > ScriptToScreen
  3. Configure your API keys in the wizard's Step 1

UNINSTALL:
  Double-click "Uninstall ScriptToScreen" to remove.

For support, visit: https://github.com/scripttoscreensts
README

# Create DMG
DMG_PATH="$DIST_DIR/${DMG_NAME}.dmg"
hdiutil create \
    -volname "ScriptToScreen Installer" \
    -srcfolder "$DMG_TEMP" \
    -ov \
    -format UDZO \
    "$DMG_PATH" 2>/dev/null || {
    # Fallback: create uncompressed DMG
    hdiutil create \
        -volname "ScriptToScreen Installer" \
        -srcfolder "$DMG_TEMP" \
        -ov \
        -format UDRW \
        "$DMG_PATH"
}

# Clean up staging
rm -rf "$DMG_TEMP"

echo ""
echo "============================================"
echo " Build complete!"
echo "============================================"
echo ""
echo " Installer app:  $APP_DIR"
echo " Uninstaller app: $UNINSTALL_DIR"
echo " DMG:            $DMG_PATH"
echo " Size:           $(du -h "$DMG_PATH" | cut -f1)"
echo ""
echo " To test: open \"$DMG_PATH\""
echo ""
