#!/bin/bash
# Install Midterms Watcher.
#
#   curl -fsSL https://raw.githubusercontent.com/frenchie4111/midterms-watcher/main/install.sh | bash
#
# Downloads the latest release into /Applications (or ~/Applications if /Applications
# isn't writable) and launches it. From a clone, `./install.sh --from-source` builds
# locally instead (needs Xcode Command Line Tools). `--uninstall` removes it.
set -euo pipefail

REPO="frenchie4111/midterms-watcher"
NAME="Midterms Watcher.app"

if [[ -w /Applications ]]; then DEST=/Applications; else DEST="$HOME/Applications"; fi
mkdir -p "$DEST"

pkill -x MidtermsWatcher 2>/dev/null || true

if [[ "${1:-}" == "--uninstall" ]]; then
    rm -rf "/Applications/$NAME" "$HOME/Applications/$NAME"
    rm -rf "$HOME/Library/Application Support/MidtermsWatcher"
    defaults delete com.mikelyons.midterms-watcher 2>/dev/null || true
    echo "Uninstalled Midterms Watcher."
    exit 0
fi

if [[ "${1:-}" == "--from-source" ]]; then
    HERE="$(cd "$(dirname "$0")" && pwd)"
    APP="$("$HERE/build.sh" | tail -1)"
    rm -rf "$DEST/$NAME"
    cp -R "$APP" "$DEST/"
else
    tmp="$(mktemp -d)"
    trap 'rm -rf "$tmp"' EXIT
    echo "Downloading latest release…"
    curl -fsSL -o "$tmp/app.zip" "https://github.com/$REPO/releases/latest/download/MidtermsWatcher.zip"
    ditto -x -k "$tmp/app.zip" "$tmp"
    rm -rf "$DEST/$NAME"
    mv "$tmp/$NAME" "$DEST/"
    xattr -dr com.apple.quarantine "$DEST/$NAME" 2>/dev/null || true
fi

open "$DEST/$NAME"
echo "Installed to $DEST/$NAME. Look for the 🏛 in your menu bar."
