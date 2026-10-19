import SwiftUI
import WaveSearchKit

@main
struct WaveSearchApp: App {
    @StateObject private var store = AppStore()
    @NSApplicationDelegateAdaptor(AppLifecycleDelegate.self) private var lifecycle

    var body: some Scene {
        Window("WaveSearch", id: "main") {
            ContentView()
                .environmentObject(store)
                .tint(AppTheme.accent)
                .appAppearance()
                .frame(minWidth: 900, minHeight: 600)
                .onAppear { lifecycle.store = store }
                .modifier(SearchShortcutActivation())
        }
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unifiedCompact(showsTitle: false))
        .commands {
            WaveSearchCommands(store: store)
        }

        Settings {
            AppSettingsView()
                .environmentObject(store)
                .tint(AppTheme.accent)
                .appAppearance()
        }

        Window("Keyboard Shortcuts", id: "shortcuts") {
            KeyboardShortcutsView().tint(AppTheme.accent).appAppearance()
        }
        .windowResizability(.contentSize)
    }
}
