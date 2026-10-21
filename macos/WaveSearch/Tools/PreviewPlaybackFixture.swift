import Foundation

/// Explicit time progression keeps transport checks independent of CoreAudio,
/// run-loop timers and machine speed. Preparation can still block/cancel.
nonisolated final class PreviewTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var time: TimeInterval = 0
    private var starts: [(String, TimeInterval)] = []
    private var pitch: Float = 0
    var lastPitch: Float { lock.lock(); defer { lock.unlock() }; return pitch }
    func pitched(_ value: Float) { lock.lock(); pitch = value; lock.unlock() }

    var now: TimeInterval { lock.lock(); defer { lock.unlock() }; return time }
    var playedNames: [String] { lock.lock(); defer { lock.unlock() }; return starts.map(\.0) }
    var firstStart: TimeInterval? { lock.lock(); defer { lock.unlock() }; return starts.first?.1 }

    func advance(_ seconds: TimeInterval) {
        lock.lock(); defer { lock.unlock() }
        time += seconds
    }

    func played(_ name: String, position: TimeInterval) {
        lock.lock(); defer { lock.unlock() }
        starts.append((name, position))
    }
}

nonisolated final class PreviewTestPlayback: PreviewPlayback {
    let duration: TimeInterval = 1
    var enableRate = true
    var pitch: Float = 0 { didSet { clock.pitched(pitch) } }
    var supportsPitch: Bool { true }
    var numberOfLoops = 0
    var volume: Float = 1
    private let clock: PreviewTestClock
    private let name: String
    private let acceptsPlayback: Bool
    private var position: TimeInterval = 0
    private var started: TimeInterval = 0
    private var running = false
    private var speed: Float = 1

    init(name: String, clock: PreviewTestClock, acceptsPlayback: Bool = true) {
        self.name = name
        self.clock = clock
        self.acceptsPlayback = acceptsPlayback
    }

    var currentTime: TimeInterval {
        get {
            let elapsed = position + (running ? (clock.now - started) * Double(speed) : 0)
            return numberOfLoops < 0 ? elapsed.truncatingRemainder(dividingBy: duration) : min(elapsed, duration)
        }
        set { position = min(max(newValue, 0), duration); started = clock.now }
    }

    var isPlaying: Bool { running && (numberOfLoops < 0 || currentTime < duration) }
    var rate: Float {
        get { speed }
        set { position = currentTime; started = clock.now; speed = newValue }
    }

    func play() -> Bool {
        guard acceptsPlayback else { return false }
        clock.played(name, position: currentTime)
        position = currentTime
        started = clock.now
        running = true
        return true
    }

    func pause() { position = currentTime; running = false }
    func stop() { running = false; position = 0 }
    func setVolume(_ volume: Float, fadeDuration duration: TimeInterval) { self.volume = volume }
}
