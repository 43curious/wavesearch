import SwiftUI
import WaveSearchKit

// Swift String equality folds canonical Unicode equivalents; catalog names are
// byte-exact. Keep their distinct menu/row identities without changing spelling.
private struct SelectsName: Identifiable {
    let name: String
    var id: Data { Data(name.utf8) }
    static func unique(_ names: [String]) -> [SelectsName] {
        var seen: Set<Data> = []
        return names.map { SelectsName(name: $0) }.filter { seen.insert($0.id).inserted }.sorted { $0.id.lexicographicallyPrecedes($1.id) }
    }
}

struct SelectsView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var player = PlayerController.shared
    @State private var tag = ""
    @State private var collection = ""
    @State private var savesRange = false

    private var tags: [SelectsName] { SelectsName.unique(store.selectsDocument.sources.flatMap(\.tags)) }
    private var collections: [SelectsName] { SelectsName.unique(store.selectsDocument.sources.flatMap { $0.collections.map(\.name) }) }
    private var canEdit: Bool { store.canUseLibrary && !store.isEditingSelects }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Tags, Collections & Favourites").font(.title2.bold())
                Spacer()
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            Text("Saved in your catalog. JSON export includes missing references and ranges; audio files stay in place.")
                .font(.callout).foregroundStyle(.secondary)
            HStack {
                Button("Import JSON…") { store.importSelects() }
                Button("Export JSON…") { store.exportSelects() }
                Menu("Browse") {
                    Button("Favourites") { browse(UInt32(WS_SELECTS_FAVOURITE), "") }
                    Section("Tags") {
                        ForEach(tags) { entry in Button(entry.name) { browse(UInt32(WS_SELECTS_TAG), entry.name) } }
                    }
                    Section("Collections") {
                        ForEach(collections) { entry in Button(entry.name) { browse(UInt32(WS_SELECTS_COLLECTION), entry.name) } }
                    }
                }
                Spacer()
                if store.isEditingSelects { ProgressView().controlSize(.small) }
            }
            .disabled(!canEdit)

            if let file = store.selectedFile {
                GroupBox("Selected: \(file.name)") {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            TextField("Tag", text: $tag).accessibilityLabel("New tag")
                            Button("Add Tag") { store.editSelects(file: file, kind: UInt32(WS_SELECTS_TAG), name: tag) }
                                .disabled(tag.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }
                        HStack {
                            TextField("Collection", text: $collection).accessibilityLabel("Collection name")
                            Toggle("Selected range", isOn: $savesRange)
                                .disabled(player.currentFile?.id != file.id || player.selection == nil || player.duration <= 0)
                            Button("Add to Collection") { addCollection(file) }
                                .disabled(collection.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || (savesRange && savedRange == nil))
                        }
                    }
                    .padding(6)
                }
                .disabled(!canEdit)
            }

            List(store.selectsDocument.sources) { source in
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Image(systemName: source.favourite ? "star.fill" : "waveform")
                            .foregroundStyle(source.favourite ? Color.orange : Color.secondary)
                        Text(URL(fileURLWithPath: source.path).lastPathComponent).fontWeight(.medium)
                        Spacer()
                        if source.file_id == nil {
                            Text("Unresolved").foregroundStyle(.secondary)
                            if let selected = store.selectedFile {
                                Button("Link to Selected Sound") { store.relinkSelects(source, to: selected) }
                                    .help("Use the selected sound for this reference and merge its annotations")
                            }
                        }
                    }
                    Text(source.path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    ForEach(source.tags.map { SelectsName(name: $0) }) { entry in
                        HStack {
                            Label(entry.name, systemImage: "tag")
                            Spacer()
                            if let file = selected(source) {
                                Button("Remove Tag") { store.editSelects(file: file, kind: UInt32(WS_SELECTS_TAG), name: entry.name, enabled: false) }
                            }
                        }
                    }
                    ForEach(source.collections, id: \.identity) { member in
                        HStack {
                            Label(member.name, systemImage: "folder")
                            if let start = member.start_ms, let end = member.end_ms {
                                Text(String(format: "%.3f–%.3f s", locale: Locale.current, Double(start) / 1000, Double(end) / 1000)).monospacedDigit()
                                if let file = selected(source) {
                                    Button("Use Range") { applyRange(member, file: file) }
                                        .disabled(player.isPreparing || player.currentFile?.id != file.id || player.duration <= 0)
                                }
                            }
                            Spacer()
                            if let file = selected(source) {
                                Button("Remove from Collection") { store.editSelects(file: file, kind: UInt32(WS_SELECTS_COLLECTION), name: member.name, range: member, enabled: false) }
                            }
                        }
                    }
                }
                .padding(.vertical, 5)
                .disabled(!canEdit)
            }
            Text("Browse a tag or collection to select its sounds. To edit a saved entry or use its range, select that sound in the results first. Unresolved entries can be linked to the selected indexed sound.")
                .font(.caption).foregroundStyle(.secondary)
            if let status = store.selectsStatus { Text(status).font(.callout).textSelection(.enabled) }
        }
        .padding(20)
        .frame(minWidth: 760, idealWidth: 840, minHeight: 540)
        .task { await store.refreshSelects() }
    }

    private func selected(_ source: SelectsSource) -> SoundFile? {
        guard let file = store.selectedFile, Int32(file.id) == source.file_id else { return nil }
        return file
    }

    private var savedRange: SelectsMembership? {
        guard let file = store.selectedFile, player.currentFile?.id == file.id,
              let range = player.selection, player.duration > 0 else { return nil }
        let start = (range.lowerBound * player.duration * 1000).rounded(.down)
        let end = (range.upperBound * player.duration * 1000).rounded(.up)
        guard start >= 0, end > start, end <= Double(Int32.max) else { return nil }
        return SelectsMembership(name: collection, start_ms: Int64(start), end_ms: Int64(end))
    }

    private func addCollection(_ file: SoundFile) {
        store.editSelects(file: file, kind: UInt32(WS_SELECTS_COLLECTION), name: collection, range: savesRange ? savedRange : nil)
    }

    private func applyRange(_ member: SelectsMembership, file: SoundFile) {
        guard player.currentFile?.id == file.id, !player.isPreparing, player.duration > 0,
              let start = member.start_ms, let end = member.end_ms else { return }
        player.setSelection(Double(start) / (player.duration * 1000)...Double(end) / (player.duration * 1000))
    }

    private func browse(_ kind: UInt32, _ name: String) {
        store.browseSelects(kind: kind, name: name)
        dismiss()
    }
}
