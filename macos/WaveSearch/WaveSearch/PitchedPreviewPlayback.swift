import Foundation
import CoreAudio
@preconcurrency import AVFoundation

/// Prepared off-main, then owned only by PlayerController on the main actor.
/// Audio callbacks enqueue state changes on that actor and reject old schedules.
/// File segments stream through AVFoundation; no full recording PCM is retained.
nonisolated final class PitchedPreviewPlayback: PreviewPlayback, @unchecked Sendable {
    private let engine: AVAudioEngine
    private let node: AVAudioPlayerNode
    private let pitchUnit: AVAudioUnitTimePitch
    private let limiter: AVAudioUnitEffect
    private let file: AVAudioFile
    private var fadeTimer: Timer?
    private var epoch: UInt64 = 0
    private var anchor: AVAudioFramePosition = 0
    private var parked: TimeInterval = 0
    private var scheduled = false
    private var running = false
    var supportsPitch: Bool { true }
    var enableRate = true
    var numberOfLoops = 0

    // AVFAudio raises an Objective-C exception (not a Swift Error) when system
    // components cannot be found, e.g. a session without Audio Unit services.
    static var isAvailable: Bool {
        let components: [(OSType, OSType)] = [
            (kAudioUnitType_Generator, kAudioUnitSubType_ScheduledSoundPlayer),
            (kAudioUnitType_Generator, kAudioUnitSubType_AudioFilePlayer),
            (kAudioUnitType_FormatConverter, kAudioUnitSubType_NewTimePitch),
            (kAudioUnitType_Effect, kAudioUnitSubType_PeakLimiter),
            (kAudioUnitType_Mixer, kAudioUnitSubType_MultiChannelMixer),
        ]
        return components.allSatisfy { type, subtype in
            var description = AudioComponentDescription(componentType: type, componentSubType: subtype,
                componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0)
            return AudioComponentFindNext(nil, &description) != nil
        }
    }

    init(url: URL, offline: Bool = false) throws {
        guard Self.isAvailable else { throw CocoaError(.featureUnsupported) }
        if !offline {
            var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            var device = AudioDeviceID(kAudioObjectUnknown)
            var size = UInt32(MemoryLayout<AudioDeviceID>.size)
            guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr,
                  device != kAudioObjectUnknown else { throw CocoaError(.featureUnsupported) }
        }
        file = try AVAudioFile(forReading: url)
        guard file.length > 0, file.processingFormat.sampleRate > 0,
              file.processingFormat.channelCount <= 2 else { throw CocoaError(.fileReadUnsupportedScheme) }
        engine = AVAudioEngine()
        node = AVAudioPlayerNode()
        pitchUnit = AVAudioUnitTimePitch()
        limiter = AVAudioUnitEffect(audioComponentDescription: AudioComponentDescription(
            componentType: kAudioUnitType_Effect, componentSubType: kAudioUnitSubType_PeakLimiter,
            componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0))
        engine.attach(node)
        engine.attach(pitchUnit)
        engine.attach(limiter)
        if offline {
            try engine.enableManualRenderingMode(.offline, format: file.processingFormat, maximumFrameCount: 4096)
        }
        engine.connect(node, to: pitchUnit, format: file.processingFormat)
        engine.connect(pitchUnit, to: limiter, format: file.processingFormat)
        engine.connect(limiter, to: engine.mainMixerNode, format: file.processingFormat)

        engine.prepare()
    }

    var duration: TimeInterval { Double(file.length) / file.processingFormat.sampleRate }
    var isPlaying: Bool { running && node.isPlaying }
    var rate: Float {
        get { pitchUnit.rate }
        set { pitchUnit.rate = min(max(newValue, 0.5), 2) }
    }
    var pitch: Float {
        get { pitchUnit.pitch }
        set { pitchUnit.pitch = min(max(newValue, -1200), 1200) }
    }
    var volume: Float {
        get { node.volume }
        set { fadeTimer?.invalidate(); fadeTimer = nil; node.volume = min(max(newValue, 0), 1) }
    }
    var currentTime: TimeInterval {
        get {
            guard scheduled, let render = node.lastRenderTime,
                  let time = node.playerTime(forNodeTime: render), time.sampleTime >= 0 else { return parked }
            return min(duration, Double(anchor + time.sampleTime) / file.processingFormat.sampleRate)
        }
        set {
            guard newValue.isFinite else { return }
            let resume = running
            parked = min(max(newValue, 0), duration)
            invalidateSchedule()
            if resume { _ = play() }
        }
    }

    func play() -> Bool {
        guard parked < duration || scheduled else { return false }
        do { if !engine.isRunning { try engine.start() } } catch { return false }
        if !scheduled { schedule(from: AVAudioFramePosition(parked * file.processingFormat.sampleRate)) }
        running = true
        node.play()
        return node.isPlaying
    }

    func pause() {
        parked = currentTime
        node.pause()
        running = false
    }

    func stop() {
        fadeTimer?.invalidate()
        fadeTimer = nil
        invalidateSchedule()
        engine.stop()
        parked = 0
    }

    // Gain changes share the native transport's bounded volume range. The final
    // peak limiter also covers overshoots introduced by pitch/time processing.
    func setVolume(_ volume: Float, fadeDuration duration: TimeInterval) {
        fadeTimer?.invalidate()
        let start = node.volume
        let target = min(max(volume, 0), 1)
        guard duration > 0 else { self.volume = target; return }
        let started = ProcessInfo.processInfo.systemUptime
        fadeTimer = Timer.scheduledTimer(withTimeInterval: duration / 8, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            let progress = min(1, (ProcessInfo.processInfo.systemUptime - started) / duration)
            self.node.volume = start + (target - start) * Float(progress)
            if progress == 1 { timer.invalidate(); self.fadeTimer = nil }
        }
    }

    private func invalidateSchedule() {
        epoch &+= 1
        running = false
        scheduled = false
        node.stop()
    }

    private func schedule(from frame: AVAudioFramePosition) {
        let count = AVAudioFrameCount(min(AVAudioFramePosition(UInt32.max), file.length - frame))
        guard count > 0 else { return }
        anchor = frame
        scheduled = true
        let token = epoch
        let end = frame + AVAudioFramePosition(count)
        node.scheduleSegment(file, startingFrame: frame, frameCount: count, at: nil,
                             completionCallbackType: .dataPlayedBack) { [weak self] _ in
            DispatchQueue.main.async { [weak self] in
                guard let self, self.epoch == token else { return }
                let resume = self.running
                self.parked = Double(end) / self.file.processingFormat.sampleRate
                self.invalidateSchedule()
                if resume, end < self.file.length {
                    _ = self.play()
                } else if resume, self.numberOfLoops < 0 {
                    self.parked = 0
                    _ = self.play()
                }
            }
        }
    }

    /// Native DSP verification without changing the system's output device.
    func renderOffline(frames: AVAudioFrameCount, into buffer: AVAudioPCMBuffer) throws -> AVAudioEngineManualRenderingStatus {
        try engine.renderOffline(frames, to: buffer)
    }

    deinit { fadeTimer?.invalidate(); node.stop(); engine.stop() }
}
