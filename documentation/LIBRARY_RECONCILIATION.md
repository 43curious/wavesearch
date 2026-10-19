# Library watching and file moves

Issues [#14](https://github.com/43curious/wavesearch/issues/14) and
[#15](https://github.com/43curious/wavesearch/issues/15) share the core's complete,
atomically published library snapshots. Native macOS code supplies filesystem
signals and preserves interface references; the core decides source identity.

## Conservative move recognition

Schema 15 stores an optional 32-byte complete-file SHA-256 in
`file_move_identities`, independently of the public fast/normal/deep hash policy.
Complete scan reads compute both digests together. Acoustic/semantic producers
and native waveform-tier storage can establish a missing proof with one
additional cancellable source read outside the database mutex. This also covers
formats decoded by macOS. Existing proofs avoid repeat reads.

A new relative path with the size of a proven old source is a candidate. When
the normal scan sampled that new file, it additionally reads the complete file
for SHA-256. Size, mtime, filename, or sampled-hash equality alone never transfers
identity. At publication, the old source must be missing and its digest must be
unique across the captured old library and staged new paths. Known duplicates,
copies whose source remains, ambiguous matches, missing proofs, and moves across
library IDs receive fresh IDs. Matching stays within one complete library
snapshot; no cross-library transaction or heuristic path guessing is involved.

Verified moves retain file IDs, valid embeddings, fingerprints, postings and
acoustic families. If the new scan changes hash mode, derived source hashes are
rebound to that scan's hash. A thread-local SQLite function permits only the
verified row's source UPDATE to bypass ordinary semantic/acoustic invalidation;
the exception ends immediately after that statement. Valid WVT3 waveform tiers
are rewritten with the new mtime/hash and checksum; corrupt or unsupported tiers
regenerate. Regular source changes retain normal invalidation behavior. Move
publication, missing-row removal and cancellation rollback share one transaction.

The macOS host resolves favourite paths to IDs before scanning and resolves those
IDs afterward. Still-present favourites follow proven moves without resurrecting
a favourite removed during the scan. Selection, preview range and playhead follow
the same ID; reopening audio is not a promise of gapless playback. Whole-library
Reconnect continues to preserve unchanged relative paths using the existing
library ID. Audio-example search mode survives catalog refreshes, but an external
example URL is not itself a persistent catalog reference.

Migration preserves existing analysis and leaves unknown proofs absent. It does
not infer SHA-256 from old hashes or automatically reread an entire old library.
A later complete/deep scan or admitted analysis can establish proofs; a rename
before then can lose its old ID. Unchanged-file size/mtime reuse remains a
heuristic: use Deep Re-index to detect edits deliberately preserving both stats.
Proofs add 32 payload bytes per proven file plus SQLite table/page overhead.

## Watching and reconciliation

**Settings → General → Library changes → Keep libraries up to date** is enabled
by default. The native source uses FSEvents file/root events with a one-second
latency. The coordinator coalesces changes by library for two seconds, admits
one root at a time at utility priority, and rotates ready roots fairly. Batches
are capped at 4,096 paths before requesting full recovery. There is no new idle
polling timer. Failed scans retry after 30 seconds; busy roots wait for a host
foreground-completion signal. Starting search, playback preparation, playback,
or selected-file analysis cooperatively cancels an automatic scan and retains
its dirty hint. Manual Re-index and Deep Re-index remain available.

FSEvents are advisory invalidation hints. The stream starts before the initial
reconciliation, covering application downtime without relying on a saved event
cursor. Events arriving during a scan schedule another pass. Dropped/wrapped
events, overflow, root/mount changes, wake and reconnected drives trigger complete
reconciliation. This follows Apple's [FSEvents guidance](https://developer.apple.com/library/archive/documentation/Darwin/Conceptual/FSEvents_ProgGuide/UsingtheFSEventsFramework/UsingtheFSEventsFramework.html)
on installing monitoring before scanning and recovering from lost events.

Reconciliation currently walks the **whole affected library root**, using the
bounded compact staging implementation. It is not incremental subtree
publication: open/stat work remains O(number of files). Unchanged files avoid
content reads, but large libraries on slow storage can still be expensive.

The host persists a volume UUID when available and checks it before scanning;
an existing mountpoint on another volume is unavailable rather than an empty
replacement library. Explicit Reconnect adopts the selected volume. The core
also verifies root device/inode identity before publication. Failed/incomplete
walks, root replacement and cancellation preserve the previous snapshot. These
checks do not make filesystem enumeration an atomic filesystem snapshot; later
events reconcile changes occurring during a successful walk.

Removal, recovery and shutdown stop the stream, invalidate obsolete callback
generations and drain its serial queue before draining admitted scans and
releasing the core or security scopes. Native callback work maps paths off-main
and passes only a bounded set of library IDs to the UI actor. If FSEvents cannot
start, Settings reports that watching is unavailable and manual scanning remains
usable. Toggling the setting retries stream creation.

## API and validation

`WS_CAP_FILE_LOOKUP` advertises `ws_file_lookup_v1` and
`ws_file_lookup_path_v1`. They copy one committed `WSResult`: 1 found, 0 absent,
-1 error, with output unchanged on absent/error. See the [C API contract](C_API.md).
Older binaries reject schema 15; retain a compatible backup.

Reproduce with:

```bash
make check-core
make check-linux                 # Compile only; native Linux execution still needed
make check                       # Includes macOS app and desktop checks
bash scripts/test-library-watching.sh
bash scripts/test-library-watching.sh --native
```

The deterministic watcher check uses injected signals plus disposable real WAVs
and a real core catalog. It covers a 500-event burst, busy admission, startup/loss
recovery, fair roots, reconnect, stale callbacks, native favourites/selection/range
relocation, foreground deferral and stop/drain order. Core checks cover changed
mtime/hash mode, duplicates/copies, missing proofs, cross-library moves, schema-14
migration, sampled collisions, replacement, cancellation during publication and
root replacement. They require no model installation.

On the development host (2026-10-19), 118 core tests passed, two optional tests
skipped, and the 3,081-case audio mutation campaign and C ABI checks passed. The
1,120,044-byte WAV fixture required 1,120,044 reader bytes once to establish its
proof. A fast rename verification read 1,382,188 bytes (complete content plus
four additional sample blocks); a mutation outside those samples was rejected
with the same read cost. Tests preserve seeded embeddings/fingerprints/tiers
without running inference; real-model inference timing was not measured.

A warm synthetic 1,000-file scan measured 395 ms initially and 161 ms unchanged,
with 8.9 MB process peak RSS. These tiny identical WAV fixtures are not a
cold-storage, real-library, or end-to-end latency result.

The deterministic Swift and refinement-policy checks pass, Linux compilation
passes, and the full Swift app/window-check sources compile with strict
concurrency checking. This host's native FSEvents probe reports unavailable;
Xcode project builds abort in the host runtime, and the lifecycle suite fails
its native autoplay assertion on both unchanged HEAD and this implementation.
Native event delivery, external-drive removal during enumeration,
desktop interaction, idle wakeups and representative foreground/cold-storage
latency still need acceptance on a normal logged-in Mac. Passing injected-event
tests does not establish those results.
