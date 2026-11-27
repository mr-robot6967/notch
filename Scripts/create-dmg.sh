#!/bin/bash
# Build Notch.dmg: background artwork, app + Applications shortcut laid out side by side.
set -euo pipefail

DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$DIR"

./Scripts/package-app.sh

VOL="Notch"
DMG="Notch.dmg"
RW="build/Notch-rw.dmg"
STAGE="build/dmg"

rm -rf "$STAGE" "$RW" "$DMG"
mkdir -p "$STAGE/.background"
cp -R "Notch.app" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
# Retina-aware background (1x + 2x in one TIFF).
tiffutil -cathidpicheck Resources/dmg-background.png Resources/dmg-background@2x.png -out "$STAGE/.background/background.tiff" >/dev/null

echo "Creating writable image..."
hdiutil create -volname "$VOL" -srcfolder "$STAGE" -ov -format UDRW -fs HFS+ "$RW" >/dev/null

# Detach any stale mount with the same name.
if [ -d "/Volumes/$VOL" ]; then hdiutil detach "/Volumes/$VOL" -force >/dev/null || true; fi
MOUNT_DIR=$(hdiutil attach -readwrite -noverify -noautoopen "$RW" | awk -F'\t' '/\/Volumes\//{print $NF}')
echo "Mounted at $MOUNT_DIR"

echo "Laying out the Finder window..."
LAYOUT_OK=1
if ! perl -e "alarm shift; exec @ARGV" 60 osascript <<EOF
tell application "Finder"
    tell disk "$VOL"
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set the bounds of container window to {200, 120, 860, 520}
        set opts to the icon view options of container window
        set arrangement of opts to not arranged
        set icon size of opts to 112
        set text size of opts to 13
        set background picture of opts to file ".background:background.tiff"
        set position of item "Notch.app" of container window to {170, 220}
        set position of item "Applications" of container window to {490, 220}
        update without registering applications
        delay 1
        close
    end tell
end tell
EOF
then
    LAYOUT_OK=0
    echo "warning: Finder layout skipped (allow Terminal to control Finder in System Settings › Privacy › Automation to get the styled window)."
fi

# Volume icon = app icon.
cp Resources/AppIcon.icns "$MOUNT_DIR/.VolumeIcon.icns"
SetFile -a C "$MOUNT_DIR" 2>/dev/null || true

sync
hdiutil detach "$MOUNT_DIR" >/dev/null
echo "Compressing..."
hdiutil convert "$RW" -format UDZO -imagekey zlib-level=9 -o "$DMG" >/dev/null
rm -rf "$STAGE" "$RW"

echo "Created $DIR/$DMG (styled layout: $([ $LAYOUT_OK = 1 ] && echo yes || echo no))"
