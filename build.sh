#!/bin/bash
# Builds Wattson.app. Pass --install to also copy it to /Applications and launch it.
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="Wattson"
BUNDLE="build/${APP_NAME}.app"

echo "==> Compiling (release)"
swift build -c release --disable-sandbox

echo "==> Assembling ${BUNDLE}"
rm -rf "$BUNDLE"
mkdir -p "${BUNDLE}/Contents/MacOS" "${BUNDLE}/Contents/Resources"
cp ".build/release/${APP_NAME}" "${BUNDLE}/Contents/MacOS/${APP_NAME}"
cp "Resources/Info.plist" "${BUNDLE}/Contents/Info.plist"
[ -f "Resources/AppIcon.icns" ] && cp "Resources/AppIcon.icns" "${BUNDLE}/Contents/Resources/AppIcon.icns"
printf 'APPL????' > "${BUNDLE}/Contents/PkgInfo"

# Ad-hoc signature: enough for a locally built app to run and to hold a login item.
echo "==> Signing (ad-hoc)"
codesign --force --sign - --timestamp=none "$BUNDLE"

echo "==> Built $(pwd)/${BUNDLE}"

if [[ "${1:-}" == "--install" ]]; then
    echo "==> Installing to /Applications"
    pkill -x "$APP_NAME" 2>/dev/null || true
    sleep 1
    rm -rf "/Applications/${APP_NAME}.app"
    cp -R "$BUNDLE" "/Applications/${APP_NAME}.app"
    open "/Applications/${APP_NAME}.app"
    echo "==> Running. Look for the icon in your menu bar."
fi
