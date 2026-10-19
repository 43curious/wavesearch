import AppKit
import Carbon
import Combine
import SwiftUI

nonisolated enum SearchShortcut: String, CaseIterable, Identifiable {
    case disabled
    case controlOptionSpace
    case controlOptionF
    case controlShiftSpace
    case commandShiftSpace

    var id: String { rawValue }
    var title: String {
        switch self {
        case .disabled: "Off"
        case .controlOptionSpace: "⌃⌥Space"
        case .controlOptionF: "⌃⌥F"
        case .controlShiftSpace: "⌃⇧Space"
        case .commandShiftSpace: "⌘⇧Space"
        }
    }

    var key: (code: UInt32, modifiers: UInt32)? {
        switch self {
        case .disabled: nil
        case .controlOptionSpace: (UInt32(kVK_Space), UInt32(controlKey | optionKey))
        case .controlOptionF: (UInt32(kVK_ANSI_F), UInt32(controlKey | optionKey))
        case .controlShiftSpace: (UInt32(kVK_Space), UInt32(controlKey | shiftKey))
        case .commandShiftSpace: (UInt32(kVK_Space), UInt32(cmdKey | shiftKey))
        }
    }
}

/// Registers only the chosen key combination; no event tap or input monitoring.
@MainActor
final class GlobalSearchShortcut: ObservableObject {
    static let shared = GlobalSearchShortcut()
    static let preferenceKey = "globalSearchShortcut"
    static let focusNotification = Notification.Name("WaveSearch.focusSearch")
    private static let signature: OSType = 0x57535348 // WSSH

    @Published private(set) var selection: SearchShortcut
    @Published private(set) var error: String?
    private let preferences: UserDefaults
    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private var onInvoke: (() -> Void)?

    init(preferences: UserDefaults = .standard) {
        self.preferences = preferences
        selection = SearchShortcut(rawValue: preferences.string(forKey: Self.preferenceKey) ?? "") ?? .disabled
    }

    func start(onInvoke: @escaping () -> Void) {
        self.onInvoke = onInvoke
        register()
    }

    func select(_ shortcut: SearchShortcut) {
        selection = shortcut
        preferences.set(shortcut.rawValue, forKey: Self.preferenceKey)
        register()
    }

    func stop() {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        hotKey = nil
        if let handler { RemoveEventHandler(handler) }
        handler = nil
        onInvoke = nil
    }

    private func register() {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        hotKey = nil
        error = nil
        guard let key = selection.key, onInvoke != nil else {
            if let handler { RemoveEventHandler(handler) }
            handler = nil
            return
        }
        if handler == nil {
            var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            let status = InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
                guard let event, let context else { return OSStatus(eventNotHandledErr) }
                var id = EventHotKeyID()
                let status = GetEventParameter(event, EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
                guard status == noErr, id.signature == 0x57535348, id.id == 1 else {
                    return OSStatus(eventNotHandledErr)
                }
                MainActor.assumeIsolated {
                    Unmanaged<GlobalSearchShortcut>.fromOpaque(context).takeUnretainedValue().onInvoke?()
                }
                return noErr
            }, 1, &eventType, Unmanaged.passUnretained(self).toOpaque(), &handler)
            guard status == noErr else {
                error = "Could not listen for the shortcut (\(status)). Try again."
                return
            }
        }
        let status = RegisterEventHotKey(key.code, key.modifiers,
            EventHotKeyID(signature: Self.signature, id: 1), GetApplicationEventTarget(), OptionBits(kEventHotKeyExclusive), &hotKey)
        if status != noErr {
            error = "\(selection.title) could not be registered (\(status)). It may be in use by another app. Choose another shortcut or retry."
        }
    }
}

/// Retains the scene's reopen action after its window closes.
struct SearchShortcutActivation: ViewModifier {
    @Environment(\.openWindow) private var openWindow
    var shortcut: GlobalSearchShortcut = .shared

    func body(content: Content) -> some View {
        content.onAppear {
            shortcut.start {
                openWindow(id: "main")
                NSApp.activate(ignoringOtherApps: true)
                Task { @MainActor in
                    await Task.yield()
                    NotificationCenter.default.post(name: GlobalSearchShortcut.focusNotification, object: nil)
                }
            }
        }
    }
}

struct SearchShortcutSettings: View {
    @ObservedObject private var shortcut = GlobalSearchShortcut.shared

    var body: some View {
        Section("Global search shortcut") {
            Picker("Show WaveSearch", selection: Binding(get: { shortcut.selection }, set: { shortcut.select($0) })) {
                ForEach(SearchShortcut.allCases) { Text($0.title).tag($0) }
            }
            Text("Bring WaveSearch forward and focus search from any app while WaveSearch is running.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let error = shortcut.error {
                Text(error).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                Button("Retry shortcut") { shortcut.select(shortcut.selection) }
            }
        }
    }
}
