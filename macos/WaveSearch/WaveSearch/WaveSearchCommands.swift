import SwiftUI

struct WaveSearchCommands: Commands {
    @ObservedObject var store: AppStore

    var body: some Commands {
        CommandGroup(replacing: .newItem) {}
        // The Settings scene supplies the standard Settings command.
        CommandGroup(replacing: .sidebar) {
            Button(store.isSidebarVisible ? "Hide Sidebar" : "Show Sidebar") {
                store.isSidebarVisible.toggle()
            }
            .keyboardShortcut("s", modifiers: [.command, .control])
        }
    }
}
