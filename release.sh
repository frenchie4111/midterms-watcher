#!/bin/bash
# Build a Developer ID–signed release: dist/MidtermsWatcher.zip and dist/MidtermsWatcher.dmg.
# Notarizes + staples when credentials are available, either:
#   - APPLE_ID / APPLE_APP_SPECIFIC_PASSWORD / APPLE_TEAM_ID in the environment, or
#   - the "midterms-watcher-notary" keychain profile (create once: ./release.sh --setup-notary).
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SIGN_ID="${SIGN_ID:-Developer ID Application: Michael Lyons (M7Y6TPCQ63)}"
TEAM_ID="M7Y6TPCQ63"
NOTARY_PROFILE="${NOTARY_PROFILE:-midterms-watcher-notary}"
DIST="$HERE/dist"

if [[ "${1:-}" == "--setup-notary" ]]; then
    read -r -p "Apple ID email: " apple_id
    exec xcrun notarytool store-credentials "$NOTARY_PROFILE" --apple-id "$apple_id" --team-id "$TEAM_ID"
fi

notarize=0
if [[ -n "${APPLE_ID:-}" && -n "${APPLE_APP_SPECIFIC_PASSWORD:-}" ]]; then
    notary_auth=(--apple-id "$APPLE_ID" --password "$APPLE_APP_SPECIFIC_PASSWORD" --team-id "${APPLE_TEAM_ID:-$TEAM_ID}")
    notarize=1
elif xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1; then
    notary_auth=(--keychain-profile "$NOTARY_PROFILE")
    notarize=1
else
    echo "warning: no notarization credentials; building signed but NOT notarized." >&2
fi

APP="$(SIGN_ID="$SIGN_ID" "$HERE/build.sh" | tail -1)"
rm -rf "$DIST" && mkdir -p "$DIST"

if [[ $notarize == 1 ]]; then
    ditto -c -k --keepParent "$APP" "$DIST/notarize.zip"
    xcrun notarytool submit "$DIST/notarize.zip" "${notary_auth[@]}" --wait
    xcrun stapler staple "$APP"
    rm "$DIST/notarize.zip"
fi

ditto -c -k --keepParent "$APP" "$DIST/MidtermsWatcher.zip"

stage="$(mktemp -d)"
cp -R "$APP" "$stage/"
ln -s /Applications "$stage/Applications"
hdiutil create -quiet -volname "Midterms Watcher" -srcfolder "$stage" -ov -format UDZO "$DIST/MidtermsWatcher.dmg"
rm -rf "$stage"
codesign --force --timestamp --sign "$SIGN_ID" "$DIST/MidtermsWatcher.dmg"
if [[ $notarize == 1 ]]; then
    xcrun notarytool submit "$DIST/MidtermsWatcher.dmg" "${notary_auth[@]}" --wait
    xcrun stapler staple "$DIST/MidtermsWatcher.dmg"
fi

ls -lh "$DIST"
version="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$HERE/Info.plist")"
echo
echo "Publish with:"
echo "  gh release create v$version dist/MidtermsWatcher.dmg dist/MidtermsWatcher.zip --title \"v$version\" --generate-notes"
