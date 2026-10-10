import SwiftUI
import AppKit

// Run with: bash scripts/test-window-chrome.sh (requires a macOS desktop session).
@main
struct WindowChromeCheck: App {
    private static let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("wavesearch-chrome-\(UUID().uuidString)")
    @StateObject private var store = AppStore(
        storageDirectory: directory,
        preferences: UserDefaults(suiteName: UUID().uuidString)!, startsRefinement: false
    )

    var body: some Scene {
        WindowGroup {
            ContentView().environmentObject(store).frame(width: 1000, height: 680)
                .preferredColorScheme(.light)
                .task {
                    try? await Task.sleep(for: .seconds(2))
                    let window = NSApp.windows.first(where: { $0.isVisible })!
                    let frame = window.contentView!.superview!
                    @MainActor func snapshot() -> NSBitmapImageRep {
                        let bitmap = frame.bitmapImageRepForCachingDisplay(in: frame.bounds)!
                        frame.cacheDisplay(in: frame.bounds, to: bitmap)
                        return bitmap
                    }
                    @MainActor func toggle() {
                        // macOS can move the principal library tabs before the navigation item.
                        let view = window.toolbar!.items.compactMap(\.view)
                            .first { $0.bounds.size == NSSize(width: 30, height: 30) }!
                        let location = view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil)
                        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                            window.sendEvent(NSEvent.mouseEvent(
                                with: type, location: location, modifierFlags: [],
                                timestamp: ProcessInfo.processInfo.systemUptime,
                                windowNumber: window.windowNumber, context: nil,
                                eventNumber: 0, clickCount: 1, pressure: 1
                            )!)
                        }
                    }
                    // Sample the sidebar background; closing must replace it with the main panel.
                    let open = snapshot().colorAt(x: 100, y: 200)
                    toggle()
                    try? await Task.sleep(for: .milliseconds(400))
                    assert(open != snapshot().colorAt(x: 100, y: 200), "Toolbar click must collapse sidebar")
                    toggle()
                    try? await Task.sleep(for: .milliseconds(400))
                    assert(open == snapshot().colorAt(x: 100, y: 200), "Toolbar click must reopen sidebar")
                    await store.shutdown()
                    try? FileManager.default.removeItem(at: Self.directory)
                    print("PASS: native sidebar toggle closes and reopens")
                    exit(0)
                }
        }
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unifiedCompact(showsTitle: false))
    }
}
