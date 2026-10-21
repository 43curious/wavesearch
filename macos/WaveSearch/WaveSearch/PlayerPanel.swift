import SwiftUI
@preconcurrency import AVFoundation
import WaveSearchKit
import AppKit
import Combine

/// The preview owns one transport after preparation hands it to the main actor.
/// Native output and a controlled test clock share the same playback commands.
nonisolated protocol PreviewPlayback: AnyObject {
    var duration: TimeInterval { get }
    var currentTime: TimeInterval { get set }
    var isPlaying: Bool { get }
    var enableRate: Bool { get set }
    var rate: Float { get set }
    var pitch: Float { get set }
    var supportsPitch: Bool { get }
    var numberOfLoops: Int { get set }
    var volume: Float { get set }
    func play() -> Bool
    func pause()
    func stop()
    func setVolume(_ volume: Float, fadeDuration duration: TimeInterval)
}

// Legacy transport remains available for focused fixtures; product preview uses
// AVAudioEngine so rate and pitch can be adjusted independently.
extension AVAudioPlayer: nonisolated PreviewPlayback {
    nonisolated var pitch: Float { get { 0 } set {} }
    nonisolated var supportsPitch: Bool { false }
}

/// One-way handoff: preparation owns the player off-main until this wrapper is
/// returned; only the main actor may then take it, once. No background references
/// survive preparation, and the non-Sendable transport never escapes otherwise.
nonisolated final class PreparedPreviewPlayer: @unchecked Sendable {
    private var player: (any PreviewPlayback)?

    init(_ player: any PreviewPlayback) {
        self.player = player
    }

    @MainActor
    func takePlayer() -> (any PreviewPlayback)? {
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
    @Published private(set) var isPreparing = false
    @Published private(set) var selection: ClosedRange<Double>?
    @Published private(set) var loops = false
    @Published private(set) var previewRate: PreviewRate = .normal
    @Published private(set) var pitchSemitones = 0
    @Published private(set) var pitchAvailable = false
    let spectrogram = SpectrogramController()
    @Published private(set) var autoplayOnSelect: Bool

    private var player: (any PreviewPlayback)?
    private var timer: Timer?
    private var shuttleTimer: Timer?
    private let preparationWorker: LatestRequestWorker<URL, PreparedPreviewPlayer?>
    private var isSuspended = false
    private var wantsPlayback = false
    private var analysisLoadTask: Task<Void, Never>?
    private let maxShuttleMultiplier: Double = 32
    private let volumeDefaultsKey = "ws_preview_volume_v1"
    private let preferences: UserDefaults
    static let autoplayKey = "ws_preview_autoplay_v1"

    init(preferences: UserDefaults = .standard, prepare: @escaping @Sendable (URL) -> PreparedPreviewPlayer? = { url in
        guard !Task.isCancelled else { return nil }
        // Preserve native multichannel/codec playback when the pitch graph
        // cannot represent this source. The interface disables pitch explicitly.
        let player: any PreviewPlayback
        if let pitched = try? PitchedPreviewPlayback(url: url) { player = pitched }
        else if let plain = try? AVAudioPlayer(contentsOf: url) {
            plain.prepareToPlay()
            player = plain
        } else { return nil }
        guard !Task.isCancelled else { return nil }
        player.enableRate = true
        player.rate = 1
        guard !Task.isCancelled else { return nil }
        return PreparedPreviewPlayer(player)
    }) {
        self.preferences = preferences
        autoplayOnSelect = preferences.bool(forKey: Self.autoplayKey)
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
        if preferences.object(forKey: volumeDefaultsKey) != nil {
            volume = min(max(preferences.double(forKey: volumeDefaultsKey), 0), 1)
        }
    }

    /// nil follows the preference; explicit true also restarts an existing source.
    func load(_ file: SoundFile, autoplay: Bool? = nil) {
        guard !isSuspended else { return }
        if currentFile == file {
            if autoplay == true { playFromSelectionStart() }
            return
        }

        spectrogram.clear()
        preparationWorker.cancel()
        analysisLoadTask?.cancel()
        player?.stop()
        player = nil
        pitchAvailable = false
        stopTimer()
        stopShuttle()

        let fileURL = file.url
        WaveformSignposts.event("FileSelected", fileID: file.id)
        currentFile = file
        waveformData = nil
        normalizationGainDB = 0
        isAnalyzingWaveform = true
        isPlaying = false
        isPreparing = true
        wantsPlayback = autoplay ?? autoplayOnSelect
        selection = nil
        progress = 0
        duration = 0

        preparationWorker.submit(fileURL) { [weak self] prepared in
            guard let self, self.currentFile == file else { return }
            self.player = prepared?.takePlayer()
            self.pitchAvailable = self.player?.supportsPitch ?? false
            self.isPreparing = false
            self.duration = self.player?.duration ?? 0
            self.player?.currentTime = self.duration * self.progress
            self.configureTransport()
            self.applyOutputGain(fade: false)
            if self.wantsPlayback { self.beginPlayback() }
            if self.player == nil { self.wantsPlayback = false }
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
        stopShuttle()

        if isPlaying || wantsPlayback {
            stopPlayback()
            return
        }

        wantsPlayback = currentFile != nil
        beginPlayback()
    }

    /// A stable ID at a new URL is a verified move, even when re-indexing changes
    /// hash mode. Keep the range/playhead while the native player reopens it.
    func relocate(_ file: SoundFile) {
        guard let currentFile, currentFile.id == file.id,
              currentFile.contentHash == file.contentHash || currentFile.path != file.path else {
            load(file)
            return
        }
        guard currentFile != file else { return }
        let range = selection
        let position = progress
        let playing = isPlaying || wantsPlayback
        load(file, autoplay: playing)
        setSelection(range)
        seek(to: position)
    }

    func playFromSelectionStart() {
        stopShuttle()
        progress = playbackRange.lowerBound
        player?.currentTime = duration * progress
        wantsPlayback = currentFile != nil
        beginPlayback()
    }

    func stopPlayback() {
        wantsPlayback = false
        player?.pause()
        stopTimer()
        stopShuttle()
        isPlaying = false
        if let player, duration > 0 {
            progress = min(max(player.currentTime / duration, playbackRange.lowerBound), playbackRange.upperBound)
        }
    }

    func stepBackward() {
        startShuttle(direction: -1)
    }

    func stepForward() {
        startShuttle(direction: 1)
    }

    func stop() {
        spectrogram.clear()
        preparationWorker.cancel()
        analysisLoadTask?.cancel()
        analysisLoadTask = nil
        player?.stop()
        player = nil
        pitchAvailable = false
        stopTimer()
        stopShuttle()
        isPlaying = false
        isPreparing = false
        wantsPlayback = false
        selection = nil
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
        await spectrogram.drain()
        await analysisTask?.value
    }

    func resume() { isSuspended = false }

    func setVolume(_ value: Double) {
        volume = min(max(value, 0), 1)
        applyOutputGain(fade: true)
        preferences.set(volume, forKey: volumeDefaultsKey)
    }

    func setAutoplayOnSelect(_ enabled: Bool) {
        autoplayOnSelect = enabled
        preferences.set(enabled, forKey: Self.autoplayKey)
        if !enabled && isPreparing { wantsPlayback = false }
    }

    func setLoops(_ enabled: Bool) {
        loops = enabled
        configureTransport()
    }

    func setPreviewRate(_ rate: PreviewRate) {
        stopShuttle()
        previewRate = rate
        configureTransport()
        if isPlaying { startTimer() }
    }

    func setPitchSemitones(_ value: Int) {
        pitchSemitones = min(max(value, -12), 12)
        configureTransport()
    }

    /// Fractions are shared with the waveform/export UI and reset per source.
    func setSelection(_ range: ClosedRange<Double>?) {
        if let range, range.lowerBound.isFinite, range.upperBound.isFinite {
            let lower = min(max(range.lowerBound, 0), 1)
            let upper = min(max(range.upperBound, 0), 1)
            selection = lower < upper ? lower...upper : nil
        } else {
            selection = nil
        }
        configureTransport()
        if isPlaying, !playbackRange.contains(progress) { seek(to: playbackRange.lowerBound) }
    }

    func markIn() {
        guard currentFile != nil else { return }
        let upper = selection?.upperBound ?? 1
        setSelection(progress...(progress < upper ? upper : 1))
    }

    func markOut() {
        guard currentFile != nil else { return }
        let lower = selection?.lowerBound ?? 0
        setSelection((progress > lower ? lower : 0)...progress)
    }

    private var playbackRange: ClosedRange<Double> { selection ?? 0...1 }

    private func configureTransport() {
        player?.pitch = Float(pitchSemitones * 100)
        player?.rate = shuttleSpeed == 2 ? 2 : Float(previewRate.rawValue)
        // Whole-source looping is native; selected ranges use the progress tick.
        player?.numberOfLoops = loops && selection == nil ? -1 : 0
    }

    private func beginPlayback() {
        guard wantsPlayback, let player, duration > 0 else { return }
        if progress < playbackRange.lowerBound || progress >= playbackRange.upperBound {
            progress = playbackRange.lowerBound
            player.currentTime = duration * progress
        }
        configureTransport()
        isPlaying = player.play()
        wantsPlayback = isPlaying
        if isPlaying {
            WaveformSignposts.event("PreviewStarted", fileID: currentFile?.id ?? 0)
            startTimer()
        }
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
        guard currentFile != nil, fraction.isFinite else { return }
        stopShuttle()
        let clamped = min(max(fraction, 0), 1)
        player?.currentTime = duration * clamped
        progress = clamped
        if isPlaying { startTimer() }
    }

    private func startTimer() {
        stopTimer()
        timer = Timer.scheduledTimer(withTimeInterval: 0.04, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refreshPlaybackPosition()
            }
        }
    }

    /// Update the playhead and enforce range bounds after a transport clock tick.
    func refreshPlaybackPosition() {
        guard let player, duration > 0 else { return }
        updatePlayback(player)
    }

    private func updatePlayback(_ player: any PreviewPlayback) {
        let range = playbackRange
        let position = player.currentTime / duration
        // Native time can briefly precede a requested seek. Keep the visible
        // playhead within the audition range while testing the raw end position.
        progress = min(max(position, range.lowerBound), range.upperBound)
        if position >= range.upperBound || !player.isPlaying {
            if loops && wantsPlayback {
                player.currentTime = duration * range.lowerBound
                progress = range.lowerBound
                isPlaying = player.play()
                wantsPlayback = isPlaying
                if !isPlaying { stopTimer(); stopShuttle() }
            } else {
                player.pause()
                player.currentTime = duration * range.upperBound
                progress = range.upperBound
                wantsPlayback = false
                isPlaying = false
                stopTimer()
                stopShuttle()
            }
        }
    }

    private func startShuttle(direction: Double) {
        guard let player, duration > 0 else { return }

        wantsPlayback = false
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
            let position = player.currentTime / duration
            if position < playbackRange.lowerBound || position >= playbackRange.upperBound {
                player.currentTime = duration * playbackRange.lowerBound
            }
            isPlaying = player.isPlaying || player.play()
            wantsPlayback = isPlaying
            guard isPlaying else { stopShuttle(); return }

            shuttleTimer = Timer.scheduledTimer(withTimeInterval: 0.04, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, let player = self.player, self.duration > 0 else { return }
                    self.updatePlayback(player)
                }
            }
            return
        }

        player.pause()
        player.rate = Float(previewRate.rawValue)
        isPlaying = false

        shuttleTimer = Timer.scheduledTimer(withTimeInterval: 0.04, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let player = self.player, self.duration > 0 else { return }

                let lower = self.duration * self.playbackRange.lowerBound
                let upper = self.duration * self.playbackRange.upperBound
                let newTime = min(max(player.currentTime + self.shuttleSpeed * 0.04, lower), upper)
                player.currentTime = newTime
                self.progress = newTime / self.duration

                if newTime <= lower || newTime >= upper {
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
        player?.rate = Float(previewRate.rawValue)
        shuttleSpeed = 0
    }
}

enum PreviewRate: Double, CaseIterable, Identifiable {
    case half = 0.5, slow = 0.75, normal = 1, fast = 1.5, double = 2
    var id: Double { rawValue }
    var title: String { "\(rawValue.formatted())×" }
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
            : rate.formatted(.number.precision(.fractionLength(1)))
        if let bitDepth, bitDepth > 0 { return "\(bitDepth)/\(rateText)" }
        if let bitRateKbps, bitRateKbps > 0 { return "\(bitRateKbps)k/\(rateText)" }
        return "—/\(rateText)"
    }

    var channelText: String {
        channels.map(String.init) ?? "—"
    }

    /// A catalog hit avoids opening AVAudioFile for each visible result. Source
    /// stats are captured by the worker before/after this lookup, as for fallback.
    nonisolated static func indexed(_ file: SoundFile, signature: WaveformSourceSignature) -> AudioFileMetadata? {
        var stored = WSFileMetadata()
        stored.struct_size = UInt32(MemoryLayout<WSFileMetadata>.size)
        let required = UInt32(WS_FILE_METADATA_CHANNELS | WS_FILE_METADATA_SAMPLE_RATE
            | WS_FILE_METADATA_BIT_DEPTH | WS_FILE_METADATA_ENCODING)
        guard ws_file_metadata_v1(Int32(file.id), &stored) == 1,
              stored.content_hash == file.contentHash,
              stored.file_size == signature.fileSize,
              stored.mtime_ns == signature.modificationNanoseconds,
              stored.known_fields & required == required else { return nil }
        return .init(bitDepth: Int(stored.bit_depth), bitRateKbps: nil,
                     sampleRate: Double(stored.sample_rate), channels: Int(stored.channels))
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
    private let inspectSource: @Sendable (String) -> AudioFileMetadata

    init(inspect: @escaping @Sendable (String) -> AudioFileMetadata = { AudioFileMetadata.inspect(path: $0) }) {
        inspectSource = inspect
    }

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
        let inspect = inspectSource
        let token = UUID()
        pending[path] = (file, generation, token)
        inFlight += 1
        Task {
            let result = await BlockingWorkRegistry.hostFiles.run(expectedGeneration: generation) {
                () -> (WaveformSourceSignature, AudioFileMetadata)? in
                guard let signature = try? WaveformSourceSignature.capture(file, analyzerVersion: 0) else { return nil }
                let metadata = cachedSignature == signature ? cached : nil
                let inspected = metadata ?? AudioFileMetadata.indexed(file, signature: signature)
                    ?? inspect(path)
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
                    .accessibilityValue(file.map { store.isFavourite($0) } == true ? "Favourite" : "Not a favourite")
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
                    .accessibilityLabel("Preview volume")
                    .accessibilityValue("\(Int(player.volume * 100)) percent")
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
                .accessibilityLabel(player.isPlaying ? "Pause preview" : "Play preview")
                .help(player.isPreparing ? "Playback will start when preparation finishes" : "Play or pause preview (Space)")

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
    @EnvironmentObject private var store: AppStore
    @ObservedObject private var player = PlayerController.shared
    @StateObject private var clipboard = AudioImportClipboard()
    @State private var showsSpectrum = false

    private var isCurrent: Bool { player.currentFile == file }
    private var positionDescription: String {
        guard isCurrent, !player.isPreparing else { return String(localized: "Preparing preview") }
        guard player.duration > 0 else { return String(localized: "Preview unavailable") }
        return String(localized: "\(timeString(player.progress * player.duration)) of \(timeString(player.duration))")
    }

    private var rangeDescription: String {
        guard isCurrent, let range = player.selection else { return String(localized: "Whole file") }
        return String(localized: "In \(timeString(range.lowerBound * player.duration)), out \(timeString(range.upperBound * player.duration))")
    }

    private var waveformDescription: String {
        let analysis = !isCurrent || player.isAnalyzingWaveform
            ? String(localized: "Analyzing waveform") : player.waveformData == nil ? String(localized: "Waveform unavailable") : String(localized: "Waveform ready")
        return "\(analysis). \(positionDescription). \(rangeDescription)"
    }

    private var loudnessDescription: String {
        guard isCurrent, let loudness = player.waveformData?.loudness, loudness.analysisComplete else {
            return player.isAnalyzingWaveform ? String(localized: "Analyzing loudness") : String(localized: "Loudness unknown")
        }
        let lufs = loudness.integratedLUFS.map { $0.formatted(.number.precision(.fractionLength(1))) } ?? "—"
        let peak = loudness.samplePeakDBFS.map { $0.formatted(.number.precision(.fractionLength(1))) } ?? "—"
        return String(localized: "\(lufs) LUFS · \(peak) dBFS sample peak")
    }

    private func refreshSpectrum() {
        if showsSpectrum, isCurrent { player.spectrogram.load(file, range: player.selection) }
        else { player.spectrogram.clear() }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(file.displayName)
                .font(.system(size: 20, weight: .semibold))
                .lineLimit(2)

            HStack(spacing: 12) {
                Toggle("Loop", isOn: Binding(get: { player.loops }, set: { player.setLoops($0) }))
                    .toggleStyle(.button)
                    .help("Loop the selected range, or the whole file when no range is selected")
                Picker("Rate", selection: Binding(get: { player.previewRate }, set: { player.setPreviewRate($0) })) {
                    ForEach(PreviewRate.allCases) { rate in Text(rate.title).tag(rate) }
                }
                .frame(width: 130)
                Button("In") { player.markIn() }
                    .help("Set the in point at the playhead (i)")
                    .accessibilityLabel("Set in point")
                Button("Out") { player.markOut() }
                    .help("Set the out point at the playhead (o)")
                    .accessibilityLabel("Set out point")
                Button("Clear Range") { player.setSelection(nil) }
                    .disabled(player.selection == nil)
                Spacer()
                if let range = player.selection {
                    Text("\(timeString(range.lowerBound * player.duration)) – \(timeString(range.upperBound * player.duration))")
                        .monospacedDigit()
                        .accessibilityLabel(rangeDescription)
                }
            }
            .font(.system(size: 11))
            .controlSize(.small)
            .disabled(!isCurrent)

            HStack(spacing: 12) {
                Picker("Pitch", selection: Binding(get: { player.pitchSemitones }, set: { player.setPitchSemitones($0) })) {
                    ForEach(-12...12, id: \.self) { value in
                        Text("\(value.formatted(.number.sign(strategy: .always()))) st").tag(value)
                    }
                }
                .frame(width: 150)
                .accessibilityValue("\(player.pitchSemitones.formatted()) semitones")
                .disabled(!isCurrent || !player.pitchAvailable)
                .help("Preview pitch in semitones; rate and exports stay independent. Unavailable for unsupported playback formats.")
                Toggle("Spectrogram", isOn: $showsSpectrum).toggleStyle(.button)
                Spacer()
                Text(loudnessDescription)
                    .font(.caption.monospacedDigit())
                    .accessibilityLabel("Original whole-file loudness and sample peak")
                    .accessibilityValue(loudnessDescription)
            }
            .controlSize(.small)

            HStack {
                Slider(value: Binding(
                    get: { isCurrent ? player.progress * player.duration : 0 },
                    set: { player.seek(to: $0 / max(player.duration, 0.01)) }
                ), in: 0...max(player.duration, 0.01), step: 0.01) {
                    Text("Preview position")
                }
                .accessibilityValue(positionDescription)
                .help("Seek with Left and Right, then use In and Out to mark a range")
                .disabled(!isCurrent || player.isPreparing || player.duration <= 0)
                Text(positionDescription)
                    .font(.system(size: 10, design: .monospaced))
                    .accessibilityHidden(true)
                Button("Copy for Editor") {
                    clipboard.copy(file: file, range: player.selection) {
                        store.canUseLibrary && store.selectedFile == file
                    }
                }
                .keyboardShortcut("c", modifiers: [.command, .shift])
                .disabled(!isCurrent || !store.canUseLibrary || clipboard.isCopying)
                .help("Copy a file URL using your editor import preference; selected ranges are trimmed only in Copy files to Exports mode")
            }
            .controlSize(.small)

            if !clipboard.status.isEmpty {
                Text(clipboard.status)
                    .font(.caption)
                    .lineLimit(2)
                    .accessibilityLabel("Editor copy status")
                    .accessibilityValue(clipboard.status)
            }

            if showsSpectrum { SpectrogramView(model: player.spectrogram) }

            WaveformView(
                data: player.currentFile == file ? player.waveformData : nil,
                progress: player.progress,
                onSeek: { fraction in
                    player.seek(to: fraction)
                },
                dragPayloadProvider: { start, end in
                    try await dragPayloadForClip(file: file, startFraction: start, endFraction: end)
                },
                selection: Binding(get: { player.selection }, set: { player.setSelection($0) })
            )
            .id("\(file.id):\(file.contentHash):\(file.path)")
            .frame(maxWidth: .infinity)
            .frame(maxHeight: .infinity)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Waveform")
            .accessibilityValue(waveformDescription)
            .accessibilityHint("Use Preview position to seek, and Set in point and Set out point to select a range")
        }
        .padding(.horizontal, 22)
        .padding(.top, 28)
        .padding(.bottom, 20)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .frame(height: showsSpectrum ? 530 : 420)
        .background(AppTheme.panelSunken)
        .onChange(of: file) { _, _ in clipboard.cancel(); refreshSpectrum() }
        .onChange(of: player.selection) { _, _ in refreshSpectrum() }
        .onChange(of: showsSpectrum) { _, _ in refreshSpectrum() }
        .onAppear { refreshSpectrum() }
        .onDisappear { clipboard.cancel(); player.spectrogram.clear() }
        .onChange(of: clipboard.status) { _, status in
            if !status.isEmpty { announceAccessibility(status) }
        }
    }
}

private func timeString(_ value: Double) -> String {
    LocalizedText.position(value)
}
