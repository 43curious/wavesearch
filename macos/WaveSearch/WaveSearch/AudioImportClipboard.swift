import AppKit
import Combine

/// Keyboard/VoiceOver alternative to dragging. Uses the same import policy and
/// work admission as drags; a replaced selection cannot publish a stale URL.
@MainActor
final class AudioImportClipboard: ObservableObject {
    @Published private(set) var isCopying = false
    @Published private(set) var status = ""
    private var task: Task<Void, Never>?
    private var requestID: UUID?
    private let writeURL: (URL) -> Bool

    convenience init(pasteboard: NSPasteboard = .general) {
        self.init(writeURL: { url in
            pasteboard.clearContents()
            return pasteboard.writeObjects([url as NSURL])
        })
    }

    init(writeURL: @escaping (URL) -> Bool) {
        self.writeURL = writeURL
    }

    func copy(
        file: SoundFile, range: ClosedRange<Double>?, behavior: AudioImportBehavior? = nil,
        canPublish: @escaping () -> Bool = { true }
    ) {
        cancel()
        let behavior = behavior ?? .current()
        let id = UUID()
        let generation = BlockingWorkRegistry.hostFiles.generation
        requestID = id
        isCopying = true
        status = "Preparing audio for editor…"
        task = Task { [weak self] in
            defer {
                if let self, self.requestID == id {
                    self.isCopying = false
                    self.task = nil
                }
            }
            do {
                let url = try await audioImportURL(
                    file: file, startFraction: range?.lowerBound ?? 0,
                    endFraction: range?.upperBound ?? 1, behavior: behavior,
                    expectedGeneration: generation
                )
                guard let self, !Task.isCancelled, self.requestID == id else { return }
                guard BlockingWorkRegistry.hostFiles.generation == generation, canPublish() else {
                    self.status = "Audio copy canceled"
                    return
                }
                let copied = self.writeURL(url)
                self.status = copied
                    ? (behavior == .keepInPlace ? "Original file copied for editor" : "Exported audio copied for editor")
                    : "Could not copy audio for editor"
            } catch {
                guard let self, !Task.isCancelled, self.requestID == id else { return }
                self.status = "Could not prepare audio: \(error.localizedDescription)"
            }
        }
    }

    func cancel() {
        requestID = nil
        task?.cancel()
        task = nil
        isCopying = false
        status = ""
    }
}
