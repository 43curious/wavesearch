# Waveform performance and cache v10

## Goals and acceptance gates

The v10 design separates first-display latency from authoritative analysis:

| Path | p95 target |
|---|---:|
| Reconstructed in-memory waveform | 4 ms |
| SQLite universal/detailed tier | 16 ms |
| Uncached SSD first usable overview | 50 ms |
| Main-actor blocking | 8 ms maximum |

Run `scripts/benchmark-waveforms.sh AUDIO_FILE` for the 30-run sparse and SQLite
p50/p95 gates. Results are hardware and storage specific; cold HDD seek latency
cannot be hidden by CPU optimization.

## Data lifecycle

```text
fast lexical publication
        |
        +--> dedicated background worker --> exact one-pass analysis
                                              |-- universal 512 Int8
                                              `-- LUFS/sample peak

file selected
        |
        +--> memory detailed hit ------------------------------> render
        +--> SQLite detailed hit ------------------------------> render
        +--> SQLite universal hit --> render --> shared exact --> detail
        `--> sparse 256 preview --> render --> shared exact ----> detail
```

The exact worker is keyed by file ID, complete source identity, and work profile.
Compatible foreground callers coalesce; 512-bucket background and 4,096-bucket
selected work do not, because consumed background samples cannot later recover
detail. Consumer IDs remove cancelled subscriptions and cancel an unneeded
producer. Foreground selection preempts background decoding rather than allowing
concurrent source reads.

## One-pass authoritative analysis

The default AVAudioFile reader supplies non-interleaved Float32 PCM in
32,768-frame chunks. A conservative direct mapped PCM WAV/AIFF reader is
implemented behind `WS_ENABLE_MAPPED_PCM=1`; unsupported layouts fall back to
AVFoundation. Accelerate/vDSP vectorizes extrema, sample peak, Double-precision
K-weighting, and segment energy. One selected long-file pass performs all
authoritative work:

- Min/max aggregation for the first two channels into at most 4,096 buckets.
- K-weighted energy accumulation for all channels.
- Sample-peak tracking for all channels.
- Integrated loudness gating after the stream ends.

Every finite source sample contributes before quantization. Early EOF or a
source-signature change rejects publication.

The selected universal tier is reduced from detailed Float32 extrema using
minimum-of-minima and maximum-of-maxima. Background work aggregates directly to
512 buckets and never constructs 1,024/2,048/4,096 levels. It is not an RMS or
average. Short selected files first publish exact extrema without loudness, then
run a small loudness-only refinement; only the complete result is persisted.

## Int8 μ-law peak encoding

Analysis remains Float32. Only completed peak buckets are encoded.

For normalized sample `x` and μ=255:

```text
y = sign(x) * log(1 + μ * abs(clamp(x,-1,1))) / log(1 + μ)
code = round(y * 127), in [-127,127]
```

Decode is:

```text
x = sign(code) * (exp(abs(code)/127 * log(1+μ)) - 1) / μ
```

Code zero maps exactly to zero and `-128` is invalid. The transform is monotonic,
so independently encoded minimum and maximum preserve ordering. Logarithmic
spacing retains quiet tails much better than linear Int8. Source audio, LUFS,
sample peak, and selected-range export are never Int8.

Fresh exact rendering quantizes and reconstructs peaks before publication. A
cache hit performs the same reconstruction, preventing a visual change caused
only by persistence.

## Tier sizes

For two displayed channels and two bytes per bucket pair (minimum and maximum):

```text
512 buckets  * 2 channels * 2 bytes = 2,048 bytes
4096 buckets * 2 channels * 2 bytes = 16,384 bytes
```

Mono uses half those peak bytes. WVT3 headers add identity, metadata, loudness,
and checksum fields.

## Schema v10

### `waveform_tiers`

One row per indexed file:

- `file_id`: primary key and cascading foreign key.
- `source_content_hash`, `source_file_size`, `source_mtime_ns`: commit identity.
- `codec_version`.
- Required `universal_blob` and verified byte count.
- Optional `detailed_blob` and verified byte count.
- `detailed_access_ns` for deterministic LRU.

The store operation begins an immediate transaction, revalidates identity
against `files`, publishes universal and optional detailed blobs atomically,
clears a matching failure, enforces detailed limits, and commits. A stale source
cannot attach its peaks to a changed file.

### `waveform_cache_state`

Contains the detailed-cache budget, durable universal-work cursor, scan-complete
bit, and one global lease-bearing claim:

- Default budget: 256 MiB.
- Hard maximum: 512 MiB.
- `universal_cursor_file_id` advances monotonically through indexed IDs and
  wraps after the end, avoiding an O(N²) scan of already completed rows.
- `waveform_claimed_file_id`, a random token, and lease deadline enforce the
  single-worker contract across threads and processes.

Detailed blobs are evicted by oldest access timestamp and file ID until both the
byte budget and 10,000-file limit are satisfied. Universal blobs are exempt.

### `waveform_failures`

Stores content hash, size, mtime, and source-identity-scoped retry/permanent
state. Stale workers cannot attach a failure to a newer identity; a source
identity change or file deletion clears it. Permanent unsupported files are omitted from pending
work counts so one codec failure cannot stall later refinement.

### Invalidation trigger

An update of size, mtime, or content identity deletes:

- Legacy opaque waveform analysis.
- Universal and detailed v10 tiers.
- Waveform failure state.

A root/path relocation with unchanged identity preserves tiers. Source changes
and deletion also release matching work claims; a guarded legacy `-1` identity
refresh retains its existing claim. WVT3 does not persist the old absolute path;
the current standardized path is supplied when decoding a tier.

## Additive C ABI

Legacy APIs are unchanged. New symbols are:

```c
ws_waveform_tier_size
ws_waveform_tier_load
ws_waveform_tiers_store
ws_waveform_tier_touch
ws_waveform_work_claim
ws_waveform_work_claim_v2
ws_waveform_work_renew
ws_waveform_work_release
ws_waveform_work_fail
ws_waveform_work_fail_v2
ws_waveform_cache_status
ws_waveform_cache_set_detailed_budget
ws_waveform_analyzer_create_v1
ws_waveform_analyzer_push_v1
ws_waveform_analyzer_cancel
ws_waveform_analyzer_finish_v1
ws_waveform_analyzer_destroy
ws_waveform_result_create_v1
ws_waveform_result_info_v1
ws_waveform_result_copy_level_v1
ws_waveform_result_serialize_wvt3_v1
ws_waveform_result_deserialize_wvt3_v1
ws_waveform_result_destroy
ws_cancel_refinement
ws_refinement_generation
ws_acoustic_index_pending_v2
ws_clap_index_pending_v2
```

`WSWaveformWorkItem`, lease-bearing `WSWaveformWorkClaim`, and
`WSWaveformCacheStatus` are versioned with `struct_size`. The v1 work ABI remains
available. Zig now owns WVT3 validation, serialization, μ-law, tier reduction,
and a portable streaming Float32 analyzer on both macOS and Linux. Codec
decoding remains in the host; macOS uses AVFoundation and may submit a faster
Accelerate-produced highest level through `ws_waveform_result_create_v1`.

## Resumable background coordinator

One coordinator applies the persisted Fast only, Balanced, or Complete policy
to waveform, acoustic, and semantic producers. Balanced is the default and
requires 30 seconds of system idle plus AC power; Complete ignores idle/power;
Fast only starts no background producer. Foreground selected waveform/loudness
analysis is independent of these modes.

Missing universal work is implicit:

```sql
files LEFT JOIN waveform_tiers WHERE waveform_tiers.file_id IS NULL
```

No million-row queue duplication is required. Claim creation and cursor advance
share one `BEGIN IMMEDIATE` transaction. A single global tokenized lease prevents
concurrent threads or processes from claiming another file while the bounded
worker is active. The host renews the five-minute lease every minute; cancellation
releases it and a crash becomes reclaimable after expiry. A completed-scan bit
makes idle polling constant-time. Tier storage or identity-scoped failure
publication clears the matching claim atomically. Missing-drive claims are
released without publishing a permanent failure, and mounted folders continue
through bounded per-folder derived calls. The coordinator:

1. Processes one file at a time.
2. Yields after each file and interleaves available waveform/acoustic/semantic
   queues in 2:1:1 turns, without a fixed per-file sleep.
3. Cancels when foreground work needs the decoder.
4. Pauses during playback, search, metadata scans, user pause, memory pressure,
   and serious/critical thermal state.
5. Records unsupported sources and continues.

The portable queue selector gives every continuously ready queue a turn within
four selections. Acoustic and semantic producers rotate folders independently;
waveform backlog no longer prevents their progress. See
[fair scheduling and its wall-clock limits](REFINEMENT_QUEUES.md#fair-background-scheduling).

## Repository lookup and coalescing

Selected-file lookup order:

1. Eight-entry reconstructed detailed memory LRU.
2. Detailed SQLite tier, followed by a debounced access touch.
3. Universal SQLite tier.
4. Bounded sparse preview.
5. Shared exact+LUFS producer.

A universal hit is immediately usable and loudness-complete. Detailed generation
may follow, but the spinner does not return. A sparse preview is provisional and
never encoded or stored.

## Crossfade

WaveformView keeps outgoing and incoming data for 120 ms and animates opacity
over 100 ms only when fidelity changes from provisional to exact for the same
source signature. Selection state lives outside waveform data. The playhead and
selection fractions therefore do not move during refinement.

## Instrumentation

The `SPL.WaveSearch/Waveform` Points of Interest category emits:

- `FileSelected`
- `FirstWaveform`
- `ExactEnvelope`
- `LoudnessComplete`
- `SparsePreview` interval
- `UniversalCacheHit`
- `DetailedCacheHit`
- `ExactAndLUFS` interval
- `JoinInFlight`
- `TierStore` interval
- `BackgroundClaim`
- `BackgroundComplete`

Capture these with Instruments Points of Interest to distinguish storage,
decode, exact analysis, persistence, and UI publication latency without logging
full source paths.

## Recovery and compatibility

Migration from v9 creates the tier/state/failure tables, installs the combined
invalidation trigger, and clears old WWF2 opaque rows. Earlier development-v10
databases gain cursor/lease/failure-identity columns in place; incomplete legacy
failure rows are discarded and reclaimed rather than becoming permanent blockers.
Legacy v3 rows with unknown `-1` size/mtime are refreshed from host stat data
through a guarded ABI before tier publication; known identity fields are never
overwritten. Legacy APIs and the
`files.waveform` column remain for ABI compatibility but are not used by the
product preview.

Backup restore validates all v10 tables, the singleton state row, triggers,
foreign keys, byte counts, source identities, and detailed budget before
publishing the staged database. Ephemeral work claims are cleared in the staged
copy because their owner belongs to the source process, not the restored index.

## Validation checklist

- μ-law mapping is monotonic and rejects `-128`.
- Silence maps to exact zero and receives no LUFS boost.
- Exact impulse extrema survive 4,096→512 reduction.
- Stereo channels remain independent.
- Fresh and cached detailed levels are byte-equivalent after reconstruction.
- Provisional data cannot be encoded.
- Stale identity stores fail atomically.
- Budget changes evict detailed but preserve universal data.
- Folder deletion cascades all tiers/failures.
- A second caller cannot claim while an unexpired lease is active.
- Stale release/failure tokens cannot clear or poison a newer claim.
- A late failure cannot coexist with a successfully published tier.
- Background work resumes after cancellation, crash lease expiry, or relaunch.
- Selected and background requests decode one shared exact stream.
