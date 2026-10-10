# Display waveform and loudness analysis

The macOS preview uses a three-stage, two-tier waveform system optimized for
instant display and bounded storage.

1. A long uncached file first receives a provisional 256-bucket overview from
   eight uniformly distributed 2,048-frame AVFoundation reads. At most 16,384
   PCM frames are decoded, independent of source duration.
2. Long selected files use one exact Float32 pass for up to 4,096 min/max
   buckets, integrated LUFS, and sample peak. Short files publish an exact
   envelope first, then complete a small loudness-only refinement. macOS keeps
   its faster Accelerate implementation; the same decoded PCM can instead be
   streamed through the portable Zig analyzer.
3. `libwavesearch` owns canonical tier construction, signed Int8 μ-law, and
   WVT3 serialization for both paths. The selected file reconstructs Float32
   Canvas values from those same codes, so fresh and cached rendering agree.

Sources no longer need the former 131,072-bucket pyramid because the complete
track is always fitted and zooming is intentionally absent. Exact detailed data
contains at most 4,096 buckets per displayed channel. A 512-bucket exact
universal tier is reduced from selected detail without averaging; background
work aggregates directly into 512 buckets and never constructs discarded detail.

## Persistence

Waveform tiers introduced in schema v10 remain central in Application Support.
Schema v12 maintains their counts/bytes/failures transactionally and indexes
batched detailed LRU eviction. Universal-only stores skip detailed eviction;
status reads do not aggregate the catalog. See the measured
[optimization results](documentation/SEARCH_OPTIMIZATION_RESULTS.md).

Stored data:

- `waveform_tiers.universal_blob`: exact 512-bucket Int8 μ-law data retained for
  every supported indexed file.
- `waveform_tiers.detailed_blob`: exact up-to-4,096-bucket Int8 μ-law data for
  selected/recent files.
- `waveform_cache_state`: a 256 MiB default detailed budget with a 512 MiB hard
  limit, resumable cursor, scan-complete bit, and tokenized single-worker lease.
- `waveform_failures`: identity-scoped terminal or retryable background errors.

Detailed data is limited to 10,000 recent files and the configured byte budget,
with deterministic LRU eviction. Universal rows are not evicted while their
indexed source remains present. Source size, nanosecond mtime, or content
identity changes atomically invalidate both tiers and failures.

Tier blobs use the `WVT3` codec. They contain one μ-law level, source identity,
sample/frame/channel metadata, LUFS, sample peak, tier identity, analyzer/codec
versions, and a checksum. Provisional or loudness-incomplete data cannot be
encoded. Lower 512/1,024/2,048 display levels are derived in memory from the
single detailed level.

The old `ws_waveform` and `ws_waveform_cache_*` APIs remain available for ABI
compatibility. Product waveform previews use the additive schema-v10
`ws_waveform_tier_*`, `ws_waveform_tiers_store`, work/status, and budget APIs.
The versioned `ws_waveform_analyzer_*_v1` streaming ABI accepts planar or
interleaved Float32 PCM and is identical on macOS and Linux. Host decoders own
codec I/O; the core copies each pushed chunk and never retains host pointers.
`ws_waveform_result_create_v1` lets Accelerate supply its highest-resolution
Float32 extrema while Zig still performs canonical reduction and encoding.

## Background generation

After the lexical snapshot becomes searchable, one unified one-file-at-a-time
coordinator schedules universal waveform, acoustic, and semantic queues.
**Fast only** disables every background producer, **Balanced** runs after 30
seconds of system idle time on AC power, and **Complete** drains available work
without idle/power requirements. Balanced is the default. Selected-file exact
waveform and loudness work remains available in every mode.

When admitted, the coordinator fills missing universal tiers first. Work is resumable because pending
files are the indexed rows without a current universal tier. A five-minute
cross-process lease is renewed every minute and explicitly released on
cancellation; crashes become reclaimable after expiry. Selected-file requests
outrank and cancel incompatible background decoding. Compatible selected
requests still coalesce by complete source identity and work profile.

All background queues pause for playback, selected analysis, active search,
metadata scans, user pause, serious/critical thermal state, and memory pressure.
Acoustic and semantic refinement yield while available universal waveform work
remains pending. Missing drives are parked and retried after mount/wake or a
bounded backoff; unsupported files are recorded by source identity and do not
block mounted libraries.

## Rendering and interaction

The SwiftUI Canvas always shows the complete recording, independent mono/stereo
lanes, played-region color, and a white playhead. A provisional-to-exact change
crossfades over 100 ms without changing playhead or selection fractions.

Dragging an unselected region creates a temporary range. A second drag beginning
inside that range starts an AppKit file promise and writes exactly that source
frame range as channel/sample-rate-preserving Float32 WAV for DaVinci or another
drop target.

## Loudness

The exact pass applies sample-rate-derived K-weighting, 400 ms blocks stepped at
100 ms, a -70 LUFS absolute gate, and a relative -10 LU gate. Loudness analysis
requires a sample rate of at least 8 kHz; extrema-only analysis remains valid
down to 1 Hz. Preview playback
targets -18 LUFS, limits correction to ±18 dB, and respects a -1 dBFS measured
sample-peak ceiling. Silence is never boosted.

See:

- `documentation/WAVEFORM_AND_AUDIO_PREVIEW.md`
- `documentation/WAVEFORM_ALGORITHM.md`
- `documentation/WAVEFORM_CACHE_V10.md`
