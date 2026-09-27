#!/usr/bin/env bash
# Runs the test suite. With only the Command Line Tools installed (no Xcode),
# SwiftPM doesn't find the Swift Testing framework on its own, so point it there.
set -euo pipefail
cd "$(dirname "$0")/.."

if [[ "$(xcode-select -p)" == *CommandLineTools* ]]; then
  CLT=/Library/Developer/CommandLineTools/Library/Developer
  exec swift test \
    -Xswiftc -F -Xswiftc "$CLT/Frameworks" \
    -Xlinker -F -Xlinker "$CLT/Frameworks" \
    -Xlinker -rpath -Xlinker "$CLT/Frameworks" \
    -Xlinker -rpath -Xlinker "$CLT/usr/lib" \
    "$@"
fi
exec swift test "$@"
