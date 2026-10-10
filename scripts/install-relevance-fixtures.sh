#!/bin/sh
set -eu

ESC50_COMMIT=33c8ce9eb2cf0b1c2f8bcf322eb349b6be34dbb6
BASE="https://raw.githubusercontent.com/karolpiczak/ESC-50/$ESC50_COMMIT"
DEST=${1:-"$PWD/.relevance/esc50"}
CATEGORIES="dog rain sea_waves footsteps helicopter chainsaw clock_tick crackling_fire"

mkdir -p "$DEST/audio"
DEST=$(cd "$DEST" && pwd)
TMP="$DEST/.metadata.tmp"
curl --fail --location --silent --show-error --retry 3 "$BASE/meta/esc50.csv" -o "$TMP"
curl --fail --location --silent --show-error --retry 3 "$BASE/LICENSE" -o "$DEST/LICENSE"

: > "$DEST/labels.tsv"
: > "$DEST/manifest.tsv"
printf '# ESC-50 commit\t%s\n' "$ESC50_COMMIT" >> "$DEST/manifest.tsv"
printf '# opaque_name\toriginal_name\tcategory\tfold\tsha256\n' >> "$DEST/manifest.tsv"

SELECTED="$DEST/.selected.tmp"
awk -F, -v wanted="$CATEGORIES" '
BEGIN { split(wanted, a, " "); for (i in a) keep[a[i]]=1 }
NR > 1 && keep[$4] && !seen[$2 SUBSEP $4]++ { print $1 "\t" $4 "\t" $2 }
' "$TMP" > "$SELECTED"

count=0
while IFS="	" read -r original category fold; do
    opaque=$(printf 'clip-%03d.wav' "$count")
    target="$DEST/audio/$opaque"
    curl --fail --location --silent --show-error --retry 3 "$BASE/audio/$original" -o "$target.tmp"
    mv "$target.tmp" "$target"
    sha=$(shasum -a 256 "$target" | awk '{print $1}')
    printf '%s\t%s\n' "$opaque" "$category" >> "$DEST/labels.tsv"
    printf '%s\t%s\t%s\t%s\t%s\n' "$opaque" "$original" "$category" "$fold" "$sha" >> "$DEST/manifest.tsv"
    count=$((count + 1))
done < "$SELECTED"

rm -f "$TMP" "$SELECTED"
if [ "$count" -ne 40 ]; then
    echo "Expected 40 fixtures, downloaded $count" >&2
    exit 1
fi

echo "Installed $count opaque-name ESC-50 clips in $DEST"
echo "Run:"
echo "  cd core"
echo "  zig build relevance -- \"\$WS_ORT_LIBRARY\" \"\$WS_CLAP_MODEL_DIR\" \"$DEST/audio\" \"$DEST/labels.tsv\""
