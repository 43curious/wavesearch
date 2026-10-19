import Foundation
import Combine
import AVFoundation
import AppKit
import Observation
import WaveSearchKit

private nonisolated final class Signal: @unchecked Sendable {
    private let lock = NSLock()
    private var fired = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func fire() {
        lock.lock()
        fired = true
        let pending = waiters
        waiters.removeAll()
        lock.unlock()
        for waiter in pending { waiter.resume() }
    }

    func wait() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if fired { lock.unlock(); continuation.resume() }
            else { waiters.append(continuation); lock.unlock() }
        }
    }
}

private nonisolated final class Gate: @unchecked Sendable {
    let entered = Signal()
    private let semaphore = DispatchSemaphore(value: 0)
    func block() {
        precondition(!Thread.isMainThread, "Blocking library work must not run on the UI thread")
        entered.fire()
        semaphore.wait() // Intentionally ignores Task cancellation.
    }
    func release() { semaphore.signal() }
}

private nonisolated final class Events: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [String] = []
    func add(_ entry: String) {
        precondition(!Thread.isMainThread, "Backend operation \(entry) ran on the UI thread")
        lock.lock(); entries.append(entry); lock.unlock()
    }
    var values: [String] { lock.lock(); defer { lock.unlock() }; return entries }
    func count(_ entry: String) -> Int { values.filter { $0 == entry }.count }
}

@main
struct AppStoreLifecycleCheck {
    private static let suite = "WaveSearch-Lifecycle-Check-\(UUID().uuidString)"
    private static let preferences = UserDefaults(suiteName: suite)!
    private static let folder = LibraryFolder(id: 1, name: "Fixture", path: "/fixture", fileCount: 3, isMissing: false)

    @MainActor static func main() async throws {
        defer { preferences.removePersistentDomain(forName: suite) }
        // Timeout is only a deadlock backstop, not a latency assertion.
        DispatchQueue.global().asyncAfter(deadline: .now() + 30) {
            FileHandle.standardError.write(Data("FAIL: lifecycle check timed out\n".utf8))
            exit(2)
        }
        try savedPreferencesRemainCompatible()
        try await appearancePreferencesPersistAndRefresh()
        await registryDrainsUncooperativeWork()
        await startupIsAsyncAndIdempotent()
        await shutdownWaitsForOpening()
        await failedStartupCanRetry()
        await shutdownBeforeStartup()
        await removalDrainsHostWork()
        await shutdownWaitsForRemoval()
        await failedRemovalPreservesLibrary()
        await shutdownDrainsPendingRecovery()
        await availabilityIsCachedCoalescedAndFresh()
        await lexicalResultsPrecedeRefinementDebounce()
        await searchesAreBoundedStagedAndDrained()
        await browsingAppendsPagesAndRetries()
        await playbackPreparationIsBoundedAndDrained()
        try await editorClipboardPublication()
        try await selectionAuditioning()
        try await externalAudioExamples()
        try await liveLibrarySmokeTest()
        try await refinementProgressesBeforeWaveformBacklogDrains()
        try await waveformDragExportsRealSelectionURL()
        print("PASS: library lifecycle (startup, removal, shutdown, blocked work, availability, preferences)")
    }

    private static func fakeBackend(_ events: Events) -> LibraryBackend {
        let folder = folder
        return LibraryBackend(
            open: { _, _ in
                events.add("open")
                return .init(opened: true, folders: [folder], scopes: [1: URL(fileURLWithPath: "/fixture")])
            },
            remove: { _ in events.add("remove"); return nil },
            authorize: { .init(folder: $0) },
            availability: { folders in
                events.add("probe")
                return folders.map { .init(id: $0.id, path: $0.path, isMissing: false) }
            },
            releaseScope: { _ in events.add("release") },
            close: { events.add("close") }
        )
    }

    private static func makeStore(_ backend: LibraryBackend,
                                  searchBackend: @escaping SearchRequest.Backend = { SearchRequest.execute($0, lexicalOnly: $1) },
                                  searchRefinementWait: @escaping SearchRequest.RefinementWait = { try await SearchRequest.waitForRefinement(until: $0) }) async -> AppStore {
        // The production app owns one store. Tests exercise successive lifetimes.
        await AudioAnalysisRepository.shared.resume()
        BlockingWorkRegistry.hostFiles.resume()
        return AppStore(storageDirectory: URL(fileURLWithPath: NSTemporaryDirectory()),
                        backend: backend, preferences: preferences, startsRefinement: false, watchesLibraries: false, searchBackend: searchBackend,
                        searchRefinementWait: searchRefinementWait)
    }

    private static func startedStore(_ backend: LibraryBackend) async -> AppStore {
        let store = await makeStore(backend)
        store.bootstrap()
        await store.waitUntilStarted()
        await store.waitForAvailability()
        precondition(store.isReady)
        return store
    }

    private static func waitForShutdownAdmission(_ store: AppStore) async {
        for await stopping in store.$isShuttingDown.values where stopping { return }
    }

    private static func savedPreferencesRemainCompatible() throws {
        let old = Data(#"[{"id":1,"name":"Fixture","path":"/fixture","fileCount":3}]"#.utf8)
        let decoded = try JSONDecoder().decode([LibraryFolder].self, from: old)
        precondition(decoded[0].isMissing, "Unprobed availability must be conservative")
        let saved = String(decoding: try JSONEncoder().encode([folder]), as: UTF8.self)
        precondition(!saved.contains("isMissing"), "Availability is not persisted")
    }

    private static func registryDrainsUncooperativeWork() async {
        let registry = BlockingWorkRegistry()
        let oldGeneration = registry.generation
        let gate = Gate()
        let operation = Task { await registry.run { gate.block(); return 42 } }
        await gate.entered.wait()
        operation.cancel()
        registry.suspend()
        precondition(registry.activeCount == 1, "Cancel does not mean complete")
        let rejected: Int? = await registry.run { preconditionFailure("Admission after suspend") }
        precondition(rejected == nil)
        let drain1 = Task { await registry.suspendAndDrain() }
        let drain2 = Task { await registry.suspendAndDrain() }
        drain1.cancel()
        gate.release()
        let result = await operation.value
        precondition(result == 42)
        await drain1.value
        await drain2.value
        precondition(registry.activeCount == 0)
        registry.resume()
        let obsolete: Int? = await registry.run(expectedGeneration: oldGeneration) {
            preconditionFailure("Old scheduled work admitted after suspend/resume")
        }
        precondition(obsolete == nil)
        let resumed = await registry.run { 7 }
        precondition(resumed == 7)
    }

    private static func startupIsAsyncAndIdempotent() async {
        let events = Events(), open = Gate(), close = Gate()
        var backend = fakeBackend(events)
        let initialOpen = backend.open
        backend.open = { path, data in open.block(); return initialOpen(path, data) }
        backend.close = { close.block(); events.add("close") }
        let store = await makeStore(backend)
        store.bootstrap()
        store.bootstrap()
        await open.entered.wait()
        // Executing this assertion on MainActor while open is blocked proves responsiveness.
        precondition(!store.isReady && !store.canModifyLibraries)
        open.release()
        await store.waitUntilStarted()
        precondition(store.isReady)
        store.bootstrap()
        precondition(events.count("open") == 1)
        let shutdown = Task { await store.shutdown() }
        await close.entered.wait()
        precondition(store.isShuttingDown && !store.isReady)
        precondition(events.count("release") == 0)
        close.release()
        await shutdown.value
        await store.shutdown()
        precondition(events.count("close") == 1 && events.count("release") == 1)
    }

    private static func shutdownWaitsForOpening() async {
        let events = Events(), open = Gate()
        var backend = fakeBackend(events)
        let initialOpen = backend.open
        backend.open = { path, data in open.block(); return initialOpen(path, data) }
        let store = await makeStore(backend)
        store.bootstrap()
        await open.entered.wait()
        let shutdown = Task { await store.shutdown() }
        await waitForShutdownAdmission(store)
        precondition(events.count("close") == 0)
        store.bootstrap() // Cannot register another initialization while terminating.
        open.release()
        await shutdown.value
        precondition(!store.isReady && store.folders.isEmpty)
        precondition(events.values == ["open", "close", "release"])
    }

    private static func failedStartupCanRetry() async {
        let events = Events()
        var backend = fakeBackend(events)
        backend.open = { _, _ in
            events.add("open")
            return .init(opened: events.count("open") > 1, error: events.count("open") == 1 ? "Fixture open error" : nil)
        }
        let store = await makeStore(backend)
        store.bootstrap()
        await store.waitUntilStarted()
        precondition(!store.isReady && store.lastBackendError == "Fixture open error")
        store.bootstrap()
        await store.waitUntilStarted()
        precondition(store.isReady && store.lastBackendError == nil && events.count("open") == 2)
        await store.shutdown()
        precondition(events.count("close") == 1)
    }

    private static func shutdownBeforeStartup() async {
        let events = Events()
        let store = await makeStore(fakeBackend(events))
        await store.shutdown()
        store.bootstrap()
        await store.waitUntilStarted()
        precondition(events.values.isEmpty && !store.canUseLibrary)
    }

    private static func removalDrainsHostWork() async {
        let events = Events(), host = Gate(), removal = Gate()
        var backend = fakeBackend(events)
        backend.remove = { _ in
            precondition(events.count("host-finished") == 1, "Remove raced a host file reader")
            removal.block()
            events.add("remove")
            return nil
        }
        let store = await startedStore(backend)
        let reading = Task {
            await BlockingWorkRegistry.hostFiles.run { host.block(); events.add("host-finished") }
        }
        await host.entered.wait()
        store.removeFolder(folder)
        precondition(store.isLibraryChanging && !store.canModifyLibraries)
        store.removeFolder(folder) // Overlapping removal is rejected.
        host.release()
        await removal.entered.wait()
        precondition(store.folders.count == 1 && events.count("release") == 0)
        removal.release()
        await store.waitForLibraryChange()
        _ = await reading.value
        precondition(store.folders.isEmpty && store.canModifyLibraries)
        precondition(events.count("remove") == 1 && events.count("release") == 1)
        await store.shutdown()
        precondition(events.count("release") == 1)
    }

    private static func shutdownWaitsForRemoval() async {
        let events = Events(), removal = Gate()
        var backend = fakeBackend(events)
        backend.remove = { _ in removal.block(); events.add("remove"); return nil }
        let store = await startedStore(backend)
        store.removeFolder(folder)
        await removal.entered.wait()
        let shutdown = Task { await store.shutdown() }
        await waitForShutdownAdmission(store)
        precondition(events.count("close") == 0)
        removal.release()
        await shutdown.value
        precondition(events.count("close") == 1 && events.count("release") == 1)
        precondition(!store.canUseLibrary)
    }

    private static func failedRemovalPreservesLibrary() async {
        let events = Events()
        var backend = fakeBackend(events)
        backend.remove = { _ in events.add("remove"); return "Fixture removal error" }
        let store = await startedStore(backend)
        store.removeFolder(folder)
        await store.waitForLibraryChange()
        precondition(store.canModifyLibraries && store.folders.count == 1)
        precondition(store.lastBackendError == "Fixture removal error")
        precondition(events.count("release") == 0)
        await store.shutdown()
    }

    private static func shutdownDrainsPendingRecovery() async {
        let events = Events(), reader = Gate()
        let store = await startedStore(fakeBackend(events))
        let reading = Task {
            await BlockingWorkRegistry.hostFiles.run { reader.block(); events.add("host-finished") }
        }
        await reader.entered.wait()
        store.clearWaveformCache()
        let shutdown = Task { await store.shutdown() }
        await waitForShutdownAdmission(store)
        precondition(events.count("close") == 0)
        reader.release()
        await shutdown.value
        _ = await reading.value
        precondition(store.recoveryError == nil, "Recovery ran against the fake backend after shutdown admission")
        precondition(events.count("close") == 1 && events.count("release") == 1)
    }

    private static func appearancePreferencesPersistAndRefresh() async throws {
        let appearance = AppearancePreferences(preferences: preferences)
        appearance.mode = .dark
        appearance.accent = PreferenceColor(red: 0.8, green: 0.3, blue: 0.2)
        appearance.waveform = PreferenceColor(red: 0.7, green: 0.4, blue: 0.9)
        let reopened = AppearancePreferences(preferences: preferences)
        precondition(reopened.mode == .dark && reopened.accent == appearance.accent && reopened.waveform == appearance.waveform,
                     "Appearance preferences did not survive reopening")
        let changed = Signal()
        withObservationTracking { _ = reopened.accent } onChange: { changed.fire() }
        reopened.accent = PreferenceColor(red: 0.1, green: 0.2, blue: 0.3)
        await changed.wait()
        reopened.resetColors()
        let reset = AppearancePreferences(preferences: preferences)
        precondition(reset.accent == AppearancePreferences.defaultAccent && reset.waveform == AppearancePreferences.defaultWaveform)
        let invalid = try JSONEncoder().encode(PreferenceColor(red: 2, green: 0, blue: 0))
        preferences.set(invalid, forKey: "ws_accent_color_v1")
        precondition(AppearancePreferences(preferences: preferences).accent == AppearancePreferences.defaultAccent,
                     "Invalid saved color was not replaced by its default")
        print("PASS: appearance preferences persist, invalidate observation, reset, and recover invalid colors")
    }

    private static func playbackPreparationIsBoundedAndDrained() async {
        let first = Gate(), newest = Gate(), events = Events()
        let player = PlayerController(prepare: { url in
            events.add(url.lastPathComponent)
            if url.lastPathComponent == "A" { first.block() } else { newest.block() }
            precondition(Task.isCancelled, "Stop/replacement must reach detached playback preparation")
            return nil
        })
        func file(_ name: String) -> SoundFile {
            SoundFile(id: 1, folderId: 1, path: "/fixture/\(name)", name: name, durationMs: 0, contentHash: 1)
        }
        player.load(file("A"))
        await first.entered.wait()
        player.load(file("B"))
        player.load(file("C"))
        precondition(events.values == ["A"])
        first.release()
        await newest.entered.wait()
        precondition(events.values == ["A", "C"] && player.currentFile?.name == "C")
        var drained = false
        let entered = Signal()
        let drain = Task {
            entered.fire()
            await player.stopAndDrain()
            drained = true
        }
        await entered.wait()
        precondition(!drained && player.currentFile == nil)
        player.load(file("D")) // A delayed view task cannot restart a suspended player.
        precondition(player.currentFile == nil)
        newest.release()
        await drain.value
        precondition(drained && events.values == ["A", "C"])
    }

    private static func selectionAuditioning() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("wavesearch-audition-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = "wavesearch-audition-\(UUID().uuidString)"
        let prefs = UserDefaults(suiteName: suite)!
        defer { prefs.removePersistentDomain(forName: suite) }
        try await Task.detached {
            let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1)!
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48000)!
            buffer.frameLength = 48000
            buffer.floatChannelData![0].initialize(repeating: 0, count: 48000)
            for name in ["A", "B", "C", "D"] {
                let file = try AVAudioFile(forWriting: root.appendingPathComponent("\(name).wav"), settings: format.settings)
                try file.write(from: buffer)
            }
        }.value
        let first = Gate(), latest = Gate(), paused = Gate(), events = Events()
        let player = PlayerController(preferences: prefs, prepare: { url in
            let name = url.deletingPathExtension().lastPathComponent
            events.add(name)
            // Return a real player even after cancellation to exercise stale delivery.
            if events.count(name) == 1 {
                if name == "A" { first.block() }
                if name == "C" { latest.block() }
                if name == "D" { paused.block() }
            }
            guard let native = try? AVAudioPlayer(contentsOf: url) else { return nil }
            native.enableRate = true
            native.prepareToPlay()
            return PreparedPreviewPlayer(native)
        })
        func file(_ name: String, id: Int = 1) -> SoundFile {
            SoundFile(id: id, folderId: 1, path: root.appendingPathComponent("\(name).wav").path,
                      name: "\(name).wav", durationMs: 1000, contentHash: Int64(id))
        }
        func ready() async {
            let deadline = ContinuousClock.now.advanced(by: .seconds(3))
            while player.isPreparing && ContinuousClock.now < deadline {
                try? await Task.sleep(for: .milliseconds(2))
            }
            precondition(!player.isPreparing, "Playback preparation did not complete")
        }
        precondition(!player.autoplayOnSelect)
        player.setVolume(0)
        player.load(file("A"), autoplay: true)
        await first.entered.wait()
        player.load(file("B"), autoplay: true)
        player.load(file("C"), autoplay: true)
        player.seek(to: 0.25)
        player.markIn()
        player.seek(to: 0.45)
        player.markOut()
        player.playFromSelectionStart() // Return during preparation must be remembered.
        precondition(player.selection == 0.25...0.45 && !player.isPlaying)
        first.release()
        await latest.entered.wait()
        precondition(events.values == ["A", "C"] && !player.isPlaying)
        latest.release()
        await ready()
        precondition(player.currentFile?.name == "C.wav" && player.isPlaying && player.progress >= 0.25,
                     "Only the newest prepared source should autoplay from its in point")
        player.setPreviewRate(.double)
        try await Task.sleep(for: .milliseconds(240))
        precondition(!player.isPlaying && abs(player.progress - 0.45) < 0.001,
                     "Non-looping preview did not stop at the out point")
        player.setLoops(true)
        player.playFromSelectionStart()
        try await Task.sleep(for: .milliseconds(300))
        precondition(player.isPlaying && player.progress >= 0.25 && player.progress < 0.55,
                     "Range loop failed: playing=\(player.isPlaying) progress=\(player.progress)")
        player.setSelection(nil)
        player.playFromSelectionStart()
        try await Task.sleep(for: .milliseconds(650))
        precondition(player.isPlaying && player.progress < 1, "Native whole-file looping stopped at EOF")
        player.setLoops(false)
        player.stopPlayback()
        player.load(file("D"), autoplay: true)
        await paused.entered.wait()
        precondition(player.selection == nil)
        player.stopPlayback()
        paused.release()
        await ready()
        precondition(!player.isPlaying, "Pause during preparation did not revoke queued playback")
        player.setAutoplayOnSelect(true)
        precondition(PlayerController(preferences: prefs).autoplayOnSelect, "Autoplay preference did not persist")
        // Warm generated WAVs; this measures the native play() handoff, not
        // physical audio output or cold/removable-storage first-audio latency.
        var samples: [Double] = []
        for index in 0..<5 {
            let started = ContinuousClock.now
            player.load(file("A", id: index + 10))
            await ready()
            precondition(player.isPlaying)
            let elapsed = started.duration(to: .now).components
            samples.append(Double(elapsed.seconds) * 1000 + Double(elapsed.attoseconds) / 1e15)
        }
        samples.sort()
        print("audition warm_generated_wav selection_to_play_handoff_ms p50=\(samples[2]) p95=\(samples[4])")
        await player.stopAndDrain()
        precondition(!player.isPlaying && player.currentFile == nil && player.selection == nil)
        print("PASS: newest-source autoplay, deferred Return, in/out marks, range/whole-file loops, rate, pause and drain")
    }

    private static func lexicalResultsPrecedeRefinementDebounce() async {
        let events = Events(), waiting = Signal(), resume = Signal()
        let marker = SoundFile(id: 1, folderId: 1, path: "/fixture/impact.wav", name: "Impact", durationMs: 0, contentHash: 1)
        let store = await makeStore(fakeBackend(events), searchBackend: { request, lexical in
            if case .text = request.kind {
                events.add(lexical ? "lexical" : "hybrid")
                return SearchOutcome(files: [marker], needsRefinement: lexical)
            }
            return SearchOutcome(needsRefinement: false)
        }, searchRefinementWait: { _ in
            waiting.fire()
            await resume.wait()
            try Task.checkCancellation()
        })
        store.bootstrap()
        await store.waitUntilStarted()
        store.search("impact")
        await waiting.wait()
        precondition(store.results == [marker] && store.isSearching,
                     "Filename results must be visible while semantic refinement is debounced")
        precondition(events.count("hybrid") == 0, "Semantic refinement must wait for the debounce")
        store.search("")
        resume.fire()
        await store.waitForSearch()
        precondition(events.count("hybrid") == 0, "Superseded refinement must never start")
        await store.shutdown()
    }

    private static func searchesAreBoundedStagedAndDrained() async {
        let events = Events(), hybrid = Gate(), browse = Gate(), example = Gate()
        let marker = SoundFile(id: 1, folderId: 1, path: "/fixture/lexical.wav", name: "Lexical", durationMs: 0, contentHash: 1)
        let store = await makeStore(fakeBackend(events), searchBackend: { request, lexical in
            switch request.kind {
            case .text(let text):
                events.add("\(text)-\(lexical ? "lexical" : "hybrid")")
                if lexical { return SearchOutcome(files: [marker]) }
                hybrid.block()
            case .browse, .browseMore:
                events.add("browse")
                browse.block()
            case .example:
                events.add("example")
                example.block()
            }
            // After cancellation the real C boundary must reject even a call
            // that has not been dispatched yet, without touching the fake DB.
            let cancelled = SearchRequest.execute(request, lexicalOnly: lexical)
            precondition(cancelled.cancelled, "Replacement did not signal the real C request")
            return SearchOutcome(error: "obsolete failure") // Ignore cancellation deliberately.
        })
        store.bootstrap()
        await store.waitUntilStarted()
        store.search("A")
        await hybrid.entered.wait()
        precondition(store.results == [marker] && store.isSearching, "Lexical stage must precede hybrid completion")
        store.search("B")
        store.search("C")
        store.selectedFolderId = 1
        store.search("") // Browse replaces the pending text requests on the SAME worker.
        precondition(events.count("browse") == 0)
        hybrid.release()
        await browse.entered.wait()
        precondition(events.count("B-lexical") == 0 && events.count("C-lexical") == 0)
        precondition(store.lastBackendError == nil && store.results == [marker])
        store.searchByExample(marker)
        store.searchByExample(marker) // Only the newest example may start.
        precondition(events.count("example") == 0)
        browse.release()
        await example.entered.wait()
        let shutdown = Task { await store.shutdown() }
        await waitForShutdownAdmission(store)
        precondition(events.count("close") == 0, "Shutdown must drain the active native search")
        example.release()
        await shutdown.value
        precondition(events.count("example") == 1 && events.count("close") == 1)
        precondition(store.lastBackendError == nil, "Obsolete failures must not publish")
    }

    private static func editorClipboardPublication() async throws {
        BlockingWorkRegistry.hostFiles.resume()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("wavesearch-clipboard-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.wav")
        let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 2048)!
        buffer.frameLength = 2048
        buffer.floatChannelData![0].initialize(repeating: 0.25, count: 2048)
        do {
            let audio = try AVAudioFile(forWriting: source, settings: format.settings)
            try audio.write(from: buffer)
        }
        let file = SoundFile(id: 1, folderId: 1, path: source.path, name: "source.wav", durationMs: 43, contentHash: 1)
        // Capture publication without requiring the system pasteboard service.
        var published: URL?
        let clipboard = AudioImportClipboard(writeURL: { published = $0; return true })
        clipboard.copy(file: file, range: 0.25...0.75, behavior: .keepInPlace)
        while clipboard.isCopying { await Task.yield() }
        precondition(published == source, "Keyboard copy must retain the full original URL in keep-in-place mode")
        clipboard.copy(file: file, range: 0.25...0.75, behavior: .copyToExports)
        while clipboard.isCopying { await Task.yield() }
        let output = published!
        defer { try? FileManager.default.removeItem(at: output) }
        let clip = try AVAudioFile(forReading: output)
        precondition(clip.length == 1024 && clip.fileFormat.streamDescription.pointee.mBitsPerChannel == 24,
                     "Keyboard copy must export the same PCM24 range as dragging")
        published = nil
        clipboard.copy(file: file, range: nil, behavior: .keepInPlace)
        clipboard.cancel()
        await Task.yield()
        precondition(published == nil, "Canceled selection must not replace the clipboard")
        clipboard.copy(file: file, range: nil, behavior: .keepInPlace)
        await BlockingWorkRegistry.hostFiles.suspendAndDrain()
        BlockingWorkRegistry.hostFiles.resume()
        while clipboard.isCopying { await Task.yield() }
        precondition(published == nil, "Work from an older library generation must not replace the clipboard")
        var stillSelected = true
        clipboard.copy(file: file, range: nil, behavior: .keepInPlace, canPublish: { stillSelected })
        stillSelected = false
        while clipboard.isCopying { await Task.yield() }
        precondition(published == nil, "A changed selection must reject publication even before its view disappears")
        precondition(FileManager.default.fileExists(atPath: source.path))
        print("PASS: keyboard editor copy preserves original URLs, trims PCM24 ranges, and rejects canceled/obsolete requests")
    }

    private static func waveformDragExportsRealSelectionURL() async throws {
        BlockingWorkRegistry.hostFiles.resume()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("wavesearch-drag-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("stereo source.wav")
        let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 2048)!
        buffer.frameLength = 2048
        for channel in 0..<2 {
            for frame in 0..<2048 { buffer.floatChannelData![channel][frame] = channel == 0 ? 0.25 : -0.25 }
        }
        do {
            let audio = try AVAudioFile(forWriting: source, settings: format.settings)
            try audio.write(from: buffer)
        }
        let file = SoundFile(id: 1, folderId: 1, path: source.path, name: source.lastPathComponent, durationMs: 43, contentHash: 1)
        precondition(AudioImportBehavior.current(preferences: preferences) == .keepInPlace)
        preferences.set(AudioImportBehavior.copyToExports.rawValue, forKey: AudioImportBehavior.preferenceKey)
        precondition(AudioImportBehavior.current(preferences: preferences) == .copyToExports)
        preferences.removeObject(forKey: AudioImportBehavior.preferenceKey)

        let originalPayload = try await dragPayloadForClip(
            file: file, startFraction: 0.25, endFraction: 0.75, behavior: .keepInPlace
        )
        let pasteboard = NSPasteboard(name: .init("wavesearch-drag-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        precondition(pasteboard.writeObjects([originalPayload.writer]))
        let originals = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]
        precondition(originals == [source], "Keep-in-place waveform drags must reference the original file")

        func providerURL(_ behavior: AudioImportBehavior) async throws -> URL {
            let provider = itemProviderForAudioImport(file, behavior: behavior)
            return try await withCheckedThrowingContinuation { continuation in
                provider.loadObject(ofClass: NSURL.self) { object, error in
                    if let url = object as? URL { continuation.resume(returning: url) }
                    else { continuation.resume(throwing: error ?? CocoaError(.fileReadUnknown)) }
                }
            }
        }
        let originalRowURL = try await providerURL(.keepInPlace)
        precondition(originalRowURL == source, "Result-row drags must reference the original file")
        let copiedURL = try await providerURL(.copyToExports)
        defer { try? FileManager.default.removeItem(at: copiedURL) }
        precondition(copiedURL != source && copiedURL.deletingLastPathComponent() == AudioClipStorage.directory)
        let originalData = try Data(contentsOf: source)
        let copiedData = try Data(contentsOf: copiedURL)
        precondition(copiedData == originalData, "Whole-file imports must copy the original bytes")
        let fullWaveformURL = try await audioImportURL(file: file, behavior: .copyToExports)
        defer { try? FileManager.default.removeItem(at: fullWaveformURL) }
        precondition(fullWaveformURL != copiedURL, "Separate copies must never overwrite previously imported media")
        let fullWaveformData = try Data(contentsOf: fullWaveformURL)
        precondition(fullWaveformData == originalData)
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await audioImportURL(file: file, behavior: .keepInPlace)
        }
        do {
            _ = try await cancelled.value
            preconditionFailure("Cancelled imports must not publish a URL")
        } catch is CancellationError {}
        precondition(FileManager.default.fileExists(atPath: source.path), "Cancellation must never remove the original")

        let payload = try await dragPayloadForClip(
            file: file, startFraction: 0.25, endFraction: 0.75, behavior: .copyToExports
        )
        pasteboard.clearContents()
        precondition(pasteboard.writeObjects([payload.writer]))
        let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]
        precondition(urls?.count == 1, "Waveform drag must supply an existing file URL, not only a Finder file promise")
        let outputURL = urls![0]
        defer { try? FileManager.default.removeItem(at: outputURL) }
        precondition(outputURL != source && FileManager.default.fileExists(atPath: outputURL.path))
        let clip = try AVAudioFile(forReading: outputURL)
        precondition(clip.length == 1024 && clip.fileFormat.sampleRate == 48000 && clip.fileFormat.channelCount == 2)
        let stream = clip.fileFormat.streamDescription.pointee
        precondition(stream.mBitsPerChannel == 24 && stream.mFormatFlags & kAudioFormatFlagIsFloat == 0, "Editor exports must use PCM24 WAV")
        let read = AVAudioPCMBuffer(pcmFormat: clip.processingFormat, frameCapacity: 1024)!
        try clip.read(into: read)
        precondition(abs(read.floatChannelData![0][0] - 0.25) < 0.000001 && abs(read.floatChannelData![1][0] + 0.25) < 0.000001)
        precondition(!outputURL.path.hasPrefix(FileManager.default.temporaryDirectory.path), "A project may reference the exported clip after temporary files are cleaned")
        print("PASS: original import URLs, persistent whole-file copies, trimmed PCM24 selections, import preference")
    }

    private static func browsingAppendsPagesAndRetries() async {
        let events = Events()
        let files = (1...213).map { i in
            SoundFile(id: i, folderId: 1, path: "/fixture/\(i).wav", name: String(format: "file-%03d.wav", i), durationMs: 100, contentHash: Int64(i))
        }
        let store = await makeStore(fakeBackend(events), searchBackend: { request, _ in
            switch request.kind {
            case .browse:
                return SearchOutcome(files: Array(files.prefix(200)), needsRefinement: false, hasMore: true)
            case .browseMore(let after):
                precondition(after.id == 200 && request.folderID == 1)
                events.add("page")
                if events.count("page") == 1 { return SearchOutcome(error: "retry page", needsRefinement: false) }
                return SearchOutcome(files: Array(files.suffix(13)), needsRefinement: false)
            default: return SearchOutcome(needsRefinement: false)
            }
        })
        store.bootstrap()
        await store.waitUntilStarted()
        store.selectedFolderId = 1
        store.search("")
        await store.waitForSearch()
        precondition(store.results.count == 200 && store.canBrowseMore)
        store.loadMore()
        await store.waitForSearch()
        precondition(store.results.count == 200 && store.canBrowseMore, "Failed page lost existing rows or disabled retry")
        store.loadMore()
        await store.waitForSearch()
        precondition(store.results.map(\.id) == files.map(\.id) && !store.canBrowseMore, "Pages were missing or duplicated")
        await store.shutdown()
    }

    private static func externalAudioExamples() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("wavesearch-examples-\(UUID().uuidString)")
        let sounds = root.appendingPathComponent("library")
        try FileManager.default.createDirectory(at: sounds, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let wav = sounds.appendingPathComponent("effect.wav")
        let compressed = root.appendingPathComponent("external.caf")
        let invalid = root.appendingPathComponent("broken.mp3")
        let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2)!
        // A varied signal gives the real fingerprint matcher useful landmarks.
        try await Task.detached {
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 144000)!
            buffer.frameLength = buffer.frameCapacity
            for frame in 0..<Int(buffer.frameLength) {
                let t = Double(frame) / 48000
                let phase = 2 * Double.pi * (180 * t + 900 * t * t)
                let value = Float(0.3 * sin(phase) + 0.2 * sin(phase * 1.71))
                buffer.floatChannelData![0][frame] = value
                buffer.floatChannelData![1][frame] = -value * 0.5
            }
            do {
                let file = try AVAudioFile(forWriting: wav, settings: [AVFormatIDKey: kAudioFormatLinearPCM,
                    AVSampleRateKey: 48000, AVNumberOfChannelsKey: 2, AVLinearPCMBitDepthKey: 16])
                try file.write(from: buffer)
            }
            do {
                let file = try AVAudioFile(forWriting: compressed, settings: [AVFormatIDKey: kAudioFormatAppleLossless,
                    AVSampleRateKey: 48000, AVNumberOfChannelsKey: 2, AVEncoderBitDepthHintKey: 16])
                try file.write(from: buffer)
            }
            let pcm = try ExampleAudio.decode(compressed, checkCancellation: {})
            precondition(pcm.frames == 144000 && pcm.channels == 2 && pcm.sampleRate == 48000)
            precondition(pcm.samples.count == 288000 && abs(pcm.samples[2000] + pcm.samples[2001] * 2) < 0.0001,
                         "Host decoding lost stereo interleaving")
            var checks = 0
            do {
                _ = try ExampleAudio.decode(compressed) {
                    checks += 1
                    if checks == 3 { throw CancellationError() }
                }
                preconditionFailure("Decode ignored chunk cancellation")
            } catch is CancellationError {}
            try Data("not an MP3".utf8).write(to: invalid)
        }.value
        await AudioAnalysisRepository.shared.resume()
        BlockingWorkRegistry.hostFiles.resume()
        let store = AppStore(storageDirectory: root.appendingPathComponent("catalog"), preferences: preferences, startsRefinement: false, watchesLibraries: false)
        store.bootstrap()
        await store.waitUntilStarted()
        store.addFolder(at: sounds)
        await store.waitForLibraryChange()
        await store.waitForIndexing()
        precondition(store.folders.count == 1 && store.folders[0].fileCount == 1)
        let indexed = await Task.detached { ws_acoustic_index_pending(-1, 0) }.value
        precondition(indexed >= 0, "Failed to prepare real acoustic matches")
        // Chooser and dropped files use exactly the same URL request path.
        store.searchByExample(url: wav)
        await store.waitForSearch()
        let expected = store.results.map(\.id)
        precondition(expected.count == 1, store.lastBackendError ?? "WAV example did not match itself")
        precondition(store.acceptSearchExamples([compressed]))
        await store.waitForSearch()
        precondition(store.lastBackendError == nil && store.results.map(\.id) == expected,
                     store.lastBackendError ?? "Compressed example lost acoustic parity without CLAP")
        precondition(store.folders[0].fileCount == 1, "External example was imported into the catalog")
        precondition(!store.acceptSearchExamples([wav, compressed]))
        precondition(store.lastBackendError != nil)
        precondition(!store.acceptSearchExamples([URL(string: "https://example.com/audio.wav")!]))
        store.acceptSearchExamples([invalid])
        await store.waitForSearch()
        precondition(store.lastBackendError?.contains("broken.mp3") == true && !store.isSearching)
        store.acceptSearchExamples([invalid])
        store.acceptSearchExamples([compressed])
        await store.waitForSearch()
        precondition(store.lastBackendError == nil && store.results.map(\.id) == expected,
                     "A superseded example published an obsolete failure")
        store.acceptSearchExamples([compressed])
        store.search("effect")
        await store.waitForSearch()
        precondition(!store.isExampleSearch && store.lastBackendError == nil && store.results.map(\.id) == expected)
        await store.shutdown()
        print("PASS: external WAV/ALAC examples, model-free acoustic parity, stereo decode, cancellation, replacement, invalid drops")
    }

    private static func liveLibrarySmokeTest() async throws {
        preferences.removePersistentDomain(forName: suite)
        await AudioAnalysisRepository.shared.resume()
        BlockingWorkRegistry.hostFiles.resume()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("wavesearch-live-\(UUID().uuidString)")
        let sounds = root.appendingPathComponent("sounds")
        try FileManager.default.createDirectory(at: sounds, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        // One valid mono PCM16 sample: enough to exercise real index/count/removal.
        let wav: [UInt8] = [82,73,70,70,38,0,0,0,87,65,86,69,102,109,116,32,
                           16,0,0,0,1,0,1,0,64,31,0,0,128,62,0,0,2,0,16,0,
                           100,97,116,97,2,0,0,0,0,0]
        try Data(wav).write(to: sounds.appendingPathComponent("click.wav"))
        let store = AppStore(storageDirectory: root.appendingPathComponent("catalog"),
                             preferences: preferences, startsRefinement: false, watchesLibraries: false)
        store.bootstrap()
        await store.waitUntilStarted()
        precondition(store.isReady, store.lastBackendError ?? "Live open failed")
        store.addFolder(at: sounds)
        await store.waitForLibraryChange()
        await store.waitForIndexing()
        precondition(store.folders.count == 1 && store.folders[0].fileCount == 1,
                     store.lastBackendError ?? "Live indexing failed")
        store.search("click")
        await store.waitForSearch()
        precondition(store.results.count == 1 && !store.isSearching, store.lastBackendError ?? "Live search failed")
        store.selectedFolderId = store.folders[0].id
        store.search("")
        await store.waitForSearch()
        precondition(store.results.count == 1 && !store.isSearching, "Live browse failed")
        let originalFile = store.results[0]
        store.toggleFavourite(originalFile)
        store.clearWaveformCache()
        await store.waitForLibraryChange()
        precondition(store.recoveryError == nil && store.isReady && store.folders[0].fileCount == 1 && store.isFavourite(originalFile),
                     store.recoveryError ?? "Cache deletion altered the catalog or favourites")
        let backup = root.appendingPathComponent("saved.wavesearchbackup")
        let backupReader = Gate()
        let readingDuringBackup = Task {
            await BlockingWorkRegistry.hostFiles.run { backupReader.block() }
        }
        await backupReader.entered.wait()
        store.createBackup(at: backup)
        precondition(store.isLibraryChanging && !store.canModifyLibraries && !FileManager.default.fileExists(atPath: backup.path))
        backupReader.release()
        await store.waitForLibraryChange()
        _ = await readingDuringBackup.value
        precondition(store.recoveryError == nil && FileManager.default.fileExists(atPath: backup.appendingPathComponent("catalog.sqlite").path),
                     store.recoveryError ?? "Backup was not published")
        let moved = root.appendingPathComponent("moved sounds")
        try FileManager.default.moveItem(at: sounds, to: moved)
        store.reconnectFolder(store.folders[0], to: moved)
        await store.waitForLibraryChange()
        store.search("click")
        await store.waitForSearch()
        precondition(store.recoveryError == nil && store.folders[0].path == moved.path && !store.folders[0].isMissing)
        precondition(store.results[0].id == originalFile.id && store.results[0].path == moved.appendingPathComponent("click.wav").path,
                     "Reconnect lost file identity or retained the old path")
        precondition(store.isFavourite(store.results[0]), "Reconnect lost the favourite")
        store.reconnectFolder(store.folders[0], to: root.appendingPathComponent("absent"))
        await store.waitForLibraryChange()
        precondition(store.recoveryError != nil && store.folders[0].path == moved.path, "Failed reconnect replaced the library")
        let invalid = root.appendingPathComponent("invalid.wavesearchbackup")
        try FileManager.default.createDirectory(at: invalid, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: invalid.appendingPathComponent("manifest.json"))
        store.restoreBackup(at: invalid)
        await store.waitForLibraryChange()
        precondition(store.recoveryError != nil && store.folders[0].path == moved.path, "Invalid backup changed host state")
        // Exercise bounded metadata storage and physical/source identity changes.
        let metadata = AudioMetadataStore.shared
        var inspected: [SoundFile] = []
        for i in 0..<288 {
            let url = root.appendingPathComponent("metadata-\(i).wav")
            try Data(wav).write(to: url)
            inspected.append(SoundFile(id: i + 1, folderId: 1, path: url.path, name: url.lastPathComponent, durationMs: 0, contentHash: Int64(i + 1)))
        }
        for start in stride(from: 0, to: inspected.count, by: 32) {
            let batch = inspected[start..<min(start + 32, inspected.count)]
            for file in batch { metadata.load(file) }
            while batch.contains(where: { metadata.metadata(for: $0) == nil }) { await Task.yield() }
            precondition(metadata.values.count <= 256, "Metadata cache exceeded capacity")
        }
        precondition(metadata.metadata(for: inspected[0]) == nil, "Old metadata was not evicted")
        let last = inspected.last!
        precondition(metadata.metadata(for: last)?.sampleRate == 8000)
        var changed = wav
        changed[24] = 128; changed[25] = 62 // 16 kHz, with corresponding PCM byte rate.
        changed[28] = 0; changed[29] = 125
        try Data(changed).write(to: last.url)
        metadata.load(last)
        while metadata.metadata(for: last)?.sampleRate != 16000 { await Task.yield() }
        let newIdentity = SoundFile(id: last.id, folderId: last.folderId, path: last.path, name: last.name, durationMs: 1, contentHash: 99999)
        precondition(metadata.metadata(for: newIdentity) == nil, "Metadata crossed source identities")
        metadata.load(newIdentity)
        while metadata.metadata(for: newIdentity) == nil { await Task.yield() }
        precondition(metadata.metadata(for: newIdentity)?.sampleRate == 16000)
        store.removeFolder(store.folders[0])
        await store.waitForLibraryChange()
        precondition(store.folders.isEmpty, store.lastBackendError ?? "Live remove failed")
        store.restoreBackup(at: backup)
        await store.waitForLibraryChange()
        precondition(store.recoveryError == nil && store.folders.count == 1 && store.folders[0].path == sounds.path,
                     store.recoveryError ?? "Restore did not recover the library manifest")
        precondition(store.folders[0].isMissing && store.folders[0].fileCount == 1 && store.isFavourite(originalFile))
        store.search("click")
        await store.waitForSearch()
        precondition(store.results.count == 1 && store.results[0].path == originalFile.path, "Restore lost indexed files")
        store.checkIntegrity()
        await store.waitForLibraryChange()
        precondition(store.recoveryError == nil && store.recoveryStatus?.hasPrefix("Passed") == true)
        await store.waitForStorage()
        store.refreshStorage()
        await store.waitForStorage()
        precondition((store.storageUsage?.indexBytes ?? 0) > 0 && (store.storageUsage?.recoveryBytes ?? 0) > 0,
                     store.storageError ?? "Storage sizes were not reported")
        await store.shutdown()
        let corrupt = Data("not a SQLite database".utf8)
        try corrupt.write(to: store.indexURL)
        let recovering = AppStore(storageDirectory: root.appendingPathComponent("catalog"),
                                  preferences: preferences, startsRefinement: false, watchesLibraries: false)
        recovering.bootstrap()
        await recovering.waitUntilStarted()
        precondition(!recovering.isReady && recovering.canRestoreBackup, "Failed startup hid recovery")
        recovering.restoreBackup(at: invalid)
        await recovering.waitForLibraryChange()
        let afterRejectedRecovery = try Data(contentsOf: store.indexURL)
        precondition(!recovering.isReady && recovering.recoveryError != nil && afterRejectedRecovery == corrupt,
                     "Invalid recovery altered an unopened index")
        try Data(contentsOf: backup.appendingPathComponent("manifest.json"))
            .write(to: invalid.appendingPathComponent("manifest.json"))
        try corrupt.write(to: invalid.appendingPathComponent("catalog.sqlite"))
        recovering.restoreBackup(at: invalid)
        await recovering.waitForLibraryChange()
        let afterRejectedCatalog = try Data(contentsOf: store.indexURL)
        precondition(!recovering.isReady && recovering.recoveryError != nil && afterRejectedCatalog == corrupt,
                     "Invalid SQLite recovery altered an unopened index")
        recovering.restoreBackup(at: backup)
        await recovering.waitForLibraryChange()
        precondition(recovering.isReady && recovering.folders.count == 1 && recovering.folders[0].fileCount == 1,
                     recovering.recoveryError ?? "Unopened index was not recovered")
        let retained = try FileManager.default.contentsOfDirectory(at: recovering.recoveryDirectory, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("Unopened-Catalog-") }
        precondition(retained.count == 1, "Original corrupt database was not retained")
        let retainedData = try Data(contentsOf: retained[0].appendingPathComponent("index.db"))
        precondition(retainedData == corrupt, "Retained database changed")
        await recovering.shutdown()
        print("PASS: catalog backup/restore, safety copy, moved library identities/favourites, failed recovery preservation, integrity and storage")
    }

    private static func refinementProgressesBeforeWaveformBacklogDrains() async throws {
        let preferenceSuite = "\(suite)-fairness"
        let isolatedPreferences = UserDefaults(suiteName: preferenceSuite)!
        defer { isolatedPreferences.removePersistentDomain(forName: preferenceSuite) }
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("wavesearch-fairness-\(UUID().uuidString)")
        let sounds = root.appendingPathComponent("sounds")
        try FileManager.default.createDirectory(at: sounds, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        // A valid one-second effect; repeated sources keep the native fixture small.
        var bytes: [UInt8] = [82,73,70,70,164,62,0,0,87,65,86,69,102,109,116,32,
                             16,0,0,0,1,0,1,0,64,31,0,0,128,62,0,0,2,0,16,0,
                             100,97,116,97,128,62,0,0]
        for frame in 0..<8000 {
            let value = Int16(10000 * sin(Double(frame) * (0.15 + Double(frame / 1000) * 0.01)))
            let bits = UInt16(bitPattern: value)
            bytes.append(UInt8(truncatingIfNeeded: bits))
            bytes.append(UInt8(truncatingIfNeeded: bits >> 8))
        }
        for file in 0..<8 { try Data(bytes).write(to: sounds.appendingPathComponent("effect-\(file).wav")) }
        let store = AppStore(storageDirectory: root.appendingPathComponent("catalog"), preferences: isolatedPreferences, startsRefinement: false, watchesLibraries: false)
        store.bootstrap()
        await store.waitUntilStarted()
        precondition(store.isReady)
        store.addFolder(at: sounds)
        await store.waitForLibraryChange()
        await store.waitForIndexing()
        precondition(store.folders.count == 1 && store.folders[0].fileCount == 8)

        let coordinator = BackgroundRefinementCoordinator()
        let progressed = Signal(), paused = Signal()
        var playing = false
        var waveformRemaining: Int64 = 0
        var acousticReady: Int64 = 0
        coordinator.start(
            configuration: .init(runtimeLibraryPath: "", modelDirectory: "", semanticThreads: 1),
            stateProvider: {
                .init(mode: .complete, userPaused: false, metadataScanning: false, searching: false,
                      playing: playing, selectedAnalysis: false, thermalConstrained: false,
                      memoryConstrained: false, lowPowerMode: false, onBattery: false,
                      idleSeconds: 31, hasAvailableLibraries: true)
            },
            folderProvider: { store.folders.map { Int32($0.id) } },
            snapshotHandler: { snapshot in
                if snapshot.acousticReady > 0 {
                    waveformRemaining = snapshot.waveformPending
                    acousticReady = snapshot.acousticReady
                    playing = true
                    progressed.fire()
                }
                if snapshot.blocker == .playback { paused.fire() }
            }
        )
        await progressed.wait()
        coordinator.policyDidChange()
        await paused.wait()
        await coordinator.stopAndDrain()
        precondition(waveformRemaining > 0, "Waveform backlog starved acoustic refinement")
        precondition(acousticReady == 1, "Background selection processed more than one acoustic file")
        await store.shutdown()
        print("PASS: acoustic progress during waveform backlog, playback pause, and refinement drain")
    }

    private static func availabilityIsCachedCoalescedAndFresh() async {
        let events = Events(), first = Gate(), second = Gate()
        var backend = fakeBackend(events)
        backend.availability = { folders in
            events.add("probe")
            if events.count("probe") == 1 { first.block() } else { second.block() }
            return folders.map { .init(id: $0.id, path: $0.path, isMissing: $0.path == "/fixture") }
        }
        let store = await makeStore(backend)
        store.bootstrap()
        await store.waitUntilStarted()
        await first.entered.wait()
        for _ in 0..<100 {
            precondition(!store.folders[0].isMissing)
            store.refreshAvailability()
        }
        precondition(events.count("probe") == 1)
        store.folders[0].path = "/replacement"
        first.release()
        await second.entered.wait()
        precondition(!store.folders[0].isMissing, "Stale path observation was applied")
        second.release()
        await store.waitForAvailability()
        precondition(events.count("probe") == 2 && !store.folders[0].isMissing)
        await store.shutdown()
    }
}
