#!/bin/bash
# Builds a Developer ID-signed, notarized, stapled Wattson-<version>.dmg in build/, and
# points the Homebrew cask in ../homebrew-tap at it.
#
# One-time setup: store notary credentials in the keychain under the profile name below.
#   xcrun notarytool store-credentials wattson-notary \
#       --apple-id <apple id> --team-id 4FGGTM5838 --password <app-specific password>
#
# Pass --no-notarize to stop after signing, e.g. to check the hardened runtime locally.
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="Wattson"
BUNDLE="build/${APP_NAME}.app"
IDENTITY="${WATTSON_SIGN_IDENTITY:-Developer ID Application: Filip Manikowski (4FGGTM5838)}"
NOTARY_PROFILE="${WATTSON_NOTARY_PROFILE:-wattson-notary}"
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Resources/Info.plist)
DMG="build/${APP_NAME}-${VERSION}.dmg"

NOTARIZE=1
[[ "${1:-}" == "--no-notarize" ]] && NOTARIZE=0

./build.sh

# build.sh leaves an ad-hoc signature; replace it. The hardened runtime is what notarization
# requires. Wattson needs no entitlements under it: IOKit user clients, spawning pmset and
# system_profiler, and dlopen of the Apple-signed libIOReport are all allowed as they are.
echo "==> Signing ${BUNDLE} as ${IDENTITY}"
codesign --force --options runtime --timestamp --sign "$IDENTITY" "$BUNDLE"
codesign --verify --strict --verbose=2 "$BUNDLE"

# Run the readers from the signed binary, so anything the hardened runtime refuses shows up
# here rather than on someone else's Mac.
echo "==> Self-test under the hardened runtime"
"${BUNDLE}/Contents/MacOS/${APP_NAME}" --selftest

notarize() {
    xcrun notarytool submit "$1" --keychain-profile "$NOTARY_PROFILE" --wait
}

if (( NOTARIZE )); then
    # The app is notarized and stapled on its own first, so its ticket travels with it once
    # it is copied out of the disk image and Gatekeeper need not go online to check it.
    echo "==> Notarizing the app"
    ZIP="build/${APP_NAME}-notarize.zip"
    rm -f "$ZIP"
    ditto -c -k --keepParent "$BUNDLE" "$ZIP"
    notarize "$ZIP"
    rm -f "$ZIP"
    xcrun stapler staple "$BUNDLE"
fi

echo "==> Building ${DMG}"
STAGING=$(mktemp -d)
trap 'rm -rf "$STAGING"' EXIT
cp -R "$BUNDLE" "$STAGING/"
ln -s /Applications "$STAGING/Applications"
rm -f "$DMG"
hdiutil create -volname "$APP_NAME" -srcfolder "$STAGING" -fs HFS+ -format UDZO -ov "$DMG" >/dev/null
codesign --force --timestamp --sign "$IDENTITY" "$DMG"

if (( NOTARIZE )); then
    echo "==> Notarizing the disk image"
    notarize "$DMG"
    xcrun stapler staple "$DMG"
    spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG"
fi

SHA=$(shasum -a 256 "$DMG" | awk '{print $1}')

# The Homebrew cask lives in TheFilipcom4607/homebrew-tap; if that is checked out next to
# this repo, its version and checksum are rewritten here so they can never drift from the image.
TAP_DIR="${TAP_DIR:-../homebrew-tap}"
CASK="${TAP_DIR}/Casks/wattson.rb"

echo "==> ${DMG}"
echo "    sha256 ${SHA}"
if [[ -f "$CASK" ]]; then
    sed -i '' -e "s/^  version \".*\"\$/  version \"${VERSION}\"/" \
              -e "s/^  sha256 \".*\"\$/  sha256 \"${SHA}\"/" "$CASK"
    echo "==> Updated ${CASK}"
    git -C "$TAP_DIR" --no-pager diff --stat
    echo "    Push the tap only once the GitHub release is up, or brew will fetch a file that isn't there."
else
    echo "==> No cask at ${CASK}; set TAP_DIR if the tap is checked out elsewhere."
fi
