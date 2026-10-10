import Foundation

/// Intentionally ignores Task cancellation. Every operation must be explicitly released.
private actor OperationGate {
    private var releases: [String: CheckedContinuation<Void, Never>] = [:]
    private var startWaiters: [String: [CheckedContinuation<Void, Never>]] = [:]
    private(set) var starts: [String] = []
    private var active = 0
    private(set) var maximumActive = 0

    func run(_ input: String) async -> String {
        starts.append(input)
        active += 1
        maximumActive = max(maximumActive, active)
        let waiters = startWaiters.removeValue(forKey: input) ?? []
        for waiter in waiters { waiter.resume() }
        await withCheckedContinuation { releases[input] = $0 }
        active -= 1
        return input
    }

    func waitForStart(_ input: String) async {
        if starts.contains(input) { return }
        await withCheckedContinuation { startWaiters[input, default: []].append($0) }
    }

    func release(_ input: String) {
        guard let continuation = releases.removeValue(forKey: input) else {
            preconditionFailure("Operation \(input) has not started")
        }
        continuation.resume()
    }
}

private nonisolated final class CancellationLog: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [String] = []

    func append(_ input: String) {
        lock.lock()
        defer { lock.unlock() }
        entries.append(input)
    }

    var values: [String] {
        lock.lock()
        defer { lock.unlock() }
        return entries
    }
}

@MainActor
private final class Observations {
    var outputs: [String] = []
    var activity: [Bool] = []
    var drained = false
}

@main
@MainActor
private enum LatestRequestWorkerCheck {
    static func main() async {
        await replacementAndDrain()
        await cancellationBeforeLaunch()
        await cancellationDuringExecution()
        await receiveReentrancy()
        await activityReentrancy()
        print("latest request worker: passed")
    }

    private static func replacementAndDrain() async {
        let gate = OperationGate()
        let observed = Observations()
        let cancelled = CancellationLog()
        let worker = LatestRequestWorker<String, String>(
            operation: { await gate.run($0) },
            onActivityChange: { observed.activity.append($0) }
        )
        worker.submit("A", cancel: { cancelled.append("A") }) { observed.outputs.append($0) }
        precondition(observed.activity == [true])
        await gate.waitForStart("A")
        worker.submit("B", cancel: { cancelled.append("B") }) { observed.outputs.append($0) }
        precondition(cancelled.values == ["A"], "Cancellation must be synchronous")
        worker.submit("C") { observed.outputs.append($0) }
        precondition(cancelled.values == ["A", "B"])
        let startsBeforeRelease = await gate.starts
        precondition(startsBeforeRelease == ["A"])

        let drainTask = await startDrain(worker, observed: observed)
        precondition(!observed.drained)
        await gate.release("A")
        await gate.waitForStart("C")
        precondition(observed.outputs.isEmpty, "Cancelled output must never be delivered")
        precondition(!observed.drained, "Drain includes newest pending work")
        precondition(observed.activity == [true], "Replacement must not report false idle")
        await gate.release("C")
        await drainTask.value
        precondition(observed.drained)
        precondition(observed.outputs == ["C"])
        precondition(observed.activity == [true, false])
        let starts = await gate.starts
        let maximum = await gate.maximumActive
        precondition(starts == ["A", "C"])
        precondition(maximum == 1)
    }

    private static func cancellationBeforeLaunch() async {
        let observed = Observations()
        let cancelled = CancellationLog()
        let worker = LatestRequestWorker<String, String>(
            operation: { _ in preconditionFailure("Cancelled before launch") },
            onActivityChange: { observed.activity.append($0) }
        )
        worker.submit("A", cancel: { cancelled.append("A") }) { observed.outputs.append($0) }
        worker.submit("B", cancel: { cancelled.append("B") }) { observed.outputs.append($0) }
        worker.cancel()
        worker.cancel()
        precondition(cancelled.values == ["A", "B"])
        precondition(observed.activity == [true])
        await worker.drain()
        precondition(observed.activity == [true, false])
        precondition(observed.outputs.isEmpty)
        await worker.drain() // Already idle is an immediate barrier.
    }

    private static func cancellationDuringExecution() async {
        let gate = OperationGate()
        let observed = Observations()
        let worker = LatestRequestWorker<String, String>(
            operation: { await gate.run($0) },
            onActivityChange: { observed.activity.append($0) }
        )
        worker.submit("A") { observed.outputs.append($0) }
        await gate.waitForStart("A")
        worker.submit("B") { observed.outputs.append($0) }
        worker.cancel()
        let drainTask = await startDrain(worker, observed: observed)
        precondition(!observed.drained)
        precondition(observed.activity == [true])
        await gate.release("A")
        await drainTask.value
        precondition(observed.outputs.isEmpty)
        precondition(observed.activity == [true, false])
        let starts = await gate.starts
        precondition(starts == ["A"])
    }

    private static func receiveReentrancy() async {
        let gate = OperationGate()
        let observed = Observations()
        var worker: LatestRequestWorker<String, String>? = LatestRequestWorker(
            operation: { await gate.run($0) },
            onActivityChange: { observed.activity.append($0) }
        )
        weak var weakWorker = worker
        worker!.submit("A") { output in
            observed.outputs.append(output)
            worker!.submit("B") { observed.outputs.append($0) }
            worker!.submit("C") { observed.outputs.append($0) }
        }
        await gate.waitForStart("A")
        await gate.release("A")
        await gate.waitForStart("C")
        precondition(observed.outputs == ["A"])
        await gate.release("C")
        await worker!.drain()
        precondition(observed.outputs == ["A", "C"])
        precondition(observed.activity == [true, false])
        let starts = await gate.starts
        let maximum = await gate.maximumActive
        precondition(starts == ["A", "C"])
        precondition(maximum == 1)
        worker = nil
        precondition(weakWorker == nil, "Finished task must not retain its worker")
    }

    private static func activityReentrancy() async {
        let gate = OperationGate()
        let observed = Observations()
        var worker: LatestRequestWorker<String, String>?
        worker = LatestRequestWorker(operation: { await gate.run($0) }, onActivityChange: { active in
            observed.activity.append(active)
            if !active, observed.outputs == ["A"] {
                worker!.submit("B") { observed.outputs.append($0) }
            }
        })
        worker!.submit("A") { observed.outputs.append($0) }
        await gate.waitForStart("A")
        let drainTask = await startDrain(worker!, observed: observed)
        await gate.release("A")
        await gate.waitForStart("B")
        precondition(!observed.drained)
        await gate.release("B")
        await drainTask.value
        precondition(observed.outputs == ["A", "B"])
        precondition(observed.activity == [true, false, true, false])
        worker = nil
    }

    /// The handshake resumes only after the drain task has entered the main actor.
    /// It then calls drain without yielding, so assertions cannot race its registration.
    private static func startDrain(
        _ worker: LatestRequestWorker<String, String>, observed: Observations
    ) async -> Task<Void, Never> {
        var task: Task<Void, Never>!
        await withCheckedContinuation { (entered: CheckedContinuation<Void, Never>) in
            task = Task { @MainActor in
                entered.resume()
                await worker.drain()
                observed.drained = true
            }
        }
        return task
    }
}
