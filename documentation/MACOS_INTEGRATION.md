# macOS activation and discovery

## Global search shortcut

Settings → General offers Off (the default), Control–Option–Space,
Control–Option–F, Control–Shift–Space, and Command–Shift–Space. The choice is
stored in user preferences. The shortcut works only while WaveSearch is running.
It activates the existing search window, restores a minimized window, or
reopens a closed window, and focuses the search field without clearing its query.
The app uses a single SwiftUI Window scene so invocation reuses that window.

`GlobalSearchShortcut` owns an exclusive Carbon RegisterEventHotKey registration
and application event handler on the main actor. It requests neither an event
tap nor Input Monitoring/Accessibility access. Changing or disabling the shortcut
releases the previous registration; termination removes both key and handler.
Native registration errors appear beside the preference, with a Retry button.
A conflict requires another combination or releasing the key in the other app.
macOS or applications can reserve/intercept keys in ways registration cannot
detect; test the chosen combination with the apps you use.

SwiftUI's [openWindow action](https://developer.apple.com/documentation/swiftui/openwindowaction)
opens the scene. A focus notification handles already visible content; newly
created content also focuses search on appearance. This route performs no
catalog, filesystem, decoding or inference work.

## Spotlight and Quick Look assessment

No extension is added at this stage. macOS already has
[Quick Look audio preview and trimming](https://support.apple.com/en-ie/guide/mac-help/mh14119/27/mac/27).
WaveSearch's catalog currently supplies source file references, metadata and
derived analysis; it has no portable collection document whose preview needs
a custom renderer. Duplicating basic playback in a Quick Look extension has
no demonstrated benefit for this workflow.

Spotlight could eventually expose app-owned tags, collections or descriptions
that are absent from source files. That is a potential benefit, rather than
evidence to publish every private/removable library path into another index.
[Core Spotlight](https://developer.apple.com/library/archive/documentation/General/Conceptual/AppSearch/AppContent.html)
would require explicit scope, stable identifiers, opening a catalog selection,
and deletion/reconciliation on library removal or disconnection. Revisit after
the tags/collections identity contract exists, then measure index size,
update/cleanup cost and foreground latency on a disposable large library.
There is no catalog discovery index or indexing overhead from this change.

## Verification

Run `make check`. The existing native window check exercises an actual exclusive
registration conflict, preference persistence, event-handler routing, search
focus, minimize/close/reopen, and disabling/releasing the key. It uses isolated
preferences and a disposable catalog. Event routing is driven by injected
Carbon hot-key events; this does not prove physical key dispatch from another
application or every system shortcut configuration.

For manual acceptance, enable a combination, focus another application, and
press it with the WaveSearch window visible, minimized, and closed. Confirm
search focus and query preservation each time. Disable it and confirm that
the former key no longer activates WaveSearch. Repeat for a conflicting system
or application shortcut and after relaunch. Physical cross-application dispatch
and hardware-layout differences remain manual checks.
