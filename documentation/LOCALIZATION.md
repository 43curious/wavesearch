# English and Spanish interface

The native `en.lproj` and `es.lproj` resources follow macOS language selection,
including its per-app language setting. English is the development fallback.
Reopen the app after changing the language. No preference keys or catalog
migrations are needed to select a language.

SwiftUI literal labels use native lookup. Calculated titles, AppKit panels,
errors, progress and accessibility announcements use `String(localized:)` before
publication. Keep whole phrases localizable where possible; do not translate
user filenames, source paths, tags/collection names, query syntax, UCS taxonomy
identifiers, model identities, JSON keys, preference raw values or cancellation
sentinels. Raw core/runtime diagnostics remain technical details in their source
language; the host's explanatory UI and recovery instructions are translated.
Interface localization is separate from bilingual lexical relevance and CLAP
language capabilities.

`LocalizedText` uses native `.stringsdict` plural rules for files, discovered
files, sounds, loaded sounds, matches and channels. Its second format argument
contains the locale-grouped number. Both plural forms must retain `%2$@`; the
`lld` count chooses the rule without formatting a second visible count. Native
number/measurement formatting preserves fractional audio durations, while
`DateComponentsFormatter` supplies elapsed-time units. The preview clock retains
its minute/second layout and hundredths;
rounding crosses minute boundaries before rendering. Exported ranges remain
integer milliseconds and all machine-readable formats retain their contracts.

## Validation

Run `bash scripts/test-localization.sh`, also included in the headless macOS
checks. It compiles production sources with complete concurrency checking, loads
copied native resources in a disposable bundle in separate English/US and
Spanish/Spain processes, and verifies enums, errors, recovery validation,
shortcut labels, Unicode source interpolation, plural forms, zero/large counts
and preview clock decimals. The compiler's extracted UI keys must exist in both
tables, with matching format argument types. No personal language preferences,
catalogs or system settings are changed.

When adding interface copy, update both `Localizable.strings` files and run this
check. Keep format arguments aligned; add a native plural entry for a new
count-dependent noun instead of concatenating a number and an English suffix.

Both-language desktop acceptance remains required: open search/empty states,
long result names, refinement progress, Settings, permission/recovery dialogs,
selects import/export, preview and keyboard help. Check long Spanish labels,
large counts, VoiceOver announcements, focused text editing and shortcuts.
The shortcut reference allows action labels to wrap. Headless resource checks
do not establish layout, keyboard focus or actual VoiceOver speech; use the
[accessibility checklist](ACCESSIBILITY.md) in a desktop session.

Native resource/plural behavior follows Apple's
[localization guide](https://developer.apple.com/library/archive/documentation/MacOSX/Conceptual/BPInternational/LocalizingYourApp/LocalizingYourApp.html)
and [plural resource documentation](https://developer.apple.com/documentation/xcode/localizing-strings-that-contain-plurals).
