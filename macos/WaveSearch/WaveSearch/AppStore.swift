import Foundation
import WaveSearchKit
import AppKit
import Combine
import UniformTypeIdentifiers

nonisolated struct SoundFile: Identifiable, Hashable, Sendable {
    let id: Int
    let folderId: Int
    let path: String
    let name: String
    let durationMs: Int
    let contentHash: Int64
    var acousticGroupId: Int64 = 0

    var url: URL { URL(fileURLWithPath: path) }
    var ext: String { url.pathExtension.uppercased() }

    var displayName: String {
        guard let dot = name.lastIndex(of: ".") else { return name }
        return String(name[..<dot])
    }
}

@MainActor
final class AppStore: ObservableObject {
    @Published var isSidebarVisible = true
    @Published var folders: [LibraryFolder] = []
    @Published private(set) var isReady = false
    @Published private(set) var isLibraryChanging = false
    @Published private(set) var isShuttingDown = false

    var canUseLibrary: Bool { isReady && !isLibraryChanging && !isShuttingDown }
    var canModifyLibraries: Bool { canUseLibrary && !isMetadataScanning }
    var canRestoreBackup: Bool {
        canModifyLibraries || (!isReady && !ownsBackend && startupTask == nil && lastBackendError != nil
                               && !isLibraryChanging && !isShuttingDown)
    }
    @Published var selectedFolderId: Int? = nil
    @Published var results: [SoundFile] = []
    @Published private(set) var canBrowseMore = false
    @Published var query: String = ""
    @Published var selectedFile: SoundFile? = nil
    @Published var isIndexing: Bool = false
    @Published var isMetadataScanning: Bool = false {
        didSet { refinementCoordinator.policyDidChange() }
    }
    @Published var isRefinementPaused: Bool = false {
        didSet {
            preferences.set(isRefinementPaused, forKey: refinementPausedKey)
            refinementCoordinator.policyDidChange()
        }
    }
    @Published var refinementMode: RefinementMode = .balanced
    @Published private(set) var refinementSnapshot = RefinementSnapshot(mode: .balanced, activeQueue: nil, blocker: nil)
    @Published var acousticRefinedCount: Int64 = 0
    @Published var acousticPendingCount: Int64 = 0
    @Published var acousticFailedCount: Int64 = 0
    @Published var semanticRefinedCount: Int64 = 0
    @Published var semanticPendingCount: Int64 = 0
    @Published var semanticFailedCount: Int64 = 0
    @Published var semanticAvailable: Bool = true
    @Published var waveformUniversalCount: Int64 = 0
    @Published var waveformPendingCount: Int64 = 0
    @Published var indexingProgress: String = ""
    @Published var indexingPhase: String = ""
    @Published var indexingDiscoveredCount: UInt64 = 0
    @Published var indexingExpectedCount: UInt64 = 0
    @Published var indexingStartedAt: Date?
    @Published var isSearching: Bool = false {
        didSet { refinementCoordinator.policyDidChange() }
    }
    @Published var lastBackendError: String? = nil
    @Published private(set) var recoveryStatus: String?
    @Published private(set) var recoveryError: String?
    @Published private(set) var storageUsage: LibraryStorageUsage?
    @Published private(set) var storageError: String?
    @Published private(set) var isRefreshingStorage = false
    private var storageTask: Task<Void, Never>?
    @Published var isExampleSearch: Bool = false
    @Published var exampleSourceName: String = ""
    @Published private(set) var favouritePaths: Set<String> = []

    private var nextFolderId: Int = 1
    private let dbPath: String
    private let backend: LibraryBackend
    private let startsRefinement: Bool
    private let preferences: UserDefaults
    private let backendWork = BlockingWorkRegistry()
    private var ownsBackend = false
    private var startupTask: Task<Void, Never>?
    private var libraryChangeTask: Task<Void, Never>?
    private var shutdownTask: Task<Void, Never>?
    private var availabilityTask: Task<Void, Never>?
    private var availabilityTimer: Task<Void, Never>?
    private var availabilityRefreshRequested = false
    private var availabilityObservers: [NSObjectProtocol] = []
    private let semanticInstallRoot: String
    private let saveKey = "ws_folders_v2"
    private let favouritesKey = "ws_favourites_v1"
    private let refinementModeKey = "ws_refinement_mode_v1"
    private let refinementPausedKey = "ws_refinement_paused_v1"
    private var activeScopes: [Int: URL] = [:]
    private let searchBackend: SearchRequest.Backend
    private let searchRefinementWait: SearchRequest.RefinementWait
    private var currentSearchID: UUID?
    private lazy var searchWorker = LatestRequestWorker<SearchRequest, SearchOutcome>(
        operation: { [weak self] request in
            guard let backend = self?.searchBackend else { return SearchOutcome(cancelled: true) }
            if case .text = request.kind {
                let deadline = ContinuousClock.now.advanced(by: .milliseconds(120))
                let lexical = await request.run(lexicalOnly: true, backend: backend)
                guard !Task.isCancelled, !lexical.cancelled, lexical.error == nil else { return lexical }
                guard lexical.needsRefinement else { return lexical }
                await self?.publishSearch(lexical, requestID: request.id, final: false)
                // Filename results publish immediately; only inference waits for
                // typing to settle. Time spent in lexical search counts as quiet time.
                do { try await self?.searchRefinementWait(deadline) }
                catch { return SearchOutcome(cancelled: true) }
                guard !Task.isCancelled else { return SearchOutcome(cancelled: true) }
            }
            return await request.run(lexicalOnly: false, backend: backend)
        },
        onActivityChange: { [weak self] active in
            self?.activeSearchOperations = active ? 1 : 0
            self?.refinementCoordinator.policyDidChange()
        }
    )
    private var indexTask: Task<Void, Never>?
    private var indexProgressTask: Task<Void, Never>?
    private var indexingGeneration: Int = 0
    private var activeSearchOperations = 0
    private var lastSearchRequest: String = ""
    private let refinementCoordinator = BackgroundRefinementCoordinator()
    private var playerSubscriptions: Set<AnyCancellable> = []

    init(storageDirectory: URL? = nil, backend: LibraryBackend = .live,
         preferences: UserDefaults = .standard, startsRefinement: Bool = true,
         searchBackend: @escaping SearchRequest.Backend = { SearchRequest.execute($0, lexicalOnly: $1) },
         searchRefinementWait: @escaping SearchRequest.RefinementWait = { try await SearchRequest.waitForRefinement(until: $0) }) {
        self.searchBackend = searchBackend
        self.searchRefinementWait = searchRefinementWait
        self.backend = backend
        self.preferences = preferences
        self.startsRefinement = startsRefinement
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!
        let dir = storageDirectory ?? appSupport.appendingPathComponent("WaveSearch")
        dbPath = dir.appendingPathComponent("index.db").path
        semanticInstallRoot = dir.appendingPathComponent("wavesearch-clap").path
        favouritePaths = Set(preferences.stringArray(forKey: favouritesKey) ?? [])
        refinementMode = RefinementMode(
            rawValue: preferences.string(forKey: refinementModeKey) ?? ""
        ) ?? .balanced
        refinementSnapshot = RefinementSnapshot(mode: refinementMode, activeQueue: nil, blocker: nil)
        isRefinementPaused = preferences.bool(forKey: refinementPausedKey)
        observePlayerActivity()
    }

    deinit {
        // The application delegate owns the async termination barrier. Never
        // perform a blocking close here or race detached work with deallocation.
        let backendStillOpen = ownsBackend
        assert(!backendStillOpen, "Await AppStore.shutdown() before releasing an open store")
    }

    /// Idempotent termination barrier. No new library work is admitted once called.
    func shutdown() async {
        if let shutdownTask { await shutdownTask.value; return }
        isShuttingDown = true
        isReady = false
        currentSearchID = nil
        searchWorker.cancel()
        indexTask?.cancel()
        indexProgressTask?.cancel()
        stopAvailabilityMonitoring()
        refinementCoordinator.stop()
        _ = ws_cancel_indexing()
        backendWork.suspend()
        BlockingWorkRegistry.hostFiles.suspend()
        shutdownTask = Task {
            // Startup/removal retain their ownership until their workers return.
            await startupTask?.value
            await libraryChangeTask?.value
            await refinementCoordinator.stopAndDrain()
            await PlayerController.shared.stopAndDrain()
            await AudioAnalysisRepository.shared.suspendAndDrain()
            await backendWork.suspendAndDrain()
            await BlockingWorkRegistry.hostFiles.suspendAndDrain()
            await indexTask?.value
            await indexProgressTask?.value
            await searchWorker.drain()
            await availabilityTask?.value
            let scopes = Array(activeScopes.values)
            activeScopes.removeAll()
            let close = ownsBackend
            let backend = backend
            await Task.detached(priority: .utility) {
                if close { backend.close() }
                for scope in scopes { backend.releaseScope(scope) }
            }.value
            ownsBackend = false
        }
        await shutdownTask?.value
    }

    var selectedFolderName: String {
        guard let id = selectedFolderId,
              let folder = folders.first(where: { $0.id == id })
        else { return "All Libraries" }
        return folder.name
    }

    var totalIndexedFiles: Int {
        folders.reduce(0) { $0 + $1.fileCount }
    }

    func bootstrap() {
        guard !isReady, !isShuttingDown, !isLibraryChanging, startupTask == nil else { return }
        let path = dbPath
        let saved = preferences.data(forKey: saveKey)
        let backend = backend
        startupTask = Task {
            defer { startupTask = nil }
            guard let opened = await backendWork.run({ backend.open(path, saved) }) else { return }
            ownsBackend = opened.opened
            activeScopes = opened.scopes
            guard !isShuttingDown else { return }
            lastBackendError = opened.error
            guard opened.opened else { return }
            folders = opened.folders
            nextFolderId = (folders.map(\.id).max() ?? 0) + 1
            isReady = true
            PlayerController.shared.resume()
            startRefinement()
            startAvailabilityMonitoring()
            refreshSearch()
        }
    }

    func waitUntilStarted() async { await startupTask?.value }
    func waitForLibraryChange() async { await libraryChangeTask?.value }
    func waitForIndexing() async { await indexTask?.value }

    private func startRefinement() {
        guard startsRefinement, canUseLibrary else { return }
        let environment = ProcessInfo.processInfo.environment
        let modelDirectory = environment["WS_CLAP_MODEL_DIR"]
            ?? URL(fileURLWithPath: semanticInstallRoot).appendingPathComponent("model").path
        #if arch(arm64)
        let defaultRuntime = URL(fileURLWithPath: semanticInstallRoot)
            .appendingPathComponent("onnxruntime-osx-arm64-1.29.0/lib/libonnxruntime.dylib").path
        #else
        let defaultRuntime = ""
        #endif
        let runtime = environment["WS_ORT_LIBRARY"] ?? defaultRuntime
        let configuredThreads = Int32(environment["WS_CLAP_THREADS"] ?? "")
        let threads = max(1, configuredThreads ?? 1)
        refinementCoordinator.start(
            configuration: .init(
                runtimeLibraryPath: runtime,
                modelDirectory: modelDirectory,
                semanticThreads: threads
            ),
            stateProvider: { [weak self] in
                guard let self else {
                    return RefinementPolicyInput(
                        mode: .fastOnly,
                        userPaused: true,
                        metadataScanning: false,
                        searching: false,
                        playing: false,
                        selectedAnalysis: false,
                        thermalConstrained: false,
                        memoryConstrained: false,
                        lowPowerMode: false,
                        onBattery: false,
                        idleSeconds: 0,
                        hasAvailableLibraries: false
                    )
                }
                return self.refinementPolicyInput
            },
            folderProvider: { [weak self] in
                self?.folders.filter { !$0.isMissing }.map { Int32($0.id) } ?? []
            },
            snapshotHandler: { [weak self] snapshot in
                self?.applyRefinementSnapshot(snapshot)
            }
        )
    }

    private var refinementPolicyInput: RefinementPolicyInput {
        RefinementPolicyInput(
            mode: refinementMode,
            userPaused: isRefinementPaused,
            metadataScanning: isMetadataScanning || isLibraryChanging || isShuttingDown,
            searching: isSearching || activeSearchOperations > 0,
            playing: PlayerController.shared.isPlaying,
            selectedAnalysis: PlayerController.shared.isAnalyzingWaveform,
            thermalConstrained: false,
            memoryConstrained: false,
            lowPowerMode: false,
            onBattery: false,
            idleSeconds: 0,
            hasAvailableLibraries: folders.contains { !$0.isMissing }
        )
    }

    private func applyRefinementSnapshot(_ snapshot: RefinementSnapshot) {
        refinementSnapshot = snapshot
        waveformUniversalCount = snapshot.waveformReady
        waveformPendingCount = snapshot.waveformPending
        acousticRefinedCount = snapshot.acousticReady
        acousticPendingCount = snapshot.acousticPending
        acousticFailedCount = snapshot.acousticFailed
        semanticRefinedCount = snapshot.semanticReady
        semanticPendingCount = snapshot.semanticPending
        semanticFailedCount = snapshot.semanticFailed
        semanticAvailable = snapshot.semanticAvailable
        if !isMetadataScanning {
            isIndexing = snapshot.isWorking
            indexingPhase = snapshot.phase
            indexingProgress = snapshot.detail
            if snapshot.isWorking {
                if indexingStartedAt == nil { indexingStartedAt = Date() }
            } else {
                indexingStartedAt = nil
            }
        }
        if let error = snapshot.lastError { lastBackendError = error }
    }

    private func observePlayerActivity() {
        PlayerController.shared.$isPlaying
            .removeDuplicates()
            .sink { [weak self] _ in self?.refinementCoordinator.policyDidChange() }
            .store(in: &playerSubscriptions)
        PlayerController.shared.$isAnalyzingWaveform
            .removeDuplicates()
            .sink { [weak self] _ in self?.refinementCoordinator.policyDidChange() }
            .store(in: &playerSubscriptions)
    }

    func folderName(for id: Int) -> String {
        folders.first(where: { $0.id == id })?.name ?? "Library"
    }

    func libraryLocation(for file: SoundFile) -> String {
        guard let folder = folders.first(where: { $0.id == file.folderId }) else { return "Library" }
        let folderURL = URL(fileURLWithPath: folder.path, isDirectory: true).standardizedFileURL
        let parentURL = file.url.deletingLastPathComponent().standardizedFileURL
        let root = folderURL.path.hasSuffix("/") ? folderURL.path : folderURL.path + "/"
        guard parentURL.path != folderURL.path, parentURL.path.hasPrefix(root) else { return folder.name }
        let relative = String(parentURL.path.dropFirst(root.count))
        return relative.isEmpty ? folder.name : "\(folder.name)/\(relative)"
    }

    func isFavourite(_ file: SoundFile) -> Bool {
        favouritePaths.contains(file.url.standardizedFileURL.path)
    }

    func toggleFavourite(_ file: SoundFile) {
        let path = file.url.standardizedFileURL.path
        if favouritePaths.contains(path) {
            favouritePaths.remove(path)
        } else {
            favouritePaths.insert(path)
        }
        preferences.set(favouritePaths.sorted(), forKey: favouritesKey)
    }

    func addFolder() {
        guard canModifyLibraries else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = "Choose a sound library folder"
        panel.prompt = "Add Library"
        panel.canCreateDirectories = false

        guard panel.runModal() == .OK, let url = panel.url else { return }
        addFolder(at: url)
    }

    /// The URL normally comes from NSOpenPanel; authorization remains on the worker.
    func addFolder(at url: URL) {
        // The panel can run a nested event loop; recheck admission after it closes.
        guard canModifyLibraries else { return }
        let folder = LibraryFolder(id: nextFolderId, name: url.lastPathComponent, path: url.path)
        nextFolderId += 1
        isLibraryChanging = true
        let backend = backend
        libraryChangeTask = Task {
            guard let access = await backendWork.run({ backend.authorize(folder) }) else {
                isLibraryChanging = false
                libraryChangeTask = nil
                return
            }
            if let scope = access.scope { activeScopes[folder.id] = scope }
            guard !isShuttingDown else { libraryChangeTask = nil; return }
            folders.append(access.folder)
            saveFolders()
            isLibraryChanging = false
            libraryChangeTask = nil
            refinementCoordinator.librariesDidChange()
            refreshAvailability()
            indexFolder(access.folder)
        }
    }

    func removeFolder(_ folder: LibraryFolder) {
        guard canModifyLibraries, folders.contains(where: { $0.id == folder.id }) else { return }
        isLibraryChanging = true
        currentSearchID = nil
        searchWorker.cancel()
        refinementCoordinator.stop()
        backendWork.suspend()
        BlockingWorkRegistry.hostFiles.suspend()
        let backend = backend
        libraryChangeTask = Task {
            await refinementCoordinator.stopAndDrain()
            await PlayerController.shared.stopAndDrain()
            await AudioAnalysisRepository.shared.suspendAndDrain()
            await backendWork.suspendAndDrain()
            await BlockingWorkRegistry.hostFiles.suspendAndDrain()
            await searchWorker.drain()
            // A quit received while draining should not initiate another mutation.
            guard !isShuttingDown else { libraryChangeTask = nil; return }
            let error = await Task.detached(priority: .utility) { backend.remove(Int32(folder.id)) }.value
            if let error {
                lastBackendError = error
            } else {
                if let scope = activeScopes.removeValue(forKey: folder.id) {
                    await Task.detached(priority: .utility) { backend.releaseScope(scope) }.value
                }
                folders.removeAll { $0.id == folder.id }
                if selectedFolderId == folder.id { selectedFolderId = nil }
                lastBackendError = nil
                saveFolders()
            }
            selectedFile = nil
            isSearching = false
            guard !isShuttingDown else { libraryChangeTask = nil; return }
            await AudioAnalysisRepository.shared.resume()
            // Shutdown waits for this task before its final suspend/drain barrier.
            guard !isShuttingDown else { libraryChangeTask = nil; return }
            backendWork.resume()
            BlockingWorkRegistry.hostFiles.resume()
            PlayerController.shared.resume()
            isLibraryChanging = false
            libraryChangeTask = nil
            startRefinement()
            refreshAvailability()
            refreshSearch()
        }
    }

    var indexURL: URL { URL(fileURLWithPath: dbPath) }
    var recoveryDirectory: URL { indexURL.deletingLastPathComponent().appendingPathComponent("Recovery", isDirectory: true) }
    var exportDirectory: URL { AudioClipStorage.directory }

    private var backupManifest: LibraryBackupManifest {
        let saved = preferences.data(forKey: saveKey).flatMap { try? JSONDecoder().decode([LibraryFolder].self, from: $0) }
        return .init(folders: ownsBackend ? folders : (saved ?? folders), favourites: favouritePaths.sorted())
    }

    func refreshStorage() {
        guard canUseLibrary, storageTask == nil else { return }
        let index = indexURL, exports = exportDirectory, recovery = recoveryDirectory
        isRefreshingStorage = true
        storageTask = Task {
            defer { storageTask = nil; isRefreshingStorage = false }
            let result = await backendWork.run {
                Result { try LibraryRecovery.storage(index: index, exports: exports, recovery: recovery) }
            }
            guard canUseLibrary, let result else { return }
            switch result {
            case .success(let usage): storageUsage = usage; storageError = nil
            case .failure(let error): storageUsage = nil; storageError = error.localizedDescription
            }
        }
    }

    func waitForStorage() async { await storageTask?.value }

    func revealStorage(_ url: URL) {
        NSWorkspace.shared.selectFile(url.path, inFileViewerRootedAtPath: url.deletingLastPathComponent().path)
    }

    func createBackup() {
        guard canModifyLibraries else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Save Backup Here"
        panel.message = "Choose where to save a new WaveSearch backup folder. It includes the index, library locations, and favourites. Original audio and exports are stored separately."
        guard panel.runModal() == .OK, let parent = panel.url else { return }
        let destination = parent.appendingPathComponent("WaveSearch-\(UUID().uuidString).wavesearchbackup", isDirectory: true)
        createBackup(at: destination)
    }

    func createBackup(at destination: URL) {
        let manifest = backupManifest
        performRecovery("Creating backup…", operation: {
            let parent = destination.deletingLastPathComponent()
            let scoped = parent.startAccessingSecurityScopedResource()
            defer { if scoped { parent.stopAccessingSecurityScopedResource() } }
            _ = try LibraryRecovery.checkIntegrity()
            try LibraryRecovery.createBackup(at: destination, manifest: manifest)
            return destination
        }, apply: { [weak self] url in
            self?.recoveryStatus = "Backup saved to \(url.path)."
        })
    }

    func restoreBackup() {
        guard canRestoreBackup else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.treatsFilePackagesAsDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose Backup"
        panel.message = "Select a WaveSearch backup folder containing catalog.sqlite and manifest.json."
        guard panel.runModal() == .OK, let source = panel.url, canRestoreBackup else { return }
        let alert = NSAlert()
        alert.messageText = "Restore this backup?"
        alert.informativeText = "This replaces the current index, library list, and favourites. WaveSearch will first save a recovery copy of the current catalog. Your original audio and exported clips stay in their locations."
        alert.addButton(withTitle: "Restore")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        restoreBackup(at: source)
    }

    func restoreBackup(at source: URL) {
        let unopened = !ownsBackend
        let index = indexURL
        let previous = backupManifest
        let recovery = recoveryDirectory
        let backend = backend
        performRecovery("Restoring backup…", allowUnopened: true, operation: {
            let scoped = source.startAccessingSecurityScopedResource()
            defer { if scoped { source.stopAccessingSecurityScopedResource() } }
            let manifest = try LibraryRecovery.readManifest(at: source)
            if unopened {
                let safety = try LibraryRecovery.recoverUnopened(at: source, index: index, recovery: recovery, previous: previous)
                let saved = try JSONEncoder().encode(manifest.folders)
                let opened = backend.open(index.path, saved)
                let check: Result<String, Error> = opened.opened
                    ? .success("Recovered catalog passed full integrity checks.")
                    : .failure(RecoveryFailure(message: opened.error ?? "Recovered catalog could not open. Retry opening the library."))
                return (opened, manifest.favourites, safety, check)
            }
            try FileManager.default.createDirectory(at: recovery, withIntermediateDirectories: true)
            let safety = recovery.appendingPathComponent("Before-Restore-\(UUID().uuidString).wavesearchbackup")
            try LibraryRecovery.createBackup(at: safety, manifest: previous)
            try LibraryRecovery.restore(at: source)
            // Once published, always return/adopt scopes and host state, even if
            // post-restore diagnostics find inconsistencies in a derived index.
            var opened = LibraryOpenResult(opened: true)
            for folder in manifest.folders {
                var access = backend.authorize(folder)
                access.folder.fileCount = max(0, Int(ws_folder_count(Int32(folder.id))))
                opened.folders.append(access.folder)
                if let scope = access.scope { opened.scopes[folder.id] = scope }
            }
            let check = Result { try LibraryRecovery.checkIntegrity() }
            return (opened, manifest.favourites, safety, check)
        }, apply: { [weak self] opened, favourites, safety, check in
            guard let self else { return }
            ownsBackend = opened.opened
            isReady = opened.opened && !isShuttingDown
            if !opened.opened { lastBackendError = opened.error }
            let scopes = Array(activeScopes.values)
            activeScopes = opened.scopes
            await Task.detached(priority: .utility) {
                for scope in scopes { backend.releaseScope(scope) }
            }.value
            folders = opened.folders
            favouritePaths = Set(favourites)
            preferences.set(favourites, forKey: favouritesKey)
            saveFolders()
            selectedFolderId = nil
            results = []
            isExampleSearch = false
            await AudioAnalysisRepository.shared.clearMemory()
            recoveryStatus = "Restored backup. Previous catalog saved to \(safety.path)."
            if case .failure(let error) = check { recoveryError = error.localizedDescription }
        })
    }

    func checkIntegrity() {
        performRecovery("Checking index integrity…", operation: { try LibraryRecovery.checkIntegrity() },
                        apply: { [weak self] report in self?.recoveryStatus = report })
    }

    func clearWaveformCache() {
        performRecovery("Deleting waveform cache…", operation: {
            guard ws_waveform_cache_clear() == 0 else {
                throw RecoveryFailure(message: ifBackendError() ?? "Could not delete waveform cache")
            }
        }, apply: { [weak self] _ in
            await AudioAnalysisRepository.shared.clearMemory()
            self?.recoveryStatus = "Waveform cache deleted. Waveforms regenerate when previewed or during background refinement. Freed database space will be reused."
        })
    }

    func reconnectFolder(_ folder: LibraryFolder) {
        guard canModifyLibraries else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.prompt = "Reconnect"
        panel.message = "Choose the new root of \(folder.name). WaveSearch will re-scan this folder and replace its indexed file list; files absent from this root will leave the index."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        reconnectFolder(folder, to: url)
    }

    func reconnectFolder(_ folder: LibraryFolder, to url: URL) {
        guard folders.contains(where: { $0.id == folder.id }) else { return }
        let newPath = url.standardizedFileURL.path
        guard !folders.contains(where: { $0.id != folder.id && URL(fileURLWithPath: $0.path).standardizedFileURL.path == newPath }) else {
            recoveryError = "This folder is already connected as another library."
            return
        }
        let backend = backend
        performRecovery("Reconnecting \(folder.name)…", operation: {
            try LibraryRecovery.reconnect(folder, to: url, backend: backend)
        }, apply: { [weak self] access in
            guard let self else { return }
            let oldScope = activeScopes.removeValue(forKey: folder.id)
            if let scope = access.scope { activeScopes[folder.id] = scope }
            if let oldScope { await Task.detached { backend.releaseScope(oldScope) }.value }
            if let index = folders.firstIndex(where: { $0.id == folder.id }) { folders[index] = access.folder }
            let oldRoot = URL(fileURLWithPath: folder.path).standardizedFileURL.path + "/"
            favouritePaths = Set(favouritePaths.map { path in
                path.hasPrefix(oldRoot) ? newPath + "/" + String(path.dropFirst(oldRoot.count)) : path
            })
            preferences.set(favouritePaths.sorted(), forKey: favouritesKey)
            saveFolders()
            recoveryStatus = "Reconnected \(folder.name): \(access.folder.fileCount) sounds indexed."
        })
    }

    /// Uses the same shutdown barrier as removal: finish every reader before
    /// changing the catalog, and retain ownership until the blocking call ends.
    private func performRecovery<Value: Sendable>(
        _ status: String, allowUnopened: Bool = false, operation: @escaping @Sendable () throws -> Value,
        apply: @escaping @MainActor (Value) async -> Void
    ) {
        guard canModifyLibraries || (allowUnopened && canRestoreBackup) else { return }
        isLibraryChanging = true
        recoveryStatus = status
        recoveryError = nil
        currentSearchID = nil
        searchWorker.cancel()
        refinementCoordinator.stop()
        backendWork.suspend()
        BlockingWorkRegistry.hostFiles.suspend()
        libraryChangeTask = Task {
            defer { libraryChangeTask = nil }
            await refinementCoordinator.stopAndDrain()
            await PlayerController.shared.stopAndDrain()
            await AudioAnalysisRepository.shared.suspendAndDrain()
            await backendWork.suspendAndDrain()
            await BlockingWorkRegistry.hostFiles.suspendAndDrain()
            await searchWorker.drain()
            guard !isShuttingDown else { return }
            let result = await Task.detached(priority: .utility) { Result { try operation() } }.value
            switch result {
            case .success(let value):
                lastBackendError = nil
                await apply(value)
            case .failure(let error):
                recoveryStatus = nil
                recoveryError = error.localizedDescription
                lastBackendError = error.localizedDescription
            }
            selectedFile = nil
            isSearching = false
            guard !isShuttingDown else { return }
            await AudioAnalysisRepository.shared.resume()
            guard !isShuttingDown else { return }
            backendWork.resume()
            BlockingWorkRegistry.hostFiles.resume()
            PlayerController.shared.resume()
            isLibraryChanging = false
            startRefinement()
            if isReady { startAvailabilityMonitoring() }
            refreshAvailability()
            refreshSearch()
            refreshStorage()
        }
    }

    func indexFolder(_ folder: LibraryFolder, deep: Bool = false) {
        guard canModifyLibraries, !folder.isMissing else { return }

        indexingGeneration &+= 1
        let generation = indexingGeneration
        _ = ws_cancel_refinement()
        refinementCoordinator.policyDidChange()
        let operationStart = Date()
        let isReindex = folder.fileCount > 0
        isIndexing = true
        isMetadataScanning = true
        indexingStartedAt = operationStart
        indexingDiscoveredCount = 0
        indexingExpectedCount = UInt64(max(folder.fileCount, 0))
        acousticRefinedCount = 0
        acousticPendingCount = 0
        acousticFailedCount = 0
        semanticRefinedCount = 0
        semanticPendingCount = 0
        semanticFailedCount = 0
        indexingPhase = deep ? "Deep-scanning library" : "Scanning library"
        indexingProgress = deep
            ? "Deep re-indexing \(folder.name)…"
            : "\(isReindex ? "Re-indexing" : "Indexing") \(folder.name)…"
        lastBackendError = nil
        startIndexProgressPolling()

        let fid = Int32(folder.id)
        let path = folder.path
        let folderName = folder.name
        let backend = backend

        indexTask = Task {
            // A bookmark unavailable at startup may become resolvable after mount.
            if activeScopes[folder.id] == nil,
               let access = await backendWork.run({ backend.authorize(folder) }) {
                if let scope = access.scope { activeScopes[folder.id] = scope }
                if !isShuttingDown, let index = folders.firstIndex(where: { $0.id == folder.id }) {
                    folders[index].bookmark = access.folder.bookmark
                    saveFolders()
                }
            }
            let accessURL = activeScopes[folder.id]
            let scan = await backendWork.run(priority: .userInitiated) { () -> (result: Int32, count: Int32, error: String?) in
                guard !Task.isCancelled else { return (-1, 0, "Cancelled") }
                let scoped = accessURL?.startAccessingSecurityScopedResource() ?? false
                defer { if scoped { accessURL?.stopAccessingSecurityScopedResource() } }
                let flags: UInt32 = deep ? UInt32(WS_INDEX_DEEP) : UInt32(WS_INDEX_FAST)
                let result = path.withCString { ws_index_folder_ex(fid, $0, flags) }
                let error = result < 0 ? ifBackendError() : nil
                let count = ws_folder_count(fid)
                return (result, count, error ?? (count < 0 ? ifBackendError() : nil))
            }

            guard !isShuttingDown, generation == indexingGeneration else { return }
            guard let scan else {
                isMetadataScanning = false
                isIndexing = false
                indexTask = nil
                indexProgressTask?.cancel()
                return
            }
            guard scan.result == 0, scan.count >= 0 else {
                isIndexing = false
                isMetadataScanning = false
                indexTask = nil
                indexProgressTask?.cancel()
                indexProgressTask = nil
                indexingPhase = scan.error == "Cancelled" ? "Cancelled" : "Index failed"
                if scan.error == "Cancelled" {
                    indexingProgress = "Index cancelled; previous searchable index preserved"
                } else {
                    lastBackendError = scan.error ?? "Unknown backend error"
                    indexingProgress = "Index failed for \(folderName)"
                }
                clearIndexingDisplay(after: .seconds(4), operationStart: operationStart)
                return
            }

            isMetadataScanning = false
            indexTask = nil
            indexProgressTask?.cancel()
            indexProgressTask = nil
            indexingDiscoveredCount = UInt64(scan.count)
            indexingExpectedCount = UInt64(scan.count)
            if let idx = folders.firstIndex(where: { $0.id == Int(fid) }) {
                folders[idx].fileCount = Int(scan.count)
            }
            // Searchability is the foreground completion boundary. Expensive
            // refinement continues one file at a time at background priority.
            saveFolders()
            refreshSearch()
            indexingPhase = "Search ready"
            indexingProgress = "\(folderName) is searchable; background refinement follows the selected mode"
            refinementCoordinator.librariesDidChange()
            refinementCoordinator.policyDidChange()
        }
    }

    func setRefinementMode(_ mode: RefinementMode) {
        guard refinementMode != mode else { return }
        refinementMode = mode
        preferences.set(mode.rawValue, forKey: refinementModeKey)
        if mode == .fastOnly { _ = ws_cancel_refinement() }
        refinementCoordinator.policyDidChange()
        refinementCoordinator.wake()
    }

    func pauseBackgroundRefinement() {
        guard !isMetadataScanning, refinementMode != .fastOnly else { return }
        isRefinementPaused = true
    }

    func resumeBackgroundRefinement() {
        guard !isMetadataScanning else { return }
        isRefinementPaused = false
        refinementCoordinator.wake()
    }

    func cancelIndexing() {
        if isMetadataScanning {
            indexTask?.cancel()
            _ = ws_cancel_indexing()
            indexingPhase = "Cancelling scan"
            indexingProgress = "Cancelling; the previous searchable snapshot will be preserved…"
        } else {
            pauseBackgroundRefinement()
        }
    }

    private func startIndexProgressPolling() {
        indexProgressTask?.cancel()
        indexProgressTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let registry = self?.backendWork else { return }
                let discovered = await registry.run { () -> UInt64? in
                    var status = WSOperationStatus()
                    status.struct_size = UInt32(MemoryLayout<WSOperationStatus>.size)
                    return ws_operation_status(&status) == 0 ? status.discovered_count : nil
                }
                guard let self, !Task.isCancelled, !self.isShuttingDown else { return }
                if let discovered = discovered ?? nil { self.indexingDiscoveredCount = max(self.indexingDiscoveredCount, discovered) }
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
    }

    private func clearIndexingDisplay(after delay: Duration, operationStart: Date) {
        Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard let self, !self.isIndexing, self.indexingStartedAt == operationStart else { return }
            self.indexingProgress = ""
            self.indexingPhase = ""
            self.indexingDiscoveredCount = 0
            self.indexingExpectedCount = 0
            self.indexingStartedAt = nil
        }
    }

    func refreshSearch() {
        lastSearchRequest = ""
        search(query)
    }

    func search(_ q: String) {
        isExampleSearch = false
        query = q
        guard canUseLibrary else { return }
        let trimmed = q.trimmingCharacters(in: .whitespacesAndNewlines)
        let requestKey = "\(selectedFolderId ?? -1)|\(trimmed)"
        guard requestKey != lastSearchRequest else { return }
        lastSearchRequest = requestKey

        if trimmed.isEmpty, selectedFolderId == nil {
            currentSearchID = nil
            searchWorker.cancel()
            isSearching = false
            applyResults([])
        } else {
            submitSearch(trimmed.isEmpty ? .browse : .text(trimmed))
        }
    }

    func loadMore() {
        guard canBrowseMore, !isSearching, !isExampleSearch,
              query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              selectedFolderId != nil, let after = results.last else { return }
        submitSearch(.browseMore(after: after))
    }

    private func submitSearch(_ kind: SearchRequest.Kind) {
        let append: Bool
        if case .browseMore = kind { append = true } else { append = false }
        canBrowseMore = false
        currentSearchID = nil
        searchWorker.cancel()
        guard let request = SearchRequest(kind: kind, folderID: selectedFolderId.map(Int32.init) ?? -1) else {
            lastBackendError = ifBackendError() ?? "Unable to allocate search request"
            lastSearchRequest = ""
            isSearching = false
            return
        }
        currentSearchID = request.id
        isSearching = true
        lastBackendError = nil
        searchWorker.submit(request, cancel: { request.cancel() }) { [weak self] outcome in
            self?.publishSearch(outcome, requestID: request.id, final: true, append: append)
        }
    }

    private func publishSearch(_ outcome: SearchOutcome, requestID: UUID, final: Bool, append: Bool = false) {
        guard canUseLibrary, currentSearchID == requestID, !outcome.cancelled else { return }
        if let error = outcome.error {
            lastBackendError = error // Keep the lexical stage if optional hybrid work fails.
            if append { canBrowseMore = true }
        } else {
            applyResults(append ? results + outcome.files : outcome.files)
            canBrowseMore = outcome.hasMore
        }
        if final { isSearching = false }
    }

    func waitForSearch() async { await searchWorker.drain() }

    var selectedResultIndex: Int? {
        guard let selectedFile else { return nil }
        return results.firstIndex(of: selectedFile)
    }

    func selectFile(_ file: SoundFile, autoplay: Bool? = nil) {
        guard canUseLibrary else { return }
        selectedFile = file
        PlayerController.shared.load(file, autoplay: autoplay)
    }

    func chooseSearchExample() {
        guard canUseLibrary else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.audio]
        panel.message = "Choose an audio clip to find acoustic matches. Compressed examples must be 60 seconds or less."
        panel.prompt = "Find Similar"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        searchByExample(url: url)
    }

    func searchByExample(_ file: SoundFile) {
        searchByExample(url: file.url)
    }

    /// Both file-panel and drop submissions enter the same replaceable worker.
    @discardableResult
    func acceptSearchExamples(_ urls: [URL]) -> Bool {
        guard canUseLibrary else { return false }
        guard urls.count == 1, let url = urls.first, url.isFileURL else {
            lastBackendError = "Drop one audio file to find similar sounds."
            return false
        }
        searchByExample(url: url)
        return true
    }

    func searchByExample(url: URL) {
        guard canUseLibrary else { return }
        lastSearchRequest = ""
        isExampleSearch = true
        exampleSourceName = url.deletingPathExtension().lastPathComponent
        query = ""
        submitSearch(.example(url))
    }

    func selectResult(at index: Int, autoplay: Bool? = nil) {
        guard !results.isEmpty else { return }
        let clamped = min(max(index, 0), results.count - 1)
        let file = results[clamped]
        selectFile(file, autoplay: autoplay)
    }

    func selectNextResult() {
        selectResult(at: (selectedResultIndex ?? -1) + 1)
    }

    func selectPreviousResult() {
        selectResult(at: (selectedResultIndex ?? results.count) - 1)
    }

    func selectFirstResult() {
        selectResult(at: 0)
    }

    func selectLastResult() {
        selectResult(at: results.count - 1)
    }

    func playSelectedResult() {
        if selectedFile == nil { selectFirstResult() }
        PlayerController.shared.playFromSelectionStart()
    }

    func revealSelectedResult() {
        guard let selectedFile else { return }
        NSWorkspace.shared.selectFile(selectedFile.path, inFileViewerRootedAtPath: "")
    }

    private func applyResults(_ files: [SoundFile]) {
        results = files

        if let selectedFile, files.contains(selectedFile) {
            return
        }

        if let first = files.first {
            selectFile(first)
        } else {
            selectedFile = nil
            PlayerController.shared.stop()
        }
    }

    private func startAvailabilityMonitoring() {
        guard availabilityTimer == nil else { return }
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification, NSWorkspace.didWakeNotification] {
            availabilityObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshAvailability() }
            })
        }
        availabilityTimer = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(30)) } catch { return }
                self?.refreshAvailability()
            }
        }
        refreshAvailability()
    }

    private func stopAvailabilityMonitoring() {
        availabilityTimer?.cancel()
        availabilityTimer = nil
        availabilityTask?.cancel()
        availabilityRefreshRequested = false
        let center = NSWorkspace.shared.notificationCenter
        for observer in availabilityObservers { center.removeObserver(observer) }
        availabilityObservers.removeAll()
    }

    /// Coalesces mount/wake/timer requests into one active probe plus one refresh.
    func refreshAvailability() {
        guard canUseLibrary else { return }
        availabilityRefreshRequested = true
        guard availabilityTask == nil else { return }
        let backend = backend
        availabilityTask = Task {
            defer { availabilityTask = nil }
            while availabilityRefreshRequested, canUseLibrary, !Task.isCancelled {
                availabilityRefreshRequested = false
                let snapshot = folders
                guard let observations = await backendWork.run({ backend.availability(snapshot) }) else { return }
                guard canUseLibrary, !Task.isCancelled else { return }
                var changed = false
                for observation in observations {
                    // A response for an older path must never mark a replacement root missing.
                    guard let index = folders.firstIndex(where: { $0.id == observation.id && $0.path == observation.path }),
                          folders[index].isMissing != observation.isMissing else { continue }
                    folders[index].isMissing = observation.isMissing
                    changed = true
                }
                if changed { refinementCoordinator.librariesDidChange() }
            }
        }
    }

    func waitForAvailability() async { await availabilityTask?.value }

    private func saveFolders() {
        guard let data = try? JSONEncoder().encode(folders) else { return }
        preferences.set(data, forKey: saveKey)
        nextFolderId = (folders.map(\.id).max() ?? 0) + 1
    }

}

nonisolated func ifBackendError() -> String? {
    guard let ptr = ws_last_error_message() else { return nil }
    let message = String(cString: ptr).trimmingCharacters(in: .whitespacesAndNewlines)
    return message.isEmpty ? nil : message
}
