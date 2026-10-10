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
        print("refinement policy: passed")
    }
}
