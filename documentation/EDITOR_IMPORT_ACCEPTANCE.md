# Native editor import acceptance

[Issue #31](https://github.com/43curious/wavesearch/issues/31) remains open for
actual timeline acceptance. The file-URL/PCM24 lifecycle checks establish payload
and byte correctness. They do not establish that an editor imported a clip.
Use disposable catalogs/projects; real-library search acceptance remains
[separately deferred](REAL_LIBRARY_ACCEPTANCE.md).

## Current evidence

Inventory on 2026-10-21, read from installed application Info.plists:

| Editor | Installed version/build | Native timeline result |
| --- | --- | --- |
| Logic Pro Creator Studio | 12.4 / 6707 | Unverified; desktop unavailable |
| DaVinci Resolve | 21.1.1 / 21.1.10010 | Unverified; desktop unavailable |
| Pro Tools | Not found in standard application locations | Unverified |
| REAPER | Not found in standard application locations | Unverified |
| Premiere Pro | Not found in standard application locations | Unverified |

The window check exits 2 before interaction because this session has no
accessible logged-in desktop/active display. No editor was launched or personal
project changed. External drives, native compressed-codec import and persistence
after quitting WaveSearch remain unverified.

## Prepare a reproducible run

From the repository root, choose a new directory:

```bash
python3 scripts/prepare-editor-import-check.py --output /tmp/wavesearch-editor-run
```

The command refuses an existing destination. It creates four-second, 48 kHz,
stereo PCM16 WAV/AIFF sources with spaces, accents and Japanese characters in
their paths. Four short bursts at 0.5, 1.25, 2.25 and 3.5 seconds make selection
boundaries audible; left/right tones differ. It attempts a lossless ALAC source
using the installed `afconvert`, recording codec failure explicitly. There are
no downloads. `acceptance.json` records source checksums, installed editor
versions and unverified cases for both import modes, whole/selected scopes and
internal/external storage. Missing editors are still unverified, not passed.
Only the requested fixture directory is written.

The preparation run on this host generated WAV/AIFF and 80 unverified cases;
independent `ffprobe` inspection confirmed both sources as stereo PCM16, 48 kHz,
4.000 seconds. Native ALAC generation was unavailable. These are synthetic fixture
checks, not a successful editor import or professional-library validation.

## Manual matrix

Create an empty editor project at 48 kHz without automatic tempo matching,
time-stretch or loudness processing. Record the actual project setting names
and their values, including any copy/consolidate/convert-on-import setting.
Index only the generated Sources folder in a disposable WaveSearch catalog.
For range cases set **In = 1.000 s, Out = 2.500 s**. Test a result-row drag for
whole files and a second drag inside the selected waveform for ranges.

| WaveSearch import mode | Scope | Expected supplied media | Expected region before editor-specific trimming |
| --- | --- | --- | --- |
| Keep the files in place | Whole | Full original URL | 4 s / 192,000 frames |
| Keep the files in place | Selected | Full original URL | 4 s / 192,000 frames; no portable in/out reference |
| Copy files to Exports | Whole | Persistent unchanged copy | 4 s / 192,000 frames |
| Copy files to Exports | Selected | Persistent stereo PCM24 WAV | 1.5 s / 72,000 frames, containing the two middle bursts |

For each available editor/source/mode/scope:

1. Drop onto an empty timeline and inspect the **actual region** duration,
   source offset, sample rate and channels. Record errors and transformations.
2. Inspect the editor's media/project browser for the actual resolved media
   path. WaveSearch's preference controls its supplied URL; an editor can still
   choose to copy or convert it. Record that choice separately.
3. Save and close the project, quit WaveSearch normally, reopen the project
   and play the imported region. Record whether the media is still online and
   both channels survive. For Exports, the path must remain usable.
4. Compare original source SHA-256 against `acceptance.json`. During an
   intentionally abandoned export, release the pointer/change selection/close
   the panel and confirm the source survives. Completed exports already used
   by a project must remain available; incomplete outputs must not be imported.
5. Repeat from a disposable folder on an external drive. Record volume format,
   source path and permission prompts. Safely eject only after closing work;
   confirm missing-media behavior without deleting or renaming originals.
6. Fill the corresponding JSON case with editor version, observed path/duration,
   copy settings, persistence and source-integrity result. Keep unsupported or
   unavailable combinations marked as such; never infer a pass from another
   editor or from WAV support alone.

After all projects are discarded, remove only exports carrying this fixture's
`WaveSearchInterop-...` prefix and these owned fixture folders. WaveSearch does
not automatically prune persistent Exports. Keep the completed report and any
failure artifacts outside the repository unless deliberately adding a minimized
regression fixture. Add code fixes only after a reproducible import failure.

## Optional selection-preserving references

The current integration supplies file URLs. A native sequence/project reference
would need an explicit export action carrying source URI, source in/out,
sample/timebase and channel mapping. It would also need Unicode/path escaping,
relinking and persistent ownership. Changing the default drag silently would
break the existing contract.

Candidate formats for a later experiment, after the basic matrix passes:

| Family | Primary evidence | Assessment |
| --- | --- | --- |
| Final Cut Pro XML | [Apple's Logic Pro import/export guide](https://support.apple.com/en-ie/guide/logicpro/lgcp9b2d2456/mac) | Logic documents XML interchange and possible sample-rate conversion. Exact schema/version and selected-range source offsets still need an exported specimen and native import checks. |
| AAF with external media | [Avid Pro Tools reference, import options](https://cdn.avid.com/ProTools/2020.12/4A5C431A/Pro_Tools_Reference_Guide_2020.12.pdf) | Avid documents link/copy/consolidate policies. This older guide establishes a candidate, not acceptance for current versions; verify installed-version behavior and identifiers. |
| REAPER project/subproject | [REAPER user guide, project import](https://dlx.reaper.fm/userguide/html/) | Project import is a candidate for an editor-specific action. A generator would require a known-good specimen and measured source-offset preservation. |

These are investigation candidates inferred from documented interchange paths.
No clip-reference exporter is implemented or advertised. Resolve/Premiere format
compatibility and all cross-editor in/out preservation remain unverified. The
first experiment should target one editor with an exported reference specimen
and assert source path, 1.000 s in, 1.500 s duration and post-quit persistence.
