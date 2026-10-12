# Changelog

This file records WaveSearch's implemented changes. The first commit is
`0.1_alpha`; subsequent work stays under **Unreleased** until a new version is
explicitly assigned. Entries describe changes, not planned features.

## Unreleased

Changes since `0.1_alpha`, including
[a5a98d5](https://github.com/43curious/wavesearch/commit/a5a98d5) and the
changelog/agent documentation added afterward.

### Added

- Editor import preference in **Settings → General**, with **Keep the files in
  place** as the default and **Copy files to Exports** as an option.
- A Finder shortcut to the Exports folder when copying is selected.
- **Show/Hide Sidebar** in the View menu, using **Control–Command–S** and the
  same visibility state as the toolbar button.
- App icon artwork and assets for the 128, 256, 512, and 1024 pixel sizes.
- This changelog and repository-wide `AGENTS.md`, with instructions to maintain
  both files and links from the project documentation.

### Changed

- Background refinement uses portable 2:1:1 waveform/acoustic/semantic turns
  with one-file steps and independent per-producer folder rotation. Acoustic
  and semantic work can progress before the waveform backlog drains; existing
  admission, backoff, cancellation, and shutdown draining remain in force.
- Consolidated byte-identical app icon assets and corrected `make clean` to
  remove both generated XCFramework copies and root/core Zig caches. Documented
  the repository audit and corrected outdated waveform/export guidance.
- Result-row and waveform drags now honor the same editor import preference.
  Keeping files in place supplies the original library URL, including files on
  external drives. A selected range supplies the full original file for the
  receiving editor to trim or copy.
- Copy mode preserves whole files byte for byte, including their original
  format. Partial waveform selections become trimmed PCM24 WAVs in the
  persistent Exports folder; each export receives a unique name.
- Copy preparation runs off the UI thread, respects library work admission and
  cancellation, and removes incomplete output while preserving source files.
- **Find Similar** is now a compact icon beside the search field.
- Updated import, waveform, operations, and keyboard shortcut documentation.
- Restyled the README with a centered app icon, title, introduction, and
  navigation links inspired by Ghostty, plus clearer sections for building,
  usage, documentation, and development.
- Extended the existing checks to cover original drag URLs, whole-file copies,
  selected-range exports, import preferences, and native menu behavior.

### Fixed

- Unchanged-file rescans retain compact identity references instead of staging
  full paths and metadata again, and reconcile removals from the original
  snapshot without a second seen-path table. Relocation, cancellation, and
  atomic publication preserve valid analysis and file IDs.
- Broad folder/duration semantic searches now choose SQ8 from the matching
  population, preserving exact Float32 reranking. Small matching sets and
  incomplete SQ8 coverage retain exact retrieval.
- Semantic and acoustic refinement now resume from indexed, durable pending
  queues across bounded calls and restarts, avoiding repeated scans of completed
  files. Schema 13 migrates and restores queues from existing analysis; changed
  sources and cleared failures re-enqueue work. Acoustic fingerprints, postings,
  and verified edges publish together so an interrupted publication stays pending.
- Waveform drags no longer create an Exports file unconditionally, allowing
  editors to reference the source media in its original location by default.
- Removed the duplicate **Settings…** command from the WaveSearch menu.

### Removed

- Native **Show Tab Bar** and **Show All Tabs** commands by disabling automatic
  window tabbing. WaveSearch's library tabs remain available.
- Repeated library/count summaries beside search and above the results.
- The redundant results toolbar containing the Library/Results label, loaded
  result count, and Search/Nav/Marks/Play shortcut hints.

## 0.1_alpha — 2026-10-10

Initial application and portable core, introduced in
[1165343](https://github.com/43curious/wavesearch/commit/1165343).

### Added

- Native SwiftUI/AppKit macOS application with a library sidebar, library tabs,
  resizable sidebar, search results, audio preview panel, and global playback
  controls.
- Library folder indexing, browsing, favourites, missing-drive status,
  re-indexing, and reconnection of relocated libraries.
- Fast searchable scan snapshots, unchanged-file reuse, optional deep
  re-indexing, atomic publication, and cooperative scan cancellation.
- Zig indexing/search/audio core with vendored SQLite, FTS5, and a public C API
  for native frontend integration.
- Ranked lexical search with filename, path, and WAV metadata retrieval,
  duration filters, typo handling, bounded candidates, and paginated browsing.
- Optional offline CLAP hybrid semantic search through dynamically loaded ONNX
  Runtime, verified model identities, resumable embedding generation, and a
  pinned opt-in model/runtime installer for macOS arm64 and Linux x86_64.
- Built-in WAV and uncompressed AIFF/AIFC decoding for core audio processing,
  plus host-decoded PCM interfaces for additional formats.
- Acoustic fingerprints, duplicate/near-duplicate families, and search by
  example using fingerprint and optional semantic similarity.
- Audio playback, seeking, preview volume, keyboard navigation and in/out
  marks, original-file drags from results, and persistent trimmed PCM24 WAV
  exports from waveform selections.
- Sparse provisional waveform previews, exact channel envelopes, integrated
  loudness and sample peak analysis, and streaming PCM analysis.
- Two-tier WVT3 waveform storage, compact Int8 encoding, bounded detailed cache
  eviction, and resumable background waveform generation.
- **Fast only**, **Balanced**, and **Complete** background refinement modes,
  pause/resume controls, and admission based on host activity and resources.
- Bounded foreground search/playback workers, per-query cancellation,
  stale-result suppression, and shutdown/removal barriers that drain active
  work before closing the catalog or releasing file access.
- Schema migrations, source identity validation, bounded semantic retrieval
  with SQ8 candidate scoring and exact reranking, and search/storage
  optimizations documented with measured benchmarks.
- Catalog backup/restore, recovery safety copies, integrity checks, storage
  usage reporting, waveform cache deletion, and Finder links in Settings.
- Persistent appearance settings for system/light/dark mode, app accent,
  waveform colors, and color resets.
- Build scripts and Make targets for the macOS application, universal
  XCFramework, portable core tests/library, and Linux cross-compilation. Linux
  support covers the core; the desktop frontend is macOS-only.
- Core and C ABI tests, Swift lifecycle/policy/window/Settings checks, synthetic
  performance benchmarks, and opt-in real-audio acceptance tools.
- Architecture, search, audio, waveform algorithm/cache, recovery, performance,
  portability, roadmap, and third-party documentation.
