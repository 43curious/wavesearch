import SwiftUI
@preconcurrency import AVFoundation
import WaveSearchKit
import AppKit
import Combine

/// One-way handoff: preparation owns the player off-main until this wrapper is
/// returned; only the main actor may then take it, once. No background references
/// survive preparation, and the non-Sendable AVAudioPlayer never escapes otherwise.
nonisolated final class PreparedPreviewPlayer: @unchecked Sendable {
    private var player: AVAudioPlayer?

    init(_ player: AVAudioPlayer) {
        self.player = player
    }

    @MainActor
    func takePlayer() -> AVAudioPlayer? {
        defer { player = nil }
        return player
    }
}

@MainActor
final class PlayerController: ObservableObject {
    static let shared = PlayerController()

    @Published private(set) var isPlaying: Bool = false
    @Published private(set) var progress: Double = 0
    @Published private(set) var currentFile: SoundFile?
    @Published private(set) var waveformData: WaveformData?
    @Published private(set) var duration: Double = 0
    @Published private(set) var shuttleSpeed: Double = 0
    @Published private(set) var volume: Double = 0.8
    @Published private(set) var normalizationGainDB: Double = 0
    @Published private(set) var isAnalyzingWaveform: Bool = false

    private var player: AVAudioPlayer?
    private var timer: Timer?
    private var shuttleTimer: Timer?
    private let preparationWorker: LatestRequestWorker<URL, PreparedPreviewPlayer?>
    private var isSuspended = false
    private var analysisLoadTask: Task<Void, Never>?
    private let maxShuttleMultiplier: Double = 32
    private let volumeDefaultsKey = "ws_preview_volume_v1"

    init(prepare: @escaping @Sendable (URL) -> PreparedPreviewPlayer? = { url in
        guard !Task.isCancelled, let player = try? AVAudioPlayer(contentsOf: url) else { return nil }
        guard !Task.isCancelled else { return nil }
        player.enableRate = true
        player.rate = 1
        player.prepareToPlay()
        guard !Task.isCancelled else { return nil }
        return PreparedPreviewPlayer(player)
    }) {
        preparationWorker = LatestRequestWorker(operation: { url in
            let task = Task.detached(priority: .userInitiated) { () -> PreparedPreviewPlayer? in
                guard !Task.isCancelled else { return nil }
                return prepare(url)
            }
            // Cancellation does not release the slot until AVFoundation returns.
            return await withTaskCancellationHandler {
                await task.value
            } onCancel: {
                task.cancel()
            }
        })
        if UserDefaults.standard.object(forKey: volumeDefaultsKey) != nil {
            volume = min(max(UserDefaults.standard.double(forKey: volumeDefaultsKey), 0), 1)
        }
    }

    func load(_ file: SoundFile) {
        guard !isSuspended else { return }
        if currentFile == file { return }

        preparationWorker.cancel()
        analysisLoadTask?.cancel()
        player?.stop()
        player = nil
        stopTimer()
        stopShuttle()

        let fileURL = file.url
        WaveformSignposts.event("FileSelected", fileID: file.id)
        currentFile = file
        waveformData = nil
        normalizationGainDB = 0
        isAnalyzingWaveform = true
        isPlaying = false
        progress = 0
        duration = 0

        preparationWorker.submit(fileURL) { [weak self] prepared in
            guard let self, self.currentFile == file else { return }
            self.player = prepared?.takePlayer()
            self.duration = self.player?.duration ?? 0
            self.applyOutputGain(fade: false)
        }

        analysisLoadTask = Task { [weak self] in
            do {
                await AudioAnalysisRepository.shared.prioritizeForeground(fileID: file.id)
                var firstStage = true
                for try await stage in AudioAnalysisRepository.shared.analysisStages(for: file) {
                    guard let self, !Task.isCancelled, self.currentFile == file else { return }
                    self.waveformData = stage
                    if firstStage {
                        WaveformSignposts.event("FirstWaveform", fileID: file.id)
                        firstStage = false
                    }
                    if stage.fidelity == .exact, !stage.loudness.analysisComplete {
                        WaveformSignposts.event("ExactEnvelope", fileID: file.id)
                    }
                    if stage.loudness.analysisComplete {
                        self.isAnalyzingWaveform = false
                        WaveformSignposts.event("LoudnessComplete", fileID: file.id)
                        self.normalizationGainDB = stage.loudness.playbackGainDB()
                        self.applyOutputGain(fade: true)
                    }
                }
            } catch is CancellationError {
                return
            } catch {
                guard let self, self.currentFile == file else { return }
                self.isAnalyzingWaveform = false
                if self.waveformData == nil {
                    self.normalizationGainDB = 0
                    self.applyOutputGain(fade: false)
                }
            }
        }
    }

    func togglePlayPause() {
        guard let player else { return }
        stopShuttle()

        if isPlaying {
            player.pause()
            stopTimer()
            isPlaying = false
            return
        }

        player.play()
        isPlaying = true
        startTimer()
    }

    func playFromSelectionStart() {
        guard let player else { return }
        stopShuttle()
        player.currentTime = 0
        progress = 0
        if !isPlaying {
            player.play()
            isPlaying = true
            startTimer()
        }
    }

    func stopPlayback() {
        guard let player else { return }
        player.pause()
        stopTimer()
        stopShuttle()
        isPlaying = false
        progress = duration > 0 ? player.currentTime / duration : 0
    }

    func stepBackward() {
        startShuttle(direction: -1)
    }

    func stepForward() {
        startShuttle(direction: 1)
    }

    func stop() {
        preparationWorker.cancel()
        analysisLoadTask?.cancel()
        analysisLoadTask = nil
        player?.stop()
        player = nil
        stopTimer()
        stopShuttle()
        isPlaying = false
        progress = 0
        duration = 0
        waveformData = nil
        normalizationGainDB = 0
        isAnalyzingWaveform = false
        currentFile = nil
    }

    func stopAndDrain() async {
        isSuspended = true
        let analysisTask = analysisLoadTask
        stop()
        await preparationWorker.drain()
        await analysisTask?.value
    }

    func resume() { isSuspended = false }

    func setVolume(_ value: Double) {
        volume = min(max(value, 0), 1)
        applyOutputGain(fade: true)
        UserDefaults.standard.set(volume, forKey: volumeDefaultsKey)
    }

    private func applyOutputGain(fade: Bool) {
        guard let player else { return }
        let normalization = pow(10, normalizationGainDB / 20)
        let effective = Float(min(max(volume * normalization, 0), 8))
        if fade {
            player.setVolume(effective, fadeDuration: 0.08)
        } else {
            player.volume = effective
        }
    }

    func seek(to fraction: Double) {
        guard let player else { return }
        stopShuttle()
        let clamped = min(max(fraction, 0), 1)
        player.currentTime = duration * clamped
        progress = clamped
    }

    private func startTimer() {
        stopShuttle()
        stopTimer()
        timer = Timer.scheduledTimer(withTimeInterval: 0.04, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let player = self.player, self.duration > 0 else { return }

                let currentProgress = player.currentTime / self.duration
                self.progress = currentProgress

                if !player.isPlaying {
                    self.isPlaying = false
                    self.stopTimer()
                }
            }
        }
    }

    private func startShuttle(direction: Double) {
        guard let player, duration > 0 else { return }

        stopTimer()

        let sameDirection = shuttleSpeed.sign == direction.sign && shuttleSpeed != 0
        let nextMultiplier = sameDirection
            ? min(abs(shuttleSpeed) * 2, maxShuttleMultiplier)
            : 2
        shuttleSpeed = direction * nextMultiplier

        shuttleTimer?.invalidate()

        if shuttleSpeed == 2 {
            player.enableRate = true
            player.rate = 2
            if !player.isPlaying {
                player.play()
            }
            isPlaying = true

            shuttleTimer = Timer.scheduledTimer(withTimeInterval: 0.04, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, let player = self.player, self.duration > 0 else { return }
                    self.progress = player.currentTime / self.duration

                    if !player.isPlaying || player.currentTime >= self.duration {
                        self.isPlaying = false
                        self.stopShuttle()
                    }
                }
            }
            return
        }

        player.pause()
        player.rate = 1
        isPlaying = false

        shuttleTimer = Timer.scheduledTimer(withTimeInterval: 0.04, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let player = self.player, self.duration > 0 else { return }

                let newTime = min(max(player.currentTime + self.shuttleSpeed * 0.04, 0), self.duration)
                player.currentTime = newTime
                self.progress = newTime / self.duration

                if newTime <= 0 || newTime >= self.duration {
                    self.stopShuttle()
                }
            }
        }
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    private func stopShuttle() {
        shuttleTimer?.invalidate()
        shuttleTimer = nil
        player?.rate = 1
        shuttleSpeed = 0
    }
}

struct AudioFileMetadata: Sendable {
    let bitDepth: Int?
    let bitRateKbps: Int?
    let sampleRate: Double?
    let channels: Int?

    var resolutionText: String {
        guard let sampleRate else { return "—" }
        let rate = sampleRate / 1_000
        let rateText = abs(rate.rounded() - rate) < 0.05
            ? String(Int(rate.rounded()))
            : String(format: "%.1f", rate)
        if let bitDepth, bitDepth > 0 { return "\(bitDepth)/\(rateText)" }
        if let bitRateKbps, bitRateKbps > 0 { return "\(bitRateKbps)k/\(rateText)" }
        return "—/\(rateText)"
    }

    var channelText: String {
        channels.map(String.init) ?? "—"
    }

    nonisolated static func inspect(path: String) -> AudioFileMetadata {
        guard let audioFile = try? AVAudioFile(forReading: URL(fileURLWithPath: path)) else {
            return AudioFileMetadata(bitDepth: nil, bitRateKbps: nil, sampleRate: nil, channels: nil)
        }
        let format = audioFile.fileFormat
        let stream = format.streamDescription.pointee
        let sampleRate = stream.mSampleRate > 0 ? stream.mSampleRate : nil
        let channels = stream.mChannelsPerFrame > 0 ? Int(stream.mChannelsPerFrame) : nil
        let bitDepth = stream.mBitsPerChannel > 0 ? Int(stream.mBitsPerChannel) : nil

        var bitRateKbps: Int?
        if let encodedRate = format.settings[AVEncoderBitRateKey] as? NSNumber, encodedRate.intValue > 0 {
            bitRateKbps = max(1, encodedRate.intValue / 1_000)
        } else if bitDepth == nil, audioFile.length > 0, audioFile.processingFormat.sampleRate > 0,
                  let attributes = try? FileManager.default.attributesOfItem(atPath: path),
                  let byteCount = attributes[.size] as? NSNumber {
            let estimate = (byteCount.doubleValue * 8) / (Double(audioFile.length) / audioFile.processingFormat.sampleRate) / 1_000
            if estimate.isFinite { bitRateKbps = max(1, Int(min(estimate, Double(Int32.max)))) }
        }
        return AudioFileMetadata(bitDepth: bitDepth, bitRateKbps: bitRateKbps, sampleRate: sampleRate, channels: channels)
    }
}

@MainActor
final class AudioMetadataStore: ObservableObject {
    static let shared = AudioMetadataStore()

    @Published private(set) var values: [String: AudioFileMetadata] = [:]
    private var pending: [String: (file: SoundFile, generation: UInt64, token: UUID)] = [:]
    private var inFlight = 0
    private var signatures: [String: WaveformSourceSignature] = [:]
    private var recent: [String] = []
    private let capacity = 256

    private init() {}

    func metadata(for file: SoundFile) -> AudioFileMetadata? {
        signatures[file.path]?.contentHash == file.contentHash ? values[file.path] : nil
    }

    func load(_ file: SoundFile) {
        // ponytail: at most 32 visible-row inspections; fast-scrolled rows retry
        // on reappearance rather than building an unbounded background queue.
        let path = file.path
        let generation = BlockingWorkRegistry.hostFiles.generation
        guard pending[path]?.file != file || pending[path]?.generation != generation else { return }
        guard inFlight < 32 else { return }
        let cached = values[path]
        let cachedSignature = signatures[path]
        let token = UUID()
        pending[path] = (file, generation, token)
        inFlight += 1
        Task {
            let result = await BlockingWorkRegistry.hostFiles.run(expectedGeneration: generation) {
                () -> (WaveformSourceSignature, AudioFileMetadata)? in
                guard let signature = try? WaveformSourceSignature.capture(file, analyzerVersion: 0) else { return nil }
                let metadata = cachedSignature == signature ? cached : nil
                let inspected = metadata ?? AudioFileMetadata.inspect(path: path)
                guard signature == (try? WaveformSourceSignature.capture(file, analyzerVersion: 0)) else { return nil }
                return (signature, inspected)
            }
            defer { inFlight -= 1 }
            guard pending[path]?.token == token else { return }
            pending.removeValue(forKey: path)
            recent.removeAll { $0 == path }
            if let entry = result ?? nil {
                signatures[path] = entry.0
                values[path] = entry.1
                recent.append(path)
                if recent.count > capacity {
                    let expired = recent.removeFirst()
                    values.removeValue(forKey: expired)
                    signatures.removeValue(forKey: expired)
                }
            } else {
                values.removeValue(forKey: path)
                signatures.removeValue(forKey: path)
            }
        }
    }
}

struct GlobalPlaybackBar: View {
    @EnvironmentObject private var store: AppStore
    @ObservedObject private var player = PlayerController.shared

    private var file: SoundFile? { player.currentFile ?? store.selectedFile }

    var body: some View {
        ZStack {
            HStack(spacing: 16) {
                HStack(spacing: 18) {
                    Button {
                        guard let file else { return }
                        NSWorkspace.shared.selectFile(file.path, inFileViewerRootedAtPath: "")
                    } label: {
                        Label("Reveal in Finder", systemImage: "folder")
                    }
                    .disabled(file == nil)

                    Button {
                        guard let file else { return }
                        store.toggleFavourite(file)
                    } label: {
                        Label(
                            "Favourite",
                            systemImage: file.map { store.isFavourite($0) } == true ? "star.fill" : "star"
                        )
                    }
                    .disabled(file == nil)
                }
                .buttonStyle(.borderless)
                .font(.system(size: 12, weight: .medium))
                .frame(maxWidth: .infinity, alignment: .leading)

                HStack(spacing: 8) {
                    Image(systemName: player.volume == 0 ? "speaker.slash.fill" : "speaker.fill")
                        .foregroundStyle(.secondary)
                    Slider(
                        value: Binding(
                            get: { player.volume },
                            set: { player.setVolume($0) }
                        ),
                        in: 0...1
                    )
                    .controlSize(.small)
                    .frame(width: 132)
                    Image(systemName: "speaker.wave.3.fill")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .trailing)
            }

            HStack(spacing: 12) {
                Text(timeString(player.progress * player.duration))
                    .frame(width: 58, alignment: .trailing)

                Button {
                    player.togglePlayPause()
                } label: {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 14, weight: .bold))
                        .frame(width: 42, height: 42)
                        .foregroundStyle(.white)
                        .background(AppTheme.accent, in: Circle())
                }
                .buttonStyle(.plain)
                .disabled(file == nil)

                Text(timeString(player.duration))
                    .frame(width: 58, alignment: .leading)
            }
            .font(.system(size: 11, weight: .medium, design: .monospaced))
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 18)
        .frame(maxWidth: .infinity)
        .frame(height: 64)
        .background(AppTheme.chrome)
        .overlay(alignment: .top) { Divider() }
    }
}

struct PlayerPanel: View {
    let file: SoundFile
    @ObservedObject private var player = PlayerController.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(file.displayName)
                .font(.system(size: 20, weight: .semibold))
                .lineLimit(2)

            WaveformView(
                data: player.currentFile == file ? player.waveformData : nil,
                progress: player.progress,
                onSeek: { fraction in
                    player.seek(to: fraction)
                },
                dragPayloadProvider: { start, end in
                    try await dragPayloadForClip(file: file, startFraction: start, endFraction: end)
                }
            )
            .id("\(file.id):\(file.contentHash):\(file.path)")
            .frame(maxWidth: .infinity)
            .frame(height: 240)
        }
        .padding(.horizontal, 22)
        .padding(.top, 28)
        .padding(.bottom, 20)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .frame(height: 340)
        .background(AppTheme.panelSunken)
        .task(id: "\(file.id):\(file.contentHash)") {
            player.load(file)
        }
    }
}

private func timeString(_ value: Double) -> String {
    guard value.isFinite, value > 0 else { return "0:00.00" }

    let minutes = Int(value) / 60
    let seconds = value.truncatingRemainder(dividingBy: 60)
    return String(format: "%d:%05.2f", minutes, seconds)
}
