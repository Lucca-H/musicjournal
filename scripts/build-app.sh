#!/usr/bin/env bash
# Builds MusicJournal and wraps it in build/MusicJournal.app (ad-hoc signed).
# Usage: scripts/build-app.sh [debug|release]
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${1:-release}"
swift build -c "$CONFIG"
BIN="$(swift build -c "$CONFIG" --show-bin-path)"

APP=build/MusicJournal.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/MusicJournal" "$APP/Contents/MacOS/MusicJournal"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
# Fraunces (SIL Open Font License), loaded at launch by Fraunces.register().
cp -R Resources/Fonts "$APP/Contents/Resources/Fonts"

# Sign with the stable local identity (scripts/setup-signing.sh) so macOS keeps granted
# permissions across rebuilds; fall back to an ad-hoc signature if it isn't set up.
IDENTITY="MusicJournal Local Signing"
if security find-certificate -c "$IDENTITY" >/dev/null 2>&1; then
  codesign --force --sign "$IDENTITY" --timestamp=none "$APP"
else
  echo "Tip: run scripts/setup-signing.sh so permissions survive rebuilds."
  codesign --force --sign - --timestamp=none "$APP"
fi
echo "Built $APP"
