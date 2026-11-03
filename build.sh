#!/bin/bash
# Build "build/Midterms Watcher.app" as a universal (Apple Silicon + Intel) binary.
# Signs ad-hoc by default; set SIGN_ID="Developer ID Application: …" for a distributable build.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
APP="$HERE/build/Midterms Watcher.app"
SIGN_ID="${SIGN_ID:--}"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$HERE/Info.plist" "$APP/Contents/Info.plist"
cp "$HERE/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"

for arch in arm64 x86_64; do
    swiftc -O -parse-as-library -target "$arch-apple-macos14.0" \
        -o "$HERE/build/MidtermsWatcher-$arch" "$HERE/MidtermsWatcher.swift"
done
lipo -create -output "$APP/Contents/MacOS/MidtermsWatcher" "$HERE"/build/MidtermsWatcher-{arm64,x86_64}
rm "$HERE"/build/MidtermsWatcher-{arm64,x86_64}

if [[ "$SIGN_ID" == "-" ]]; then
    codesign --force --sign - "$APP"
else
    codesign --force --options runtime --timestamp --sign "$SIGN_ID" "$APP"
fi
codesign --verify --strict "$APP"
echo "$APP"
