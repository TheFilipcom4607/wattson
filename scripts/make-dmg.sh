#!/usr/bin/env bash
# Builds the disk image people download: Wattson and an Applications link over a background with
# an arrow. Lifted from ffmep's make-dmg.sh.
# Usage: scripts/make-dmg.sh path/to/Wattson.app out.dmg
#
# Finder lays the window out through AppleScript, so the first run asks to let the terminal control Finder.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="${1:?Usage: scripts/make-dmg.sh APP DMG}"
DMG="${2:?Usage: scripts/make-dmg.sh APP DMG}"
VOLNAME="Wattson"
MOUNT="/Volumes/$VOLNAME"

# Finder finds the window by volume name, so another Wattson volume would get laid out instead.
if [[ -e "$MOUNT" ]]; then
  echo "$MOUNT is already mounted. Eject it first." >&2
  exit 1
fi

WORK="$(mktemp -d)"
cleanup() { hdiutil detach -quiet "$MOUNT" 2>/dev/null || true; rm -rf "$WORK"; }
trap cleanup EXIT

echo "==> Drawing the background"
swift "$ROOT/scripts/make-dmg-background.swift" "$WORK/background.png" 1
swift "$ROOT/scripts/make-dmg-background.swift" "$WORK/background@2x.png" 2

STAGE="$WORK/stage"
mkdir -p "$STAGE/.background"
cp -R "$APP" "$STAGE/Wattson.app"
ln -s /Applications "$STAGE/Applications"
# One TIFF holding both sizes, so the arrow stays sharp on Retina.
tiffutil -cathidpicheck "$WORK/background.png" "$WORK/background@2x.png" -out "$STAGE/.background/background.tiff" 2>/dev/null

# Writable first, with room for the .DS_Store Finder is about to write.
SIZE_MB=$(( $(du -sm "$STAGE" | cut -f1) + 20 ))
hdiutil create -quiet -format UDRW -fs HFS+ -volname "$VOLNAME" -size "${SIZE_MB}m" -srcfolder "$STAGE" "$WORK/rw.dmg"
hdiutil attach -quiet -readwrite -noverify -noautoopen "$WORK/rw.dmg"

echo "==> Laying out the window"
# 640×400 of content, matching the background; the extra 32 is the title bar.
osascript <<EOF
tell application "Finder"
  tell disk "$VOLNAME"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set bounds of container window to {200, 120, 840, 552}
    set opts to icon view options of container window
    set arrangement of opts to not arranged
    set icon size of opts to 128
    set text size of opts to 13
    set background picture of opts to file ".background:background.tiff"
    set position of item "Wattson.app" to {160, 190}
    set position of item "Applications" to {480, 190}
    close
    open
    update without registering applications
    delay 1
    close
  end tell
end tell
EOF

# Finder writes .DS_Store lazily; wait for it rather than shipping a window with no layout.
for _ in {1..20}; do
  [[ -f "$MOUNT/.DS_Store" ]] && break
  sleep 0.5
done
if [[ ! -f "$MOUNT/.DS_Store" ]]; then
  echo "Finder never saved the window layout." >&2
  exit 1
fi

# The volume icon goes on only now: the Finder layout above deletes .VolumeIcon.icns and
# clears the volume's custom-icon flag, so an icon staged with the rest shipped as a generic disk.
cp "$ROOT/Resources/AppIcon.icns" "$MOUNT/.VolumeIcon.icns"
SetFile -a C "$MOUNT"

rm -rf "$MOUNT/.fseventsd" "$MOUNT/.Trashes"
sync
hdiutil detach -quiet "$MOUNT"

echo "==> Compressing"
rm -f "$DMG"
hdiutil convert -quiet "$WORK/rw.dmg" -format UDZO -imagekey zlib-level=9 -o "$DMG"
