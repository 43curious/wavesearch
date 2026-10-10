# WaveSearch

Zig + SwiftUI sound effect search app for macOS.
SQLite FTS5 index, optional local CLAP hybrid search, native Tahoe sidebar, and waveform player panel.

## Prerequisites

- macOS 14+ (Sonoma or Tahoe)
- Xcode 26+ for the macOS app and Swift checks
- Zig 0.17.0 (pinned in `.zig-version`)

---

## Build

The build pipeline is automated from the repo root:

```bash
make build   # Zig core + macOS app
make core    # Zig core / XCFramework only
make macos   # full macOS debug build
make clean   # remove local build caches
```

Opening `macos/WaveSearch/wavesearch.xcodeproj` and pressing **Cmd+R** also
works: Xcode runs a pre-build phase that rebuilds the Zig XCFramework before the
Swift app links.

Portable core development on macOS or Linux:

```bash
cd core
zig build test -Doptimize=safe
zig build lib -Doptimize=safe
```

`zig build xcframework -Doptimize=safe` is intentionally macOS-only.

## Local checks

```bash
make check        # Run before committing: formatting, scripts, core tests/build
                  # and, on macOS, the app build and existing Swift checks
make check-core   # Portable checks on either macOS or Linux
make check-linux  # Cross-compile the Linux x86_64 library from macOS
```

On macOS, `make check` requires a logged-in desktop session for the settings
appearance check. App builds use local ad-hoc signing and need no developer
account. Optional model downloads and performance benchmarks are separate.
Use `make check ZIG=/path/to/zig` to select the pinned compiler explicitly.

The repository contains the portable core and macOS app together. A Linux UI
can use the C API in `core/include/wavesearch.h`; the SwiftUI app remains macOS
only. Cross-compilation checks library compatibility, while `make check-core`
on Linux runs the portable tests on that platform.

Build caches, generated XCFramework copies, personal Xcode state and optional
model/runtime artifacts are ignored. A clean checkout regenerates frameworks
through `make build` or the Xcode build phase.

Schema-12 search/resource changes, measured before/after results, and validation
limits: [search optimization results](documentation/SEARCH_OPTIMIZATION_RESULTS.md).
Existing catalog page sizes are preserved; checked 16 KiB compaction is an
explicit new-copy operation, never a startup vacuum.

The XCFramework build will:
1. Download the SQLite amalgamation into `core/vendor/` (requires internet, one-time)
2. Compile the Zig core for arm64 + x86_64
3. Rebuild Apple archive symbol tables with `ranlib`
4. Run `lipo` → universal binary
5. Run `xcodebuild -create-xcframework` → `WaveSearchKit.xcframework`
6. Copy it into `macos/WaveSearch/WaveSearch/` for the Xcode project

---

## Using WaveSearch

1. Click **+** at the bottom of the sidebar to add a library folder
2. WaveSearch publishes a fast searchable snapshot; progress is available from
   the indicator at the top right
3. Type in the search bar immediately; Balanced refinement waits until the Mac
   is idle and on AC power
4. Click a result to load it into the player panel
5. Press **Space** to play/pause (when search bar is not focused)
6. Choose **Fast only**, **Balanced** (default), or **Complete** background refinement from the top-right status popover
7. Click the waveform to seek
8. Right-click a folder in the sidebar to re-index or remove it
9. Use **Settings → Storage & Recovery** for catalog backups, restore, full
   integrity checks, and storage sizes. **Reconnect Library…** in a folder's
   context menu reconnects a moved library by re-scanning its new root.
10. Press **⌘,** to open Settings. **General** controls preview volume and
    background refinement; **Appearance** controls light/dark mode, app accent,
    and waveform colors. **Storage & Recovery** shows cache locations and can
    delete generated waveform caches.

Keyboard shortcuts:

- **⌘K** or **/** — focus search
- **Esc** — leave search
- **j / k** — next / previous result
- **gg / G** — first / last result
- **Return** — play selected result from the in point
- **h / l** — step backward / forward
- **i / o** — set DaVinci-style in / out points
- **b** — reveal selected file in Finder

Search supports duration filters:

- `whoosh <2s` — shorter than 2 seconds
- `riser >5s` — longer than 5 seconds
- `impact =1.5s` — around 1.5 seconds
- `click <500ms` — shorter than 500 ms

WaveSearch also indexes WAV metadata when present (`bext`, `iXML`, and
`LIST/INFO`) and labels duplicate-looking results in the current result set.

Optional offline CLAP semantic search is available on macOS arm64 and Linux
x86_64. It requires an explicit, verified model/runtime installation (about
800 MB); normal builds never download models:

```bash
./scripts/install-clap-model.sh
```

See `core/models/README.md` for platform, licensing, custom-path, and built-in
WAV/AIFF semantic indexing details. Lexical search remains available when CLAP is not
installed or cannot load.

Phase 3 adds robust WAV/AIFF acoustic families and search-by-example, available from
result context menus and the **Find Similar** toolbar action. Phase 4 adds
cancellable/deep indexing, bounded-memory waveform and semantic scans, integrity
checks, and online backup/recovery. See `documentation/README.md` for the
current documentation index, including the full waveform algorithm reference;
additional operational references are `ACOUSTIC_SEARCH.md`, `OPERATIONS.md`,
`BENCHMARKS.md`, `WAVEFORM.md`, and `ROADMAP.md`.

Optional semantic search uses the verified `muzaiten/clap-htsat-base-onnx`
pack and a dynamically loaded ONNX Runtime. It is never downloaded by the app.
See [`core/models/README.md`](core/models/README.md) for the explicit installer,
environment variables, integrity contract, and limitations. Built-in semantic indexing supports WAV and uncompressed AIFF/AIFC. Host-decoded
compressed formats can use the additive interleaved-PCM search ABI; unsupported
formats retain lexical indexing/search.

If a hard drive is disconnected, the folder shows **"Missing drive"** in red
and its files remain searchable from the index.

---

## Architecture

```
wavesearch/
├── build.sh
├── core/                         ← portable Zig indexing/search/DSP core
│   ├── build.zig                 ← arm64 + x86_64 → lipo → xcframework
│   ├── vendor/
│   │   ├── sqlite3.c             ← downloaded by build.sh
│   │   └── sqlite3.h
│   ├── include/
│   │   ├── wavesearch.h          ← C API
│   │   └── module.modulemap
│   └── src/
│       ├── main_c.zig            ← exported C functions
│       ├── db.zig                ← SQLite wrapper
│       ├── search.zig            ← FTS5 + hybrid retrieval
│       ├── clap_provider.zig     ← verified/refcounted CLAP lifecycle
│       ├── model_manifest.zig    ← model integrity contract
│       ├── audio.zig             ← built-in WAV/AIFF decoding
│       └── waveform.zig          ← streaming PCM analysis, tiers, μ-law, WVT3
└── macos/                        ← Swift UI and platform adapters
    └── WaveSearch/
        ├── wavesearch.xcodeproj
        └── WaveSearch/
            ├── WaveSearchKit.xcframework ← generated
            ├── WaveSearchApp.swift
            ├── AppStore.swift            ← state + Zig bridge
            ├── ZigWaveformAnalysis.swift ← AVFoundation-to-core PCM adapter
            ├── AudioAnalysis.swift       ← AVFoundation/Accelerate host path
            ├── ContentView.swift
            ├── SidebarView.swift         ← Tahoe sidebar
            ├── MainView.swift            ← search + results list
            └── PlayerPanel.swift         ← waveform + playback
```

## Inner development loop

```bash
# Edit Zig code, then:
./build.sh          # recompiles + copies xcframework
# Xcode auto-picks up the new framework → Cmd+R
```
