#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "usage: $0 AUDIO_FILE" >&2
  exit 2
fi

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
./build.sh >/dev/null

HEADERS="core/WaveSearchKit.xcframework/macos-arm64_x86_64/Headers"
LIBRARY="core/WaveSearchKit.xcframework/macos-arm64_x86_64/libwavesearch.a"
OUTPUT="${TMPDIR:-/tmp}/wavesearch-waveform-benchmark"

xcrun swiftc -O -parse-as-library \
  -I "$HEADERS" \
  macos/WaveSearch/WaveSearch/AudioAnalysis.swift \
  macos/WaveSearch/WaveSearch/ZigWaveformAnalysis.swift \
  macos/WaveSearch/WaveSearch/AudioAnalysisRepository.swift \
  macos/WaveSearch/WaveSearch/WaveformSignposts.swift \
  macos/WaveSearch/Tools/LegacyWaveformReference.swift \
  macos/WaveSearch/Tools/WaveformBenchmark.swift \
  "$LIBRARY" \
  -o "$OUTPUT" \
  -framework AVFoundation -framework Accelerate -framework Foundation -framework OSLog -liconv

"$OUTPUT" "$1"
