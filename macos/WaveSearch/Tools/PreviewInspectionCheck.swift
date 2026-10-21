import Foundation
@preconcurrency import AVFoundation
import AudioToolbox

nonisolated final class InspectionGate: @unchecked Sendable {
    private let lock = NSLock()
    private let release = DispatchSemaphore(value: 0)
    private var names: [Int] = []
    var calls: [Int] { lock.lock(); defer { lock.unlock() }; return names }
    func record(_ id: Int) {
        lock.lock(); names.append(id); lock.unlock()
        if id == 1 { release.wait() }
    }
    func unblock() { release.signal() }
}

@main
struct PreviewInspectionCheck {
    @MainActor
    static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("wavesearch-inspection-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("antiphase café 東京.wav")
        try await Task.detached {
            let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2)!
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 96000)!
            buffer.frameLength = 96000
            for frame in 0..<96000 {
                let hz = frame < 48000 ? 750.0 : 3000.0
                let sample = Float(0.25 * sin(Double(frame) * 2 * .pi * hz / 48000))
                buffer.floatChannelData![0][frame] = sample
                buffer.floatChannelData![1][frame] = -sample
            }
            let output = try AVAudioFile(forWriting: url, settings: format.settings)
            try output.write(from: buffer)
        }.value
        let file = SoundFile(id: 10, folderId: 1, path: url.path, name: url.lastPathComponent, durationMs: 2000, contentHash: 10)
        let original = try Data(contentsOf: url)
        let started = ContinuousClock.now
        let data = try await Task.detached {
            try SpectrogramAnalyzer.analyze(.init(file: file, range: 0...0.5, generation: 0))
        }.value
        let elapsed = started.duration(to: .now).components
        print("spectrum generated_stereo_wav first_request_ms=\(Double(elapsed.seconds) * 1000 + Double(elapsed.attoseconds) / 1e15) columns=\(data.columns)")
        precondition(data.columns <= 256 && data.image.width == data.columns && data.image.height == 513)
        precondition(data.startSeconds == 0 && data.endSeconds == 1 && data.sampleRate == 48000)
        let pixels = data.image.dataProvider!.data! as Data
        precondition(pixels.count <= 256 * 513)
        precondition(pixels[(512 - 16) * data.columns] > 215, "Antiphase stereo lost its 750 Hz tone")
        precondition(pixels[(512 - 64) * data.columns] < 5, "Spectrum read the 3000 Hz audio outside the selected range")
        do {
            _ = try SpectrogramAnalyzer.analyze(.init(file: file, range: 1...1, generation: 0))
            preconditionFailure("An empty spectrum range was accepted")
        } catch {}

        let gate = InspectionGate()
        let controller = SpectrogramController { request in
            gate.record(request.file.id) // Deliberately ignore cancellation until native work returns.
            return SpectrogramData(image: data.image, sampleRate: Double(request.file.id), startSeconds: 0, endSeconds: 1, columns: data.columns)
        }
        func marker(_ id: Int) -> SoundFile {
            SoundFile(id: id, folderId: 1, path: url.path, name: "\(id)", durationMs: 2000, contentHash: Int64(id))
        }
        controller.load(marker(1), range: nil)
        await wait { gate.calls == [1] }
        controller.load(marker(2), range: nil)
        controller.load(marker(3), range: nil)
        gate.unblock()
        await controller.drain()
        precondition(gate.calls == [1, 3] && controller.data?.sampleRate == 3 && !controller.isLoading)
        controller.clear()
        precondition(controller.data == nil && !controller.isLoading)

        let shutdownGate = InspectionGate()
        let pending = SpectrogramController { request in
            shutdownGate.record(request.file.id)
            return data
        }
        pending.load(marker(1), range: nil)
        await wait { shutdownGate.calls == [1] }
        pending.clear()
        var drained = false
        let drain = Task { await pending.drain(); drained = true }
        await Task.yield()
        precondition(!drained, "Canceled spectrum work bypassed the actual-work drain")
        shutdownGate.unblock()
        await drain.value
        precondition(drained && pending.data == nil)
        let after = try Data(contentsOf: url)
        precondition(after == original, "Preview inspection changed source audio")
        print("PASS: spectrum range isolation, antiphase stereo, raster bounds, newest-request replacement and shutdown drain")

        guard PitchedPreviewPlayback.isAvailable else {
            // Also verify the product constructor fails before AVFAudio can
            // raise an uncaught Objective-C exception for missing components.
            do { _ = try PitchedPreviewPlayback(url: url); preconditionFailure("Missing Audio Units were accepted") }
            catch {}
            print("SKIP: native pitch DSP; required Apple Audio Units are unavailable in this session")
            if CommandLine.arguments.contains("--native-pitch") { exit(2) }
            return
        }
        try nativePitch(url)
    }

    @MainActor
    private static func wait(_ condition: () -> Bool) async {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !condition(), ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(2)) }
        precondition(condition(), "Timed out waiting for spectrum work")
    }

    /// Inspect rendered native samples, independently of speaker hardware or
    /// controller state, after the time-pitch unit's startup latency has passed.
    private static func nativePitch(_ url: URL) throws {
        let player = try PitchedPreviewPlayback(url: url, offline: true)
        let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4096)!
        player.volume = 0.25
        player.pitch = 1200
        player.rate = 0.5
        precondition(player.play())
        var samples: [Float] = []
        for _ in 0..<12 {
            let status = try player.renderOffline(frames: 4096, into: buffer)
            precondition(status == .success)
            samples.append(contentsOf: UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
        }
        let middle = samples[16384..<32768]
        let crossings = zip(middle, middle.dropFirst()).filter { $0 <= 0 && $1 > 0 }.count
        let frequency = Double(crossings) * 48000 / Double(middle.count)
        precondition(abs(frequency - 1500) < 25, "Pitch did not double 750 Hz independently of half-speed playback: \(frequency)")
        precondition(samples.allSatisfy { $0.isFinite && abs($0) <= 1 }, "Pitch output clipped or contained invalid PCM")
        precondition(player.currentTime < 0.8, "Half-speed pitch audition consumed the source too quickly")
        player.pause()
        precondition(!player.isPlaying)
        player.currentTime = 1.5
        player.stop()
        precondition(player.currentTime == 0 && !player.isPlaying)
        print("PASS: native offline-rendered pitch frequency, independent rate, clipping, seek and stop")
    }
}
