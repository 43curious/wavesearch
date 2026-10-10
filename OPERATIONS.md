# Operations, recovery, and scaling

## Indexing

`ws_index_folder` remains the synchronous compatibility API. New integrations
should call `ws_index_folder_ex`. `WS_INDEX_FAST` publishes a searchable
snapshot using at most five uniformly spaced 64 KiB identity samples per file
and at most 256 KiB of recognized WAV metadata; fast identities are marked
provisional and are never exposed as exact legacy hash-duplicate proof;
`WS_INDEX_DEEP` bypasses size/mtime reuse and streams every file byte through
the content hash. All modes build a complete snapshot before the short SQLite publication transaction, so cancellation,
filesystem errors, or process interruption cannot expose a partial folder.

`ws_cancel_indexing` is lock-free and may be called from a UI thread. The scan
checks cancellation between directory entries and immediately before database
publication. Restarting the operation resumes safely from the previous live
snapshot; semantic and acoustic derived indexes independently resume from their
persisted pending rows. The macOS app uses `WS_INDEX_FAST`, refreshes lexical
results immediately after publication, then alternates one acoustic file and
one semantic file on a single background worker. The worker uses one CLAP
intra-op thread by default, yields while interactive search is active, pauses
under serious thermal pressure, and sleeps between files. Accuracy algorithms
remain unchanged: full-timeline acoustic fingerprints and up to five CLAP
windows are eventually produced.

`ws_operation_status` reports active/deep/cancel state, discovered files, and
completed/cancelled/failed operation counters. The macOS app exposes Cancel and
Deep Re-index actions.

## Integrity

Run quick checks during routine diagnostics and full checks before/after backup:

```c
WSIntegrityReport report = { .struct_size = sizeof(report) };
int rc = ws_integrity_check(WS_INTEGRITY_FULL, &report);
```

Checks include SQLite integrity, foreign keys, FTS row synchronization, vector
blob dimensions, fingerprint token/blob consistency, and schema version.
`rc == 0` means no errors; `rc == 1` means the report found inconsistencies;
negative values are API failures.

## Backup and recovery

In the macOS app, open **Settings → Storage & Recovery** to create a backup,
restore one, or run a full integrity check. Backup folders contain
`catalog.sqlite` (created through SQLite's online backup API) and `manifest.json`
(library IDs, locations, bookmarks, and favourites). The app pauses admission and
drains playback, search, analysis, and refinement before recovery work; disk and
core operations run off the UI thread. Restore validates the manifest and the
core's schema contract, and saves the current catalog under
`Application Support/WaveSearch/Recovery` before replacing it. The full
post-restore integrity result is shown in Settings.
If startup cannot open the index, Restore remains available in Settings. It
validates and migrates the backup in an isolated catalog, retains the unopened
database and journals in a separate Recovery folder, then opens the recovered
catalog. These retained raw files are diagnostic copies, not normal app backups.

Original audio, installed models, and exported clips are not included in catalog
backups. Exported clips remain persistent media in
`Application Support/WaveSearch/Exports`; editing projects may reference them.
Settings reports index and journal sizes, waveform cache bytes (already included
in the database), the detailed cache budget, exports, and recovery copies, with
Finder links and manual refresh.

Press **⌘,** or choose **WaveSearch → Settings…** to open the native Settings
window. General contains editor import behavior, preview volume, and background
refinement. **Keep the files in place** is the default and passes the full original
file URL to the editor; **Copy files to Exports** copies whole files unchanged
and renders selected waveform ranges as trimmed WAVs. Appearance
contains System/Light/Dark mode, app accent, and waveform/played-waveform colors
with a live preview and a color reset. These preferences persist across launches.

**Delete Waveform Cache…** confirms before clearing both waveform tiers, legacy
peaks/analyses, failures, and the host's waveform memory cache. The app drains
producers first. Indexed files, favourites, acoustic/semantic search refinements,
and exported media remain intact. Waveforms regenerate when previewed or during
background refinement. SQLite reuses freed pages; deleting caches does not vacuum
or shrink the database file. The cache path is the index database shown in
Settings; exports and recovery copies also show their paths and Finder links.

Choose **Reconnect Library…** from a library's context menu, or **Reconnect…**
in Settings, to select its new root. This re-scans the chosen root using the same
library ID, preserving file IDs and analysis for unchanged relative files. The
library path and favourites change only after a successful scan. Select the
original library's root: files absent from the replacement root leave the index.
Unavailable libraries remain searchable and can be reconnected later.

Never copy `index.db` alone while WAL is active. Use SQLite's online backup API:

```c
ws_backup_create("/safe/location/wavesearch.sqlite");
```

Recovery procedure:

1. Stop indexing and retain the suspect database plus `-wal`/`-shm` files.
2. Run full integrity on the backup using a diagnostic build or separate copy.
3. Call `ws_backup_restore` with the verified backup.
4. Run full integrity again.
5. Re-load the optional CLAP provider and resume semantic/acoustic pending work.
6. If an older binary must be used, restore a backup whose schema version that
   binary supports; older binaries intentionally reject future schemas.

Restore validates `quick_check` and the WaveSearch schema contract, copies the
source into a temporary database, completes any supported migration there, and
only then publishes through SQLite's backup API. WAL state is handled correctly
and a malformed legacy backup cannot replace the live index. Schema v7-to-v8 group migration, v8-to-v9 waveform-analysis migration,
v9-to-v10 two-tier waveform-cache migration, and legacy-schema preservation, backup/restore, cancellation rollback, and
integrity checks have automated regression tests.

## Background refinement modes

WaveSearch persists one of three producer policies under
`ws_refinement_mode_v1`; an absent or invalid preference defaults to **Balanced**.
The mode never gates selected-file waveform or loudness analysis.

- **Fast only** publishes metadata and lexical search, but does not claim
  universal-waveform work or invoke acoustic/semantic indexing. Existing derived
  rows remain intact. CLAP is unloaded to release model memory.
- **Balanced** waits for 30 seconds of system-wide keyboard/mouse idle time and
  AC power. It processes one item at a time, prioritizing universal waveforms and
  then alternating acoustic fingerprints and semantic embeddings.
- **Complete** drains every currently available queue one item at a time without
  requiring idle time or AC power.

Balanced and Complete both pause for explicit user pause, metadata scans,
search, playback, selected waveform analysis, serious/critical thermal state,
and memory pressure. Missing libraries are parked rather than marked as
permanent failures; mounted libraries continue and mount/wake notifications
retry parked work. Fast only does not delete already generated caches.

`ws_cancel_refinement()` preempts only acoustic/semantic work. The coordinator
captures `ws_refinement_generation()` immediately before dispatch and uses the
v2 bounded acoustic/semantic calls, so cancellation cannot be lost if it arrives
before a detached worker registers. Scan cancellation retains the legacy
`ws_cancel_indexing()` behavior, which cancels both the scan and derived work.
Mode and pause controls are available from the top-right indexing popover and
Settings.

## Memory and large libraries

- Waveform analysis streams decoded Float32 PCM in at most 32,768-frame pushes and retains only up to 4,096 stereo extrema plus bounded loudness state. Acoustic fingerprinting separately retains at most five minutes of canonical 16 kHz mono samples (about 19.2 MiB).
- Semantic exact search uses an independent read-only WAL snapshot, streams one vector at a time, and retains only top K, so indexing and unrelated database operations are not held behind the scan.
- Fingerprint candidate generation uses 96 selectors and verifies at most 128
  full fingerprints per query.
- Folder publication remains atomic; the filesystem manifest is currently held
  in memory until publication. The published million-row metadata benchmark in
  `BENCHMARKS.md` is the regression gate for current scaling behavior.
