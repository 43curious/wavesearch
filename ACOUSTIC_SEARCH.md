# Acoustic identity and search by example

WaveSearch schema v8 stores versioned landmark fingerprints independently from
CLAP embeddings. The algorithm uses the complete WAV/AIFF timeline resampled by
a 32-tap anti-aliased polyphase sinc filter to canonical 16 kHz mono (bounded to
five minutes), 1024-point Hann-window FFT frames, local spectral peaks, bounded
landmark pairs, fuzzy quantized-hash neighborhoods, and tolerant time-offset
voting. Neighbor hashes are retrieved in one bounded SQLite `IN` batch per
selector rather than one statement per hash. Corpus document frequency
suppresses common selectors. Persisted edges and deterministic connected
components provide transitive family IDs; dirty components are rebuilt once at
the end of an indexing operation rather than after every file batch.

Extraction streams bounded canonical PCM into the same v3 algorithm. Schema 14
adds lossless grouped storage and resumable legacy repacking, plus explicit
source strength and complete-byte duplicate verification. See
[contracts, measurements, and compatibility](documentation/INDEXING_STORAGE_IDENTITIES.md).

## Behavior

- `ws_acoustic_index_pending` is resumable and invalidates changed files while
  preserving unchanged and relocated files. Schema 13 uses
  [durable pending queues](documentation/REFINEMENT_QUEUES.md) across bounded
  calls and reopen; refinement publishes fingerprints, postings, and edges in
  one transaction.
- `ws_search_by_example` uses versioned integer confidence calibration to weight
  high-confidence fingerprint families ahead of CLAP audio-embedding neighbors and remains useful when CLAP is unavailable.
- `ws_acoustic_group` returns persisted transitive family identity/count and a
  conservative weakest-edge component confidence. Dirty components are hidden
  until deterministic union-find reconstruction completes.
- Legacy `ws_duplicate_count(content_hash)` remains ABI-compatible and verifies
  complete bytes for known full-hash groups. Unknown/sampled/ambiguous groups
  return zero; `ws_duplicate_verify_v1` verifies candidates by file ID. Acoustic
  families remain the UI's primary similarity signal.
- Built-in acoustic decoding supports WAV and uncompressed AIFF/AIFC. The
  `ws_search_by_example_pcm` ABI supports finite host-decoded PCM from optional
  MP3/FLAC/AAC decoders without making codecs core dependencies.

## Deterministic fixture acceptance

Tests synthesize a non-stationary source effect plus:

1. PCM16 48 kHz source;
2. PCM16 44.1 kHz, -14 dB level-shifted/resampled variant;
3. hop-misaligned leading/trailing trimmed variant;
4. equivalent big-endian AIFF container/level variant;
5. unrelated non-stationary distractor.

The source-family example search retrieves all four positives before the
negative, with no high-confidence false positive. Additional tests cover
anti-alias rejection, fuzzy hash boundaries, transitive A-B-C families and
bridge deletion, multi-window planning, and host-decoded PCM search. The fixture matrix therefore
records precision 1.00, transformed-variant recall 1.00, and source-family
recall@5 1.00. Separate pure-algorithm tests cover gain invariance, trim offset
alignment, deterministic serialization, and negative rejection.

Run:

```sh
cd core
zig build test
```

These generated fixtures contain no third-party media and run offline on macOS
and Linux.

An explicit optional codec matrix uses the pinned ESC-50 fixtures plus FFmpeg to
produce gain/resample, trim, EQ/compression, MP3-roundtrip, and FLAC-roundtrip
families:

```sh
./scripts/generate-acoustic-acceptance.sh
cd core
zig build acoustic-acceptance -- \
  ../.acoustic-acceptance/audio ../.acoustic-acceptance/labels.tsv
```

The harness enforces precision >= 0.99 and source-family recall@5 >= 0.90;
normal builds/tests never invoke FFmpeg or download this corpus.
