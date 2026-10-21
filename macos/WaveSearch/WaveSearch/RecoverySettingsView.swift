import SwiftUI

struct RecoverySettingsView: View {
    @EnvironmentObject private var store: AppStore
    @State private var confirmingCacheDeletion = false

    var body: some View {
        Form {
            Section("Backup & recovery") {
                Text("Back up the index, library locations, and favourites. Original audio, installed models, and exported clips are stored separately.")
                    .foregroundStyle(.secondary)
                HStack {
                    Button("Create Backup…") { store.createBackup() }
                        .disabled(!store.canModifyLibraries)
                    Button("Restore Backup…") { store.restoreBackup() }
                        .disabled(!store.canRestoreBackup)
                    Button("Check Integrity") { store.checkIntegrity() }
                        .disabled(!store.canModifyLibraries)
                }
                if store.isLibraryChanging {
                    ProgressView().controlSize(.small)
                }
                if let status = store.recoveryStatus {
                    Text(status).textSelection(.enabled)
                }
                if let error = store.recoveryError {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red).textSelection(.enabled)
                }
                if !store.isReady {
                    Text(store.lastBackendError ?? String(localized: "The catalog is opening…"))
                        .foregroundStyle(.secondary)
                    if store.canRestoreBackup {
                        Text("Restore a backup to recover an index that cannot open. The original database and journals will be retained in Recovery.")
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section("Library locations") {
                if store.folders.isEmpty { Text("No libraries connected.").foregroundStyle(.secondary) }
                ForEach(store.folders) { folder in
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(folder.name)
                            Text(folder.path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                            if folder.isMissing {
                                Text("Folder unavailable").font(.caption).foregroundStyle(.red)
                            }
                        }
                        Spacer()
                        Button("Reconnect…") { store.reconnectFolder(folder) }
                            .disabled(!store.canModifyLibraries)
                    }
                }
            }

            Section("Storage") {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Waveform cache location")
                        Spacer()
                        Button("Show in Finder") { store.revealStorage(store.indexURL) }
                    }
                    Text(store.indexURL.path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    Text("Waveforms are cached inside the index database. Deleting the cache keeps your indexed sounds, favourites, and exports.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Button("Delete Waveform Cache…", role: .destructive) { confirmingCacheDeletion = true }
                    .disabled(!store.canModifyLibraries)
                if let usage = store.storageUsage {
                    storageRow(String(localized: "Index database"), bytes: usage.indexBytes, url: store.indexURL)
                    storageRow(String(localized: "Index journals"), bytes: usage.journalBytes, url: nil)
                    storageRow(String(localized: "Universal waveforms"), bytes: usage.universalBytes, url: nil)
                    storageRow(String(localized: "Detailed waveforms"), bytes: usage.detailedBytes, url: nil)
                    Text("Waveform cache is included in the index size. Detailed cache limit: \(formatBytes(usage.detailedBudgetBytes)).")
                        .font(.caption).foregroundStyle(.secondary)
                    storageRow(String(localized: "Exported clips"), bytes: usage.exportBytes, url: store.exportDirectory)
                    Text("Exports are persistent media that editing projects may reference.")
                        .font(.caption).foregroundStyle(.secondary)
                    storageRow(String(localized: "Recovery copies"), bytes: usage.recoveryBytes, url: store.recoveryDirectory)
                }
                if let error = store.storageError {
                    Text(error).foregroundStyle(.red)
                }
                HStack {
                    Button("Refresh Storage") { store.refreshStorage() }
                        .disabled(!store.canUseLibrary || store.isRefreshingStorage)
                    if store.isRefreshingStorage { ProgressView().controlSize(.small) }
                }
            }
        }
        .formStyle(.grouped)
        .padding(12)
        .task { store.refreshStorage() }
        .onChange(of: store.isReady) { _, ready in if ready { store.refreshStorage() } }
        .alert("Delete waveform cache?", isPresented: $confirmingCacheDeletion) {
            Button("Delete Cache", role: .destructive) { store.clearWaveformCache() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This deletes generated waveforms and loudness analysis. Waveforms will regenerate when previewed or during background refinement. Freed database space will be reused. Your audio files, index, favourites, and exported clips stay available.")
        }
    }

    private func storageRow(_ title: String, bytes: Int64, url: URL?) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(title)
                Spacer()
                Text(formatBytes(bytes)).foregroundStyle(.secondary).monospacedDigit()
                if let url {
                    Button { store.revealStorage(url) } label: { Image(systemName: "folder") }
                        .help("Show \(title.lowercased()) in Finder")
                        .accessibilityLabel("Show \(title.lowercased()) in Finder")
                }
            }
            if let url {
                Text(url.path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
        }
    }

    private func formatBytes(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
