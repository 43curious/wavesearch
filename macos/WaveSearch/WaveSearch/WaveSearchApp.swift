import SwiftUI
import WaveSearchKit

@main
struct WaveSearchApp: App {
    @StateObject private var store = AppStore()
    @NSApplicationDelegateAdaptor(AppLifecycleDelegate.self) private var lifecycle

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(store)
                .tint(AppTheme.accent)
                .appAppearance()
                .frame(minWidth: 900, minHeight: 600)
                .onAppear { lifecycle.store = store }
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
    }
}
