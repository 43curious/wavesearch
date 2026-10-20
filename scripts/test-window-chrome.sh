#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
BUILD="$(mktemp -d "${TMPDIR:-/tmp}/wavesearch-chrome.XXXXXX")"
trap 'rm -rf "$BUILD"' EXIT
swiftc macos/WaveSearch/Tools/DesktopSessionCheck.swift -o "$BUILD/desktop"
"$BUILD/desktop"
KIT="macos/WaveSearch/WaveSearch/WaveSearchKit.xcframework/macos-arm64_x86_64"
SOURCES=()
for file in macos/WaveSearch/WaveSearch/*.swift; do
    [[ "$file" == */WaveSearchApp.swift ]] || SOURCES+=("$file")
done
swiftc -parse-as-library -swift-version 5 -default-isolation MainActor \
    -I "$KIT/Headers" "$KIT/libwavesearch.a" -framework IOKit \
    "${SOURCES[@]}" macos/WaveSearch/Tools/WindowChromeCheck.swift -o "$BUILD/check"
bash scripts/run-gui-check.sh "$BUILD/check" | tee "$BUILD/output"
# A window close must not quit the test app before reopening assertions run.
grep -q 'PASS: native shortcut conflict' "$BUILD/output"
grep -q 'PASS: sidebar toolbar/menu shortcut' "$BUILD/output"
