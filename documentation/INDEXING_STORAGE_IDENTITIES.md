# Streaming fingerprints, storage, and byte identity

Issues [#3](https://github.com/43curious/wavesearch/issues/3),
[#5](https://github.com/43curious/wavesearch/issues/5), and
[#7](https://github.com/43curious/wavesearch/issues/7) add bounded extraction,
lossless storage, and complete-byte duplicate verification. Existing C structures
and entry points remain compatible. Schema 14 adds source kind/algorithm columns
and an indexed fingerprint storage revision. Older binaries reject this schema;
retain a compatible backup. Fingerprint algorithm v3 and CLAP preprocessing/model
identities remain unchanged.

Schema 15 subsequently adds optional complete-byte SHA-256 proofs for
[conservative file moves and library reconciliation](LIBRARY_RECONCILIATION.md).
The public hash kinds and duplicate-verification contract below remain unchanged.

## Bounded extraction

`clap_audio.FingerprintReader` streams canonical 16 kHz mono blocks into
`fingerprint.Analyzer`. State consists of bounded decoder buffers, a 1,024-sample
overlap buffer, five spectrogram rows, delayed peak/anchor rings, and at most
100,000 output landmarks. Source reads include the sinc neighborhood and final
fractional tail: every source frame is decoded and validated.

Format/duration rejection precedes PCM reading. Full-timeline Float validation
is fused with decoding; sparse semantic windows retain whole-file Float
validation. A synchronized two-entry coefficient cache occupies 262,400 bytes
and returns owned copies of the original numerical coefficients. Cancellation
is cooperative; final path/descriptor stats reject changed or replaced sources.
The legacy waveform PCM-array helper remains, but acoustic file extraction does
not use it. Borrowed PCM adds no second whole-timeline array to the analyzer.

## Lossless storage and recovery

WFP1 groups sorted hashes and encodes hash/frame deltas with bounded unsigned
LEB128. It includes a version, decoded count, payload length, checksum, and
checked padding. Raw pairs remain readable and are used when smaller. Counts,
varints, ordering, checksum, padding, and truncation are validated. Decoded
landmarks, comparisons, selectors, postings, and family edges remain identical.

Migration preserves raw blobs. `ws_fingerprint_storage_repack_v1` explicitly
processes 1–1,024 rows per call, one at a time, from the indexed
`storage_version=0` work set. CPU work runs outside the mutation mutex;
publication guards connection, source, original bytes, and stored count. Each
row commits atomically. Cancellation/reopen resumes remaining rows, retaining
completed conversions. No decoding, inference, or posting/family rebuild is
required. This is a maintenance C API; the macOS UI does not invoke it automatically.
Integrity, restore, and compaction validate both raw and compressed payloads.

Freed pages stay allocated/reusable. `ws_backup_compact` creates a smaller
checked copy at a **new** path without rewriting the original.

Full trigram detail is retained: the vendored SQLite experiment on 10,000 rows
found 1,250 matches for `MATCH 'impact'` in the current index; the
`detail=none,columnsize=0` alternative rejected that phrase query. A different
candidate/reranking design needs independent quality and latency acceptance.

The universal waveform policy remains unchanged. Stereo WVT3 uses 2,048 peak
bytes plus a 96-byte header/checksum: 2.144 GB per million assets before SQLite
overhead; mono uses 1,120 bytes each. On-demand overviews trade persistent
coverage for first-preview I/O/decoding. Cold/removable-storage and preview
acceptance are required before changing that policy. Detailed caches, model
packs, and canonical Float32 vectors remain independent storage costs.

## Explicit identity and verification

`ws_file_identity_v1` reports kind and algorithm:

| Kind | Meaning |
| --- | --- |
| Unknown | Historical/external identity; its sign does not establish strength. |
| Fast provisional | Existing bounded fast policy, always negative. |
| Sampled | Normal files larger than 16 MiB use head/tail samples, now negative. |
| Full | Smaller normal files or deep scans hash all bytes, positive; still a candidate hash. |

Algorithm 1 is the existing seed-zero Wyhash contract with a little-endian size
prefix and mode-specific offsets. Migration labels historical hashes unknown.
The next successful scan refreshes metadata; subsequent unchanged scans retain
it compactly. Matching fast hashes preserve analysis during metadata upgrade;
old positive normal sampled hashes change sign and invalidate/re-enqueue analysis.

`ws_duplicate_verify_v1` uses request-local cancellation and a read snapshot to
compare complete bytes for matching hash/kind/algorithm/size candidates. Anchor
hash, source stats, path replacement, and final catalog revision are checked.
The source counts as one member; additional equal members constitute duplicates.
Scratch is 128 KiB plus a bounded 2 MiB reader cache; I/O can be substantial.
Call off-main and drain before closing the core or releasing access. Failures
and cancellation publish no result. Normal size/mtime reuse remains a heuristic:
deep-scan sources whose changes might preserve those fields.

Legacy `ws_duplicate_count` confirms only known full-hash groups whose complete
bytes verify equal. Sampled, unknown, or ambiguous groups return zero. It is now
a potentially blocking filesystem call. Acoustic families continue to mean
similarity rather than byte equality. Analysis is not shared between separate
files, avoiding new cross-model/source lifetime risks; sharing saves **zero**
analysis time/disk here and remains a separate design choice.

## Measurements (2026-10-12)

Serial before/after processes used generated mono Float32 48 kHz WAVs on local
macOS arm64 with Zig 0.17.0 `safe`. Three-run medians are descriptive, not cold
storage or p95 acceptance:

| Fixture | Before | After |
| --- | ---: | ---: |
| 3 s extraction | 3.885 ms | 4.215 ms |
| 3 s returned source bytes | 1,152,056 | 577,420 |
| 3 s payload | 256 bytes | 89 bytes |
| 300 s extraction | 284.352 ms | 283.650 ms |
| 300 s returned source bytes | 115,209,108 | 57,745,260 |
| 300 s peak process RSS | 26,017,792 bytes | 6,373,376 bytes |
| 300 s payload | 25,952 bytes | 3,625 bytes |

Short extraction pays about 0.33 ms extra; long latency is essentially unchanged.
Long RSS fell 75.5% and returned bytes 49.9%. These are logical file-read bytes,
not physical device I/O. Canonical digests match: `5fbd365dd928cfb3` (32 landmarks)
and `aae7d5e50a75b14e` (3,244 landmarks).

A separate 30-second noise fixture yields 22,404 landmarks: 179,232 raw bytes
become 63,785 (64.4% smaller), preserving canonical digest `4077abbfe9e0262d`.
Across 30 codec runs, encoding p50/p95 was 0.171/0.218 ms and decoding
0.153/0.211 ms, excluding audio decoding and search.

A 1,000-asset synthetic catalog with 200 landmarks per file repacked in 33.843 ms:
payload 1,600,000 → 241,000 bytes (84.9% smaller). Allocated catalog space stayed
3,620,864 bytes; explicit compaction produced a 2,048,000-byte copy (43.4% smaller).
Peak RSS was 18,530,304 bytes. This includes metadata, FTS, postings, families,
and pending-storage indexing, but no vectors or waveforms.

The three-file 18 MiB fixture has two equal files and one different middle.
Normal indexing took 22.953 ms; verification took 20.236 ms, read 56,885,336 bytes,
and confirmed two of three candidates. Process RSS was 10,747,904 bytes. This is
one warm generated case, not duplicate-heavy inference or professional libraries.
Real audio/vector acceptance, cold/network/removable storage, and total
application/model memory remain separate measurements.

## Reproduction and validation

`make check` covers canonical v3 output; chunk/rate/tail equivalence; bounded
five-minute PCM memory; Float corruption; cancellation; lossless round trips;
codec corruption/truncation; migration; mixed backup/restore; stale publication;
same-head/tail different-middle files; metadata changes; and path replacement.
Two optional model tests remain opt-in.

Final validation passed: `make check` (103 core tests, two optional model skips,
fresh macOS library/app build, and refinement/lifecycle/window/Settings checks),
`make check-linux`, 80 local Markdown file/anchor links, and `git diff --check`.
Linux compilation does not establish native Linux runtime behavior.

```sh
cd core
zig build optimization-bench -Doptimize=safe -- fingerprint-codec /tmp/ws-codec.sqlite 30
zig build optimization-bench -Doptimize=safe -- fingerprint-storage /tmp/ws-storage.sqlite 1000
zig build optimization-bench -Doptimize=safe -- trigram-detail /tmp/ws-trigram.sqlite 10000
```

DB paths must be new/disposable. `fingerprint-file PATH SECONDS` also reads a
caller-supplied `PATH.wav`; `duplicates PATH COUNT` reads caller-supplied
`PATH.audio` containing `a.wav`. Those sources are never modified or deleted by
the modes; only their protected disposable catalogs are cleaned up.
