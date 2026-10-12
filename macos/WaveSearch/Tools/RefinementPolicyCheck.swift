import Foundation

@main
enum RefinementPolicyCheck {
    static func main() {
        var input = RefinementPolicyInput(
            mode: .balanced,
            userPaused: false,
            metadataScanning: false,
            searching: false,
            playing: false,
            selectedAnalysis: false,
            thermalConstrained: false,
            memoryConstrained: false,
            lowPowerMode: false,
            onBattery: false,
            idleSeconds: 31,
            hasAvailableLibraries: true
        )
        precondition(RefinementPolicy.blocker(for: input) == nil)

        input.mode = .fastOnly
        precondition(RefinementPolicy.blocker(for: input) == .fastOnly)
        input.mode = .balanced
        input.idleSeconds = 5
        precondition(RefinementPolicy.blocker(for: input) == .waitingForIdle(secondsRemaining: 25))
        input.idleSeconds = 31
        input.onBattery = true
        precondition(RefinementPolicy.blocker(for: input) == .batteryPower)
        input.mode = .complete
        precondition(RefinementPolicy.blocker(for: input) == nil)
        input.lowPowerMode = true
        precondition(RefinementPolicy.blocker(for: input) == nil)
        input.lowPowerMode = false
        input.playing = true
        precondition(RefinementPolicy.blocker(for: input) == .playback)
        input.playing = false
        input.memoryConstrained = true
        precondition(RefinementPolicy.blocker(for: input) == .memoryPressure)
        input.memoryConstrained = false
        input.metadataScanning = true
        precondition(RefinementPolicy.blocker(for: input) == .metadataScan)
        input.metadataScanning = false
        input.hasAvailableLibraries = false
        precondition(RefinementPolicy.blocker(for: input) == .noAvailableLibraries)
        input.hasAvailableLibraries = true
        input.userPaused = true
        precondition(RefinementPolicy.blocker(for: input) == .userPaused)

        let invalid = RefinementMode(rawValue: "not-a-mode") ?? .balanced
        precondition(invalid == .balanced)
        var schedule = RefinementSchedule()
        let folders: [Int32] = [10, 20]
        var visited: [RefinementQueue: [Int32]] = [:]
        // Interleaving producers must not partition two folders between them.
        for _ in 0..<3 {
            for queue: RefinementQueue in [.acoustic, .semantic] {
                visited[queue, default: []].append(schedule.nextFolder(for: queue, from: folders)!)
            }
        }
        precondition(visited[.acoustic] == [10, 20, 10])
        precondition(visited[.semantic] == [10, 20, 10])
        precondition(schedule.nextFolder(for: .acoustic, from: []) == nil)
        precondition(schedule.nextFolder(for: .acoustic, from: [30]) == 30)
        // Exercise the actual C bridge with one unavailable optional producer.
        var acousticTurns = 0
        for _ in 0..<12 {
            let queue = schedule.next(waveform: true, acoustic: true, semantic: false)
            precondition(queue != nil && queue != .semantic)
            if queue == .acoustic { acousticTurns += 1 }
        }
        precondition(acousticTurns >= 3)
        precondition(schedule.next(waveform: false, acoustic: false, semantic: false) == nil)
        print("refinement policy, fair queue selection and independent folder rotation: passed")
    }
}
