#!/bin/bash
# Shared CI setup: use only the checkout's exact, checksum-verified toolchain.
set -euo pipefail
cd "$(dirname "$0")/.."
: "${RUNNER_TEMP:?GitHub Actions RUNNER_TEMP is required}"
: "${GITHUB_PATH:?GitHub Actions GITHUB_PATH is required}"
version="$(cat .zig-version)"
case "$(uname -s)/$(uname -m)" in
    Linux/x86_64) platform=x86_64-linux ;;
    Darwin/arm64) platform=aarch64-macos ;;
    Darwin/x86_64) platform=x86_64-macos ;;
    *) echo "Unsupported runner platform" >&2; exit 1 ;;
esac
curl --fail --silent --show-error --location --retry 3 \
    https://ziglang.org/download/index.json -o "$RUNNER_TEMP/zig-index.json"
python3 - "$version" "$platform" "$RUNNER_TEMP/zig-index.json" > "$RUNNER_TEMP/zig-release.txt" <<'PY'
import json, sys
with open(sys.argv[3]) as source:
    release = json.load(source)[sys.argv[1]][sys.argv[2]]
print(release["tarball"], release["shasum"])
PY
read -r url checksum < "$RUNNER_TEMP/zig-release.txt"
curl --fail --silent --show-error --location --retry 3 \
    "$url" -o "$RUNNER_TEMP/zig.tar.xz"
echo "$checksum  $RUNNER_TEMP/zig.tar.xz" | shasum -a 256 --check
mkdir -p "$RUNNER_TEMP/wavesearch-zig"
tar -xJf "$RUNNER_TEMP/zig.tar.xz" --strip-components=1 -C "$RUNNER_TEMP/wavesearch-zig"
test "$("$RUNNER_TEMP/wavesearch-zig/zig" version)" = "$version"
echo "$RUNNER_TEMP/wavesearch-zig" >> "$GITHUB_PATH"
