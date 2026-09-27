#!/usr/bin/env bash
# Opens MusicJournal in each review state (sample data, no music, no Claude, a throwaway
# journal) and captures only its window to build/ui-review/<state>.png.
# Needs Screen Recording permission for the terminal running this.
# Usage: scripts/ui-review.sh [state ...]   (default: every state)
set -euo pipefail
cd "$(dirname "$0")/.."

APP=build/MusicJournal.app
OUT=build/ui-review
mkdir -p "$OUT" build/review-tools
swiftc -O scripts/review/window-id.swift -o build/review-tools/window-id 2>/dev/null

STATES=("$@")
if [ ${#STATES[@]} -eq 0 ]; then
  STATES=(welcome-0 welcome-1 welcome-2 welcome-3 welcome-4 welcome-5 mood mood-working mood-results now-playing journal journal-locked zen settings)
fi

for state in "${STATES[@]}"; do
  pkill -x MusicJournal 2>/dev/null || true
  sleep 0.8
  open -n "$APP" --args --review "$state"
  sleep 3.5
  which=main; [ "$state" = settings ] && which=settings
  wid=$(build/review-tools/window-id "$which" || true)
  if [ -z "$wid" ]; then echo "✗ $state: window not found"; continue; fi
  if screencapture -x -o -l "$wid" "$OUT/$state.png" 2>/dev/null; then
    echo "✓ $state"
  else
    echo "✗ $state: capture failed (Screen Recording permission?)"
  fi
done
pkill -x MusicJournal 2>/dev/null || true
