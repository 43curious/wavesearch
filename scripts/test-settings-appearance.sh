#!/bin/bash
# Requires a macOS desktop session; uses an isolated test process and no catalog.
set -euo pipefail
cd "$(dirname "$0")/.."
BUILD="$(mktemp -d "${TMPDIR:-/tmp}/wavesearch-settings-appearance.XXXXXX")"
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
    "${SOURCES[@]}" macos/WaveSearch/Tools/SettingsAppearanceCheck.swift -o "$BUILD/check"
bash scripts/run-gui-check.sh "$BUILD/check"
