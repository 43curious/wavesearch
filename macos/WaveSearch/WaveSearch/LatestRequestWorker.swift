/// Serializes expensive asynchronous work, retaining only the newest waiting request.
///
/// Submission and cancellation are synchronous on the main actor. Cancellation signals
/// the operation but does not release its execution slot: even an uncooperative operation
/// must return before the next one starts. The operation chooses its own executor.
@MainActor
final class LatestRequestWorker<Input: Sendable, Output: Sendable> {
    private struct Request {
        let generation: UInt64
        let input: Input
        let cancel: @Sendable () -> Void
        let receive: @MainActor (Output) -> Void
    }

    private let operation: @Sendable (Input) async -> Output
    private let onActivityChange: (@MainActor (Bool) -> Void)?
    private var generation: UInt64 = 0
    private var pending: Request?
    private var activeGeneration: UInt64?
    private var activeTask: Task<Void, Never>?
    private var activeCancellation: (@Sendable () -> Void)?
    private var isActive = false
    private var drainWaiters: [CheckedContinuation<Void, Never>] = []

    init(
        operation: @escaping @Sendable (Input) async -> Output,
        onActivityChange: (@MainActor (Bool) -> Void)? = nil
    ) {
        self.operation = operation
        self.onActivityChange = onActivityChange
    }

    /// Superseded requests receive cancellation once, including requests not yet started.
    func submit(
        _ input: Input,
        cancel: @escaping @Sendable () -> Void = {},
        receive: @escaping @MainActor (Output) -> Void
    ) {
        generation &+= 1
        let replaced = pending
        pending = Request(generation: generation, input: input, cancel: cancel, receive: receive)
        cancelActive()
        replaced?.cancel()
        startIfIdle()
    }

    func cancel() {
        generation &+= 1
        let replaced = pending
        pending = nil
        cancelActive()
        replaced?.cancel()
    }

    /// Waits for real completion, not just cancellation. New submissions while waiting
    /// are included. Cancelling the waiting task does not abandon the drain barrier.
    func drain() async {
        guard activeGeneration != nil || pending != nil else { return }
        await withCheckedContinuation { drainWaiters.append($0) }
    }

    private func cancelActive() {
        let callback = activeCancellation
        activeCancellation = nil
        activeTask?.cancel()
        callback?()
    }

    private func startIfIdle() {
        guard activeGeneration == nil, let request = pending else { return }
        pending = nil
        activeGeneration = request.generation
        activeCancellation = request.cancel
        let operation = operation
        // Do not retain the worker across an operation that might never cooperate.
        activeTask = Task { [weak self] in
            guard !Task.isCancelled else {
                self?.finished(request, output: nil)
                return
            }
            let output = await operation(request.input)
            self?.finished(request, output: .some(output))
        }
        if !isActive {
            isActive = true
            onActivityChange?(true)
        }
    }

    private func finished(_ request: Request, output: Output?) {
        guard activeGeneration == request.generation else { return }
        // Keep the slot occupied during delivery: receive may synchronously submit.
        if request.generation == generation, let output {
            request.receive(output)
        }
        activeTask = nil
        activeGeneration = nil
        activeCancellation = nil
        startIfIdle()
        guard activeGeneration == nil else { return }
        isActive = false
        onActivityChange?(false)
        // An activity observer can also synchronously submit another request.
        guard activeGeneration == nil, pending == nil else { return }
        let waiters = drainWaiters
        drainWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }
}
