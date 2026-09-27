#!/usr/bin/env bash
# Regenerates Resources/AppIcon.icns from scripts/icon/AppIcon.swift.
set -euo pipefail
cd "$(dirname "$0")/.."

WORK=build/icon
rm -rf "$WORK" && mkdir -p "$WORK"
swiftc -parse-as-library -O scripts/icon/AppIcon.swift -o "$WORK/render-icon"
"$WORK/render-icon" "$WORK/AppIcon.iconset"
iconutil -c icns "$WORK/AppIcon.iconset" -o Resources/AppIcon.icns
cp "$WORK/AppIcon.iconset/icon_512x512@2x.png" Resources/AppIcon-1024.png
echo "Wrote Resources/AppIcon.icns"
