# WaveSearch systems page

A one-page A4 explainer using Apollo Operations Handbook conventions: numbered
paragraphs, vector schematics, a design-data table and an operator checklist.
The main idea is that WaveSearch catalogs sound effects while originals stay
in their library folders. The second figure shows the choice between original
file URLs and persistent exports.

- [Print PDF](wavesearch-systems.pdf)
- [PNG preview](wavesearch-systems.png)
- [Editable HTML](wavesearch-systems.html)

The drawings simplify the runtime: worker admission, cancellation, cache tiers,
reconciliation and ranking details are omitted. The waveform is illustrative.
The import selector is a schematic of the Settings preference. Host-decoded
example limits concern the compressed-example path, not every source or library.
Pitch availability depends on the native processing path. No performance or
editor-interoperability claim is implied by the diagram.

## Source checks

The page was checked against the repository on 1 November 2026.

| Printed fact | Source |
| --- | --- |
| Catalog, search and original-media workflow | [Project overview](../../README.md), [search](../../core/src/search.zig), [application state](../../macos/WaveSearch/WaveSearch/AppStore.swift) |
| macOS 14 minimum | [Xcode deployment settings](../../macos/WaveSearch/wavesearch.xcodeproj/project.pbxproj) |
| 0.5×–2× preview rate; −12 to +12 semitones; pitch availability | [PlayerPanel.swift](../../macos/WaveSearch/WaveSearch/PlayerPanel.swift) |
| Duration equality tolerance of ±250 ms | [search.zig](../../core/src/search.zig) |
| Host-decoded examples: 60 seconds and 64 MiB of Float32 PCM | [ExampleAudio.swift](../../macos/WaveSearch/WaveSearch/ExampleAudio.swift) |
| Default original URL; whole-file copy; PCM24 WAV range export; persistent Exports | [AudioClipExport.swift](../../macos/WaveSearch/WaveSearch/AudioClipExport.swift) |
| Bare Space and i/o keys require results focus | [MainView.swift](../../macos/WaveSearch/WaveSearch/MainView.swift) |
| Background refinement yields to foreground work | [RefinementPolicy.swift](../../macos/WaveSearch/WaveSearch/RefinementPolicy.swift) |

The Basic Date is the date of initial commit `1165343`; the Change Date is the
page's revision date. These handbook identifiers do not assign an app release.

## Editing and rendering

Edit the HTML and keep `fonts/` beside it. Fonts and their distribution notices
are retained from the `nasa-handbook` skill. Iowan Old Style is supplied by
macOS; the HTML falls back to Georgia elsewhere.

Open the HTML in Chromium and print to PDF with A4 paper, background graphics
on and browser headers/footers off. For the same automated PDF/PNG pair, use
the skill's `scripts/render.sh` with this HTML path; set `CHROME` to an existing
Chrome/Chromium executable when needed. Its fit check must show room above the
footer. The skill's `scripts/check.py` checks page count, size and ink colors
and emits 300 dpi review tiles.

Validation: one A4 page, black and white only, embedded drawing/checklist fonts,
no footer overflow, and visual inspection of all eight review tiles. This is a
documentation artifact; the application was not rebuilt for it.
