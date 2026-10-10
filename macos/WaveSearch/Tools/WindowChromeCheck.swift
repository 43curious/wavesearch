import SwiftUI
import AppKit

// Run with: bash scripts/test-window-chrome.sh (requires a macOS desktop session).
@main
struct WindowChromeCheck: App {
    @NSApplicationDelegateAdaptor(AppLifecycleDelegate.self) private var lifecycle
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
                    NSApp.setActivationPolicy(.regular)
                    NSApp.activate(ignoringOtherApps: true)
                    window.makeKeyAndOrderFront(nil)
                    try? await Task.sleep(for: .milliseconds(250))
                    let menus = NSApp.mainMenu!.items.compactMap(\.submenu)
                    for menu in menus { menu.update() }
                    let items = menus.flatMap(\.items)
                    precondition(items.filter { $0.keyEquivalent == "," }.count == 1, "Settings must appear once")
                    precondition(!items.contains { $0.action == #selector(NSWindow.toggleTabBar(_:)) || $0.action == #selector(NSWindow.toggleTabOverview(_:)) }, "Native window tab commands must be absent")
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
                    let shortcut = NSEvent.keyEvent(
                        with: .keyDown, location: .zero, modifierFlags: [.command, .control],
                        timestamp: ProcessInfo.processInfo.systemUptime,
                        windowNumber: window.windowNumber, context: nil,
                        characters: "s", charactersIgnoringModifiers: "s", isARepeat: false, keyCode: 1
                    )!
                    window.makeKey()
                    try? await Task.sleep(for: .milliseconds(250))
                    for menu in menus { menu.update() }
                    NSApp.sendEvent(shortcut)
                    try? await Task.sleep(for: .milliseconds(400))
                    precondition(open != snapshot().colorAt(x: 100, y: 200), "Menu shortcut must collapse sidebar")
                    NSApp.sendEvent(shortcut)
                    try? await Task.sleep(for: .milliseconds(400))
                    precondition(open == snapshot().colorAt(x: 100, y: 200), "Menu shortcut must reopen sidebar")
                    await store.shutdown()
                    try? FileManager.default.removeItem(at: Self.directory)
                    print("PASS: sidebar toolbar/menu shortcut, single Settings command, no native window tabs")
                    exit(0)
                }
        }
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unifiedCompact(showsTitle: false))
        .commands { WaveSearchCommands(store: store) }
        Settings { AppSettingsView().environmentObject(store) }
    }
}
