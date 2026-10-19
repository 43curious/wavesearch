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
        preferences: UserDefaults(suiteName: UUID().uuidString)!, startsRefinement: false, watchesLibraries: false
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
                        try await checkAuditionKeys(window: window)
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
        Window("Keyboard Shortcuts", id: "shortcuts") {
            KeyboardShortcutsView()
        }
        .windowResizability(.contentSize)
    }

    @MainActor
    private func checkAuditionKeys(window: NSWindow) async throws {
        let root = Self.directory.appendingPathComponent("audio")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        // Silent mono PCM16 at 8 kHz, one second per file. No user library.
        var bytes = Data([82,73,70,70,164,62,0,0,87,65,86,69,102,109,116,32,
                          16,0,0,0,1,0,1,0,64,31,0,0,128,62,0,0,2,0,16,0,
                          100,97,116,97,128,62,0,0])
        bytes.append(Data(repeating: 0, count: 16000))
        try bytes.write(to: root.appendingPathComponent("first.wav"))
        try bytes.write(to: root.appendingPathComponent("second.wav"))
        store.addFolder(at: root)
        await store.waitForLibraryChange()
        await store.waitForIndexing()
        store.selectedFolderId = store.folders.first!.id
        store.search("")
        await store.waitForSearch()
        precondition(store.results.count == 2)
        // The shortcut test may have recreated the main window.
        let main = NSApp.windows.first { $0.identifier?.rawValue == "main" && $0.isVisible } ?? window
        main.makeKeyAndOrderFront(nil)
        func key(_ code: UInt16, _ text: String, modifiers: NSEvent.ModifierFlags = []) async {
            let flags: NSEvent.ModifierFlags = (123...126).contains(code) ? modifiers.union([.function, .numericPad]) : modifiers
            NSApp.sendEvent(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags,
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: main.windowNumber,
                context: nil, characters: text, charactersIgnoringModifiers: text,
                isARepeat: false, keyCode: code)!)
            try? await Task.sleep(for: .milliseconds(50))
        }
        await key(53, "\u{1b}") // Leave the search field before preview commands.
        store.selectFirstResult()
        await key(125, "\u{f701}")
        precondition(store.selectedResultIndex == 1, "Down arrow did not select the next sound")
        await key(126, "\u{f700}")
        precondition(store.selectedResultIndex == 0, "Up arrow did not select the previous sound")
        let player = PlayerController.shared
        player.stopPlayback()
        player.seek(to: 0.2)
        await key(34, "i")
        player.seek(to: 0.6)
        await key(31, "o")
        precondition(player.selection == 0.2...0.6, "Keyboard marks did not reach the waveform/player range")
        let elements = accessibilityElements(main)
        precondition(elements.contains { $0.accessibilityLabel() == "Search sounds" }, "Search needs a stable accessible label")
        let results = elements.first { $0.accessibilityIdentifier() == "sound-results" }!
        precondition(!(results.accessibilitySelectedRows() ?? results.accessibilitySelectedChildren() ?? []).isEmpty,
                     "Native results must expose their selected row")
        let row = elements.first { $0.accessibilityLabel() == store.selectedFile!.displayName }!
        precondition(row.accessibilityCustomActions()?.contains { $0.name == "Play Preview" } == true,
                     "Result actions must be available to VoiceOver")
        let waveform = elements.first { $0.accessibilityLabel() == "Waveform" }!
        precondition((waveform.accessibilityValue() as? String)?.contains("In 0:00.20, out 0:00.60") == true,
                     "Waveform must expose the actual shared range")
        let slider = elements.first { $0.accessibilityLabel() == "Preview position" && $0.accessibilityRole() == .slider }!
        precondition(slider.isAccessibilityEnabled())
        let selectedID = store.selectedFile?.id
        slider.setAccessibilityFocused(true)
        try await Task.sleep(for: .milliseconds(100))
        let beforeSeek = player.progress
        await key(124, "\u{f703}")
        precondition(player.progress > beforeSeek && store.selectedFile?.id == selectedID,
                     "A focused slider must seek instead of navigating results")
        let out = accessibilityElements(main).first { $0.accessibilityLabel() == "Set out point" }!
        precondition(out.accessibilityPerformPress(), "VoiceOver must be able to set an out point")
        precondition(player.selection?.upperBound == player.progress)
        player.setSelection(0.2...0.6)
        // Re-enter the results focus scope before bare audition commands.
        NotificationCenter.default.post(name: GlobalSearchShortcut.focusNotification, object: nil)
        try await Task.sleep(for: .milliseconds(100))
        await key(53, "\u{1b}")
        await key(36, "\r")
        precondition(player.isPlaying && player.progress >= 0.2 && player.progress < 0.6,
                     "Return failed: playing=\(player.isPlaying) preparing=\(player.isPreparing) progress=\(player.progress) duration=\(player.duration) source=\(player.currentFile?.name ?? "none")")
        await key(49, " ")
        precondition(!player.isPlaying)
        await key(44, "?", modifiers: .shift)
        let help = NSApp.windows.first { $0.identifier?.rawValue == "shortcuts" && $0.isVisible }
        precondition(help != nil, "Question mark must open shortcut help from results")
        precondition(accessibilityElements(help!).contains { $0.accessibilityLabel() == "Close" || $0.accessibilityTitle() == "Close" })
        help?.performClose(nil)
        main.makeKeyAndOrderFront(nil)
        try await Task.sleep(for: .milliseconds(100))
        let helpMenu = NSApp.mainMenu!.items.compactMap(\.submenu).first { $0.items.contains { $0.title == "Keyboard Shortcuts…" } }!
        helpMenu.performActionForItem(at: helpMenu.items.firstIndex { $0.title == "Keyboard Shortcuts…" }!)
        try await Task.sleep(for: .milliseconds(100))
        let reopenedHelp = NSApp.windows.first { $0.identifier?.rawValue == "shortcuts" && $0.isVisible }
        precondition(reopenedHelp != nil, "Help menu must reopen shortcut help")
        reopenedHelp?.performClose(nil)
        main.makeKeyAndOrderFront(nil)
        NotificationCenter.default.post(name: GlobalSearchShortcut.focusNotification, object: nil)
        try await Task.sleep(for: .milliseconds(100))
        precondition(main.firstResponder is NSTextView)
        player.setSelection(nil)
        await key(34, "i")
        await key(31, "o")
        precondition(player.selection == nil, "Preview commands intercepted search-field editing")
        precondition(main.firstResponder is NSTextView, "Text input must retain focus")
        print("PASS: native result accessibility/actions, waveform range, slider focus and shortcut help")
        print("PASS: native arrow navigation, i/o range, Return, Space and text-input focus")
    }

    private func accessibilityElements(_ root: any NSAccessibilityProtocol) -> [any NSAccessibilityProtocol] {
        var elements: [any NSAccessibilityProtocol] = []
        var pending = [root]
        var visited: Set<ObjectIdentifier> = []
        while let element = pending.popLast() {
            guard visited.insert(ObjectIdentifier(element)).inserted else { continue }
            elements.append(element)
            pending.append(contentsOf: (element.accessibilityChildren() ?? []).compactMap { $0 as? any NSAccessibilityProtocol })
        }
        return elements
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
