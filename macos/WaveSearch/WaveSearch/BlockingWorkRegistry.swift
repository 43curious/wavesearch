import Foundation

/// Tracks the lifetime of blocking calls, including detached calls whose Swift
/// caller has been cancelled. This is a drain barrier, not a search scheduler.
@MainActor
final class BlockingWorkRegistry {
    static let hostFiles = BlockingWorkRegistry()

    private var accepting = true
    private(set) var generation: UInt64 = 0
    private var active: [UUID: @Sendable () -> Void] = [:]
    private var waiters: [CheckedContinuation<Void, Never>] = []

    var activeCount: Int { active.count }

    /// Capture generation before scheduling a caller task and pass it here when
    /// that task might arrive after a suspend/resume cycle (e.g. file promises).
    func run<Value: Sendable>(
        priority: TaskPriority = .utility,
        expectedGeneration: UInt64? = nil,
        _ operation: @escaping @Sendable () -> Value
    ) async -> Value? {
        guard accepting, !Task.isCancelled,
              expectedGeneration == nil || expectedGeneration == generation else { return nil }
        let id = UUID()
        let task = Task.detached(priority: priority, operation: operation)
        active[id] = { task.cancel() }
        defer {
            active.removeValue(forKey: id)
            if active.isEmpty {
                let completed = waiters
                waiters.removeAll()
                for waiter in completed { waiter.resume() }
            }
        }
        return await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
    }

    func suspend() {
        if accepting { generation &+= 1 }
        accepting = false
        for cancel in active.values { cancel() }
    }

    /// Suspends admission first, then awaits actual completion. Even a cancelled
    /// drain caller must not bypass the barrier and close resources prematurely.
    func suspendAndDrain() async {
        suspend()
        guard !active.isEmpty else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func resume() {
        precondition(active.isEmpty, "Drain blocking work before resuming")
        accepting = true
    }
}
