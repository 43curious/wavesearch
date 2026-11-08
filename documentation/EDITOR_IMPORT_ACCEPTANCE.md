# Native editor import acceptance

[Issue #31](https://github.com/43curious/wavesearch/issues/31) remains open for
drag-and-drop, external-drive and cross-editor acceptance. The file-URL/PCM24
lifecycle checks establish payload and byte correctness. The scripted Resolve
run below additionally establishes native timeline import and decoded output.
Use disposable catalogs/projects; real-library search acceptance remains
[separately deferred](REAL_LIBRARY_ACCEPTANCE.md).

## Current evidence

Inventory on 2026-11-08, read from installed application Info.plists:

| Editor | Installed version/build | Native timeline result |
| --- | --- | --- |
| Logic Pro Creator Studio | 13.0 / 7801 | Unverified; not run |
| DaVinci Resolve Studio | 21.1.1 / 21.1.10010 | 12 scripted timeline cases and reopened-project render passed; pointer drops unverified |
| Pro Tools | Not found in standard application locations | Unverified |
| REAPER | Not found in standard application locations | Unverified |
| Premiere Pro | Not found in standard application locations | Unverified |

The macOS window and Settings checks now pass in this host's desktop session.
The earlier October run lacked a desktop. The November Resolve run used a new,
disposable project; no existing project was edited. Physical external drives,
other editors, audible playback and an actual WaveSearch app quit remain unverified.

### Scripted Resolve acceptance, 2026-11-08

The [machine-readable report](editor-import/resolve-2026-11-08.json) records all
12 combinations of WAV/AIFF/lossless ALAC, both import preferences and
whole/selected scopes. A separate Swift producer called the production
`audioImportURL` and exited before native import. Resolve's `MediaPool.ImportMedia`
and `AppendToTimeline` (`mediaType: 2`) placed each payload on a stereo track in
a 24 fps / 48 kHz project. Supplied and observed media paths identified the same
files; Resolve did not make an additional copy. Compare filesystem identity
rather than Unicode path spelling: this run preserved the same files despite
NFC/NFD differences in the returned paths.

Every whole-file case, including selected ranges under **Keep the files in
place**, occupied 4 seconds. Each selected **Copy files to Exports** case occupied
1.5 seconds with the correct source material. All 12 paths and durations survived
saving, closing and reopening the project after the producer had exited.

Resolve then rendered the reopened 40.5-second timeline as stereo PCM24 at
48 kHz. All 1,944,000 frames matched the expected PCM16 source samples scaled
to PCM24 exactly in both channels, including the two middle bursts in trimmed
cases. Original and supplied-media SHA-256 values remained unchanged. This is
native decoding/render acceptance; pointer delivery, clipboard paste, audible
playback, actual app quit and physical external storage are separate checks.
After recording the results, the disposable project and its owned fixture
exports were removed. Original sources and raw reports/rendered audio were
retained outside the repository.

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

The November preparation run generated WAV/AIFF/ALAC and 120 initially unverified
cases. The earlier October run generated WAV/AIFF and 80 cases because ALAC
conversion was unavailable then. Fixture generation alone is not an editor pass
or professional-library validation.

To prepare the actual production import URLs, build the core and run the opt-in
helper once on those fixtures:

```bash
make core
bash scripts/prepare-editor-import-payloads.sh /tmp/wavesearch-editor-run
```

It compiles the app's import code, verifies source/whole-copy bytes and range
frame counts, and writes `payloads.json`. The helper creates persistent fixture
media in WaveSearch's Exports directory; it does not install models or start the
app. It refuses an existing `payloads.json`. This helper is outside normal checks
because editor acceptance must be deliberate and completed exports persist.

For a scripted Resolve reproduction, start from an empty project manager or an
empty Untitled Project. Create a uniquely named `WaveSearchInterop-…` project;
never switch away from existing work. Verify 24 fps and a 48 kHz project sample
rate before adding media. Iterate `payloads.json` in order: use
`pool.ImportMedia([case["path"]])` followed by
`pool.AppendToTimeline([{"mediaPoolItem": clip, "mediaType": 2}])`. Assert each
duration, channel count, sample rate and resolved file identity. Save, close and
reopen that project, then repeat the assertions.

Before rendering, load the built-in **Audio Only** preset. Set whole-timeline
export with video disabled, audio enabled, `AudioFormat: "wav"`,
`AudioCodec: "lpcm"`, `AudioBitDepth: 24`, `AudioSampleRate: 48000`, and an owned
fixture output directory/name. Add/start the job and require **Complete**, then
check its output (Python 3.12+ handles Resolve's extensible WAV header):

```bash
python3.14 scripts/check-editor-import-render.py \
  --fixture /tmp/wavesearch-editor-run --render /path/to/native-render.wav
```

The checker compares every sample, source/payload checksums and the complete
timeline length, writing `render-analysis.json`. A producer URL or persisted
project metadata alone is insufficient for this render check. Preserve the raw
run artifacts outside the repo; the checked-in report omits personal paths.

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
