#!/usr/bin/env bash
# Builds a universal (Apple silicon + Intel) release copy of MusicJournal and zips it for a GitHub Release.
# Usage: scripts/package.sh   → dist/MusicJournal-<version>.zip
#
# The zipped copy is signed ad hoc (not with your local signing identity), since that
# identity only means something on this Mac. Your own build/MusicJournal.app is left as is.
set -euo pipefail
cd "$(dirname "$0")/.."

scripts/build-app.sh release

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)"
STAGE="dist/stage"
ZIP="dist/MusicJournal-$VERSION.zip"

rm -rf "$STAGE" "$ZIP"
mkdir -p "$STAGE"
ditto build/MusicJournal.app "$STAGE/MusicJournal.app"

# Universal: add an Intel build next to the Apple silicon one, so it runs on any Mac.
# (Its own scratch folder: sharing .build with the Apple silicon build confuses SwiftPM.)
swift build -c release --arch x86_64 --scratch-path .build-intel
INTEL="$(swift build -c release --arch x86_64 --scratch-path .build-intel --show-bin-path)/MusicJournal"
lipo -create build/MusicJournal.app/Contents/MacOS/MusicJournal "$INTEL" \
  -output "$STAGE/MusicJournal.app/Contents/MacOS/MusicJournal"
# Drop debug info: it records the folder the app was built in (your username included).
strip -S -x "$STAGE/MusicJournal.app/Contents/MacOS/MusicJournal"
codesign --force --sign - --timestamp=none "$STAGE/MusicJournal.app"
codesign --verify --strict "$STAGE/MusicJournal.app"
ditto -c -k --keepParent "$STAGE/MusicJournal.app" "$ZIP"
rm -rf "$STAGE"

echo "Packaged $ZIP ($(du -h "$ZIP" | cut -f1))"
echo "Next: on GitHub, Releases → Draft a new release → tag v$VERSION → attach $ZIP → Publish."
