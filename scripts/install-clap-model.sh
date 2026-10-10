#!/bin/sh
set -eu

# Explicit, opt-in installer for the WaveSearch Phase 2 CLAP pack. The app and
# normal build never invoke this script or perform model/runtime downloads.
if [ "$#" -gt 1 ]; then
    echo "Usage: $0 [INSTALL_PARENT_DIRECTORY]" >&2
    echo "Downloads about 800 MB and installs an additional ONNX Runtime archive." >&2
    exit 2
fi

if [ "$#" -eq 1 ]; then
    DEST=$1
elif [ "$(uname -s)" = Darwin ]; then
    # WaveSearch is sandboxed; its writable/readable Application Support lives
    # inside the app container. The app auto-discovers this default location.
    DEST="$HOME/Library/Containers/SPL.WaveSearch/Data/Library/Application Support/WaveSearch"
else
    DEST="${XDG_DATA_HOME:-$HOME/.local/share}/wavesearch"
fi
BUNDLE="$DEST/wavesearch-clap"
if [ -e "$BUNDLE" ]; then
    echo "Refusing to replace existing $BUNDLE" >&2
    exit 1
fi
command -v curl >/dev/null 2>&1 || { echo "curl is required" >&2; exit 1; }
command -v tar >/dev/null 2>&1 || { echo "tar is required" >&2; exit 1; }

case "$(uname -s):$(uname -m)" in
    Darwin:arm64)
        ORT_ARCHIVE=onnxruntime-osx-arm64-1.29.0.tgz
        ORT_SHA256=d0706fc34f315d8c88639d0a8c81f2e09e815f282cabed3493c06a054352cf92
        ORT_DIR=onnxruntime-osx-arm64-1.29.0
        ORT_LIBRARY=lib/libonnxruntime.dylib
        ;;
    Linux:x86_64)
        ORT_ARCHIVE=onnxruntime-linux-x64-1.29.0.tgz
        ORT_SHA256=c3fddc4f139a045b0c4902c57410f0694f1c2fdf9b6939fbe38b1aeae7cd14ba
        ORT_DIR=onnxruntime-linux-x64-1.29.0
        ORT_LIBRARY=lib/libonnxruntime.so
        ;;
    Darwin:x86_64)
        echo "The pinned ONNX Runtime 1.29.0 release has no supported macOS x86_64 artifact; installation aborted." >&2
        exit 1
        ;;
    *)
        echo "Unsupported platform: $(uname -s) $(uname -m) (supported: macOS arm64, Linux x86_64)" >&2
        exit 1
        ;;
esac

SHA_TOOL=
if command -v shasum >/dev/null 2>&1; then
    SHA_TOOL=shasum
elif command -v sha256sum >/dev/null 2>&1; then
    SHA_TOOL=sha256sum
else
    echo "shasum or sha256sum is required" >&2
    exit 1
fi

mkdir -p "$DEST"
STAGE=$(mktemp -d "$DEST/.wavesearch-clap.XXXXXX")
trap 'rm -rf "$STAGE"' EXIT HUP INT TERM
MODEL="$STAGE/model"
mkdir -p "$MODEL"
HF_REV=d4d4372c9894b975ec118589b4f4328103796e15
HF_BASE="https://huggingface.co/muzaiten/clap-htsat-base-onnx/resolve/$HF_REV"
ORT_URL="https://github.com/microsoft/onnxruntime/releases/download/v1.29.0/$ORT_ARCHIVE"

verify() {
    expected=$1
    file=$2
    if [ "$SHA_TOOL" = shasum ]; then
        actual=$(shasum -a 256 "$file" | cut -d ' ' -f 1)
    else
        actual=$(sha256sum "$file" | cut -d ' ' -f 1)
    fi
    if [ "$actual" != "$expected" ]; then
        echo "SHA-256 mismatch for $file" >&2
        echo "expected $expected" >&2
        echo "actual   $actual" >&2
        exit 1
    fi
}

download() {
    url=$1
    expected=$2
    output=$3
    partial="$output.partial"
    echo "Downloading $(basename "$output")..."
    curl --fail --location --retry 3 --proto '=https' --tlsv1.2 "$url" -o "$partial"
    verify "$expected" "$partial"
    mv "$partial" "$output"
}

download "$HF_BASE/manifest.json" 520b7ae740d9b634680c1f1af0735ca227b2fc80c9c33c006f53f1b8242ea83e "$MODEL/manifest.json"
download "$HF_BASE/audio.onnx" 9533ed823c150fb13c91ecd7359aa3bff1aa6da7b44099a21ccea10c0adba2d6 "$MODEL/audio.onnx"
download "$HF_BASE/text.onnx" 069e323e309284ae9aca6587b884afcd38f943fa1cba260823f4673b18f09a26 "$MODEL/text.onnx"
download "$HF_BASE/tokenizer.json" 2bb1a22cfbe25b8e5a232b7fc4d7fc5073923b45724a5f813b00811bb6620f66 "$MODEL/tokenizer.json"
download "$ORT_URL" "$ORT_SHA256" "$STAGE/$ORT_ARCHIVE"

tar -xzf "$STAGE/$ORT_ARCHIVE" -C "$STAGE"
rm "$STAGE/$ORT_ARCHIVE"
[ -f "$STAGE/$ORT_DIR/$ORT_LIBRARY" ] || { echo "ONNX Runtime archive layout did not match the pinned contract" >&2; exit 1; }

# STAGE is on the destination filesystem, so this final rename is atomic.
mv "$STAGE" "$BUNDLE"
trap - EXIT HUP INT TERM

echo "Installed verified CLAP model and ONNX Runtime in $BUNDLE"
if [ "$(uname -s)" = Darwin ] && [ "$#" -eq 0 ]; then
    echo "WaveSearch will auto-discover this container installation on its next launch."
else
    echo "Set:"
    echo "export WS_CLAP_MODEL_DIR='$BUNDLE/model'"
    echo "export WS_ORT_LIBRARY='$BUNDLE/$ORT_DIR/$ORT_LIBRARY'"
    echo "export WS_CLAP_THREADS=2"
fi
