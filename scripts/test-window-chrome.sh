#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
BUILD="$(mktemp -d "${TMPDIR:-/tmp}/wavesearch-chrome.XXXXXX")"
trap 'rm -rf "$BUILD"' EXIT
KIT="macos/WaveSearch/WaveSearch/WaveSearchKit.xcframework/macos-arm64_x86_64"
SOURCES=()
for file in macos/WaveSearch/WaveSearch/*.swift; do
    [[ "$file" == */WaveSearchApp.swift ]] || SOURCES+=("$file")
done
swiftc -parse-as-library -swift-version 5 -default-isolation MainActor \
    -I "$KIT/Headers" "$KIT/libwavesearch.a" -framework IOKit \
    "${SOURCES[@]}" macos/WaveSearch/Tools/WindowChromeCheck.swift -o "$BUILD/check"
"$BUILD/check"
