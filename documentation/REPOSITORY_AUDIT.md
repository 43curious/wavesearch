# Repository cleanup audit

## Inventory and evidence (2026-10-12)

The audit starts from `82c2859`: 129 tracked files totaling 16,870,904 bytes.
Tracked source/assets, untracked files, and ignored local artifacts were listed
separately. There was no pre-existing untracked work. Exact SHA-256 grouping
found two pairs of byte-identical tracked files, both in the app icon catalog.

| Finding | Action and reason |
| --- | --- |
| `WaveSearch_Icon_Default_256 1.png` duplicates `WaveSearch_Icon_Default_256.png` (223,823 bytes). | Both 128-point/2x and 256-point/1x slots reference the canonical 256-pixel image; remove the duplicate. |
| `WaveSearch_Icon_Default_512 1.png` duplicates `WaveSearch_Icon_Default_512.png` (837,462 bytes). | Both 256-point/2x and 512-point/1x slots reference the canonical 512-pixel image; remove the duplicate. |
| `make clean` referenced `macos/WaveSearchKit.xcframework`, while the build creates the framework in `core/` and copies it into the app source directory. | Remove the two actual generated copies with `clean`, alongside root/core Zig caches and core output. |
| DerivedData cleanup paths were unquoted. | Quote the selected directory so a custom path containing spaces is removed as one path. `clean` removes only its Build directory; `distclean` removes the selected directory. |
| Waveform references still described file promises, Float32 exports, an eight-file sleep burst, and waveform-first queue draining. | Correct the active references to current file-URL imports, PCM24 partial-copy exports, and fair one-file background scheduling. Preserve historical benchmark/release records. |

Consolidating the icons removes 1,061,285 bytes from the working source snapshot.
Both scale slots remain populated; the artwork is unchanged. Git history still
contains the original images, so this does not claim equal savings in an
existing clone or the compiled app.

Build roots and relative Zig imports reach every `core/src/*.zig` module. The
Xcode project uses its synchronized app source/asset directory; the scripts
reference the native check and waveform benchmark tools. No source file was
removed merely because a text search failed to find an apparent caller.

## Intentionally retained

- SQLite/ONNX Runtime headers, licenses, and notices: required build inputs and
  dependency attribution, not generated runtime installations.
- Benchmark, acceptance, and check tools: separate workflows, including opt-in
  real-audio checks and the legacy waveform comparison used by benchmarks.
- Root overview/operations/acoustic guides, the concise waveform summary, and
  the Spanish explanation: distinct audiences and purposes. Detailed waveform
  references remain linked; corrected active claims do not erase history.
- Historical research, benchmark results, and unfinished roadmap items: useful
  evidence/proposals, not dead implementation files.
- The old internal waveform coordinator type alias: retained source
  compatibility; it is not a second worker implementation.
- Ignored personal Xcode state, `.DS_Store`, optional fixtures/models/runtime
  artifacts, and alternate DerivedData directories: inventoried without
  deleting local data. Existing ignore rules cover these categories and the
  generated framework copies. Select alternate DerivedData explicitly when
  cleaning it rather than globbing all local directories.

Persistent exports and original library media are outside build cleanup. No
history rewrite, vendor update, model download, or blanket local-data deletion
is part of this audit.

## Verification

- Checked local Markdown file links and all asset catalog image references.
- Ran the actual `clean` and `distclean` targets in a disposable directory with
  dummy caches/frameworks and a DerivedData path containing spaces. The targets
  removed the expected products and preserved source/vendor, models, fixtures,
  personal Xcode state, and an Exports sentinel. `distclean` additionally removed
  the selected DerivedData directory.
- Core checks and focused native lifecycle/refinement checks passed, including
  actual acoustic publication before the waveform backlog drains, playback
  pause, and draining.
- The full `make check` passed from an exact export of the staged source with
  no project caches, build products, models, or downloaded fixtures. It rebuilt
  both framework copies and the macOS application, passed 97 core tests (two
  optional model tests skipped), and passed the refinement, lifecycle, window,
  and Settings checks.
- Linux x86_64 `make check-linux` cross-compilation passed from the same export;
  native Linux execution was not available on this macOS host.

For a clean source export, run `make check` to regenerate both framework copies,
build the app, and execute core/native checks without model installation.
`make check-linux` checks cross-compilation only; native Linux execution remains
separate. This inventory identifies demonstrated cleanup opportunities, not a
proof that every retained function or document is necessary forever.
