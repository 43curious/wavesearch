import Foundation
import WaveSearchKit

@MainActor
private final class EventSource {
    var receive: (@Sendable (LibraryWatchEvent) -> Void)?
    var starts: [[String]] = []
    var stops = 0

    var source: LibraryWatchSource {
        LibraryWatchSource { [self] paths, receive in
            starts.append(paths)
            self.receive = receive
            return { self.stops += 1 }
        }
    }
}

nonisolated private final class BlockingScan: @unchecked Sendable {
    private let lock = NSLock()
    private let gate = DispatchSemaphore(value: 0)
    private var entries: [String] = []
    var events: [String] { lock.lock(); defer { lock.unlock() }; return entries }
    func record(_ event: String) { lock.lock(); entries.append(event); lock.unlock() }
    func run() {
        precondition(!Thread.isMainThread)
        record("scan-start")
        gate.wait() // Deliberately ignores Task cancellation; shutdown must drain it.
        record("scan-end")
    }
    func release() { gate.signal() }
}

@main
struct LibraryWatchCheck {
    @MainActor static func main() async throws {
        if CommandLine.arguments.contains("--native") {
            try await nativeEvents()
            return
        }
        await coalescingAndRecovery()
        try await favouriteRelocation()
        await shutdownDrainsScanning()
        print("PASS: library event coalescing/recovery, real file relocation and watcher shutdown")
    }

    private static func until(_ predicate: () -> Bool) async {
        let deadline = ContinuousClock.now.advanced(by: .seconds(6))
        while !predicate(), ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(5)) }
        precondition(predicate(), "Library watch check timed out")
    }

    private static func coalescingAndRecovery() async {
        let source = EventSource()
        var calls: [Int] = []
        var busy = false
        let coordinator = LibraryWatchCoordinator(source: source.source, delay: .milliseconds(5)) { id in
            guard !busy else { return false }
            calls.append(id)
            return true
        }
        let first = LibraryFolder(id: 1, name: "One", path: "/one", isMissing: false)
        var second = LibraryFolder(id: 2, name: "Two", path: "/two", isMissing: false)
        coordinator.update([first, second])
        await until { calls.count == 2 }
        precondition(calls == [1, 2], "Starting at now must reconcile downtime for each library")
        for _ in 0..<500 { source.receive?(.init(paths: ["/one/nested/clip.wav"])) }
        await until { calls.count == 3 }
        try? await Task.sleep(for: .milliseconds(30))
        precondition(calls == [1, 2, 1], "An event burst must produce one pending root, not hundreds of scans")
        busy = true
        source.receive?(.init(paths: ["/two/clip.wav"]))
        try? await Task.sleep(for: .milliseconds(30))
        precondition(calls.count == 3, "Foreground work must defer reconciliation")
        busy = false
        coordinator.wake()
        await until { calls.count == 4 }
        precondition(calls.last == 2)
        source.receive?(.init(requiresFullScan: true))
        await until { calls.count == 6 }
        precondition(Array(calls.suffix(2)) == [1, 2], "Lost events must reconcile every root fairly")
        let obsolete = source.receive
        second.path = "/reconnected"
        coordinator.update([second])
        await until { calls.count == 7 }
        precondition(source.stops == 1 && source.starts.last == ["/reconnected"])
        coordinator.stop()
        obsolete?(.init(requiresFullScan: true))
        source.receive?(.init(paths: ["/reconnected/new.wav"]))
        try? await Task.sleep(for: .milliseconds(30))
        precondition(calls.count == 7 && source.stops == 2, "Stopped/replaced sources must not admit new scans")
        print("PASS: 500-event burst, busy admission, downtime/loss, fair roots, reconnect and obsolete callbacks")
    }

    private static func favouriteRelocation() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("wavesearch-move-check-\(UUID().uuidString)")
        let sounds = root.appendingPathComponent("sounds")
        try FileManager.default.createDirectory(at: sounds, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        // One second of silent PCM16, 8 kHz. No user sources or audio device.
        var bytes = Data([82,73,70,70,164,62,0,0,87,65,86,69,102,109,116,32,
                          16,0,0,0,1,0,1,0,64,31,0,0,128,62,0,0,2,0,16,0,
                          100,97,116,97,128,62,0,0])
        bytes.append(Data(repeating: 0, count: 16000))
        let old = sounds.appendingPathComponent("old.wav")
        let new = sounds.appendingPathComponent("new.wav")
        try bytes.write(to: old)
        let wrongVolume = LibraryFolder(id: 99, name: "Wrong volume", path: sounds.path,
                                        volumeUUID: "another-volume", isMissing: false)
        let observation = await Task.detached { LibraryBackend.live.availability([wrongVolume]) }.value
        precondition(observation.first?.isMissing == true,
                     "An existing mountpoint on another volume must not become an empty authoritative library")
        let suite = "wavesearch-moves-\(UUID().uuidString)"
        let preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite) }
        var backend = LibraryBackend.live
        backend.authorize = { folder in
            var available = folder
            available.isMissing = false
            return .init(folder: available)
        }
        await AudioAnalysisRepository.shared.resume()
        BlockingWorkRegistry.hostFiles.resume()
        let store = AppStore(storageDirectory: root, backend: backend, preferences: preferences,
                             startsRefinement: false, watchesLibraries: false)
        store.bootstrap()
        await store.waitUntilStarted()
        precondition(store.isReady)
        store.addFolder(at: sounds)
        await store.waitForLibraryChange()
        await store.waitForIndexing()
        store.selectedFolderId = store.folders[0].id
        store.search("")
        await store.waitForSearch()
        let file = store.results.first!
        store.toggleFavourite(file)
        let player = PlayerController.shared
        player.seek(to: 0.3)
        player.setSelection(0.2...0.8)
        try FileManager.default.moveItem(at: old, to: new)
        store.indexFolder(store.folders[0])
        await store.waitForIndexing()
        await store.waitForSearch()
        precondition(store.selectedFile?.id == file.id && store.selectedFile?.path == new.path)
        precondition(store.favouritePaths == [new.path], "Favourite paths must follow verified IDs")
        precondition(player.currentFile?.path == new.path && player.selection == 0.2...0.8 && player.progress == 0.3,
                     "The selected sound must keep its playhead/range when reopening its moved URL")
        precondition(preferences.stringArray(forKey: "ws_favourites_v1") == [new.path])
        await store.shutdown()
        print("PASS: real core rename preserves native favourites, selected ID, range and playhead")
    }

    private static func shutdownDrainsScanning() async {
        let source = EventSource()
        let scan = BlockingScan()
        let suite = "wavesearch-watch-shutdown-\(UUID().uuidString)"
        let preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite) }
        let folder = LibraryFolder(id: 1, name: "Fixture", path: "/fixture", fileCount: 1, isMissing: false)
        let backend = LibraryBackend(
            open: { _, _ in .init(opened: true, folders: [folder], scopes: [1: URL(fileURLWithPath: "/fixture")]) },
            remove: { _ in nil }, authorize: { .init(folder: $0) },
            availability: { $0.map { .init(id: $0.id, path: $0.path, isMissing: false) } },
            releaseScope: { _ in scan.record("scope-release") }, close: { scan.record("close") },
            scan: { _, _, _, _, _ in scan.run(); return .init(result: 0, count: 1) }
        )
        await AudioAnalysisRepository.shared.resume()
        BlockingWorkRegistry.hostFiles.resume()
        let store = AppStore(backend: backend, preferences: preferences, startsRefinement: false,
                             watchSource: source.source, searchBackend: { _, _ in SearchOutcome(needsRefinement: false) })
        store.bootstrap()
        await store.waitUntilStarted()
        await until { scan.events.contains("scan-start") }
        store.search("foreground request")
        precondition(store.indexingPhase == "Waiting for foreground work" && source.stops == 0,
                     "Foreground requests must cancel an automatic scan and keep its watcher alive")
        let obsolete = source.receive
        var drained = false
        let shutdown = Task { await store.shutdown(); drained = true }
        await until { source.stops == 1 }
        precondition(!drained && !scan.events.contains("close") && !scan.events.contains("scope-release"))
        obsolete?(.init(requiresFullScan: true))
        scan.release()
        await shutdown.value
        precondition(scan.events == ["scan-start", "scan-end", "close", "scope-release"])
        precondition(source.stops == 1)
        print("PASS: native source stops before admitted scanning drains, then core close/scope release")
    }

    private static func nativeEvents() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("wavesearch-native-events-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var observed = false
        guard let stop = LibraryWatchSource.live.start([root.path], { event in
            Task { @MainActor in if event.requiresFullScan || !event.paths.isEmpty { observed = true } }
        }) else {
            FileHandle.standardError.write(Data("FAIL: FSEvents unavailable on this host\n".utf8))
            exit(2)
        }
        defer { stop() }
        try Data([0]).write(to: root.appendingPathComponent("new.wav"))
        await until { observed }
        print("PASS: native FSEvents delivered a disposable audio-file change")
    }
}
