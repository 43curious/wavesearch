#!/bin/sh
set -eu

SOURCE=${1:-"$PWD/.relevance/esc50"}
DEST=${2:-"$PWD/.acoustic-acceptance"}
command -v ffmpeg >/dev/null 2>&1 || {
    echo "ffmpeg is required only to generate the optional codec acceptance fixtures" >&2
    exit 2
}
[ -f "$SOURCE/labels.tsv" ] || {
    echo "Install semantic fixtures first: ./scripts/install-relevance-fixtures.sh" >&2
    exit 2
}
rm -rf "$DEST"
mkdir -p "$DEST/audio"
: > "$DEST/labels.tsv"

TAB=$(printf '\t')
awk -F '\t' '!seen[$2]++ { print $1 "\t" $2 }' "$SOURCE/labels.tsv" |
while IFS="$TAB" read -r original family; do
    index=$(awk 'END { print NR+1 }' "$DEST/sources.tmp" 2>/dev/null || echo 1)
    printf '%s\n' "$family" >> "$DEST/sources.tmp"
    prefix=$(printf 'family-%02d' "$index")
    input="$SOURCE/audio/$original"
    cp "$input" "$DEST/audio/$prefix-source.wav"
    printf '%s-source.wav\t%s\t1\n' "$prefix" "$family" >> "$DEST/labels.tsv"

    ffmpeg -v error -y -i "$input" -af volume=0.18 -ar 44100 "$DEST/audio/$prefix-gain-resample.wav"
    printf '%s-gain-resample.wav\t%s\t0\n' "$prefix" "$family" >> "$DEST/labels.tsv"

    ffmpeg -v error -y -ss 0.23 -i "$input" -t 4.4 "$DEST/audio/$prefix-trim.wav"
    printf '%s-trim.wav\t%s\t0\n' "$prefix" "$family" >> "$DEST/labels.tsv"

    ffmpeg -v error -y -i "$input" -af "highpass=f=120,lowpass=f=6500,acompressor=threshold=-20dB:ratio=3,volume=0.8" "$DEST/audio/$prefix-eq-compress.wav"
    printf '%s-eq-compress.wav\t%s\t0\n' "$prefix" "$family" >> "$DEST/labels.tsv"

    ffmpeg -v error -y -i "$input" -codec:a libmp3lame -q:a 5 "$DEST/$prefix.mp3"
    ffmpeg -v error -y -i "$DEST/$prefix.mp3" -c:a pcm_s16le "$DEST/audio/$prefix-mp3-roundtrip.wav"
    rm -f "$DEST/$prefix.mp3"
    printf '%s-mp3-roundtrip.wav\t%s\t0\n' "$prefix" "$family" >> "$DEST/labels.tsv"

    ffmpeg -v error -y -i "$input" -c:a flac "$DEST/$prefix.flac"
    ffmpeg -v error -y -i "$DEST/$prefix.flac" -c:a pcm_s24le "$DEST/audio/$prefix-flac-roundtrip.wav"
    rm -f "$DEST/$prefix.flac"
    printf '%s-flac-roundtrip.wav\t%s\t0\n' "$prefix" "$family" >> "$DEST/labels.tsv"
done
rm -f "$DEST/sources.tmp"

echo "Generated acoustic acceptance fixtures in $DEST"
echo "Run: cd core && zig build acoustic-acceptance -- '$DEST/audio' '$DEST/labels.tsv'"
