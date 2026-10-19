# Waveform and audio preview system

## 1. Purpose

The WaveSearch macOS preview is designed to make a selected sound immediately
understandable and usable without opening an editor. It provides:

- Full-track mono or stereo min/max waveform envelopes.
- A bounded instant overview followed by one exact-envelope-plus-LUFS pass.
- A playback-progress color and visible playhead.
- Click-to-seek behavior.
- Mouse selection of a temporary range.
- Native drag-and-drop of that selected range into applications such as
  DaVinci Resolve.
- Versioned memory and SQLite caches.

The complete recording is always visible. The current UI has no waveform zoom,
scrolling, timeline ruler, or permanent in/out points. Preview ranges are shared
between the waveform, keyboard marks and player, and reset when files change.

## 2. User interaction

### Playback and playhead

The bottom playback controls start and pause `AVAudioPlayer`. While playback is
active, `PlayerController` samples `AVAudioPlayer.currentTime` every 40 ms and
publishes a normalized progress value from `0` through `1`.

The waveform displays progress in two ways:

1. The portion already played receives the played-waveform color.
2. A 1.5-point white vertical playhead is drawn over both mono and stereo lanes.

The line is kept just inside the Canvas edge at the beginning and end, so it
remains visible at both `0%` and `100%`. Updating the playhead never starts audio
analysis again.

**Return** and double-click playback start at the active range's in point (zero
without a range) and stop at its out point. **Space** pauses/resumes. Requests
made while the selected source is preparing wait for that preparation; pausing
revokes queued playback. Latest-request admission and generation checks prevent
superseded preparations from starting audio. A preparation failure clears queued
play intent.

The panel's **In**/**Out** buttons and **i**/**o** keys set range boundaries at
the displayed playhead. Setting an in point past the previous out resets out to
the end; setting out before in resets in to zero. **Clear Range** restores full
source auditioning. **Up/Down** and **j/k** navigate results. Preview keys are
limited to the main window and leave normal text-input editing intact.

**Settings → General → Audio preview → Autoplay selected sounds** is off by
default and persists independently of preview volume. When enabled, selection
starts playback only after the newest source is prepared. The panel's **Loop**
and **Rate** controls are session settings, retained across selected files. Rates
are 0.5×, 0.75×, 1×, 1.5× and 2×. These controls never modify sources or rendered
exports. The existing h/l shuttle remains available and explicit rate selection
ends shuttling.

Whole-file looping uses AVAudioPlayer's native loop count. Selected-range stop
and loop boundaries are checked on the 40 ms progress timer; they are approximate
preview boundaries, not sample-accurate or guaranteed gapless loops. Main-thread
scheduling can delay a tick, and higher rates increase the audible overshoot.
Selected-range exports still use the exact frame-boundary rules below.

### Seeking

A click in an unselected area, or mouse movement there shorter than three
points, is treated as a seek. It:

- Clears the current temporary selection, if any.
- Converts the horizontal mouse coordinate to a fraction of the full track.
- Sets `AVAudioPlayer.currentTime` to `duration × fraction`.

A click inside an existing selection leaves it intact so the next movement can
unambiguously begin a selected-range file drag.

### Selecting a range

Press in an unselected part of the waveform and drag at least three points.
The start and current pointer positions become an ordered closed range. A
translucent blue rectangle shows that range. Dragging from either direction is
supported.

Starting another selection outside the current range replaces the old range.
Selections are temporary player state; they are not saved to SQLite and are cleared
when the selected source file changes.

### Dragging a selected range

Selection and file dragging are deliberately separate gestures:

1. First drag over an unselected area to create a range.
2. Release the mouse.
3. Press inside the highlighted range and drag again.

The second drag starts a native AppKit `NSDraggingSession` with an existing file
URL. **Settings → General → Importing into editors** defaults to **Keep the files
in place**: the URL references the full original in its library location, and
the editor handles trimming and its own media copies. **Copy files to Exports**
renders a selected range as a WAV off the UI thread; a full-range drag copies
the original file unchanged. Result-row drags use the same preference.
Editors such as DaVinci Resolve need a file URL rather than a Finder-only file
promise. Keep the mouse button held while a copy or clip is prepared; releasing
it or closing the view cancels preparation instead of starting a stale drag.

A drag beginning inside the selection imports according to that preference. A drag beginning
outside it creates a replacement selection instead. This decision is made from
the mouse-down position, so the selection cannot accidentally turn into an
export halfway through the first gesture.

## 3. Selected-range export

With **Copy files to Exports** enabled, a trimmed exported file is named:

```text
<original-name>-selection-<UUID>.wav
```

Before starting a trimmed file drag, WaveSearch:

1. Opens the source through `AVAudioFile` as non-interleaved Float32 PCM.
2. Converts the normalized range to source-frame boundaries.
3. Uses the lower frame boundary for the start and a rounded-up boundary for
   the end.
4. Guarantees at least one output frame.
5. Seeks directly to the first selected source frame.
6. Reads and writes in 32,768-frame chunks.
7. Produces a 24-bit integer PCM WAV for editor interoperability.

The export preserves source sample rate and channel count. Compressed sources
such as AAC or FLAC are decoded to PCM; the selected result is not re-encoded to
a lossy codec. Stereo channel independence is retained.

The export helper removes partial output if reading, writing, or cancellation
fails. Completed clips live in Application Support's `WaveSearch/Exports`
directory, not a temporary cache. They are never automatically pruned: a Resolve
project may reference those files directly. Copy used clips into the project's
media folder (or use the editor's media-management tools) before manually
removing exports. Storage therefore grows with exported selections.

## 4. Analysis pipeline

### Source decoding

All formats readable by the installed AVFoundation stack use `AVAudioFile` by
default with Float32 non-interleaved 32,768-frame buffers and cancellation
checks between chunks. A bounds-checked mapped PCM reader supports integer
8/16/24/32-bit WAV/AIFF plus Float32 WAV behind `WS_ENABLE_MAPPED_PCM=1`.
Unsupported, compressed, symlinked, or ambiguous layouts fall back to
AVFoundation. It remains opt-in because warm-cache AVFoundation decoding is
currently faster; the direct path is retained for cold external-drive testing.

The analyzer never retains the complete decoded PCM recording. Only aggregate
waveform buckets and loudness state remain in memory.

A decoder that ends before its authoritative client-frame extent causes
analysis to fail. WaveSearch does not fill an unexpectedly truncated tail with
fabricated silence.

### Stage 0: bounded instant overview

The repository first checks reconstructed memory, the detailed v10 tier, and the
universal v10 tier. A tier hit decodes no source PCM. If no tier exists and the
source exceeds 131,072 frames, `AudioAnalyzer.preview(...)` decodes eight
uniformly distributed 2,048-frame windows—at most 16,384 frames regardless of
source duration. Eight segments per window provide 64 real PCM anchors per
channel, interpolated into a provisional 256-bucket overview.

The provisional overview may omit an unsampled transient. It is never persisted.
The loading indicator disappears when this usable overview appears.

### Stage 1: exact waveform and loudness completion

For files at or below 131,072 frames, the first stage scans exact extrema without
K-weighting and publishes them immediately; a loudness-only refinement follows.
Long selected files retain one fused full-source pass after their provisional or
universal view is visible. In each 32,768-frame chunk it:

- Aggregates Float32 min/max values into at most 4,096 buckets for the first two
  channels.
- Runs K-weighting and energy accumulation for every source channel.
- Tracks sample peak before display clamping.

Accelerate/vDSP performs exact bucket-run extrema, sample peak, cascaded
Double-precision K-weighting, and segment energy. It remains the default macOS
backend because current long-file benchmarks are more than twice as fast as the
portable scalar implementation. `WS_WAVEFORM_ANALYZER_BACKEND=zig` selects the
versioned libwavesearch streaming analyzer for differential testing. Compatible
selected callers join one task. A selected request cancels an incompatible 512-only background
pass instead of running two decoders concurrently.

After EOF, both backends pass through libwavesearch's canonical result path.
Zig μ-law-quantizes peaks to Int8, constructs exact 512/1,024/2,048/4,096 tiers,
and immediately reconstructs display values. Selected work reduces a
512-bucket universal level from detailed extrema. Background work aggregates
directly into one 512-bucket level and does not construct discarded detail
levels. Zig also serializes/deserializes WVT3; only loudness-complete universal
plus optional detailed blobs are committed atomically.

### Cache-hit path

A detailed hit provides 512/1,024/2,048/4,096 levels derived in memory. A
universal hit provides an exact 512-bucket view and complete loudness immediately,
then selected-file detailed generation may continue. Neither path shows a
spinner after its first result.

## 5. Min/max waveform representation

### Bucket generation

For each rendered channel and bucket, WaveSearch stores:

```text
minimum = smallest finite PCM sample in the bucket
maximum = largest finite PCM sample in the bucket
```

Non-finite decoded samples are treated as zero. This is an envelope, not RMS,
average amplitude, or every-Nth-sample point sampling. Positive and negative
transients are preserved.

The exact detailed bucket count is `min(source frames, 4,096)`. Files shorter
than 512 frames never receive fabricated buckets. The exact universal target is
`min(detailed buckets, 512)`.

### Lower levels

Only one universal and one detailed level are persisted. Detailed cache hits
derive 512, 1,024, and 2,048 levels in memory by minimum-of-minima and
maximum-of-maxima reduction. No averaging occurs, so transients survive every
level.

### Channels

- Mono uses one centered lane.
- Stereo uses aligned `L` and `R` lanes.
- Sources with more than two channels display the first two channels.
- Loudness analysis still consumes every decoded source channel.

## 6. Rendering

`WaveformView` uses an asynchronously rendered SwiftUI `Canvas`.

For the current Canvas width, `WaveformData.level(forPixelWidth:)` chooses the
smallest level with roughly 1.15 buckets per visible point. Because the complete
track is always visible, the visible fraction is always `1`.

Each lane contains:

- A subtle zero-amplitude center line.
- A coherent filled min/max envelope.
- A light outline.
- A played-color envelope clipped at playback progress.

After the channels are rendered, the white playhead is drawn on top. The
selection rectangle is drawn behind the waveform, preventing it from obscuring
transient shape or the playhead.

Window resizing may select another cached level, but it does not decode or
reanalyze audio.

## 7. Loudness matching

WaveSearch computes a BS.1770-style integrated loudness estimate for sample
rates of at least 8 kHz using:

- Sample-rate-derived K-weighting filters.
- 100 ms energy segments.
- 400 ms windows stepped every 100 ms.
- A `-70 LUFS` absolute gate.
- A relative gate 10 LU below preliminary integrated loudness.
- Frame-weighted handling for effects shorter than a complete 400 ms block.

Digital silence has no integrated LUFS value and is never boosted.

Preview playback targets `-18 LUFS`. Requested normalization is:

- Limited to `-18 dB ... +18 dB`.
- Reduced when necessary to keep the measured sample peak below `-1 dBFS`.
- Multiplied independently by the user’s persisted volume setting.
- Applied with a short fade when analysis arrives or volume changes.

The peak constraint uses decoded sample peak, not an oversampled standards-grade
true-peak meter.

## 8. Source identity and invalidation

Before analysis, WaveSearch captures a `WaveformSourceSignature` containing:

- Standardized source path.
- File byte size.
- Nanosecond modification time.
- WaveSearch content hash or provisional content identity.
- Audio analyzer revision.

After decoding, the signature is captured again. A mismatch rejects the result,
which prevents publication when a source changes during analysis.

The current analyzer revision is `3` and WVT3 codec version is `3`. The Zig
ownership migration retains these revisions because canonical WVT3 bytes remain
byte-for-byte compatible, portable and vDSP tiers are identical, and LUFS/sample
peak differ by no more than 0.000001 in the differential gate. Revision changes invalidate older analysis automatically.

## 9. Memory and SQLite cache

### Memory and coalescing

`AudioAnalysisRepository` is an actor with an eight-entry reconstructed detailed
LRU and an in-flight exact-task map keyed by complete source identity. Foreground
selection and background universal generation await one shared authoritative
decode instead of opening the same file twice.

### SQLite schema v10

`waveform_tiers` stores a required exact 512-bucket universal WVT3 blob and an
optional exact up-to-4,096-bucket detailed WVT3 blob. `waveform_cache_state`
stores the 256 MiB default detailed budget, bounded to 512 MiB, plus the durable
cursor, scan-complete bit, and global tokenized work lease. `waveform_failures`
prevents unsupported files from blocking resumable work.

Detailed cache is capped by bytes and 10,000 recent files. Access touches drive
deterministic LRU eviction. Universal tiers remain while files are indexed.
Source identity changes invalidate both tiers atomically.

WVT3 stores one μ-law Int8 level plus tier/analyzer identity, source identity,
sample/frame/channel metadata, LUFS, sample peak, and checksum. It deliberately
does not store absolute source paths or redundant lower levels. Provisional or
loudness-incomplete values cannot encode.

The additive schema-v10 C ABI is documented in
[`WAVEFORM_CACHE_V10.md`](WAVEFORM_CACHE_V10.md). Legacy waveform APIs remain
unchanged for binary compatibility but are not used by the product preview.

## 10. Concurrency and cancellation

- `PlayerController` is main-actor isolated.
- Source signature capture, sparse overview generation, and exact+LUFS
  generation run in detached tasks.
- Selected sparse/exact stages use user-initiated priority.
- Universal library backfill and SQLite cache I/O use background/utility
  priority.
- A five-minute cross-process claim is renewed every minute; cancellation
  releases it and a crash becomes reclaimable after lease expiry.
- `AudioAnalysisRepository` serializes cache state through actor isolation.
- Selecting another file cancels the previous subscription; an exact producer
  continues only while another foreground/background consumer still needs it.
- An analysis result is published only when the current file still matches.
- The `WaveformView` is keyed by file identity so a selection cannot leak to a
  newly selected source.

Playback loading and waveform analysis are independent. A waveform failure does
not prevent `AVAudioPlayer` from playing a readable source, and playback does not
wait for LUFS refinement.

## 11. Failure behavior

| Failure | Behavior |
|---|---|
| Source cannot be opened by AVFoundation | Waveform remains unavailable; playback may independently report the same limitation. |
| Source changes during analysis | Result is discarded. |
| User changes files | The old subscription is cancelled and cannot publish into the new file; an unshared producer is cancelled at its next chunk check. |
| Cache is stale or malformed | Cache is ignored and regenerated. |
| Decoder ends early | Analysis fails rather than showing a false silent tail. |
| Sparse overview succeeds but exact+LUFS scan fails | The provisional overview remains visible for the current selection. |
| Universal cache is valid but detailed generation fails | The exact universal view and cached normalization remain usable. |
| Copy/selected-range export fails | Drag preparation reports the error and removes incomplete output. |
| Drag preparation is abandoned | Preparation is cancelled, incomplete output is removed, and no stale drag starts. Completed exports remain persistent. |

## 12. Supported formats

Waveform analysis and range export accept formats that `AVAudioFile` can decode
on the running macOS version. Validation currently covers WAV, AIFF, AAC/M4A,
and FLAC, including mono, stereo, silence, transients, speech, dense material,
short clips, and multi-minute recordings. Schema-v10 tests additionally cover
atomic tier storage, stale identity rejection, detailed eviction, exclusive
lease claims, stale-token rejection, resumable pending work, early development
v10 recovery, and v9 migration.

Optional formats remain dependent on AVFoundation’s installed decoder support.
The selected-range output is always PCM WAV for predictable interchange.

## 13. Validation

The app lifecycle check uses disposable silent WAVs and real AVAudioPlayers to
exercise blocked/rapid replacement, Return during preparation, cancellation by
pause, selected-range stopping/looping, native full-file looping, 2× preview,
autoplay preference persistence and shutdown draining. The native window check
injects Up/Down, i/o, Return and Space events and verifies that search text entry
does not trigger preview commands.

A run of five warm generated one-second WAV selections measured
31.5 ms p50 and 42.5 ms p95 from selection to the native `play()` handoff, including
2 ms readiness polling. This is not a measurement of physical first-audio output
or cold/removable-storage performance. `FileSelected` and `PreviewStarted`
signposts support tracing those workflows; representative cold-drive and audible
latency acceptance remains unverified. Hover audition and neighbour prefetch are
not enabled without those measurements, avoiding extra speculative file reads.

The implementation has been checked with:

- Digital silence.
- Quiet and loud tones with different LUFS values.
- Positive and negative narrow transients.
- Percussive material.
- Dense stereo music.
- Independent left and right channel content.
- Files shorter than 256 frames.
- A 181-second recording.
- AIFF speech.
- AAC/M4A and FLAC sources.
- Cache encode/decode round trips.
- Checksum corruption rejection.
- SQLite reopening.
- Source-mtime invalidation.
- Exact selected-range frame count and stereo WAV export.
- Native `NSFilePromiseProvider` fulfillment.

The macOS target is also built through Xcode with strict Swift concurrency
checking and exercised with a runtime smoke launch.

## 14. Main implementation files

| File | Responsibility |
|---|---|
| `macos/WaveSearch/WaveSearch/AudioAnalysis.swift` | Bounded sparse overview, exact PCM envelopes, level construction, K-weighting, LUFS, sample peak. |
| `macos/WaveSearch/WaveSearch/AudioAnalysisRepository.swift` | Tier lookup, WVT3 codec, in-flight coalescing, atomic persistence. |
| `macos/WaveSearch/WaveSearch/WaveformBackgroundCoordinator.swift` | Resumable one-file universal backfill and pause policy. |
| `macos/WaveSearch/WaveSearch/WaveformSignposts.swift` | Points-of-Interest latency and queue instrumentation. |
| `macos/WaveSearch/WaveSearch/WaveformView.swift` | Canvas rendering, playhead, selection display, AppKit pointer and drag session. |
| `macos/WaveSearch/WaveSearch/AudioClipExport.swift` | Original-file URLs, persistent whole-file copies, and selected-range PCM24 WAV rendering. |
| `macos/WaveSearch/WaveSearch/PlayerPanel.swift` | `AVAudioPlayer`, progress timer, staged publication, LUFS gain, panel integration. |
| `core/include/wavesearch.h` | Public opaque waveform-cache C ABI. |
| `core/src/main_c.zig` | C ABI validation and error translation. |
| `core/src/db.zig` | Schema-v10 two-tier cache, work/failure state, budget/LRU, migration and integrity. |

## 15. Current limitations

- The complete track is always fitted; sample-level zoom editing is not offered.
- Only the first two channels are drawn.
- Selection has no draggable edge handles or numeric time fields.
- Selection is temporary and is not restored after changing files or relaunching.
- Selected-range loops use a UI timer and can overshoot or introduce a gap;
  whole-source loops use native playback. Cold-drive first-audio latency has not
  been established by the generated-fixture check.
- Partial selections in Copy mode export as PCM24 WAV; whole-file copies preserve
  the source container. Keep-in-place drags supply the full original file.
- Loudness protection uses sample peak rather than oversampled true peak.
- Rendering uses SwiftUI Canvas rather than a custom Metal waveform renderer.
