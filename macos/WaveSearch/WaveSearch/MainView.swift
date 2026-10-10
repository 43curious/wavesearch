import SwiftUI
import AppKit

struct MainView: View {
    @EnvironmentObject private var store: AppStore
    @State private var query: String = ""
    @FocusState private var searchFocused: Bool
    @State private var keyMonitor: Any?
    @State private var mouseMonitor: Any?
    @State private var lastGPress: Date?

    var body: some View {
        VStack(spacing: 0) {
            SearchHeader(query: $query, searchFocused: $searchFocused)

            Divider()

            // Show overview only when "All Libraries" is selected and no search query.
            // When a specific library is selected (even with empty query), show its sounds.
            if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && store.selectedFolderId == nil && !store.isExampleSearch {
                LibraryOverviewView()
            } else {
                SearchWorkspaceView()
            }
        }
        .background(AppTheme.panel)
        .animation(.spring(response: 0.26, dampingFraction: 0.92), value: store.selectedFile?.id)
        .animation(.easeOut(duration: 0.16), value: store.results.count)
        .onAppear {
            query = store.query
            searchFocused = true
            installKeyboardMonitor()
            installMouseMonitor()
            // If a folder is already selected, trigger a browse
            if store.selectedFolderId != nil && store.query.isEmpty {
                store.search("")
            }
        }
        .onDisappear {
            removeKeyboardMonitor()
            removeMouseMonitor()
        }
        .onChange(of: query) { _, newValue in
            if !store.isExampleSearch { store.search(newValue) }
        }
        .onChange(of: store.query) { _, newValue in
            if newValue != query {
                query = newValue
            }
        }
    }

    private func installKeyboardMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

            if modifiers == .command, event.keyCode == 40 { // ⌘K
                focusSearch()
                return nil
            }

            if searchFocused || isTextInputFocused() {
                if event.keyCode == 53 { // Esc
                    searchFocused = false
                    event.window?.makeFirstResponder(nil)
                    return nil
                }
                return event
            }

            if modifiers == .shift, event.keyCode == 5 { // G
                store.selectLastResult()
                return nil
            }

            guard modifiers.isEmpty else { return event }

            switch event.keyCode {
            case 44: // /
                focusSearch()
                return nil
            case 53: // Esc
                searchFocused = false
                event.window?.makeFirstResponder(nil)
                return nil
            case 49: // Space
                PlayerController.shared.togglePlayPause()
                return nil
            case 36, 76: // Return / Enter
                store.playSelectedResult()
                return nil
            case 38: // j
                store.selectNextResult()
                return nil
            case 40: // k
                store.selectPreviousResult()
                return nil
            case 5: // g, gg → first result
                if let lastGPress, Date().timeIntervalSince(lastGPress) < 0.45 {
                    store.selectFirstResult()
                    self.lastGPress = nil
                } else {
                    lastGPress = Date()
                }
                return nil
            case 32: // u, alternative first result
                store.selectFirstResult()
                return nil
            case 4: // h
                PlayerController.shared.stepBackward()
                return nil
            case 37: // l
                PlayerController.shared.stepForward()
                return nil
            case 11: // b, reveal in Finder
                store.revealSelectedResult()
                return nil
            default:
                return event
            }
        }
    }

    private func focusSearch() {
        searchFocused = true
    }

    private func removeKeyboardMonitor() {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
    }

    private func installMouseMonitor() {
        guard mouseMonitor == nil else { return }
        mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { event in
            guard let window = event.window,
                  let contentView = window.contentView
            else { return event }

            let point = contentView.convert(event.locationInWindow, from: nil)
            let hitView = contentView.hitTest(point)
            if !isTextInputView(hitView) {
                searchFocused = false
                window.makeFirstResponder(nil)
            }
            return event
        }
    }

    private func removeMouseMonitor() {
        if let mouseMonitor {
            NSEvent.removeMonitor(mouseMonitor)
            self.mouseMonitor = nil
        }
    }

    private func isTextInputFocused() -> Bool {
        guard let responder = NSApp.keyWindow?.firstResponder else { return false }
        return responder is NSTextView || responder is NSTextField
    }

    private func isTextInputView(_ view: NSView?) -> Bool {
        var currentView = view
        while let current = currentView {
            if current is NSTextField || current is NSTextView {
                return true
            }
            currentView = current.superview
        }
        return false
    }
}

private struct SearchHeader: View {
    @EnvironmentObject private var store: AppStore
    @Binding var query: String
    let searchFocused: FocusState<Bool>.Binding
    @State private var showsIndexingPopover = false

    private var placeholder: String {
        if store.isExampleSearch { return "Similar to \(store.exampleSourceName)" }
        if let id = store.selectedFolderId,
           let folder = store.folders.first(where: { $0.id == id }) {
            return "Filter \(folder.name)…"
        }
        return "Search all libraries…"
    }

    var body: some View {
        HStack(spacing: 12) {
            HStack(spacing: 9) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)

                TextField(placeholder, text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13, weight: .medium))
                    .focused(searchFocused)

                if store.isSearching {
                    InlineSpinner(size: 12, lineWidth: 1.5)
                }

                if !query.isEmpty {
                    Button {
                        query = ""
                        searchFocused.wrappedValue = true
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .frame(maxWidth: 560)
            .background(AppTheme.panelSunken, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(AppTheme.hairline, lineWidth: 1)
            )

            Text(store.searchSummary)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)

            Spacer()

            if store.isIndexing || !store.indexingProgress.isEmpty {
                Button {
                    showsIndexingPopover.toggle()
                } label: {
                    HStack(spacing: 6) {
                        if store.isIndexing {
                            InlineSpinner(size: 11, lineWidth: 1.5)
                        } else if store.isRefinementPaused {
                            Image(systemName: "pause.circle.fill")
                                .font(.system(size: 11))
                                .foregroundStyle(.orange)
                        } else if store.refinementSnapshot.blocker != nil,
                                  store.refinementSnapshot.blocker != .fastOnly {
                            Image(systemName: "clock.fill")
                                .font(.system(size: 11))
                                .foregroundStyle(.orange)
                        } else {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 11))
                                .foregroundStyle(.green)
                        }
                        Text(store.indexingPhase.isEmpty ? "Indexing" : store.indexingPhase)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        Image(systemName: "chevron.down")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(AppTheme.panelRaised, in: Capsule())
                    .overlay(Capsule().strokeBorder(AppTheme.hairline, lineWidth: 1))
                }
                .buttonStyle(.plain)
                .popover(isPresented: $showsIndexingPopover, arrowEdge: .bottom) {
                    IndexingProgressPopover()
                        .environmentObject(store)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(AppTheme.chrome)
    }
}

private struct IndexingProgressPopover: View {
    @EnvironmentObject private var store: AppStore

    private var isScanning: Bool { store.isMetadataScanning }
    private var modeBinding: Binding<RefinementMode> {
        Binding(get: { store.refinementMode }, set: { store.setRefinementMode($0) })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 9) {
                if store.isIndexing {
                    InlineSpinner(size: 15, lineWidth: 2)
                } else if store.isRefinementPaused {
                    Image(systemName: "pause.circle.fill")
                        .foregroundStyle(.orange)
                } else if store.refinementSnapshot.blocker != nil,
                          store.refinementSnapshot.blocker != .fastOnly {
                    Image(systemName: "clock.fill")
                        .foregroundStyle(.orange)
                } else {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(store.indexingPhase.isEmpty ? "Indexing" : store.indexingPhase)
                        .font(.system(size: 13, weight: .semibold))
                    Text(store.indexingProgress)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer()
            }

            if !isScanning {
                Picker("Refinement", selection: modeBinding) {
                    ForEach(RefinementMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                Text(store.refinementMode.summary)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if store.isIndexing {
                if isScanning, store.indexingExpectedCount > 0 {
                    ProgressView(
                        value: min(Double(store.indexingDiscoveredCount), Double(store.indexingExpectedCount)),
                        total: Double(store.indexingExpectedCount)
                    )
                } else {
                    ProgressView()
                        .progressViewStyle(.linear)
                }
            }

            if !isScanning {
                VStack(alignment: .leading, spacing: 7) {
                    Label("All filenames and metadata are already searchable", systemImage: "bolt.fill")
                        .foregroundStyle(AppTheme.accent)
                    HStack {
                        Text("Waveforms")
                        Spacer()
                        Text("\(store.waveformUniversalCount.formatted()) ready · \(store.waveformPendingCount.formatted()) pending")
                    }
                    HStack {
                        Text("Acoustic")
                        Spacer()
                        Text("\(store.acousticRefinedCount.formatted()) ready · \(store.acousticPendingCount.formatted()) pending · \(store.acousticFailedCount.formatted()) skipped")
                    }
                    HStack {
                        Text("Semantic")
                        Spacer()
                        Text(store.refinementMode == .fastOnly
                            ? "Disabled by Fast only mode"
                            : store.semanticAvailable
                                ? "\(store.semanticRefinedCount.formatted()) ready · \(store.semanticPendingCount.formatted()) pending · \(store.semanticFailedCount.formatted()) skipped"
                                : store.refinementSnapshot.semanticConfigured
                                    ? "Local model will load when policy allows"
                                    : "Unavailable — install the optional CLAP model")
                    }
                    .foregroundStyle(.secondary)
                }
                .font(.system(size: 11))
            }

            if store.indexingDiscoveredCount > 0 {
                HStack {
                    Label("\(store.indexingDiscoveredCount.formatted()) files discovered", systemImage: "doc.on.doc")
                    Spacer()
                    if store.indexingExpectedCount > 0, isScanning {
                        Text("of about \(store.indexingExpectedCount.formatted())")
                    }
                }
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            }

            if let started = store.indexingStartedAt {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    let elapsed = max(0, context.date.timeIntervalSince(started))
                    HStack {
                        Label("Elapsed \(compactDuration(elapsed))", systemImage: "clock")
                        Spacer()
                        if isScanning,
                           store.indexingExpectedCount > store.indexingDiscoveredCount,
                           store.indexingDiscoveredCount > 0,
                           elapsed > 1 {
                            let remaining = elapsed * Double(store.indexingExpectedCount - store.indexingDiscoveredCount) / Double(store.indexingDiscoveredCount)
                            Text("About \(compactDuration(remaining)) remaining")
                        }
                    }
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                }
            }

            if isScanning || store.refinementMode != .fastOnly || store.isRefinementPaused {
                Divider()
                HStack {
                    Text(isScanning
                        ? "The previous index remains available during the scan."
                        : "Foreground playback, search, and selected analysis always take priority.")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                    Spacer()
                    if isScanning {
                        Button("Cancel") { store.cancelIndexing() }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                    } else if store.isRefinementPaused {
                        Button("Resume") { store.resumeBackgroundRefinement() }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                    } else if store.refinementMode != .fastOnly {
                        Button("Pause") { store.pauseBackgroundRefinement() }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                    }
                }
            }
        }
        .padding(16)
        .frame(width: 340)
    }
}

private func compactDuration(_ seconds: TimeInterval) -> String {
    let total = max(0, Int(seconds.rounded()))
    if total < 60 { return "\(total)s" }
    let minutes = total / 60
    if minutes < 60 { return "\(minutes)m \(total % 60)s" }
    return "\(minutes / 60)h \(minutes % 60)m"
}

struct InlineSpinner: View {
    let size: CGFloat
    let lineWidth: CGFloat
    @State private var spinning = false

    var body: some View {
        Circle()
            .trim(from: 0.18, to: 0.88)
            .stroke(AppTheme.accent, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
            .frame(width: size, height: size)
            .rotationEffect(.degrees(spinning ? 360 : 0))
            .animation(.linear(duration: 0.8).repeatForever(autoreverses: false), value: spinning)
            .onAppear { spinning = true }
    }
}

private struct KeyboardHint: View {
    let key: String
    let label: String

    init(_ key: String, _ label: String) {
        self.key = key
        self.label = label
    }

    var body: some View {
        HStack(spacing: 4) {
            Text(key)
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(Color(nsColor: .separatorColor).opacity(0.22), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
            Text(label)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
        }
    }
}

private struct SearchWorkspaceView: View {
    @EnvironmentObject private var store: AppStore

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 0) {
                ResultsToolbar()
                Divider()
                ResultsTableHeader()
                Divider()
                ResultsList()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Group {
                if let file = store.selectedFile {
                    Divider()
                    PlayerPanel(file: file)
                } else {
                    Divider()
                    PreviewPlaceholder()
                }
            }
            .frame(maxWidth: .infinity)
        }
    }
}

private struct ResultsToolbar: View {
    @EnvironmentObject private var store: AppStore

    private var label: String {
        if store.isExampleSearch { return "Acoustic Matches" }
        return store.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Library" : "Results"
    }

    var body: some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)

            if !store.results.isEmpty {
                Text("\(store.results.count)")
                    .font(.system(size: 11, weight: .semibold))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(AppTheme.accent.opacity(0.14), in: Capsule())
                    .foregroundStyle(AppTheme.accent)
            }

            Spacer()

            Button {
                store.chooseSearchExample()
            } label: {
                Label("Find Similar", systemImage: "waveform.badge.magnifyingglass")
                    .font(.system(size: 11, weight: .medium))
            }
            .buttonStyle(.borderless)

            HStack(spacing: 10) {
                KeyboardHint("⌘K", "Search")
                KeyboardHint("j/k", "Nav")
                KeyboardHint("I/O", "Marks")
                KeyboardHint("⏎", "Play")
            }

            Text(store.searchSummary)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(AppTheme.panelRaised)
    }
}

private struct ResultsTableHeader: View {
    var body: some View {
        HStack(spacing: 12) {
            Text("Name")
                .frame(maxWidth: .infinity, alignment: .leading)
            Text("Duration")
                .frame(width: 64, alignment: .trailing)
            Text("Bitrate / Sample Rate")
                .frame(width: 126, alignment: .trailing)
                .help("Bit depth or encoded bitrate / sample rate in kHz")
            Text("Channels")
                .frame(width: 64, alignment: .trailing)
            Text("Library location")
                .frame(width: 170, alignment: .leading)
        }
        .font(.system(size: 10, weight: .semibold))
        .foregroundStyle(.secondary)
        .textCase(.uppercase)
        .padding(.horizontal, 16)
        .frame(height: 28)
        .background(AppTheme.chrome)
    }
}

struct ResultsList: View {
    @EnvironmentObject private var store: AppStore

    var body: some View {
        Group {
            if store.results.isEmpty {
                ContentUnavailableView.search(text: store.query)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(store.results) { file in
                                VStack(spacing: 0) {
                                    ResultRow(file: file, isSelected: store.selectedFile?.id == file.id)
                                        .id(file.id)
                                        .onTapGesture(count: 1) {
                                            store.selectFile(file)
                                        }
                                        .onTapGesture(count: 2) {
                                            store.selectFile(file)
                                            PlayerController.shared.playFromSelectionStart()
                                        }
                                        .onDrag {
                                            itemProviderForOriginalFile(file)
                                        }
                                        .contextMenu {
                                            Button("Find Similar Sounds") { store.searchByExample(file) }
                                            Button(store.isFavourite(file) ? "Remove from Favourites" : "Add to Favourites") {
                                                store.toggleFavourite(file)
                                            }
                                            Button("Reveal in Finder") { NSWorkspace.shared.selectFile(file.path, inFileViewerRootedAtPath: "") }
                                        }
                                    Divider()
                                        .padding(.leading, 44)
                                }
                            }
                            if store.canBrowseMore {
                                Button("Load More") { store.loadMore() }
                                    .padding()
                                    .disabled(store.isSearching)
                            }
                        }
                    }
                    .background(Color.clear)
                    .onChange(of: store.selectedFile?.id) { _, selectedId in
                        guard let selectedId else { return }
                        withAnimation(.easeOut(duration: 0.12)) {
                            proxy.scrollTo(selectedId, anchor: .center)
                        }
                    }
                }
            }
        }
    }
}

private struct ResultRow: View {
    let file: SoundFile
    let isSelected: Bool
    @EnvironmentObject private var store: AppStore
    @ObservedObject private var metadataStore = AudioMetadataStore.shared

    private var metadata: AudioFileMetadata? {
        metadataStore.metadata(for: file)
    }

    var body: some View {
        HStack(spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "waveform.path.ecg.rectangle")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(isSelected ? AppTheme.accent : .secondary)
                    .frame(width: 20)

                Text(file.displayName)
                    .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                if store.isFavourite(file) {
                    Image(systemName: "star.fill")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.yellow)
                }

                if file.acousticGroupId != 0 {
                    Text("family")
                        .font(.system(size: 9, weight: .bold))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(Color.orange.opacity(0.16), in: Capsule())
                        .foregroundStyle(.orange)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text(file.durationMs > 0 ? resultDurationString(file.durationMs) : "—")
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 64, alignment: .trailing)

            Text(metadata?.resolutionText ?? "…")
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 126, alignment: .trailing)

            Text(metadata?.channelText ?? "…")
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 64, alignment: .trailing)

            Text(store.libraryLocation(for: file))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(width: 170, alignment: .leading)
                .help(file.path)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 7)
        .background(isSelected ? AppTheme.accent.opacity(0.16) : Color.clear)
        .contentShape(Rectangle())
        .task(id: file) {
            metadataStore.load(file)
        }
    }
}

private func resultDurationString(_ durationMs: Int) -> String {
    let totalSeconds = max(durationMs, 0) / 1000
    let minutes = totalSeconds / 60
    let seconds = totalSeconds % 60
    return String(format: "%d:%02d", minutes, seconds)
}

private struct LibraryOverviewView: View {
    @EnvironmentObject private var store: AppStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack(spacing: 14) {
                    OverviewCard(
                        title: "Indexed Sounds",
                        value: "\(store.totalIndexedFiles)",
                        detail: "Ready for instant prefix search",
                        systemImage: "bolt.fill"
                    )
                    OverviewCard(
                        title: "Libraries",
                        value: "\(store.folders.count)",
                        detail: "Keep source drives mounted for smooth access",
                        systemImage: "externaldrive.fill.badge.checkmark"
                    )
                }

                Text("Libraries")
                    .font(.system(size: 18, weight: .semibold))

                if store.folders.isEmpty {
                    ContentUnavailableView(
                        "Add your first library",
                        systemImage: "folder.badge.plus",
                        description: Text("Index a folder to start searching, previewing, and dragging clips into your editor.")
                    )
                    .frame(maxWidth: .infinity, minHeight: 280)
                    .background(AppTheme.panelRaised, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
                } else {
                    LazyVStack(spacing: 12) {
                        ForEach(store.folders) { folder in
                            HStack(spacing: 14) {
                                Image(systemName: folder.isMissing ? "externaldrive.badge.xmark" : "folder.fill")
                                    .font(.system(size: 18, weight: .semibold))
                                    .foregroundStyle(folder.isMissing ? .red : AppTheme.accent)
                                    .frame(width: 24)

                                VStack(alignment: .leading, spacing: 4) {
                                    Text(folder.name)
                                        .font(.system(size: 14, weight: .semibold))
                                    Text(folder.path)
                                        .font(.system(size: 11))
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }

                                Spacer()

                                Text(folder.isMissing ? "Missing" : "\(folder.fileCount) files")
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundStyle(folder.isMissing ? .red : .secondary)
                            }
                            .padding(16)
                            .background(AppTheme.panelRaised, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                        }
                    }
                }
            }
            .padding(24)
        }
    }
}

private struct OverviewCard: View {
    let title: String
    let value: String
    let detail: String
    let systemImage: String

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 20, weight: .bold))
                .foregroundStyle(AppTheme.accent)

            Text(title)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)

            Text(value)
                .font(.system(size: 34, weight: .bold, design: .rounded))

            Text(detail)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
        .background(AppTheme.panelRaised, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .strokeBorder(Color(nsColor: .separatorColor).opacity(0.45), lineWidth: 1)
        )
    }
}

private struct PreviewPlaceholder: View {
    var body: some View {
        VStack(spacing: 14) {
            Spacer()
            Image(systemName: "waveform.and.magnifyingglass")
                .font(.system(size: 42, weight: .light))
                .foregroundStyle(.secondary)
            Text("Pick a sound")
                .font(.system(size: 18, weight: .semibold))
            Text("Preview, set in and out points, then drag the clip into DaVinci or any other timeline.")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 240)
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .frame(height: 250)
        .background(AppTheme.panelSunken)
    }
}
