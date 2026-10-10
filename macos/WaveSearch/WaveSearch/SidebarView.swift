import SwiftUI

struct SidebarView: View {
    @EnvironmentObject var store: AppStore
    // Local @State owns the selection — never write directly into @Published from List
    @State private var selection: Int? = nil

    var body: some View {
        List(selection: $selection) {
            Section {
                Label("All Libraries", systemImage: "music.note.list")
                    .tag(Optional<Int>.none)
                    .listRowSeparator(.hidden)
            }
            Section("Libraries") {
                ForEach(store.folders) { folder in
                    FolderRow(folder: folder)
                        .tag(Optional(folder.id))
                        .contextMenu {
                            LibraryFolderActions(folder: folder)
                        }
                }
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .background(AppTheme.chrome)
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 0) {
                Divider()
                Button { store.addFolder() } label: {
                    Label("Add Library", systemImage: "plus")
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!store.canModifyLibraries)
                .help("Add a sound library folder")

                if let lastBackendError = store.lastBackendError {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Text(lastBackendError)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer()
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 10)
                }
            }
            .background(AppTheme.chrome)
        }
        .frame(minWidth: 200)
        // Sync local state → store AFTER render, not during
        .onChange(of: selection) { _, newValue in
            guard store.selectedFolderId != newValue else { return }
            store.selectedFolderId = newValue
            store.search(store.query)
        }
        // Keep local state in sync if store changes it externally
        .onAppear { selection = store.selectedFolderId }
        .onChange(of: store.selectedFolderId) { _, newValue in
            selection = newValue
        }
    }
}

struct LibraryTabsView: View {
    @EnvironmentObject private var store: AppStore

    var body: some View {
        HStack(spacing: 8) {
            ScrollViewReader { proxy in
                ScrollView(.horizontal) {
                    HStack(spacing: 4) {
                        tab("All Libraries", systemImage: "music.note.list", folderID: nil)
                            .id("all")

                        ForEach(store.folders) { folder in
                            tab(folder.name,
                                systemImage: folder.isMissing ? "externaldrive.badge.xmark" : "folder.fill",
                                folderID: folder.id, isMissing: folder.isMissing)
                                .id(String(folder.id))
                                .help("\(folder.path) · \(folder.isMissing ? "Missing drive" : "\(folder.fileCount) files")")
                                .contextMenu { LibraryFolderActions(folder: folder) }
                        }
                    }
                }
                .scrollIndicators(.hidden)
                .onAppear {
                    proxy.scrollTo(selectedTabID)
                }
                .onChange(of: store.selectedFolderId) { _, _ in
                    proxy.scrollTo(selectedTabID)
                }
            }

            Button { store.addFolder() } label: {
                Image(systemName: "plus")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!store.canModifyLibraries)
            .accessibilityLabel("Add Library")
            .help("Add a sound library folder")
        }
    }

    private var selectedTabID: String {
        store.selectedFolderId.map(String.init) ?? "all"
    }

    private func tab(_ title: String, systemImage: String, folderID: Int?, isMissing: Bool = false) -> some View {
        let isSelected = store.selectedFolderId == folderID
        return Button {
            store.selectedFolderId = folderID
            store.search(store.query)
        } label: {
            Label(title, systemImage: systemImage)
                .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                .lineLimit(1)
                .padding(.horizontal, 12)
                .frame(height: 28)
                .foregroundStyle(isMissing ? Color.red : (isSelected ? AppTheme.accent : Color.primary))
                .background(isSelected ? AppTheme.accent.opacity(0.16) : Color.clear,
                            in: RoundedRectangle(cornerRadius: 6))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityValue(isMissing ? "Missing drive" : "")
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
        .help(title)
    }
}

private struct LibraryFolderActions: View {
    @EnvironmentObject private var store: AppStore
    let folder: LibraryFolder

    var body: some View {
        Button("Re-index") { store.indexFolder(folder) }
            .disabled(folder.isMissing || !store.canModifyLibraries)
        Button("Deep Re-index") { store.indexFolder(folder, deep: true) }
            .disabled(folder.isMissing || !store.canModifyLibraries)
        Button("Reconnect Library…") { store.reconnectFolder(folder) }
            .disabled(!store.canModifyLibraries)
        Divider()
        Button("Remove", role: .destructive) { store.removeFolder(folder) }
            .disabled(!store.canModifyLibraries)
    }
}

struct FolderRow: View {
    let folder: LibraryFolder

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: folder.isMissing ? "externaldrive.badge.xmark" : "folder.fill")
                .foregroundStyle(folder.isMissing ? Color.red : AppTheme.accent)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(folder.name)
                    .lineLimit(1)
                if folder.isMissing {
                    Text("Missing drive")
                        .font(.caption2)
                        .foregroundStyle(.red)
                } else if folder.fileCount > 0 {
                    Text("\(folder.fileCount) files")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 2)
        .opacity(folder.isMissing ? 0.6 : 1)
    }
}
