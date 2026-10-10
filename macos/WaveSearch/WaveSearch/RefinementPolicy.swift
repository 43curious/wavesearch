import Foundation

nonisolated enum RefinementMode: String, CaseIterable, Codable, Identifiable, Sendable {
    case fastOnly
    case balanced
    case complete

    var id: String { rawValue }

    var title: String {
        switch self {
        case .fastOnly: "Fast only"
        case .balanced: "Balanced"
        case .complete: "Complete"
        }
    }

    var summary: String {
        switch self {
        case .fastOnly:
            "Metadata and lexical search only. Selected sounds still receive exact waveform and loudness analysis on demand."
        case .balanced:
            "Refines while the Mac is idle and on AC power. Pauses immediately for playback, search, scans, or system pressure."
        case .complete:
            "Drains every available refinement queue, while still yielding to foreground work and system pressure."
        }
    }
}

nonisolated enum RefinementQueue: String, Sendable {
    case waveform
    case acoustic
    case semantic

    var title: String {
        switch self {
        case .waveform: "waveforms"
        case .acoustic: "acoustic fingerprints"
        case .semantic: "semantic embeddings"
        }
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
        case .fastOnly: "Background refinement is disabled in Fast only mode"
        case .userPaused: "Background refinement is paused"
        case .metadataScan: "Waiting for the metadata scan to finish"
        case .search: "Paused for search"
        case .playback: "Paused for playback"
        case .selectedAnalysis: "Paused for selected waveform analysis"
        case .thermalPressure: "Waiting for the Mac to cool down"
        case .memoryPressure: "Waiting for memory pressure to clear"
        case .lowPowerMode: "Waiting for Low Power Mode to turn off"
        case .batteryPower: "Balanced mode waits for AC power"
        case .waitingForIdle(let seconds): "Waiting for about \(seconds)s of idle time"
        case .noAvailableLibraries: "Waiting for an available library"
        case .missingLibrary: "Waiting for a library drive"
        case .semanticProviderUnavailable: "Optional semantic model is unavailable"
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
    var lastError: String?

    var hasPendingWork: Bool { waveformPending + acousticPending + semanticPending > 0 }
    var isWorking: Bool { activeQueue != nil }

    var phase: String {
        if let activeQueue { return "Refining \(activeQueue.title)" }
        if let blocker { return blocker.message }
        if hasPendingWork { return "Refinement ready to continue" }
        return semanticAvailable ? "Fully refined" : "Available refinement complete"
    }

    var detail: String {
        if mode == .fastOnly {
            return "Fast metadata and lexical search are ready. Selected sounds are still analyzed on demand."
        }
        if let blocker { return blocker.message }
        if let activeQueue {
            return "Search is ready · processing one \(activeQueue.title) item at a time"
        }
        if hasPendingWork {
            return "Search is ready · background work will resume when policy allows"
        }
        return semanticAvailable
            ? "Fast search, acoustic families, waveforms, and semantic search are ready"
            : "Fast search, acoustic families, and waveforms are ready; install CLAP for semantic refinement"
    }
}
