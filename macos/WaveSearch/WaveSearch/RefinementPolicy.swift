import Foundation
import WaveSearchKit

nonisolated enum RefinementMode: String, CaseIterable, Codable, Identifiable, Sendable {
    case fastOnly
    case balanced
    case complete

    var id: String { rawValue }

    var title: String {
        switch self {
        case .fastOnly: String(localized: "Fast only")
        case .balanced: String(localized: "Balanced")
        case .complete: String(localized: "Complete")
        }
    }

    var summary: String {
        switch self {
        case .fastOnly:
            String(localized: "Metadata and lexical search only. Selected sounds still receive exact waveform and loudness analysis on demand.")
        case .balanced:
            String(localized: "Refines while the Mac is idle and on AC power. Pauses immediately for playback, search, scans, or system pressure.")
        case .complete:
            String(localized: "Drains every available refinement queue, while still yielding to foreground work and system pressure.")
        }
    }
}

nonisolated enum RefinementQueue: String, Sendable {
    case waveform
    case acoustic
    case semantic

    var title: String {
        switch self {
        case .waveform: String(localized: "waveforms")
        case .acoustic: String(localized: "acoustic fingerprints")
        case .semantic: String(localized: "semantic embeddings")
        }
    }
}

nonisolated struct RefinementSchedule {
    private var cursor: UInt32 = 0
    private var folderOffsets: [RefinementQueue: Int] = [:]

    mutating func next(waveform: Bool, acoustic: Bool, semantic: Bool) -> RefinementQueue? {
        let ready = (waveform ? WS_REFINEMENT_QUEUE_WAVEFORM : 0)
            | (acoustic ? WS_REFINEMENT_QUEUE_ACOUSTIC : 0)
            | (semantic ? WS_REFINEMENT_QUEUE_SEMANTIC : 0)
        switch ws_refinement_next_queue(&cursor, ready) {
        case WS_REFINEMENT_QUEUE_WAVEFORM: return .waveform
        case WS_REFINEMENT_QUEUE_ACOUSTIC: return .acoustic
        case WS_REFINEMENT_QUEUE_SEMANTIC: return .semantic
        default: return nil
        }
    }

    /// Each producer visits every available folder independently.
    mutating func nextFolder(for queue: RefinementQueue, from folders: [Int32]) -> Int32? {
        guard !folders.isEmpty else { return nil }
        let offset = folderOffsets[queue, default: 0] % folders.count
        folderOffsets[queue] = (offset + 1) % folders.count
        return folders[offset]
    }
}

nonisolated enum RefinementBlocker: Equatable, Sendable {
    case fastOnly
    case userPaused
    case metadataScan
    case search
    case playback
    case selectedAnalysis
    case thermalPressure
    case memoryPressure
    case lowPowerMode
    case batteryPower
    case waitingForIdle(secondsRemaining: Int)
    case noAvailableLibraries
    case missingLibrary
    case semanticProviderUnavailable

    var message: String {
        switch self {
        case .fastOnly: String(localized: "Background refinement is disabled in Fast only mode")
        case .userPaused: String(localized: "Background refinement is paused")
        case .metadataScan: String(localized: "Waiting for the metadata scan to finish")
        case .search: String(localized: "Paused for search")
        case .playback: String(localized: "Paused for playback")
        case .selectedAnalysis: String(localized: "Paused for selected waveform analysis")
        case .thermalPressure: String(localized: "Waiting for the Mac to cool down")
        case .memoryPressure: String(localized: "Waiting for memory pressure to clear")
        case .lowPowerMode: String(localized: "Waiting for Low Power Mode to turn off")
        case .batteryPower: String(localized: "Balanced mode waits for AC power")
        case .waitingForIdle(let seconds): String(localized: "Waiting for about \(seconds)s of idle time")
        case .noAvailableLibraries: String(localized: "Waiting for an available library")
        case .missingLibrary: String(localized: "Waiting for a library drive")
        case .semanticProviderUnavailable: String(localized: "Optional semantic model is unavailable")
        }
    }
}

nonisolated struct RefinementPolicyInput: Sendable {
    var mode: RefinementMode
    var userPaused: Bool
    var metadataScanning: Bool
    var searching: Bool
    var playing: Bool
    var selectedAnalysis: Bool
    var thermalConstrained: Bool
    var memoryConstrained: Bool
    var lowPowerMode: Bool
    var onBattery: Bool
    var idleSeconds: TimeInterval
    var hasAvailableLibraries: Bool
}

nonisolated enum RefinementPolicy {
    static let balancedIdleSeconds: TimeInterval = 30

    static func blocker(for input: RefinementPolicyInput) -> RefinementBlocker? {
        if input.mode == .fastOnly { return .fastOnly }
        if input.userPaused { return .userPaused }
        if input.metadataScanning { return .metadataScan }
        if input.searching { return .search }
        if input.playing { return .playback }
        if input.selectedAnalysis { return .selectedAnalysis }
        if input.thermalConstrained { return .thermalPressure }
        if input.memoryConstrained { return .memoryPressure }
        if !input.hasAvailableLibraries { return .noAvailableLibraries }
        guard input.mode == .balanced else { return nil }
        if input.lowPowerMode { return .lowPowerMode }
        if input.onBattery { return .batteryPower }
        if input.idleSeconds < balancedIdleSeconds {
            return .waitingForIdle(secondsRemaining: max(1, Int(ceil(balancedIdleSeconds - input.idleSeconds))))
        }
        return nil
    }
}

nonisolated struct RefinementSnapshot: Sendable {
    var mode: RefinementMode
    var activeQueue: RefinementQueue?
    var blocker: RefinementBlocker?
    var waveformReady: Int64 = 0
    var waveformPending: Int64 = 0
    var acousticReady: Int64 = 0
    var acousticPending: Int64 = 0
    var acousticFailed: Int64 = 0
    var semanticReady: Int64 = 0
    var semanticPending: Int64 = 0
    var semanticFailed: Int64 = 0
    var semanticAvailable: Bool = true
    var semanticConfigured: Bool = false
    var semanticProviderError: String?
    var lastError: String?
    var estimates: [RefinementQueue: RefinementEstimate] = [:]
    var deferredQueues: Set<RefinementQueue> = []

    func estimateDetail(for queue: RefinementQueue) -> String {
        let pending: Int64
        switch queue {
        case .waveform: pending = waveformPending
        case .acoustic: pending = acousticPending
        case .semantic: pending = semanticPending
        }
        guard pending > 0 else { return String(localized: "No pending work") }
        guard mode != .fastOnly, blocker == nil, !deferredQueues.contains(queue),
              queue != .semantic || semanticAvailable else { return String(localized: "Estimate suspended") }
        guard let estimate = estimates[queue] else { return String(localized: "Learning processing speed…") }
        return estimate.detail(pending: pending)
    }

    var hasPendingWork: Bool { waveformPending + acousticPending + semanticPending > 0 }
    var isWorking: Bool { activeQueue != nil }

    var phase: String {
        if let activeQueue { return String(localized: "Refining \(activeQueue.title)") }
        if let blocker { return blocker.message }
        if hasPendingWork { return String(localized: "Refinement ready to continue") }
        return semanticAvailable ? String(localized: "Fully refined") : String(localized: "Available refinement complete")
    }

    var detail: String {
        if mode == .fastOnly {
            return String(localized: "Fast metadata and lexical search are ready. Selected sounds are still analyzed on demand.")
        }
        if let blocker { return blocker.message }
        if let activeQueue {
            return String(localized: "Search is ready · processing one \(activeQueue.title) item at a time")
        }
        if hasPendingWork {
            return String(localized: "Search is ready · background work will resume when policy allows")
        }
        return semanticAvailable
            ? String(localized: "Fast search, acoustic families, waveforms, and semantic search are ready")
            : String(localized: "Fast search, acoustic families, and waveforms are ready; install CLAP for semantic refinement")
    }
}

/// A bounded session-only window of completed steps. Pauses, cancelled work and
/// empty polls never enter the sample; each producer learns its own cost.
nonisolated struct RefinementEstimator {
    private var samples: [RefinementQueue: [(items: Int64, seconds: Double)]] = [:]

    mutating func record(_ queue: RefinementQueue, items: Int64, seconds: Double) {
        guard items > 0, seconds.isFinite, seconds > 0 else { return }
        var window = samples[queue, default: []]
        window.append((items, seconds))
        samples[queue] = Array(window.suffix(20))
    }

    var estimates: [RefinementQueue: RefinementEstimate] {
        samples.compactMapValues { window in
            guard window.count >= 3 else { return nil }
            let items = window.reduce(0.0) { $0 + Double($1.items) }
            let seconds = window.reduce(0.0) { $0 + $1.seconds }
            return RefinementEstimate(secondsPerItem: seconds / items)
        }
    }
}

nonisolated struct RefinementEstimate: Sendable {
    let secondsPerItem: Double

    func detail(pending: Int64) -> String {
        let minutes = secondsPerItem * Double(pending) / 60
        let duration: String
        if minutes < 1 { duration = String(localized: "less than 1 min") }
        else if minutes < 10 { duration = String(localized: "about \(Int(ceil(minutes))) min") }
        else if minutes < 60 { duration = String(localized: "about \(Int(ceil(minutes / 5)) * 5) min") }
        else { duration = String(localized: "about \((minutes / 60).formatted(.number.precision(.fractionLength(1)))) hr") }
        let rate = (60 / secondsPerItem).formatted(.number.precision(.fractionLength(1)))
        return String(localized: "\(rate) items/min · \(duration) active processing")
    }
}
