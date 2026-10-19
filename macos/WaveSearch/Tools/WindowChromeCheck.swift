import SwiftUI
import AppKit
import Carbon

// Run with: bash scripts/test-window-chrome.sh (requires a macOS desktop session).
@main
struct WindowChromeCheck: App {
    private static var ranChecks = false
    private static let shortcutSuite = "wavesearch-shortcut-check-\(UUID().uuidString)"
    private static let shortcutPreferences = UserDefaults(suiteName: shortcutSuite)!
    @StateObject private var shortcut = GlobalSearchShortcut(preferences: shortcutPreferences)
    @NSApplicationDelegateAdaptor(AppLifecycleDelegate.self) private var lifecycle
    private static let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("wavesearch-chrome-\(UUID().uuidString)")
    @StateObject private var store = AppStore(
        storageDirectory: directory,
        preferences: UserDefaults(suiteName: UUID().uuidString)!, startsRefinement: false
    )

    var body: some Scene {
        Window("WaveSearch", id: "main") {
            ContentView().environmentObject(store).frame(width: 1000, height: 680)
                .preferredColorScheme(.light)
                .modifier(SearchShortcutActivation(shortcut: shortcut))
                .onAppear {
                    guard !Self.ranChecks else { return }
                    Self.ranChecks = true
                    Task { @MainActor in
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
                        await checkGlobalShortcut(window: window)
                        await store.shutdown()
                        try? FileManager.default.removeItem(at: Self.directory)
                        print("PASS: sidebar toolbar/menu shortcut, single Settings command, no native window tabs")
                        exit(0)
                    }
                }
        }
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unifiedCompact(showsTitle: false))
        .commands { WaveSearchCommands(store: store) }
        Settings { AppSettingsView().environmentObject(store) }
    }

    @MainActor
    private func checkGlobalShortcut(window: NSWindow) async {
        precondition(shortcut.selection == .disabled)
        // Reserve the key first, exercising the native collision response.
        let key = SearchShortcut.controlOptionF.key!
        var reservation: EventHotKeyRef?
        precondition(RegisterEventHotKey(key.code, key.modifiers,
            EventHotKeyID(signature: 0x54455354, id: 2), GetApplicationEventTarget(),
            OptionBits(kEventHotKeyExclusive), &reservation) == noErr)
        shortcut.select(.controlOptionF)
        precondition(shortcut.error != nil, "A reserved shortcut must report a conflict")
        UnregisterEventHotKey(reservation!)
        shortcut.select(.controlOptionF)
        precondition(shortcut.error == nil)
        precondition(GlobalSearchShortcut(preferences: Self.shortcutPreferences).selection == .controlOptionF)

        // Deliver an actual Carbon hot-key event through the installed handler.
        // This checks routing/reopening, separately from physical key dispatch.
        func invoke() {
            var event: EventRef?
            precondition(CreateEvent(nil, OSType(kEventClassKeyboard), UInt32(kEventHotKeyPressed),
                0, 0, &event) == noErr)
            var id = EventHotKeyID(signature: 0x57535348, id: 1)
            precondition(SetEventParameter(event!, EventParamName(kEventParamDirectObject),
                EventParamType(typeEventHotKeyID), MemoryLayout<EventHotKeyID>.size, &id) == noErr)
            precondition(SendEventToEventTarget(event!, GetApplicationEventTarget()) == noErr)
            ReleaseEvent(event!)
        }
        // Scene restoration and field-editor focus arrive asynchronously.
        // Wait for the requested state instead of sampling at a fixed delay.
        func focusedSearchWindow() async -> NSWindow? {
            let deadline = ContinuousClock.now.advanced(by: .seconds(3))
            while ContinuousClock.now < deadline {
                if let window = NSApp.windows.first(where: { $0.identifier?.rawValue == "main" && $0.isVisible && $0.isKeyWindow }),
                   let editor = window.firstResponder as? NSTextView,
                   editor.string == "shortcut fixture" { return window }
                try? await Task.sleep(for: .milliseconds(20))
            }
            return nil
        }
        store.search("shortcut fixture")
        window.makeFirstResponder(nil)
        window.miniaturize(nil)
        invoke()
        let restored = await focusedSearchWindow()
        precondition(restored === window && !window.isMiniaturized, "Shortcut must restore search focus and preserve the query")
        window.performClose(nil)
        try? await Task.sleep(for: .milliseconds(250))
        invoke()
        let reopened = await focusedSearchWindow()
        precondition(reopened != nil, "Shortcut must reopen search with focus and the existing query")
        shortcut.select(.disabled)
        precondition(RegisterEventHotKey(key.code, key.modifiers,
            EventHotKeyID(signature: 0x54455354, id: 2), GetApplicationEventTarget(),
            OptionBits(kEventHotKeyExclusive), &reservation) == noErr, "Disabling must release the key")
        UnregisterEventHotKey(reservation!)
        shortcut.stop()
        Self.shortcutPreferences.removePersistentDomain(forName: Self.shortcutSuite)
        print("PASS: native shortcut conflict, persistence, focus, minimize/close/reopen, disable cleanup (injected Carbon events)")
    }
}
