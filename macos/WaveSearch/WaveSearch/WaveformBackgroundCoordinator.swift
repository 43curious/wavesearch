@preconcurrency import AppKit
@preconcurrency import Foundation
import IOKit.ps
import WaveSearchKit

@MainActor
final class BackgroundRefinementCoordinator {
    struct Configuration: Sendable {
        let runtimeLibraryPath: String
        let modelDirectory: String
        let semanticThreads: Int32
    }

    typealias StateProvider = @MainActor () -> RefinementPolicyInput
    typealias FolderProvider = @MainActor () -> [Int32]
    typealias SnapshotHandler = @MainActor (RefinementSnapshot) -> Void

    private var worker: Task<Void, Never>?
    private var drainTask: Task<Void, Never>?
    private var backgroundCancellation: Task<Void, Never>?
    private var isRunning = false
    private var generation = UUID()
    private var activeStep: Task<Void, Never>?
    private var policyWatchdog: Task<Void, Never>?
    private var stateProvider: StateProvider?
    private var folderProvider: FolderProvider?
    private var snapshotHandler: SnapshotHandler?
    private var configuration: Configuration?
    private var memoryPressureSource: DispatchSourceMemoryPressure?
    private var memoryConstrained = false
    private var observers: [(center: NotificationCenter, token: NSObjectProtocol)] = []
    private var schedule = RefinementSchedule()
    private var estimator = RefinementEstimator()
    private var waveformDeferredUntil = Date.distantPast
    private var consecutiveMissingWaveforms = 0
    private var acousticDeferredUntil = Date.distantPast
    private var semanticDeferredUntil = Date.distantPast
    private var acousticNoProgressFolders: Set<Int32> = []
    private var semanticNoProgressFolders: Set<Int32> = []
    private var semanticLoadAttempted = false
    private var semanticProviderError: String?
    private var semanticProviderOwner: UUID?
    private var semanticLoadedByCoordinator: Bool { semanticProviderOwner != nil }
    private var semanticCanBeConfigured = false
    private var lastModelProbe = Date.distantPast
    private var cachedSnapshot: RefinementSnapshot?
    private var lastSnapshotRead = Date.distantPast
    private var lastError: String?

    func start(
        configuration: Configuration,
        stateProvider: @escaping StateProvider,
        folderProvider: @escaping FolderProvider,
        snapshotHandler: @escaping SnapshotHandler
    ) {
        // A restart is supported only after stopAndDrain() has completed.
        precondition(!isRunning && drainTask == nil && worker == nil, "Stop and drain before restarting refinement")
        isRunning = true
        generation = UUID()
        semanticCanBeConfigured = false
        semanticLoadAttempted = false
        semanticProviderError = nil
        schedule = RefinementSchedule()
        estimator = RefinementEstimator()
        lastModelProbe = .distantPast
        self.configuration = configuration
        self.stateProvider = stateProvider
        self.folderProvider = folderProvider
        self.snapshotHandler = snapshotHandler
        installSystemObservers()
        startWorkerIfNeeded()
    }

    func policyDidChange() {
        guard isRunning else { return }
        guard worker != nil else {
            startWorkerIfNeeded()
            return
        }
        guard let stateProvider else { return }
        var input = stateProvider()
        input.memoryConstrained = memoryConstrained
        input.thermalConstrained = Self.thermalConstrained
        input.lowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled
        input.onBattery = Self.isOnBatteryPower
        input.idleSeconds = Self.systemIdleSeconds
        if RefinementPolicy.blocker(for: input) != nil {
            activeStep?.cancel()
            _ = ws_cancel_refinement()
            requestBackgroundCancellation()
        }
    }

    func wake() {
        startWorkerIfNeeded()
    }

    /// An explicit install/retry makes a previously failed provider eligible again.
    func semanticInstallationDidChange() {
        guard isRunning else { return }
        semanticLoadAttempted = false
        semanticProviderError = nil
        lastModelProbe = .distantPast
        lastError = nil
        cachedSnapshot = nil
        semanticDeferredUntil = .distantPast
        semanticNoProgressFolders.removeAll()
        startWorkerIfNeeded()
    }

    func librariesDidChange() {
        guard isRunning else { return }
        resetUnavailableBackoff()
        startWorkerIfNeeded()
    }

    /// Immediately prevents new work; teardown continues asynchronously.
    /// The core must remain initialized until stopAndDrain() returns.
    func stop() {
        guard isRunning else { return }
        isRunning = false
        let stoppedGeneration = generation
        let step = activeStep
        let watchdog = policyWatchdog
        let runningWorker = worker
        let pendingCancellation = backgroundCancellation
        step?.cancel()
        watchdog?.cancel()
        runningWorker?.cancel()
        _ = ws_cancel_refinement()
        memoryPressureSource?.cancel()
        memoryPressureSource = nil
        for observer in observers { observer.center.removeObserver(observer.token) }
        observers.removeAll()
        // Keep ownership until every registered operation (including a load
        // that succeeds after cancellation) has finished. No restart can race
        // this generation's teardown.
        drainTask = Task {
            await AudioAnalysisRepository.shared.cancelBackgroundAnalysis()
            await step?.value
            await runningWorker?.value
            await watchdog?.value
            await pendingCancellation?.value
            // Also cover repository work registered while cancellation began.
            await AudioAnalysisRepository.shared.cancelBackgroundAnalysis()
            await unloadSemanticProvider(ownedBy: stoppedGeneration)
            activeStep = nil
            policyWatchdog = nil
            worker = nil
            backgroundCancellation = nil
            stateProvider = nil
            folderProvider = nil
            snapshotHandler = nil
            drainTask = nil
        }
    }

    /// Await before ws_deinit(). Cancellation of the caller does not skip draining.
    func stopAndDrain() async {
        stop()
        await drainTask?.value
    }

    private func requestBackgroundCancellation() {
        let previous = backgroundCancellation
        backgroundCancellation = Task {
            await previous?.value
            await AudioAnalysisRepository.shared.cancelBackgroundAnalysis()
        }
    }

    private func unloadSemanticProvider(ownedBy owner: UUID) async {
        guard semanticProviderOwner == owner else { return }
        await Task.detached(priority: .utility) { ws_clap_unload() }.value
        if semanticProviderOwner == owner { semanticProviderOwner = nil }
    }

    private func startWorkerIfNeeded() {
        guard isRunning, drainTask == nil, worker == nil, stateProvider != nil, folderProvider != nil else { return }
        worker = Task { [weak self] in
            guard let self else { return }
            await self.run()
        }
    }

    private func run() async {
        defer { if isRunning { worker = nil } }
        while isRunning, !Task.isCancelled {
            await probeSemanticAvailabilityIfNeeded()
            guard isRunning, !Task.isCancelled, let stateProvider, let folderProvider else { return }
            var input = stateProvider()
            let folderIDs = folderProvider()
            input.hasAvailableLibraries = !folderIDs.isEmpty
            input.memoryConstrained = memoryConstrained
            input.thermalConstrained = Self.thermalConstrained
            input.lowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled
            input.onBattery = Self.isOnBatteryPower
            input.idleSeconds = Self.systemIdleSeconds

            if input.mode == .fastOnly, semanticLoadedByCoordinator {
                await unloadSemanticProvider(ownedBy: generation)
                guard isRunning, !Task.isCancelled else { return }
            }
            if input.mode == .fastOnly { semanticLoadAttempted = false }

            if let blocker = RefinementPolicy.blocker(for: input) {
                var snapshot = await snapshotWhileBlocked(mode: input.mode)
                guard isRunning, !Task.isCancelled else { return }
                snapshot.activeQueue = nil
                snapshot.blocker = blocker
                if input.mode == .fastOnly { snapshot.semanticAvailable = false }
                publish(snapshot)
                let delay: Duration
                if case .waitingForIdle = blocker {
                    delay = .milliseconds(400)
                } else {
                    delay = .seconds(2)
                }
                try? await Task.sleep(for: delay)
                continue
            }

            var snapshot = await readSnapshot(mode: input.mode)
            guard isRunning, !Task.isCancelled else { return }
            guard let queue = chooseQueue(snapshot: snapshot) else {
                snapshot.activeQueue = nil
                if hasDeferredPendingWork(snapshot) {
                    snapshot.blocker = .missingLibrary
                } else {
                    snapshot.blocker = snapshot.semanticAvailable ? nil : .semanticProviderUnavailable
                }
                publish(snapshot)
                try? await Task.sleep(for: .seconds(2))
                continue
            }

            snapshot.activeQueue = queue
            snapshot.blocker = nil
            publish(snapshot)
            guard isRunning, !Task.isCancelled else { return }
            let acousticPendingBefore = snapshot.acousticPending
            let semanticPendingBefore = snapshot.semanticPending
            let step = Task { [weak self] in
                guard let self else { return }
                let start = ContinuousClock.now
                let completed: Int64
                switch queue {
                case .waveform:
                    completed = await self.runWaveformStep()
                case .acoustic:
                    completed = await self.runAcousticStep(folderIDs: folderIDs, pendingBefore: acousticPendingBefore)
                case .semantic:
                    completed = await self.runSemanticStep(folderIDs: folderIDs, pendingBefore: semanticPendingBefore)
                }
                if !Task.isCancelled {
                    let elapsed = start.duration(to: .now).components
                    self.estimator.record(queue, items: completed,
                        seconds: Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18)
                }
            }
            activeStep = step
            let watchdog = Task { [weak self] in
                guard let self else { return }
                await self.watchPolicy(whileRunning: step)
            }
            policyWatchdog = watchdog
            await step.value
            watchdog.cancel()
            await watchdog.value
            policyWatchdog = nil
            activeStep = nil
            if !Task.isCancelled { await Task.yield() }
        }
    }

    private func watchPolicy(whileRunning step: Task<Void, Never>) async {
        while !Task.isCancelled, !step.isCancelled {
            try? await Task.sleep(for: .milliseconds(250))
            guard isRunning, !Task.isCancelled, let stateProvider, let folderProvider else { return }
            var input = stateProvider()
            input.hasAvailableLibraries = !folderProvider().isEmpty
            input.memoryConstrained = memoryConstrained
            input.thermalConstrained = Self.thermalConstrained
            input.lowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled
            input.onBattery = Self.isOnBatteryPower
            input.idleSeconds = Self.systemIdleSeconds
            if RefinementPolicy.blocker(for: input) != nil {
                step.cancel()
                _ = ws_cancel_refinement()
                await AudioAnalysisRepository.shared.cancelBackgroundAnalysis()
                return
            }
        }
    }

    private func chooseQueue(snapshot: RefinementSnapshot) -> RefinementQueue? {
        let now = Date()
        let waveformPending = snapshot.waveformPending > 0 && now >= waveformDeferredUntil
        let acousticPending = snapshot.acousticPending > 0 && now >= acousticDeferredUntil
        let semanticPending = (snapshot.semanticPending > 0 || !snapshot.semanticAvailable)
            && semanticCanBeConfigured
            && (!semanticLoadAttempted || snapshot.semanticAvailable)
            && now >= semanticDeferredUntil
        return schedule.next(waveform: waveformPending, acoustic: acousticPending, semantic: semanticPending)
    }

    private func hasDeferredPendingWork(_ snapshot: RefinementSnapshot) -> Bool {
        let now = Date()
        return (snapshot.waveformPending > 0 && now < waveformDeferredUntil)
            || (snapshot.acousticPending > 0 && now < acousticDeferredUntil)
            || (snapshot.semanticPending > 0 && semanticCanBeConfigured && now < semanticDeferredUntil)
    }

    private func probeSemanticAvailabilityIfNeeded() async {
        guard isRunning, !Task.isCancelled, let configuration,
              Date().timeIntervalSince(lastModelProbe) >= 30 else { return }
        lastModelProbe = Date()
        let available = await Task.detached(priority: .utility) {
            !configuration.runtimeLibraryPath.isEmpty
                && FileManager.default.fileExists(atPath: configuration.runtimeLibraryPath)
                && FileManager.default.fileExists(atPath: configuration.modelDirectory)
        }.value
        guard isRunning, !Task.isCancelled else { return }
        if available && !semanticCanBeConfigured { semanticLoadAttempted = false }
        semanticCanBeConfigured = available
    }

    private func snapshotWhileBlocked(mode: RefinementMode) async -> RefinementSnapshot {
        if var cachedSnapshot, Date().timeIntervalSince(lastSnapshotRead) < 5 {
            cachedSnapshot.mode = mode
            return cachedSnapshot
        }
        return await readSnapshot(mode: mode)
    }

    private func readSnapshot(mode: RefinementMode) async -> RefinementSnapshot {
        let status = await Task.detached(priority: .background) { () -> (WSWaveformCacheStatus?, Bool, WSAcousticStatus?, WSSemanticStatus?) in
            var waveform = WSWaveformCacheStatus()
            waveform.struct_size = UInt32(MemoryLayout<WSWaveformCacheStatus>.size)
            let waveformValue = ws_waveform_cache_status(&waveform) == 0 ? waveform : nil
            let waveformWorkDue = ws_waveform_work_pending() == 1
            var acoustic = WSAcousticStatus()
            acoustic.struct_size = UInt32(MemoryLayout<WSAcousticStatus>.size)
            let acousticValue = ws_acoustic_status(&acoustic) == 0 ? acoustic : nil
            var semantic = WSSemanticStatus()
            semantic.struct_size = UInt32(MemoryLayout<WSSemanticStatus>.size)
            let semanticValue = ws_semantic_status(&semantic) == 0 ? semantic : nil
            return (waveformValue, waveformWorkDue, acousticValue, semanticValue)
        }.value
        var snapshot = RefinementSnapshot(mode: mode, activeQueue: nil, blocker: nil)
        snapshot.semanticConfigured = semanticCanBeConfigured
        if let waveform = status.0 {
            snapshot.waveformReady = waveform.universal_count
            snapshot.waveformPending = max(waveform.pending_count, status.1 ? 1 : 0)
        } else if status.1 {
            snapshot.waveformPending = 1
        }
        if let acoustic = status.2 {
            snapshot.acousticReady = acoustic.indexed_count
            snapshot.acousticPending = acoustic.pending_count
            snapshot.acousticFailed = acoustic.failed_count
        }
        if let semantic = status.3 {
            snapshot.semanticReady = semantic.embedded_count
            snapshot.semanticPending = semantic.pending_count
            snapshot.semanticFailed = semantic.failed_count
            snapshot.semanticAvailable = semantic.provider_loaded != 0
        } else {
            snapshot.semanticAvailable = false
        }
        snapshot.lastError = lastError
        snapshot.semanticProviderError = semanticProviderError
        cachedSnapshot = snapshot
        lastSnapshotRead = Date()
        return snapshot
    }

    private func runWaveformStep() async -> Int64 {
        let claimed = await Task.detached(priority: .background) { () -> WSWaveformWorkClaim? in
            var item = WSWaveformWorkClaim()
            item.struct_size = UInt32(MemoryLayout<WSWaveformWorkClaim>.size)
            return ws_waveform_work_claim_v2(&item) == 1 ? item : nil
        }.value
        guard let claimed else {
            waveformDeferredUntil = Date().addingTimeInterval(1)
            return 0
        }
        if Task.isCancelled {
            await release(claimed)
            return 0
        }

        let path = withUnsafeBytes(of: claimed.path) {
            String(cString: $0.baseAddress!.assumingMemoryBound(to: CChar.self))
        }
        let pathExists = await Task.detached(priority: .background) {
            FileManager.default.fileExists(atPath: path)
        }.value
        guard isRunning, !Task.isCancelled else {
            await release(claimed)
            return 0
        }
        guard pathExists else {
            await release(claimed)
            consecutiveMissingWaveforms += 1
            if consecutiveMissingWaveforms >= 8 {
                consecutiveMissingWaveforms = 0
                waveformDeferredUntil = Date().addingTimeInterval(30)
            }
            return 0
        }
        consecutiveMissingWaveforms = 0

        WaveformSignposts.event("BackgroundClaim", fileID: Int(claimed.file_id))
        let file = SoundFile(
            id: Int(claimed.file_id),
            folderId: 0,
            path: path,
            name: URL(fileURLWithPath: path).lastPathComponent,
            durationMs: 0,
            contentHash: claimed.content_hash
        )
        let renewer = Task.detached(priority: .background) {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                guard !Task.isCancelled else { return }
                if ws_waveform_work_renew(claimed.file_id, claimed.claim_token) != 0 { return }
            }
        }
        var completed: Int64 = 0
        do {
            try await AudioAnalysisRepository.shared.backfillUniversal(for: file)
            try Task.checkCancellation()
            await release(claimed)
            completed = 1
            lastError = nil
            WaveformSignposts.event("BackgroundComplete", fileID: file.id)
        } catch is CancellationError {
            await release(claimed)
        } catch {
            if Task.isCancelled {
                await release(claimed)
            } else {
                let detail = String(describing: error)
                let outcome = await Task.detached(priority: .background) {
                    let current = try? WaveformSourceSignature.capture(file, analyzerVersion: AudioAnalyzer.version)
                    let legacyIdentity = claimed.file_size < 0 || claimed.mtime_ns < 0
                    let identityMatches = current?.fileSize == claimed.file_size
                        && current?.modificationNanoseconds == claimed.mtime_ns
                    let permanent = FileManager.default.fileExists(atPath: path) && (legacyIdentity || identityMatches)
                    let failureSize = legacyIdentity ? (current?.fileSize ?? claimed.file_size) : claimed.file_size
                    let failureMtime = legacyIdentity ? (current?.modificationNanoseconds ?? claimed.mtime_ns) : claimed.mtime_ns
                    let result = detail.withCString {
                        ws_waveform_work_fail_v2(
                            claimed.file_id,
                            claimed.content_hash,
                            failureSize,
                            failureMtime,
                            claimed.claim_token,
                            permanent ? 1 : 0,
                            $0
                        )
                    }
                    return (result, permanent)
                }.value
                if outcome.0 != 0 { await release(claimed) }
                if outcome.0 == 0 && outcome.1 { completed = 1 }
                lastError = outcome.1 ? detail : nil
            }
        }
        renewer.cancel()
        await renewer.value
        return Task.isCancelled ? 0 : completed
    }

    private func runAcousticStep(folderIDs: [Int32], pendingBefore: Int64) async -> Int64 {
        guard !Task.isCancelled, let folderID = schedule.nextFolder(for: .acoustic, from: folderIDs) else { return 0 }
        let expectedGeneration = ws_refinement_generation()
        let outcome = await Task.detached(priority: .background) { () -> (Int32, Int64?, String?) in
            let result = ws_acoustic_index_pending_v2(folderID, 1, expectedGeneration)
            var status = WSAcousticStatus()
            status.struct_size = UInt32(MemoryLayout<WSAcousticStatus>.size)
            let pending = ws_acoustic_status(&status) == 0 ? status.pending_count : nil
            return (result, pending, result < 0 ? ifBackendError() : nil)
        }.value
        guard !Task.isCancelled else { return 0 }
        if outcome.0 < 0, outcome.2 != "Cancelled" {
            lastError = outcome.2 ?? "Acoustic refinement failed"
            try? await Task.sleep(for: .seconds(2))
        } else if outcome.0 > 0 || (outcome.1 ?? pendingBefore) < pendingBefore {
            acousticNoProgressFolders.removeAll()
            lastError = nil
        } else if outcome.0 == 0 {
            acousticNoProgressFolders.insert(folderID)
            if Set(folderIDs).isSubset(of: acousticNoProgressFolders) {
                acousticNoProgressFolders.removeAll()
                acousticDeferredUntil = Date().addingTimeInterval(30)
            }
        }
        // One-file calls can also resolve a terminal failure without a ready result.
        return outcome.0 >= 0 ? min(1, max(Int64(outcome.0), pendingBefore - (outcome.1 ?? pendingBefore))) : 0
    }

    private func runSemanticStep(folderIDs: [Int32], pendingBefore: Int64) async -> Int64 {
        guard !Task.isCancelled,
              await ensureSemanticProvider(),
              !Task.isCancelled else { return 0 }
        if pendingBefore == 0 { return 0 }
        guard let folderID = schedule.nextFolder(for: .semantic, from: folderIDs) else { return 0 }
        let expectedGeneration = ws_refinement_generation()
        let outcome = await Task.detached(priority: .background) { () -> (Int32, Int64?, String?) in
            let result = ws_clap_index_pending_v2(folderID, 1, expectedGeneration)
            var status = WSSemanticStatus()
            status.struct_size = UInt32(MemoryLayout<WSSemanticStatus>.size)
            let pending = ws_semantic_status(&status) == 0 ? status.pending_count : nil
            return (result, pending, result < 0 ? ifBackendError() : nil)
        }.value
        guard !Task.isCancelled else { return 0 }
        if outcome.0 < 0, outcome.2 != "Cancelled" {
            lastError = outcome.2 ?? "Semantic refinement failed"
            try? await Task.sleep(for: .seconds(2))
        } else if outcome.0 > 0 || (outcome.1 ?? pendingBefore) < pendingBefore {
            semanticNoProgressFolders.removeAll()
            lastError = nil
        } else if outcome.0 == 0 {
            semanticNoProgressFolders.insert(folderID)
            if Set(folderIDs).isSubset(of: semanticNoProgressFolders) {
                semanticNoProgressFolders.removeAll()
                semanticDeferredUntil = Date().addingTimeInterval(30)
            }
        }
        // One-file calls can also resolve a terminal failure without a ready result.
        return outcome.0 >= 0 ? min(1, max(Int64(outcome.0), pendingBefore - (outcome.1 ?? pendingBefore))) : 0
    }

    private func ensureSemanticProvider() async -> Bool {
        guard isRunning, !Task.isCancelled else { return false }
        let owner = generation
        let status = await Task.detached(priority: .background) { () -> Bool in
            var semantic = WSSemanticStatus()
            semantic.struct_size = UInt32(MemoryLayout<WSSemanticStatus>.size)
            return ws_semantic_status(&semantic) == 0 && semantic.provider_loaded != 0
        }.value
        guard isRunning, !Task.isCancelled, generation == owner else { return false }
        if status { semanticProviderError = nil; return true }
        guard !semanticLoadAttempted, semanticCanBeConfigured, let configuration else { return false }
        semanticLoadAttempted = true
        // This load is registered in activeStep before stop can run. Draining
        // waits for it even though detached work does not inherit cancellation.
        let outcome = await Task.detached(priority: .utility) {
            let result = configuration.runtimeLibraryPath.withCString { runtime in
                configuration.modelDirectory.withCString { model in
                    ws_clap_load(runtime, model, configuration.semanticThreads)
                }
            }
            // The backend error is thread-local: copy it on the loading thread.
            return (result, result != 0 ? ifBackendError() : nil)
        }.value
        if outcome.0 == 0 { semanticProviderOwner = owner }
        guard isRunning, !Task.isCancelled, generation == owner else {
            await unloadSemanticProvider(ownedBy: owner)
            return false
        }
        if outcome.0 == 0 {
            semanticProviderError = nil
            lastError = nil
            return true
        }
        lastError = outcome.1 ?? "Semantic provider could not be loaded"
        semanticProviderError = lastError
        return false
    }

    private func release(_ claim: WSWaveformWorkClaim) async {
        _ = await Task.detached(priority: .background) {
            ws_waveform_work_release(claim.file_id, claim.claim_token)
        }.value
    }

    private func publish(_ value: RefinementSnapshot) {
        var snapshot = value
        snapshot.estimates = estimator.estimates
        let now = Date()
        if now < waveformDeferredUntil { snapshot.deferredQueues.insert(.waveform) }
        if now < acousticDeferredUntil { snapshot.deferredQueues.insert(.acoustic) }
        if now < semanticDeferredUntil { snapshot.deferredQueues.insert(.semantic) }
        snapshotHandler?(snapshot)
    }

    private func resetUnavailableBackoff() {
        guard isRunning else { return }
        lastModelProbe = .distantPast
        waveformDeferredUntil = .distantPast
        consecutiveMissingWaveforms = 0
        acousticDeferredUntil = .distantPast
        semanticDeferredUntil = .distantPast
        acousticNoProgressFolders.removeAll()
        semanticNoProgressFolders.removeAll()
        if !semanticLoadedByCoordinator { semanticLoadAttempted = false }
        policyDidChange()
    }

    private func installSystemObservers() {
        guard memoryPressureSource == nil else { return }
        let source = DispatchSource.makeMemoryPressureSource(
            eventMask: [.normal, .warning, .critical],
            queue: .main
        )
        source.setEventHandler { [weak self, weak source] in
            guard let self, let source else { return }
            self.memoryConstrained = source.data.contains(.warning) || source.data.contains(.critical)
            self.policyDidChange()
        }
        source.resume()
        memoryPressureSource = source

        let center = NotificationCenter.default
        observers.append((center, center.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.policyDidChange() } }))
        observers.append((center, center.addObserver(
            forName: Notification.Name.NSProcessInfoPowerStateDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.policyDidChange() } }))
        let workspaceCenter = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification, NSWorkspace.didWakeNotification] {
            observers.append((workspaceCenter, workspaceCenter.addObserver(
                forName: name,
                object: nil,
                queue: .main
            ) { [weak self] _ in MainActor.assumeIsolated { self?.resetUnavailableBackoff() } }))
        }
    }

    private static var thermalConstrained: Bool {
        switch ProcessInfo.processInfo.thermalState {
        case .serious, .critical: true
        default: false
        }
    }

    private static var systemIdleSeconds: TimeInterval {
        let anyEvent = CGEventType(rawValue: ~UInt32(0))!
        return CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: anyEvent)
    }

    private static var isOnBatteryPower: Bool {
        let info = IOPSCopyPowerSourcesInfo().takeRetainedValue()
        let sources = IOPSCopyPowerSourcesList(info).takeRetainedValue() as Array
        for source in sources {
            guard let description = IOPSGetPowerSourceDescription(info, source).takeUnretainedValue() as? [String: Any],
                  let state = description[kIOPSPowerSourceStateKey] as? String else { continue }
            if state == kIOPSBatteryPowerValue { return true }
            if state == kIOPSACPowerValue { return false }
        }
        return false
    }
}

// Preserve the old type name for source compatibility inside older project files.
typealias WaveformBackgroundCoordinator = BackgroundRefinementCoordinator
