import SwiftUI

struct WaveSearchCommands: Commands {
    @ObservedObject var store: AppStore
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .newItem) {}
        // The Settings scene supplies the standard Settings command.
        CommandGroup(replacing: .sidebar) {
            Button(store.isSidebarVisible ? "Hide Sidebar" : "Show Sidebar") {
                store.isSidebarVisible.toggle()
            }
            .keyboardShortcut("s", modifiers: [.command, .control])
        }
        CommandMenu("Library") {
            Button("Tags, Collections & Favourites…") { store.showsSelects = true }
                .disabled(!store.canUseLibrary)
            Button("Browse Favourites") { store.browseSelects(kind: 0) }
                .disabled(!store.canUseLibrary)
            Divider()
            Button("Add Library…") { store.addFolder() }
                .keyboardShortcut("o", modifiers: [.command, .shift])
                .disabled(!store.canModifyLibraries)
            if let folder = store.folders.first(where: { $0.id == store.selectedFolderId }) {
                Menu(folder.name) {
                    LibraryFolderActions(folder: folder).environmentObject(store)
                }
            }
        }
        CommandGroup(after: .help) {
            Button("Keyboard Shortcuts…") { openWindow(id: "shortcuts") }
                .keyboardShortcut("?", modifiers: .command)
        }
    }
}

struct KeyboardShortcutsView: View {
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Keyboard Shortcuts").font(.title2.bold())
            Text("Preview keys work while results have focus. Press Esc in search to focus results; press Esc again or ⌘K to return to search. Tab and Shift–Tab move between controls; arrows adjust the focused control.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Grid(alignment: .leading, horizontalSpacing: 32, verticalSpacing: 9) {
                shortcut("⌘K or /", "Focus search")
                shortcut("↓ / ↑ or j / k", "Next / previous sound")
                shortcut("gg or u / Shift–G", "First / last sound")
                shortcut("Return", "Play from the in point")
                shortcut("Space", "Play / pause")
                shortcut("h / l", "Shuttle backward / forward; repeat to accelerate")
                shortcut("i / o", "Set in / out point at the playhead")
                shortcut("b", "Reveal selected sound in Finder")
                shortcut("⌘⇧C", "Copy sound or range for your editor")
                shortcut("⌃⌘S", "Show / hide sidebar")
                shortcut("⌘⇧O", "Add a library")
                shortcut("⌘,", "Open Settings")
                shortcut("? or ⌘?", "Show keyboard shortcuts")
            }
            Text("Use the Preview position slider to seek, then In and Out to mark a range. Copy for Editor follows your import preference: keep the full original file in place, or copy to Exports and trim selected ranges. Paste into an editor that accepts file URLs.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Close") { dismissWindow(id: "shortcuts") }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(24)
        .frame(width: 560)
    }

    private func shortcut(_ keys: String, _ action: String) -> some View {
        GridRow {
            Text(keys).monospaced()
            Text(action)
        }
        .accessibilityElement(children: .combine)
    }
}
