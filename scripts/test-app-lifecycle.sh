#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="$(mktemp -d "${TMPDIR:-/tmp}/wavesearch-lifecycle.XXXXXX")"
trap 'rm -rf "$BUILD"' EXIT
cd "$ROOT"
KIT="macos/WaveSearch/WaveSearch/WaveSearchKit.xcframework/macos-arm64_x86_64"
# Point at a freshly built native library when validating core changes.
CORE_LIBRARY="${WS_CORE_LIBRARY:-$KIT/libwavesearch.a}"
CORE_HEADERS="${WS_CORE_HEADERS:-$KIT/Headers}"
if [[ -n "${WS_CORE_LIBRARY:-}" && -z "${WS_CORE_HEADERS:-}" ]]; then CORE_HEADERS="$ROOT/core/include"; fi
swiftc -swift-version 5 -default-isolation MainActor \
    macos/WaveSearch/WaveSearch/LatestRequestWorker.swift \
    macos/WaveSearch/Tools/LatestRequestWorkerCheck.swift -o "$BUILD/worker-check"
"$BUILD/worker-check"
SOURCES=()
for file in macos/WaveSearch/WaveSearch/*.swift; do
    [[ "$file" == */WaveSearchApp.swift ]] || SOURCES+=("$file")
done
swiftc -parse-as-library -swift-version 5 -default-isolation MainActor \
    -I "$CORE_HEADERS" "$CORE_LIBRARY" -framework IOKit \
    "${SOURCES[@]}" macos/WaveSearch/Tools/AppStoreLifecycleCheck.swift \
    -o "$BUILD/check"
"$BUILD/check"
