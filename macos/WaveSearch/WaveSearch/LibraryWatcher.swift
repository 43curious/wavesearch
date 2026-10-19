import Foundation
import CoreServices

nonisolated struct LibraryWatchEvent: Sendable {
    var paths: [String] = []
    var requiresFullScan = false
}

/// The stop closure drains the native callback queue before returning.
struct LibraryWatchSource {
    var start: ([String], @escaping @Sendable (LibraryWatchEvent) -> Void) -> (() -> Void)?

    static let live = LibraryWatchSource { paths, receive in
        guard let source = NativeLibraryWatcher(paths: paths, receive: receive) else { return nil }
        return { source.stop() }
    }
}

nonisolated private final class WatchCallback: Sendable {
    let receive: @Sendable (LibraryWatchEvent) -> Void
    init(_ receive: @escaping @Sendable (LibraryWatchEvent) -> Void) { self.receive = receive }
}

@MainActor
private final class NativeLibraryWatcher {
    private var stream: FSEventStreamRef?
    private let queue = DispatchQueue(label: "WaveSearch.LibraryEvents", qos: .utility)
    private let callback: WatchCallback

    init?(paths: [String], receive: @escaping @Sendable (LibraryWatchEvent) -> Void) {
        callback = WatchCallback(receive)
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(callback).toOpaque(),
            retain: { info in
                guard let info else { return nil }
                _ = Unmanaged<WatchCallback>.fromOpaque(info).retain()
                return info
            }, release: { info in
                guard let info else { return }
                Unmanaged<WatchCallback>.fromOpaque(info).release()
            }, copyDescription: nil)
        let flags = kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents
            | kFSEventStreamCreateFlagWatchRoot | kFSEventStreamCreateFlagNoDefer
        stream = FSEventStreamCreate(nil, { _, info, count, rawPaths, flags, _ in
            guard let info else { return }
            let callback = Unmanaged<WatchCallback>.fromOpaque(info).takeUnretainedValue()
            let paths = unsafeBitCast(rawPaths, to: NSArray.self)
            let recovery = UInt32(kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagUserDropped
                | kFSEventStreamEventFlagKernelDropped | kFSEventStreamEventFlagEventIdsWrapped
                | kFSEventStreamEventFlagRootChanged | kFSEventStreamEventFlagMount | kFSEventStreamEventFlagUnmount)
            var event = LibraryWatchEvent(requiresFullScan: count > 4096)
            for index in 0..<min(count, 4096) {
                if flags[index] & recovery != 0 { event.requiresFullScan = true }
                guard let path = paths[index] as? String else { event.requiresFullScan = true; continue }
                event.paths.append(path)
            }
            if event.requiresFullScan || !event.paths.isEmpty { callback.receive(event) }
        }, &context, paths as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 1, FSEventStreamCreateFlags(flags))
        guard let stream else { return nil }
        FSEventStreamSetDispatchQueue(stream, queue)
        guard FSEventStreamStart(stream) else {
            FSEventStreamInvalidate(stream)
            queue.sync {}
            FSEventStreamRelease(stream)
            self.stream = nil
            return nil
        }
    }

    func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        queue.sync {} // Callback only copies events and enqueues a MainActor task.
        FSEventStreamRelease(stream)
        self.stream = nil
    }
}

/// FSEvents are invalidation hints. Coalesce by library, then reconcile one
/// complete root through the core's bounded, atomic staging path. No idle timer.
@MainActor
final class LibraryWatchCoordinator {
    private let source: LibraryWatchSource
    private let delay: Duration
    private let reconcile: (Int) -> Bool
    private var roots: [Int: String] = [:]
    private var pending: Set<Int> = []
    private var retryAt: [Int: ContinuousClock.Instant] = [:]
    private var task: Task<Void, Never>?
    private var stopSource: (() -> Void)?
    private var generation: UInt64 = 0
    private var delivering = false
    private var lastServed: Int?
    private(set) var isWatching = false

    init(source: LibraryWatchSource? = nil, delay: Duration = .seconds(2), reconcile: @escaping (Int) -> Bool) {
        self.source = source ?? .live
        self.delay = delay
        self.reconcile = reconcile
    }

    func update(_ folders: [LibraryFolder]) {
        let available = Dictionary(folders.filter { !$0.isMissing }.map {
            ($0.id, URL(fileURLWithPath: $0.path).standardizedFileURL.path)
        }, uniquingKeysWith: { first, _ in first })
        guard roots != available else { return }
        stop()
        roots = available
        guard !roots.isEmpty else { return }
        let generation = generation
        let watchedRoots = roots
        stopSource = source.start(Array(Set(roots.values)).sorted()) { [weak self] event in
            // Native callbacks map even large batches off-main. Only a bounded
            // set of library IDs crosses to the UI actor, not thousands of paths.
            let affected = Self.affectedRoots(event, roots: watchedRoots)
            guard !affected.isEmpty else { return }
            Task { @MainActor in
                guard let self, self.generation == generation else { return }
                self.pending.formUnion(affected)
                self.wake()
            }
        }
        isWatching = stopSource != nil
        // Starting a stream at "now" cannot recover application downtime.
        requestFullReconciliation()
    }

    func receive(_ event: LibraryWatchEvent) {
        pending.formUnion(Self.affectedRoots(event, roots: roots))
        wake()
    }

    nonisolated private static func affectedRoots(_ event: LibraryWatchEvent, roots: [Int: String]) -> Set<Int> {
        if event.requiresFullScan { return Set(roots.keys) }
        var affected: Set<Int> = []
        for path in event.paths {
            let matching = roots.filter { path == $0.value || path.hasPrefix($0.value + "/") }.keys
            // A stream may report a resolved alias or parent/root event.
            if matching.isEmpty { return Set(roots.keys) }
            affected.formUnion(matching)
        }
        return affected
    }

    func requestFullReconciliation() {
        pending.formUnion(roots.keys)
        wake()
    }

    func retry(_ id: Int) {
        guard roots[id] != nil else { return }
        pending.insert(id)
        retryAt[id] = .now.advanced(by: .seconds(30))
        wake()
    }

    func discard(_ id: Int) {
        pending.remove(id)
        retryAt.removeValue(forKey: id)
    }

    /// Call when foreground work or a scan finishes. Busy admission leaves dirty
    /// roots queued without polling until the host signals another opportunity.
    func wake() {
        guard task == nil, !pending.isEmpty, !delivering else { return }
        let wait = pending.map { id in retryAt[id].map { ContinuousClock.now.duration(to: $0) } ?? .zero }.min() ?? .zero
        let pause = max(delay, wait)
        let generation = generation
        task = Task { [weak self] in
            do { try await Task.sleep(for: pause) } catch { return }
            guard let self, self.generation == generation else { return }
            self.task = nil
            self.delivering = true
            let ready = self.pending.sorted().filter { self.retryAt[$0].map { $0 <= .now } ?? true }
            var admitted = false
            let next = ready.first { $0 > (self.lastServed ?? Int.min) } ?? ready.first
            if let id = next, self.reconcile(id) {
                self.discard(id)
                self.lastServed = id
                admitted = true
            }
            self.delivering = false
            if admitted || ready.isEmpty { self.wake() }
        }
    }

    func stop() {
        generation &+= 1
        task?.cancel()
        task = nil
        stopSource?()
        stopSource = nil
        isWatching = false
        roots.removeAll()
        pending.removeAll()
        retryAt.removeAll()
    }
}
