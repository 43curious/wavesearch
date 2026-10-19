# Keyboard and accessibility workflows

WaveSearch uses native selectable Lists for libraries and results. Results expose
the sound name, duration (or unknown duration), library, known channel count,
favourite state and acoustic-family membership. Their accessibility actions
provide selection, preview playback, similar-sound search, favourites and Finder
reveal. The native list also exposes its selected rows.

## Focus and commands

**Command–K** focuses search. **Escape** moves from search to results, then from
results back to search. Bare navigation/preview keys, including arrows, Space,
Return, j/k, h/l and i/o, operate only while the results list has focus. Other
focused controls receive their normal keys; Command/Control/Option combinations
used by VoiceOver are not intercepted. Modal sheets and other windows are
excluded from the main-window monitor.

**Tab / Shift–Tab** follow native macOS Keyboard navigation settings. The search
field, sidebar, result list, player controls and Settings retain normal focus
handling. Mouse clicks no longer forcibly clear the first responder.

**Help → Keyboard Shortcuts**, **Command–?**, or **?** outside text input opens a
separate reference window. Escape closes it. The reference lists the actual
commands, including the gg/u and Shift–G first/last-result shortcuts. See the
[README shortcut table](../README.md#keyboard-shortcuts).

The **Library** menu provides **Add Library** (Command–Shift–O) and actions for
the selected library: re-index, deep re-index, reconnect and remove. These use
the same availability/disabled rules as the library context menu. Settings
remains available through **Command–comma**.

## Seeking, ranges and editor copies

The labeled **Preview position** slider seeks in 0.01-second steps. It exposes
the current position and duration, and is disabled during preparation or when
playback is unavailable. **Set in point**, **Set out point** and **Clear Range**
operate on the same `PlayerController.selection` as pointer selection and i/o.
The waveform exposes analysis/preparation availability, playhead time and the
current range. The volume slider has a label and percentage value; favourite
controls expose their state.

**Copy for Editor** (Command–Shift–C) prepares a file URL for pasting into an
editor that accepts file URLs, using the same policy as dragging:

- **Keep the files in place:** the full original URL, including for a range.
- **Copy files to Exports:** an unchanged whole-file copy, or a PCM24 WAV for a
  partial range. Completed exports remain persistent media.

Preparation uses the host blocking-work registry and captures its generation
before scheduling. Cancellation, a replaced file selection, or a library
suspend/resume prevents stale clipboard publication. Preparation errors are
shown in the panel. Copy status, completed searches, scan state and refinement
pause changes request low-priority accessibility announcements; continuous progress ticks do
not repeatedly request speech. The indexing status button exposes its current
progress for inspection.

## Validation and limits

The existing lifecycle check includes original-URL publication, real PCM24 range
rendering, cancellation, selection replacement and obsolete-generation rejection
for keyboard copies. Its injected URL writer isolates those behaviors from the
system pasteboard service. Existing drag checks exercise actual pasteboard file
URLs separately.

The window check includes native result selection/actions, search labeling,
waveform range values, focused-slider keyboard seeking, an accessibility action
for the out mark, and opening shortcut help by key and menu. It retains existing
arrow/mark/playback/text-entry checks. Run GUI checks sequentially with a logged-in
desktop via `make check`; see [CI](CI.md) for the headless split.

During implementation, core checks, direct Swift app/window-check compilation,
refinement-policy checks and focused keyboard-copy checks could run. The host
could not run Xcode project builds or the native window check, and the full
lifecycle suite encountered unavailable native playback/pasteboard services.
Consequently keyboard focus, accessibility-tree assertions and actual VoiceOver
speech have not passed desktop acceptance. A file URL on the clipboard does not
prove that a DAW or NLE imports it; see [editor import validation](WAVEFORM_AND_AUDIO_PREVIEW.md).

Complete these checks on a normal desktop before treating
[issue #28](https://github.com/43curious/wavesearch/issues/28) as fully accepted:

1. Navigate search, libraries, results, playback and Settings with keyboard only,
   including disabled controls, empty results, long lists and repeated searches.
2. With VoiceOver, verify sound names, selected-row announcements, result actions,
   waveform position/range/availability, volume, favourites and copy errors.
3. Adjust the position slider, set/clear marks and audition the range. Confirm
   controls retain Space/Return/arrows and text input retains letters and **?**.
4. Observe search completion, scan/pause and copy announcements without
   repeated progress-tick speech. Open and close shortcut help by key and menu.
5. Copy whole sounds and ranges under both import preferences, paste into the
   intended editor, then replace selections or remove a library during a copy.
