# Working in WaveSearch

## Jon's preferences

- Keep solutions simple and use type safety to make invalid states harder to
  represent. Propose substantial simplifications when they benefit the task.
- Questions are read-only. If Jon asks about feasibility, opinions, or why
  something happens, answer without editing files. Even a trivial change needs
  a follow-up instruction to implement it.
- Preserve unrelated work, including staged files. Inspect `git status` and the
  relevant diff before making changes. Destructive actions require explicit
  authorization. Finish issues with a local commit and let Jon push it.
- Keep comments concise and useful, and update them when behavior changes.
- Use focused tests that exercise real behavior. Avoid repetitive smoke tests
  and tests whose only purpose is to assert that deleted UI/code is absent.

## Orientation

Read [README.md](README.md) for setup, supported platforms, build commands, and
user workflows. Check [CHANGELOG.md](CHANGELOG.md) for recent behavior changes.

- `core/src/`: Zig catalog, indexing, search, fingerprints, semantic providers,
  and waveform/audio processing. `core/include/wavesearch.h` is the frontend C
  API; `core/build.zig` defines the build and tests.
- `macos/WaveSearch/WaveSearch/`: SwiftUI/AppKit interface, application state,
  native audio decoding/playback, settings, permissions, and platform adapters.
- `macos/WaveSearch/Tools/` and `scripts/test-*.sh`: existing Swift checks.
- `Makefile`, `build.sh`, and `.zig-version`: build entry points and the pinned
  Zig toolchain. Use this repository's Zig flags rather than assuming another
  compiler version's syntax.
- The macOS app requires macOS 14+ and Xcode 26+. The core has macOS/Linux build
  paths. A Linux desktop frontend and Windows support remain future work;
  cross-compilation does not prove native runtime behavior.

Read these references when touching the corresponding behavior:

| Change area | Reference |
| --- | --- |
| Public C API, ownership, or host lifecycle | [C API contract](documentation/C_API.md) |
| CI or build/check entry points | [Continuous integration](documentation/CI.md) |
| Playback, waveforms, selected-range imports | [Audio preview](documentation/WAVEFORM_AND_AUDIO_PREVIEW.md); [algorithm](documentation/WAVEFORM_ALGORITHM.md); [cache](documentation/WAVEFORM_CACHE_V10.md) |
| Search ranking, storage, or performance | [Search optimizations](documentation/SEARCH_OPTIMIZATION_RESULTS.md); [lexical vocabulary](documentation/LEXICAL_SEARCH.md); [benchmarks](BENCHMARKS.md) |
| Audio metadata parsing or browsing headers | [Sparse metadata and cache identity](documentation/AUDIO_METADATA.md) |
| Filesystem scans, watching, or file moves | [Reconciliation and move proofs](documentation/LIBRARY_RECONCILIATION.md); [Operations](OPERATIONS.md) |
| Refinement queues, retries, or queue migration | [Durable refinement](documentation/REFINEMENT_QUEUES.md) |
| CLAP loading, installation, preprocessing, or semantic coverage | [Model contract](core/models/README.md); [relevance acceptance](core/models/RELEVANCE.md); [coverage experiment](documentation/SEMANTIC_COVERAGE_EXPERIMENT.md) |
| Fingerprints, duplicate families, or example search | [Acoustic search](ACOUSTIC_SEARCH.md) |
| Fingerprint storage, decoding, or source hash strength | [Storage and identity](documentation/INDEXING_STORAGE_IDENTITIES.md) |
| Database lifecycle, backups, recovery, or library moves | [Operations](OPERATIONS.md) |
| Tags, collections, favourites, or selects JSON | [Portable selects](documentation/PORTABLE_SELECTS.md) |
| Platform boundaries, concurrency, or resource scheduling | [Performance and portability plan](documentation/PERFORMANCE_AND_PORTABILITY_PLAN.md); [fair scheduling](documentation/REFINEMENT_QUEUES.md#fair-background-scheduling) |
| Global search activation or macOS discovery integration | [macOS integration](documentation/MACOS_INTEGRATION.md) |
| Interface copy, counts, number/time formatting, or localization | [English/Spanish interface](documentation/LOCALIZATION.md) |
| Release signing, notarization, DMG packaging, or hardened runtime | [Release workflow](documentation/RELEASING.md) |

Use [documentation/README.md](documentation/README.md) to find further references.
Treat unchecked roadmap/plan items as proposals, and verify historical notes
against the implementation before relying on them.

## Implementation boundaries

- Keep indexing, search, schema, fingerprints, and canonical analysis behavior
  in the Zig core. Native hosts own interface, file permissions, playback,
  platform decoding, and OS signals. Preserve existing C API compatibility when
  extending the core.
- Keep blocking filesystem, database, decoding, and inference work off the
  main actor. Follow `BlockingWorkRegistry` admission/drain rules for host work
  and `LatestRequestWorker` for replaceable foreground requests. Capture work
  generation before scheduling deferred file preparation. Drain actual work
  before closing the core or releasing security-scoped access.
- Preserve atomic catalog updates, source/model identity checks, bounded
  memory use, and cooperative cancellation. An OS or runtime call may finish
  before cancellation takes effect; a canceled caller is not proof of draining.
- Treat filesystem events as invalidation hints for complete snapshots. Transfer
  individual file identity only with unambiguous complete-byte proof. Stop/drain
  native watches before library teardown and keep missing-volume scans safe.
- Native host workers can have small stacks. Avoid large stack scratch buffers
  when sorting core records that contain full paths.
- Keep indexed metadata unknown/limited states explicit. Validate catalog header
  metadata against physical source identity before skipping host inspection;
  XML extraction must never load external resources or expand DTD entities.
- Keep optional model/runtime downloads explicit and opt-in. Normal builds and
  tests must work without installing models. The native installer owns and drains
  its network/staging task at shutdown; verify before atomic activation and
  retain the previous bundle when repairing. See [model setup](core/models/README.md).
- Keep temporary preview ranges in `PlayerController` so waveform selection,
  keyboard marks, auditioning, and selected-range exports share the same bounds.
- Scope bare preview/navigation keys to results focus. Preserve text editing
  and native control keys, and provide keyboard and accessibility alternatives
  to pointer-only interactions. See [accessibility](documentation/ACCESSIBILITY.md).
- Editor imports default to **Keep the files in place**, passing the full
  original URL even for a selected range. **Copy files to Exports** copies whole
  files unchanged and renders partial selections as PCM24 WAVs. Exports are
  persistent media that projects may reference; source files must survive
  cancellation, and completed exports are not disposable caches.
- Keep generated build products, XCFramework copies, personal Xcode state, and
  model/runtime artifacts out of commits. Vendor updates should be deliberate
  dependency changes.

## Validation

Use existing checks appropriate to the change; fix failures before finishing.

- Core changes: `make check-core`. Changes to platform code also need native
  execution on the affected OS; `make check-linux` compiles the Linux library
  and core check executables without running them.
- Swift changes: `make macos`, plus the relevant existing lifecycle, refinement,
  window, or Settings script. Window/Settings checks need a desktop session;
  run GUI checks sequentially so they do not compete for focus.
- Headless macOS checks: `make check-core check-macos-headless`. Hosted CI skips
  window/Settings interaction; local `make check` still includes both.
  If Xcode project initialization fails, `make check-macos-runtime` rebuilds the
  core and compiles/links all Swift sources before running headless checks;
  it does not validate the app bundle. Lifecycle checks always cover controlled
  playback; lifecycle flags `--native-audio --native-codecs --native-pasteboard`
  require output, ALAC and pasteboard services (see the CI reference).
- Before committing code, run `make check` for the repository's full check
  entry point. If the host cannot run part of it, report exactly what remains
  unverified. For documentation-only changes, check facts, local links, and
  `git diff --check`; an application rebuild is unnecessary.
- When core code changes, rebuild the library used by Swift checks rather than
  testing against a stale XCFramework. The lifecycle, refinement-policy,
  `test-clap-installer.sh` and watcher scripts support `WS_CORE_LIBRARY` and
  `WS_CORE_HEADERS` overrides. Watcher checks inject events by default;
  `--native` additionally needs working FSEvents. Unrelated AppStore fixtures
  should set `watchesLibraries: false` to avoid unsolicited reconciliation.
- Run benchmarks and real-audio acceptance only when relevant. Use disposable
  fixtures/catalogs, and keep synthetic, cold-storage, real-audio, and GUI
  results distinct. An emitted drag URL does not prove a DAW imported it.

Finish by reporting the behavior changed, checks run, and material limits.

## Keep documentation current

- Update **CHANGELOG.md in the same changeset** for every meaningful feature,
  fix, removal, behavior change, or documentation/workflow change. Add concise
  entries to **Unreleased** under Added, Changed, Fixed, or Removed; consolidate
  related entries rather than recording every edit or test run.
- Preserve `0.1_alpha` as the first commit's version (`1165343`). Assign a new
  version/date only when Jon specifies a release. Historical sections describe
  what shipped at that point, and should change only to correct factual errors.
- **Review this AGENTS.md before finishing every task.** Update it in the same
  changeset when you discover or change a durable repository rule, architecture
  boundary, build/check workflow, recurring pitfall, or explicit preference.
  Correct or remove stale guidance. If none changed, leave it as is.
- Keep this file short and actionable. Put detailed implementation explanations
  in the relevant reference document and link them with the condition for
  reading them. Use the changelog for history, not AGENTS.md.
- Preserve the README's centered app icon, title, introduction, and navigation
  layout. Keep its overview and usage approachable, with detailed design and
  performance records in linked reference documents.
- Preserve Jon's preferences and authorization rules unless Jon changes them.
  Record project facts and workflows without inventing new approval gates.
- Update related README/reference documentation and comments whenever the
  implementation changes their claims. Verify local links before finishing.
