import SwiftUI
@preconcurrency import AVFoundation
import WaveSearchKit

nonisolated struct SpectrogramRequest: Sendable {
    let file: SoundFile
    let range: ClosedRange<Double>
    let generation: UInt64
}

/// Immutable CGImage plus labels; at most 256 × 513 grayscale bytes, no disk cache.
nonisolated struct SpectrogramData: @unchecked Sendable {
    let image: CGImage
    let sampleRate: Double
    let startSeconds: Double
    let endSeconds: Double
    let columns: Int
}

nonisolated enum SpectrogramAnalyzer {
    static func analyze(_ request: SpectrogramRequest) throws -> SpectrogramData {
        try Task.checkCancellation()
        let before = try WaveformSourceSignature.capture(request.file, analyzerVersion: 1)
        let file = try AVAudioFile(forReading: request.file.url, commonFormat: .pcmFormatFloat32, interleaved: false)
        let format = file.processingFormat
        let range = request.range
        guard file.length > 0, format.sampleRate.isFinite, format.sampleRate > 0,
              format.channelCount > 0, format.channelCount <= 32,
              range.lowerBound.isFinite, range.upperBound.isFinite,
              range.lowerBound >= 0, range.upperBound <= 1, range.lowerBound < range.upperBound,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1024) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let start = min(file.length - 1, AVAudioFramePosition(Double(file.length) * range.lowerBound))
        let end = min(file.length, max(start + 1, AVAudioFramePosition(ceil(Double(file.length) * range.upperBound))))
        let window = min(1024, end - start)
        let columns = Int(min(256, max(1, (end - start + 511) / 512)))
        var pixels = [UInt8](repeating: 0, count: columns * 513)
        var bins = [Float](repeating: -100, count: 513)
        for column in 0..<columns {
            try Task.checkCancellation()
            file.framePosition = start + AVAudioFramePosition(Double(end - start - window) * Double(column) / Double(max(1, columns - 1)))
            buffer.frameLength = 0
            try file.read(into: buffer, frameCount: AVAudioFrameCount(window))
            guard buffer.frameLength == window, let data = buffer.floatChannelData else { throw CocoaError(.fileReadCorruptFile) }
            let planes = (0..<Int(format.channelCount)).map { Optional(UnsafePointer(data[$0])) }
            let status = planes.withUnsafeBufferPointer { planes in
                bins.withUnsafeMutableBufferPointer { output in
                    ws_spectrum_column_v1(planes.baseAddress, format.channelCount, buffer.frameLength, output.baseAddress, UInt32(output.count))
                }
            }
            guard status == 0 else { throw CocoaError(.fileReadCorruptFile) }
            for bin in 0..<513 {
                pixels[(512 - bin) * columns + column] = UInt8(min(max((bins[bin] + 100) * 2.55, 0), 255))
            }
        }
        try Task.checkCancellation()
        guard before == (try WaveformSourceSignature.capture(request.file, analyzerVersion: 1)),
              let provider = CGDataProvider(data: Data(pixels) as CFData),
              let image = CGImage(width: columns, height: 513, bitsPerComponent: 8, bitsPerPixel: 8,
                                  bytesPerRow: columns, space: CGColorSpaceCreateDeviceGray(),
                                  bitmapInfo: CGBitmapInfo(rawValue: 0), provider: provider,
                                  decode: nil, shouldInterpolate: false, intent: .defaultIntent) else {
            throw CocoaError(.fileReadUnknown)
        }
        return SpectrogramData(image: image, sampleRate: format.sampleRate,
                               startSeconds: Double(start) / format.sampleRate,
                               endSeconds: Double(end) / format.sampleRate, columns: columns)
    }
}

@MainActor
final class SpectrogramController: ObservableObject {
    @Published private(set) var data: SpectrogramData?
    @Published private(set) var isLoading = false
    @Published private(set) var failed = false
    private let worker: LatestRequestWorker<SpectrogramRequest, Result<SpectrogramData, Error>?>

    init(analyze: @escaping @Sendable (SpectrogramRequest) throws -> SpectrogramData = { try SpectrogramAnalyzer.analyze($0) }) {
        worker = LatestRequestWorker { request in
            await BlockingWorkRegistry.hostFiles.run(priority: .userInitiated, expectedGeneration: request.generation) {
                Result { try analyze(request) }
            }
        }
    }

    func load(_ file: SoundFile, range: ClosedRange<Double>?) {
        clear()
        isLoading = true
        worker.submit(SpectrogramRequest(file: file, range: range ?? 0...1, generation: BlockingWorkRegistry.hostFiles.generation)) { [weak self] result in
            guard let self else { return }
            self.isLoading = false
            if case .success(let data) = result { self.data = data }
            else { self.failed = true }
        }
    }

    func clear() {
        worker.cancel()
        data = nil
        isLoading = false
        failed = false
    }

    func drain() async { await worker.drain() }
}

struct SpectrogramView: View {
    @ObservedObject var model: SpectrogramController

    private var description: String {
        guard let data = model.data else {
            return model.isLoading ? String(localized: "Analyzing spectrum") : String(localized: "Spectrum unavailable")
        }
        return String(localized: "From \(LocalizedText.position(data.startSeconds)) to \(LocalizedText.position(data.endSeconds)); 0 to \((data.sampleRate / 2).formatted()) Hz; sampled original audio.")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let data = model.data {
                HStack {
                    Text("0–\((data.sampleRate / 2).formatted(.number.precision(.fractionLength(0)))) Hz · −100–0 dBFS")
                    Spacer()
                    Text("\(LocalizedText.position(data.startSeconds)) – \(LocalizedText.position(data.endSeconds))")
                }
                .font(.caption2)
                Image(decorative: data.image, scale: 1)
                    .resizable()
                    .interpolation(.none)
                    .accessibilityHidden(true)
                Text("Sampled windows; brief events between windows may be missed. Original audio before preview effects.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else if model.isLoading {
                ProgressView("Analyzing spectrum")
            } else {
                Text("Spectrum unavailable")
            }
        }
        .frame(maxWidth: .infinity, minHeight: 90, maxHeight: 120)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Spectrogram")
        .accessibilityValue(description)
    }
}
