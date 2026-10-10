#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT_DIR"

# Xcode GUI launches scripts with a minimal PATH. Include common Homebrew
# locations so `zig`, `lipo`, and `xcodebuild` are found consistently.
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH"

ZIG="${ZIG:-zig}"
if ! command -v "$ZIG" >/dev/null 2>&1; then
    echo "❌ Zig not found. Install it with: brew install zig"
    echo "   PATH=$PATH"
    exit 1
fi

echo "▶ Checking for SQLite amalgamation..."
if [ ! -f "core/vendor/sqlite3.c" ]; then
    echo "  Downloading SQLite amalgamation..."
    mkdir -p core/vendor
    curl -L "https://www.sqlite.org/2024/sqlite-amalgamation-3450200.zip" -o /tmp/sqlite.zip
    unzip -j /tmp/sqlite.zip "*/sqlite3.c" "*/sqlite3.h" -d core/vendor
    rm /tmp/sqlite.zip
    echo "  ✓ SQLite ready"
else
    echo "  ✓ SQLite already present"
fi

echo "▶ Building WaveSearchKit (Zig → xcframework)..."
cd "$ROOT_DIR/core"
"$ZIG" build xcframework -Doptimize=safe

echo "▶ Copying WaveSearchKit.xcframework into the Xcode app sources..."
APP_FRAMEWORK_DIR="$ROOT_DIR/macos/WaveSearch/WaveSearch/WaveSearchKit.xcframework"
rm -rf "$APP_FRAMEWORK_DIR"
cp -R WaveSearchKit.xcframework "$APP_FRAMEWORK_DIR"

echo "✅ Done. Open macos/WaveSearch/wavesearch.xcodeproj in Xcode and press Run."
