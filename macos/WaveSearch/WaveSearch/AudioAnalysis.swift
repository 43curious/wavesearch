import Foundation
@preconcurrency import AVFoundation
import Accelerate
import Darwin

nonisolated struct WaveformPeak: Sendable, Equatable {
    let minimum: Float
    let maximum: Float
}

nonisolated struct WaveformLevel: Sendable, Equatable {
    let bucketCount: Int
    let channels: [[WaveformPeak]]
}

nonisolated enum WaveformFidelity: UInt32, Sendable, Equatable {
    case provisional = 0
    case exact = 1
}

nonisolated struct LoudnessMeasurement: Sendable, Equatable {
    let integratedLUFS: Double?
    let samplePeakDBFS: Double?
    let analysisComplete: Bool

    func playbackGainDB(targetLUFS: Double = -18, peakCeilingDBFS: Double = -1) -> Double {
        guard let integratedLUFS, let samplePeakDBFS else { return 0 }
        let loudnessGain = min(max(targetLUFS - integratedLUFS, -18), 18)
        let peakSafeGain = peakCeilingDBFS - samplePeakDBFS
        return min(loudnessGain, peakSafeGain)
    }
}

nonisolated struct WaveformSourceSignature: Sendable, Equatable {
    let standardizedPath: String
    let fileSize: Int64
    let modificationNanoseconds: Int64
    let contentHash: Int64
    let analyzerVersion: UInt32

    nonisolated static func capture(_ file: SoundFile, analyzerVersion: UInt32) throws -> WaveformSourceSignature {
        let path = URL(fileURLWithPath: file.path).standardizedFileURL.path
        var info = Darwin.stat()
        guard lstat(path, &info) == 0 else { throw CocoaError(.fileReadNoSuchFile) }
        let nanos = Int64(info.st_mtimespec.tv_sec) &* 1_000_000_000 &+ Int64(info.st_mtimespec.tv_nsec)
        return .init(
            standardizedPath: path,
            fileSize: Int64(info.st_size),
            modificationNanoseconds: nanos,
            contentHash: file.contentHash,
            analyzerVersion: analyzerVersion
        )
    }
}

nonisolated struct WaveformData: Sendable, Equatable {
    let signature: WaveformSourceSignature
    let sampleRate: Double
    let frameCount: Int64
    let sourceChannelCount: Int
    let levels: [WaveformLevel]
    let fidelity: WaveformFidelity
    let loudness: LoudnessMeasurement

    func level(forPixelWidth width: CGFloat, visibleFraction: Double) -> WaveformLevel? {
        guard !levels.isEmpty else { return nil }
        let required = max(1, Int(ceil(Double(max(width, 1)) / max(visibleFraction, 0.000_001) * 1.15)))
        return levels.first(where: { $0.bucketCount >= required }) ?? levels.last
    }
}

nonisolated enum PCMReaderPreference: Sendable {
    case automatic
    case avFoundation
    case mappedPCM
}

nonisolated protocol SequentialPCMReader: AnyObject {
    var sampleRate: Double { get }
    var frameCount: Int64 { get }
    var channelCount: Int { get }
    var processingFormat: AVAudioFormat { get }
    func read(into buffer: AVAudioPCMBuffer, frameCount: AVAudioFrameCount) throws
}

private nonisolated final class AVFoundationPCMReader: SequentialPCMReader {
    private let file: AVAudioFile
    let sampleRate: Double
    let frameCount: Int64
    let channelCount: Int
    let processingFormat: AVAudioFormat

    init(url: URL) throws {
        file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        processingFormat = file.processingFormat
        sampleRate = processingFormat.sampleRate
        frameCount = max(Int64(file.length), 1)
        channelCount = max(Int(processingFormat.channelCount), 1)
    }

    func read(into buffer: AVAudioPCMBuffer, frameCount: AVAudioFrameCount) throws {
        try file.read(into: buffer, frameCount: frameCount)
    }
}

private nonisolated final class MappedPCMReader: SequentialPCMReader {
    private enum Encoding {
        case unsigned8
        case signed8
        case signed16(littleEndian: Bool)
        case signed24(littleEndian: Bool)
        case signed32(littleEndian: Bool)
        case float32(littleEndian: Bool)

        var bytesPerSample: Int {
            switch self {
            case .unsigned8, .signed8: 1
            case .signed16: 2
            case .signed24: 3
            case .signed32, .float32: 4
            }
        }
    }

    private let data: Data
    private let dataOffset: Int
    private let dataByteCount: Int
    private let encoding: Encoding
    private let blockAlignment: Int
    private var position: Int64 = 0
    let sampleRate: Double
    let frameCount: Int64
    let channelCount: Int
    let processingFormat: AVAudioFormat

    static func openIfSupported(
        url: URL,
        signature: WaveformSourceSignature,
        requireOptIn: Bool = true
    ) -> MappedPCMReader? {
        // AVFoundation is faster on current Apple PCM decoders in warm-cache
        // measurements. Keep the conservative direct reader opt-in until cold
        // external-drive parity and throughput gates prove a win.
        if requireOptIn, ProcessInfo.processInfo.environment["WS_ENABLE_MAPPED_PCM"] != "1" { return nil }
        var info = Darwin.stat()
        guard lstat(url.path, &info) == 0 else { return nil }
        let modificationNanoseconds = Int64(info.st_mtimespec.tv_sec) &* 1_000_000_000 &+ Int64(info.st_mtimespec.tv_nsec)
        guard (info.st_mode & S_IFMT) == S_IFREG,
              info.st_size > 0,
              Int64(info.st_size) == signature.fileSize,
              modificationNanoseconds == signature.modificationNanoseconds else { return nil }
        return try? MappedPCMReader(url: url)
    }

    private init(url: URL) throws {
        data = try Data(contentsOf: url, options: [.mappedIfSafe, .uncached])
        if data.count >= 12, data.ascii(at: 0, count: 4) == "RIFF", data.ascii(at: 8, count: 4) == "WAVE" {
            let parsed = try Self.parseWave(data)
            dataOffset = parsed.offset
            dataByteCount = parsed.byteCount
            encoding = parsed.encoding
            blockAlignment = parsed.blockAlignment
            sampleRate = parsed.sampleRate
            frameCount = parsed.frameCount
            channelCount = parsed.channels
        } else if data.count >= 12, data.ascii(at: 0, count: 4) == "FORM" {
            let parsed = try Self.parseAIFF(data)
            dataOffset = parsed.offset
            dataByteCount = parsed.byteCount
            encoding = parsed.encoding
            blockAlignment = parsed.blockAlignment
            sampleRate = parsed.sampleRate
            frameCount = parsed.frameCount
            channelCount = parsed.channels
        } else {
            throw CocoaError(.fileReadUnsupportedScheme)
        }
        guard let format = planarFloatAudioFormat(sampleRate: sampleRate, channels: channelCount) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        processingFormat = format
    }

    func read(into buffer: AVAudioPCMBuffer, frameCount requested: AVAudioFrameCount) throws {
        let count = min(Int64(requested), frameCount - position)
        guard count > 0 else { buffer.frameLength = 0; return }
        guard buffer.format.channelCount == AVAudioChannelCount(channelCount),
              let channels = buffer.floatChannelData else { throw CocoaError(.fileReadCorruptFile) }
        let frames = Int(count)
        let byteStart = dataOffset + Int(position) * blockAlignment
        let bytesNeeded = frames * blockAlignment
        guard byteStart >= dataOffset,
              bytesNeeded >= 0,
              byteStart <= dataOffset + dataByteCount,
              bytesNeeded <= dataOffset + dataByteCount - byteStart else {
            throw CocoaError(.fileReadCorruptFile)
        }

        try data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                throw CocoaError(.fileReadCorruptFile)
            }
            let source = base.advanced(by: byteStart)
            for channel in 0..<channelCount {
                let output = channels[channel]
                switch encoding {
                case .unsigned8:
                    vDSP_vfltu8(source.advanced(by: channel), vDSP_Stride(channelCount), output, 1, vDSP_Length(frames))
                    var offset: Float = -128
                    var scale: Float = 1 / 128
                    vDSP_vsadd(output, 1, &offset, output, 1, vDSP_Length(frames))
                    vDSP_vsmul(output, 1, &scale, output, 1, vDSP_Length(frames))
                case .signed8:
                    vDSP_vflt8(UnsafeRawPointer(source.advanced(by: channel)).assumingMemoryBound(to: CChar.self), vDSP_Stride(channelCount), output, 1, vDSP_Length(frames))
                    var scale: Float = 1 / 128
                    vDSP_vsmul(output, 1, &scale, output, 1, vDSP_Length(frames))
                case let .signed16(littleEndian)
                    where littleEndian == Self.hostIsLittleEndian
                    && Self.isAligned(source.advanced(by: channel * 2), to: MemoryLayout<Int16>.alignment):
                    let input = UnsafeRawPointer(source.advanced(by: channel * 2)).assumingMemoryBound(to: Int16.self)
                    vDSP_vflt16(input, vDSP_Stride(channelCount), output, 1, vDSP_Length(frames))
                    var scale: Float = 1 / 32_768
                    vDSP_vsmul(output, 1, &scale, output, 1, vDSP_Length(frames))
                case let .signed32(littleEndian)
                    where littleEndian == Self.hostIsLittleEndian
                    && Self.isAligned(source.advanced(by: channel * 4), to: MemoryLayout<Int32>.alignment):
                    let input = UnsafeRawPointer(source.advanced(by: channel * 4)).assumingMemoryBound(to: Int32.self)
                    vDSP_vflt32(input, vDSP_Stride(channelCount), output, 1, vDSP_Length(frames))
                    var scale: Float = 1 / 2_147_483_648
                    vDSP_vsmul(output, 1, &scale, output, 1, vDSP_Length(frames))
                case let .float32(littleEndian)
                    where littleEndian == Self.hostIsLittleEndian
                    && Self.isAligned(source.advanced(by: channel * 4), to: MemoryLayout<Float>.alignment):
                    let input = UnsafeRawPointer(source.advanced(by: channel * 4)).assumingMemoryBound(to: Float.self)
                    var scale: Float = 1
                    vDSP_vsmul(input, vDSP_Stride(channelCount), &scale, output, 1, vDSP_Length(frames))
                default:
                    for frame in 0..<frames {
                        let sample = source.advanced(by: frame * blockAlignment + channel * encoding.bytesPerSample)
                        output[frame] = Self.decode(sample, encoding: encoding)
                    }
                }
            }
        }
        position += count
        buffer.frameLength = AVAudioFrameCount(frames)
    }

    private struct Parsed {
        let offset: Int
        let byteCount: Int
        let encoding: Encoding
        let blockAlignment: Int
        let sampleRate: Double
        let frameCount: Int64
        let channels: Int
    }

    private static func parseWave(_ data: Data) throws -> Parsed {
        var cursor = 12
        var format: (tag: UInt16, channels: Int, rate: Double, align: Int, bits: Int)?
        var payload: (offset: Int, count: Int)?
        while cursor <= data.count - 8 {
            let id = data.ascii(at: cursor, count: 4)
            let size = Int(try data.u32(at: cursor + 4, littleEndian: true))
            let start = cursor + 8
            guard size >= 0, start <= data.count, size <= data.count - start else { throw CocoaError(.fileReadCorruptFile) }
            if id == "fmt ", size >= 16 {
                format = (
                    try data.u16(at: start, littleEndian: true),
                    Int(try data.u16(at: start + 2, littleEndian: true)),
                    Double(try data.u32(at: start + 4, littleEndian: true)),
                    Int(try data.u16(at: start + 12, littleEndian: true)),
                    Int(try data.u16(at: start + 14, littleEndian: true))
                )
            } else if id == "data" {
                payload = (start, size)
            }
            let padded = size + (size & 1)
            guard padded <= data.count - start else { throw CocoaError(.fileReadCorruptFile) }
            cursor = start + padded
        }
        guard let format, let payload,
              format.channels > 0, format.channels <= 32,
              format.rate > 0, format.rate.isFinite,
              format.align > 0, payload.count >= format.align else { throw CocoaError(.fileReadCorruptFile) }
        let encoding: Encoding
        switch (format.tag, format.bits) {
        case (1, 8): encoding = .unsigned8
        case (1, 16): encoding = .signed16(littleEndian: true)
        case (1, 24): encoding = .signed24(littleEndian: true)
        case (1, 32): encoding = .signed32(littleEndian: true)
        case (3, 32): encoding = .float32(littleEndian: true)
        default: throw CocoaError(.fileReadUnsupportedScheme)
        }
        guard format.align == format.channels * encoding.bytesPerSample,
              payload.count % format.align == 0 else { throw CocoaError(.fileReadCorruptFile) }
        return .init(
            offset: payload.offset,
            byteCount: payload.count,
            encoding: encoding,
            blockAlignment: format.align,
            sampleRate: format.rate,
            frameCount: Int64(payload.count / format.align),
            channels: format.channels
        )
    }

    private static func parseAIFF(_ data: Data) throws -> Parsed {
        let form = data.ascii(at: 8, count: 4)
        guard form == "AIFF" || form == "AIFC" else { throw CocoaError(.fileReadUnsupportedScheme) }
        var cursor = 12
        var common: (channels: Int, frames: Int64, bits: Int, rate: Double, compression: String)?
        var payload: (offset: Int, count: Int)?
        while cursor <= data.count - 8 {
            let id = data.ascii(at: cursor, count: 4)
            let size = Int(try data.u32(at: cursor + 4, littleEndian: false))
            let start = cursor + 8
            guard size >= 0, start <= data.count, size <= data.count - start else { throw CocoaError(.fileReadCorruptFile) }
            if id == "COMM", size >= 18 {
                let compression = form == "AIFC" && size >= 22 ? data.ascii(at: start + 18, count: 4) : "NONE"
                common = (
                    Int(try data.u16(at: start, littleEndian: false)),
                    Int64(try data.u32(at: start + 2, littleEndian: false)),
                    Int(try data.u16(at: start + 6, littleEndian: false)),
                    try data.extended80(at: start + 8),
                    compression
                )
            } else if id == "SSND", size >= 8 {
                let offset = Int(try data.u32(at: start, littleEndian: false))
                guard offset <= size - 8 else { throw CocoaError(.fileReadCorruptFile) }
                payload = (start + 8 + offset, size - 8 - offset)
            }
            let padded = size + (size & 1)
            guard padded <= data.count - start else { throw CocoaError(.fileReadCorruptFile) }
            cursor = start + padded
        }
        guard let common, let payload,
              common.channels > 0, common.channels <= 32,
              common.frames > 0, common.rate > 0, common.rate.isFinite else { throw CocoaError(.fileReadCorruptFile) }
        let littleEndian: Bool
        switch common.compression {
        case "NONE", "twos": littleEndian = false
        case "sowt": littleEndian = true
        default: throw CocoaError(.fileReadUnsupportedScheme)
        }
        let encoding: Encoding
        switch common.bits {
        case 8: encoding = .signed8
        case 16: encoding = .signed16(littleEndian: littleEndian)
        case 24: encoding = .signed24(littleEndian: littleEndian)
        case 32: encoding = .signed32(littleEndian: littleEndian)
        default: throw CocoaError(.fileReadUnsupportedScheme)
        }
        let alignment = common.channels * encoding.bytesPerSample
        let availableFrames = Int64(payload.count / alignment)
        guard common.frames > 0, availableFrames >= common.frames else { throw CocoaError(.fileReadCorruptFile) }
        let frames = common.frames
        return .init(
            offset: payload.offset,
            byteCount: Int(frames) * alignment,
            encoding: encoding,
            blockAlignment: alignment,
            sampleRate: common.rate,
            frameCount: frames,
            channels: common.channels
        )
    }

    private static func isAligned(_ pointer: UnsafePointer<UInt8>, to alignment: Int) -> Bool {
        Int(bitPattern: pointer) % alignment == 0
    }

    private static var hostIsLittleEndian: Bool {
        var value: UInt16 = 1
        return withUnsafeBytes(of: &value) { $0[0] == 1 }
    }

    private static func decode(_ bytes: UnsafePointer<UInt8>, encoding: Encoding) -> Float {
        switch encoding {
        case .unsigned8:
            return (Float(bytes[0]) - 128) / 128
        case .signed8:
            return Float(Int8(bitPattern: bytes[0])) / 128
        case let .signed16(littleEndian):
            let raw = littleEndian
                ? UInt16(bytes[0]) | UInt16(bytes[1]) << 8
                : UInt16(bytes[0]) << 8 | UInt16(bytes[1])
            return Float(Int16(bitPattern: raw)) / 32_768
        case let .signed24(littleEndian):
            let raw = littleEndian
                ? Int32(bytes[0]) | Int32(bytes[1]) << 8 | Int32(bytes[2]) << 16
                : Int32(bytes[0]) << 16 | Int32(bytes[1]) << 8 | Int32(bytes[2])
            let signed = (raw & 0x80_0000) != 0 ? raw | ~0xFF_FFFF : raw
            return Float(signed) / 8_388_608
        case let .signed32(littleEndian):
            let raw = littleEndian
                ? UInt32(bytes[0]) | UInt32(bytes[1]) << 8 | UInt32(bytes[2]) << 16 | UInt32(bytes[3]) << 24
                : UInt32(bytes[0]) << 24 | UInt32(bytes[1]) << 16 | UInt32(bytes[2]) << 8 | UInt32(bytes[3])
            return Float(Int32(bitPattern: raw)) / 2_147_483_648
        case let .float32(littleEndian):
            let raw = littleEndian
                ? UInt32(bytes[0]) | UInt32(bytes[1]) << 8 | UInt32(bytes[2]) << 16 | UInt32(bytes[3]) << 24
                : UInt32(bytes[0]) << 24 | UInt32(bytes[1]) << 16 | UInt32(bytes[2]) << 8 | UInt32(bytes[3])
            let value = Float(bitPattern: raw)
            return value.isFinite ? value : 0
        }
    }
}

private nonisolated extension Data {
    func ascii(at offset: Int, count: Int) -> String {
        guard offset >= 0, count >= 0, offset <= self.count, count <= self.count - offset else { return "" }
        return String(decoding: self[offset..<(offset + count)], as: UTF8.self)
    }

    func u16(at offset: Int, littleEndian: Bool) throws -> UInt16 {
        guard offset >= 0, offset <= count - 2 else { throw CocoaError(.fileReadCorruptFile) }
        return littleEndian
            ? UInt16(self[offset]) | UInt16(self[offset + 1]) << 8
            : UInt16(self[offset]) << 8 | UInt16(self[offset + 1])
    }

    func u32(at offset: Int, littleEndian: Bool) throws -> UInt32 {
        guard offset >= 0, offset <= count - 4 else { throw CocoaError(.fileReadCorruptFile) }
        if littleEndian {
            return UInt32(self[offset]) | UInt32(self[offset + 1]) << 8 | UInt32(self[offset + 2]) << 16 | UInt32(self[offset + 3]) << 24
        }
        return UInt32(self[offset]) << 24 | UInt32(self[offset + 1]) << 16 | UInt32(self[offset + 2]) << 8 | UInt32(self[offset + 3])
    }

    func extended80(at offset: Int) throws -> Double {
        guard offset >= 0, offset <= count - 10 else { throw CocoaError(.fileReadCorruptFile) }
        let exponentRaw = try u16(at: offset, littleEndian: false)
        let negative = (exponentRaw & 0x8000) != 0
        let exponent = Int(exponentRaw & 0x7FFF)
        var mantissa: UInt64 = 0
        for index in 0..<8 { mantissa = (mantissa << 8) | UInt64(self[offset + 2 + index]) }
        guard exponent != 0x7FFF else { throw CocoaError(.fileReadCorruptFile) }
        if exponent == 0, mantissa == 0 { return 0 }
        let value = Double(mantissa) / 9_223_372_036_854_775_808.0 * pow(2, Double(exponent - 16_383))
        return negative ? -value : value
    }
}

nonisolated enum SequentialPCMReaderFactory {
    static func open(
        url: URL,
        signature: WaveformSourceSignature,
        preference: PCMReaderPreference
    ) throws -> SequentialPCMReader {
        switch preference {
        case .automatic:
            if let mapped = MappedPCMReader.openIfSupported(url: url, signature: signature) { return mapped }
            return try AVFoundationPCMReader(url: url)
        case .avFoundation:
            return try AVFoundationPCMReader(url: url)
        case .mappedPCM:
            guard let mapped = MappedPCMReader.openIfSupported(
                url: url,
                signature: signature,
                requireOptIn: false
            ) else {
                throw CocoaError(.fileReadUnsupportedScheme)
            }
            return mapped
        }
    }
}

nonisolated enum ExactAnalysisBackend: Sendable, Equatable {
    case automatic
    case accelerate
    case zigPortable
}

nonisolated enum ExactAnalysisPurpose: Sendable, Hashable {
    case selectedEnvelopeOnly
    case selectedLoudnessComplete
    case backgroundUniversal
}

nonisolated func planarFloatAudioFormat(sampleRate: Double, channels: Int) -> AVAudioFormat? {
    guard sampleRate.isFinite, sampleRate >= 1, sampleRate <= 768_000,
          channels > 0, channels <= 256 else { return nil }
    if channels <= 2 {
        return AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: AVAudioChannelCount(channels),
            interleaved: false
        )
    }
    let tag = kAudioChannelLayoutTag_DiscreteInOrder | AudioChannelLayoutTag(channels)
    guard let layout = AVAudioChannelLayout(layoutTag: tag) else { return nil }
    return AVAudioFormat(standardFormatWithSampleRate: sampleRate, channelLayout: layout)
}

nonisolated enum AudioAnalyzer {
    static let version: UInt32 = 3
    static let sparsePreviewThresholdFrames: Int64 = 131_072
    private static let chunkFrames: AVAudioFrameCount = 32_768
    private static let maximumBuckets = 4_096

    static func preview(file: SoundFile, signature: WaveformSourceSignature) throws -> WaveformData {
        let audioFile = try AVAudioFile(
            forReading: URL(fileURLWithPath: file.path),
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
        let format = audioFile.processingFormat
        let totalFrames = max(Int64(audioFile.length), 1)
        let sourceChannels = max(Int(format.channelCount), 1)
        let renderedChannels = min(sourceChannels, 2)

        // Publish exact extrema for short effects without making first display
        // wait for the substantially more expensive BS.1770 pass.
        if totalFrames <= sparsePreviewThresholdFrames {
            return try exact(file: file, signature: signature, purpose: .selectedEnvelopeOnly)
        }

        let outputBuckets = 256
        let windowFrames: AVAudioFrameCount = 2_048
        let windowCount = 8
        let segmentsPerWindow = 8
        var anchors = Array(repeating: [(fraction: Double, peak: WaveformPeak)](), count: renderedChannels)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: windowFrames) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let maximumStart = max(0, totalFrames - Int64(windowFrames))

        for window in 0..<windowCount {
            try Task.checkCancellation()
            let start = windowCount == 1
                ? 0
                : scaledFloor(maximumStart, multiplier: window, divisor: Int64(windowCount - 1))
            audioFile.framePosition = start
            buffer.frameLength = 0
            let requested = AVAudioFrameCount(min(Int64(windowFrames), totalFrames - start))
            try audioFile.read(into: buffer, frameCount: requested)
            let decoded = Int(buffer.frameLength)
            guard decoded > 0, let channelData = buffer.floatChannelData else {
                throw CocoaError(.fileReadCorruptFile)
            }

            for segment in 0..<segmentsPerWindow {
                let localStart = segment * decoded / segmentsPerWindow
                let localEnd = (segment + 1) * decoded / segmentsPerWindow
                guard localStart < localEnd else { continue }
                let centerFrame = start + Int64((localStart + localEnd) / 2)
                let fraction = min(max(Double(centerFrame) / Double(totalFrames), 0), 1)
                for channel in 0..<renderedChannels {
                    var low = Float.greatestFiniteMagnitude
                    var high = -Float.greatestFiniteMagnitude
                    for frame in localStart..<localEnd {
                        let raw = channelData[channel][frame]
                        let value = raw.isFinite ? raw : 0
                        low = min(low, value)
                        high = max(high, value)
                    }
                    anchors[channel].append((fraction, .init(minimum: low, maximum: high)))
                }
            }
        }

        let channels = anchors.map { channelAnchors -> [WaveformPeak] in
            guard let first = channelAnchors.first, let last = channelAnchors.last else {
                return Array(repeating: .init(minimum: 0, maximum: 0), count: outputBuckets)
            }
            var result: [WaveformPeak] = []
            result.reserveCapacity(outputBuckets)
            var upperIndex = 1
            for bucket in 0..<outputBuckets {
                let fraction = (Double(bucket) + 0.5) / Double(outputBuckets)
                while upperIndex < channelAnchors.count, channelAnchors[upperIndex].fraction < fraction {
                    upperIndex += 1
                }
                if fraction <= first.fraction {
                    result.append(first.peak)
                } else if fraction >= last.fraction || upperIndex >= channelAnchors.count {
                    result.append(last.peak)
                } else {
                    let lower = channelAnchors[upperIndex - 1]
                    let upper = channelAnchors[upperIndex]
                    let span = max(upper.fraction - lower.fraction, 0.000_000_1)
                    let amount = Float((fraction - lower.fraction) / span)
                    result.append(.init(
                        minimum: lower.peak.minimum + (upper.peak.minimum - lower.peak.minimum) * amount,
                        maximum: lower.peak.maximum + (upper.peak.maximum - lower.peak.maximum) * amount
                    ))
                }
            }
            return result
        }

        let after = try WaveformSourceSignature.capture(file, analyzerVersion: version)
        guard after == signature else { throw CocoaError(.fileReadUnknown) }
        return WaveformData(
            signature: signature,
            sampleRate: format.sampleRate,
            frameCount: totalFrames,
            sourceChannelCount: sourceChannels,
            levels: [.init(bucketCount: outputBuckets, channels: channels)],
            fidelity: .provisional,
            loudness: .init(integratedLUFS: nil, samplePeakDBFS: nil, analysisComplete: false)
        )
    }

    static func exact(
        file: SoundFile,
        signature: WaveformSourceSignature,
        purpose: ExactAnalysisPurpose,
        backend: ExactAnalysisBackend = .automatic
    ) throws -> WaveformData {
        if resolvedBackend(backend) == .zigPortable {
            return try ZigWaveformCore.analyze(file: file, signature: signature, purpose: purpose)
        }
        switch purpose {
        case .selectedEnvelopeOnly:
            return try analyze(file: file, signature: signature, includeLoudness: false)
        case .selectedLoudnessComplete:
            return try analyze(file: file, signature: signature, includeLoudness: true)
        case .backgroundUniversal:
            return try analyze(
                file: file,
                signature: signature,
                includeLoudness: true,
                maximumBucketCount: 512,
                backgroundUniversal: true
            )
        }
    }

    private static func resolvedBackend(_ requested: ExactAnalysisBackend) -> ExactAnalysisBackend {
        switch requested {
        case .automatic:
            return ProcessInfo.processInfo.environment["WS_WAVEFORM_ANALYZER_BACKEND"] == "zig"
                ? .zigPortable
                : .accelerate
        case .accelerate, .zigPortable:
            return requested
        }
    }

    static func analyze(
        file: SoundFile,
        signature: WaveformSourceSignature,
        includeLoudness: Bool = true,
        maximumBucketCount: Int = maximumBuckets,
        backgroundUniversal: Bool = false,
        readerPreference: PCMReaderPreference = .automatic
    ) throws -> WaveformData {
        let reader = try SequentialPCMReaderFactory.open(
            url: URL(fileURLWithPath: file.path),
            signature: signature,
            preference: readerPreference
        )
        let totalFrames = max(reader.frameCount, 1)
        let sourceChannels = max(reader.channelCount, 1)
        let renderedChannels = min(sourceChannels, 2)
        let sampleRate = reader.sampleRate
        guard sampleRate.isFinite, sampleRate >= 1, sampleRate <= 768_000,
              (!includeLoudness || sampleRate >= 8_000),
              reader.processingFormat.sampleRate == sampleRate,
              Int(reader.processingFormat.channelCount) == sourceChannels
        else { throw CocoaError(.fileReadCorruptFile) }
        let format = reader.processingFormat
        let preserveLegacyShortPartition = backgroundUniversal && totalFrames < Int64(maximumBuckets)
        let baseCount = preferredBaseBucketCount(
            frameCount: totalFrames,
            maximum: preserveLegacyShortPartition ? maximumBuckets : maximumBucketCount
        )

        var minima = Array(repeating: Float.greatestFiniteMagnitude, count: baseCount * renderedChannels)
        var maxima = Array(repeating: -Float.greatestFiniteMagnitude, count: baseCount * renderedChannels)
        var touched = Array(repeating: false, count: baseCount)
        let loudness = includeLoudness
            ? LoudnessAccumulator(sampleRate: sampleRate, channels: sourceChannels)
            : nil
        var samplePeak: Float = 0
        var frameOffset: Int64 = 0

        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunkFrames) else {
            throw CocoaError(.fileReadCorruptFile)
        }

        while frameOffset < totalFrames {
            try Task.checkCancellation()
            buffer.frameLength = 0
            let requested = AVAudioFrameCount(min(Int64(chunkFrames), totalFrames - frameOffset))
            try reader.read(into: buffer, frameCount: requested)
            let count = Int(buffer.frameLength)
            if count == 0 { break }
            guard let channelData = buffer.floatChannelData else { throw CocoaError(.fileReadCorruptFile) }

            aggregateExtrema(
                channelData: channelData,
                frameCount: count,
                frameOffset: frameOffset,
                totalFrames: totalFrames,
                renderedChannels: renderedChannels,
                bucketCount: baseCount,
                minima: &minima,
                maxima: &maxima,
                touched: &touched
            )
            if includeLoudness {
                samplePeak = max(samplePeak, finiteSamplePeak(channelData: channelData, frameCount: count, channels: sourceChannels))
                loudness?.consume(channelData: channelData, frameCount: count)
            }
            frameOffset += Int64(count)
        }
        guard frameOffset == totalFrames else { throw CocoaError(.fileReadCorruptFile) }
        if includeLoudness { loudness?.finishStream() }

        let after = try WaveformSourceSignature.capture(file, analyzerVersion: version)
        guard after == signature else { throw CocoaError(.fileReadUnknown) }

        for bucket in 0..<baseCount where !touched[bucket] {
            for channel in 0..<renderedChannels {
                let index = channel * baseCount + bucket
                minima[index] = 0
                maxima[index] = 0
            }
        }

        let levels = [makeLevel(
            minima: minima,
            maxima: maxima,
            channels: renderedChannels,
            bucketCount: baseCount
        )]
        let peakDB = samplePeak > 0 ? 20 * log10(Double(samplePeak)) : nil
        let raw = WaveformData(
            signature: signature,
            sampleRate: sampleRate,
            frameCount: frameOffset,
            sourceChannelCount: sourceChannels,
            levels: levels,
            fidelity: .exact,
            loudness: .init(
                integratedLUFS: includeLoudness ? loudness?.integratedLUFS() : nil,
                samplePeakDBFS: includeLoudness ? peakDB : nil,
                analysisComplete: includeLoudness
            )
        )
        let purpose: ExactAnalysisPurpose = backgroundUniversal
            ? .backgroundUniversal
            : (includeLoudness ? .selectedLoudnessComplete : .selectedEnvelopeOnly)
        return try ZigWaveformCore.canonicalize(raw, purpose: purpose)
    }

    static func refineLoudness(
        file: SoundFile,
        signature: WaveformSourceSignature,
        envelope: WaveformData,
        readerPreference: PCMReaderPreference = .automatic
    ) throws -> WaveformData {
        guard envelope.fidelity == .exact else { throw CocoaError(.fileReadCorruptFile) }
        if resolvedBackend(.automatic) == .zigPortable {
            return try ZigWaveformCore.analyze(
                file: file,
                signature: signature,
                purpose: .selectedLoudnessComplete,
                readerPreference: readerPreference
            )
        }
        let reader = try SequentialPCMReaderFactory.open(
            url: URL(fileURLWithPath: file.path),
            signature: signature,
            preference: readerPreference
        )
        let totalFrames = max(reader.frameCount, 1)
        let sourceChannels = max(reader.channelCount, 1)
        guard reader.sampleRate == envelope.sampleRate,
              reader.sampleRate >= 8_000,
              totalFrames == envelope.frameCount,
              sourceChannels == envelope.sourceChannelCount,
              reader.processingFormat.sampleRate == reader.sampleRate,
              Int(reader.processingFormat.channelCount) == sourceChannels
        else {
            throw CocoaError(.fileReadUnknown)
        }
        let format = reader.processingFormat

        let loudness = LoudnessAccumulator(sampleRate: reader.sampleRate, channels: sourceChannels)
        var samplePeak: Float = 0
        var frameOffset: Int64 = 0
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunkFrames) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        while frameOffset < totalFrames {
            try Task.checkCancellation()
            buffer.frameLength = 0
            let requested = AVAudioFrameCount(min(Int64(chunkFrames), totalFrames - frameOffset))
            try reader.read(into: buffer, frameCount: requested)
            let count = Int(buffer.frameLength)
            guard count > 0, let channelData = buffer.floatChannelData else {
                throw CocoaError(.fileReadCorruptFile)
            }
            samplePeak = max(samplePeak, finiteSamplePeak(channelData: channelData, frameCount: count, channels: sourceChannels))
            loudness.consume(channelData: channelData, frameCount: count)
            frameOffset += Int64(count)
        }
        loudness.finishStream()
        let after = try WaveformSourceSignature.capture(file, analyzerVersion: version)
        guard after == signature else { throw CocoaError(.fileReadUnknown) }
        let peakDB = samplePeak > 0 ? 20 * log10(Double(samplePeak)) : nil
        return WaveformData(
            signature: signature,
            sampleRate: envelope.sampleRate,
            frameCount: envelope.frameCount,
            sourceChannelCount: envelope.sourceChannelCount,
            levels: envelope.levels,
            fidelity: .exact,
            loudness: .init(
                integratedLUFS: loudness.integratedLUFS(),
                samplePeakDBFS: peakDB,
                analysisComplete: true
            )
        )
    }

    private static func preferredBaseBucketCount(frameCount: Int64, maximum: Int = maximumBuckets) -> Int {
        max(1, min(maximum, Int(clamping: frameCount)))
    }

    private static func aggregateExtrema(
        channelData: UnsafePointer<UnsafeMutablePointer<Float>>,
        frameCount: Int,
        frameOffset: Int64,
        totalFrames: Int64,
        renderedChannels: Int,
        bucketCount: Int,
        minima: inout [Float],
        maxima: inout [Float],
        touched: inout [Bool]
    ) {
        var localStart = 0
        while localStart < frameCount {
            let absoluteStart = frameOffset + Int64(localStart)
            let bucket = min(bucketCount - 1, Int(scaledFloor(
                absoluteStart,
                multiplier: bucketCount,
                divisor: totalFrames
            )))
            let nextBoundary = scaledCeiling(
                totalFrames,
                multiplier: bucket + 1,
                divisor: Int64(bucketCount)
            )
            let runEnd = min(frameCount, max(localStart + 1, Int(nextBoundary - frameOffset)))
            let runCount = runEnd - localStart
            touched[bucket] = true
            for channel in 0..<renderedChannels {
                let source = channelData[channel].advanced(by: localStart)
                var low: Float = 0
                var high: Float = 0
                vDSP_minv(source, 1, &low, vDSP_Length(runCount))
                vDSP_maxv(source, 1, &high, vDSP_Length(runCount))
                if !low.isFinite || !high.isFinite {
                    low = .greatestFiniteMagnitude
                    high = -.greatestFiniteMagnitude
                    for frame in 0..<runCount {
                        let raw = source[frame]
                        let value = raw.isFinite ? raw : 0
                        low = min(low, value)
                        high = max(high, value)
                    }
                }
                let index = channel * bucketCount + bucket
                minima[index] = min(minima[index], low)
                maxima[index] = max(maxima[index], high)
            }
            localStart = runEnd
        }
    }

    private static func scaledFloor(_ value: Int64, multiplier: Int, divisor: Int64) -> Int64 {
        precondition(value >= 0 && multiplier >= 0 && divisor > 0)
        let product = UInt64(value).multipliedFullWidth(by: UInt64(multiplier))
        let division = UInt64(divisor).dividingFullWidth(product)
        return Int64(division.quotient)
    }

    private static func scaledCeiling(_ value: Int64, multiplier: Int, divisor: Int64) -> Int64 {
        precondition(value >= 0 && multiplier >= 0 && divisor > 0)
        let product = UInt64(value).multipliedFullWidth(by: UInt64(multiplier))
        let division = UInt64(divisor).dividingFullWidth(product)
        return Int64(division.quotient + (division.remainder == 0 ? 0 : 1))
    }

    private static func finiteSamplePeak(
        channelData: UnsafePointer<UnsafeMutablePointer<Float>>,
        frameCount: Int,
        channels: Int
    ) -> Float {
        var result: Float = 0
        for channel in 0..<channels {
            var peak: Float = 0
            vDSP_maxmgv(channelData[channel], 1, &peak, vDSP_Length(frameCount))
            if peak.isFinite {
                result = max(result, peak)
            } else {
                for frame in 0..<frameCount {
                    let value = channelData[channel][frame]
                    if value.isFinite { result = max(result, abs(value)) }
                }
            }
        }
        return result
    }

    private static func makeLevel(
        minima: [Float],
        maxima: [Float],
        channels: Int,
        bucketCount: Int
    ) -> WaveformLevel {
        .init(
            bucketCount: bucketCount,
            channels: (0..<channels).map { channel in
                (0..<bucketCount).map { bucket in
                    let index = channel * bucketCount + bucket
                    return .init(minimum: minima[index], maximum: maxima[index])
                }
            }
        )
    }

}

private nonisolated struct Biquad {
    let b0: Double
    let b1: Double
    let b2: Double
    let a1: Double
    let a2: Double
    var z1: Double = 0
    var z2: Double = 0

    mutating func process(_ input: Double) -> Double {
        let output = b0 * input + z1
        z1 = b1 * input - a1 * output + z2
        z2 = b2 * input - a2 * output
        return output
    }

    static func kShelf(sampleRate: Double) -> Biquad {
        let frequency = 1_681.974450955533
        let gain = 3.999843853973347
        let q = 0.7071752369554196
        let k = tan(.pi * frequency / sampleRate)
        let vh = pow(10, gain / 20)
        let vb = pow(vh, 0.4996667741545416)
        let a0 = 1 + k / q + k * k
        return .init(
            b0: (vh + vb * k / q + k * k) / a0,
            b1: 2 * (k * k - vh) / a0,
            b2: (vh - vb * k / q + k * k) / a0,
            a1: 2 * (k * k - 1) / a0,
            a2: (1 - k / q + k * k) / a0
        )
    }

    static func rlbHighPass(sampleRate: Double) -> Biquad {
        let frequency = 38.13547087602444
        let q = 0.5003270373238773
        let k = tan(.pi * frequency / sampleRate)
        let a0 = 1 + k / q + k * k
        return .init(b0: 1, b1: -2, b2: 1, a1: 2 * (k * k - 1) / a0, a2: (1 - k / q + k * k) / a0)
    }
}

private nonisolated struct KWeightingChannel {
    var shelf: Biquad
    var highPass: Biquad

    init(sampleRate: Double) {
        shelf = .kShelf(sampleRate: sampleRate)
        highPass = .rlbHighPass(sampleRate: sampleRate)
    }

    mutating func process(_ sample: Double) -> Double {
        highPass.process(shelf.process(sample))
    }
}

private nonisolated final class LoudnessAccumulator {
    private let setup: vDSP_biquad_SetupD?
    private var delays: [[Double]]
    private var fallbackFilters: [KWeightingChannel]
    private let channelPowerWeights: [Double]
    private let segmentFrames: Int
    private var converted: [Double] = []
    private var filtered: [[Double]]
    private var segmentEnergy: Double = 0
    private var framesInSegment: Int = 0
    private var recentSegments: [(energy: Double, frames: Int)] = []
    private var gatedPowerSums: [Double]
    private var gatedCounts: [Int]
    private var absolutePowerSum: Double = 0
    private var absoluteBlockCount: Int = 0
    private var totalEnergy: Double = 0
    private var totalFrames: Int = 0

    init(sampleRate: Double, channels: Int) {
        let shelf = Biquad.kShelf(sampleRate: sampleRate)
        let highPass = Biquad.rlbHighPass(sampleRate: sampleRate)
        let coefficients = [
            shelf.b0, shelf.b1, shelf.b2, shelf.a1, shelf.a2,
            highPass.b0, highPass.b1, highPass.b2, highPass.a1, highPass.a2,
        ]
        setup = coefficients.withUnsafeBufferPointer {
            vDSP_biquad_CreateSetupD($0.baseAddress!, 2)
        }
        delays = Array(repeating: Array(repeating: 0, count: 6), count: channels)
        fallbackFilters = (0..<channels).map { _ in KWeightingChannel(sampleRate: sampleRate) }
        filtered = Array(repeating: [], count: channels)
        // Common 5.1/7.1 AVFoundation order is L,R,C,LFE,surrounds.
        // BS.1770 excludes LFE and applies +1.5 dB (power 1.41) to surrounds.
        channelPowerWeights = (0..<channels).map { channel in
            if channels >= 6, channel == 3 { return 0 }
            if channels >= 6, channel >= 4 { return 1.41 }
            return 1
        }
        // 0.001 LU bins from -70 through +50 bound memory independently of
        // recording duration while keeping relative-gate classification tight.
        gatedPowerSums = Array(repeating: 0, count: 120_001)
        gatedCounts = Array(repeating: 0, count: 120_001)
        segmentFrames = max(1, Int((sampleRate * 0.1).rounded()))
    }

    deinit {
        if let setup { vDSP_biquad_DestroySetupD(setup) }
    }

    func consume(
        channelData: UnsafePointer<UnsafeMutablePointer<Float>>,
        frameCount: Int
    ) {
        guard frameCount > 0 else { return }
        if converted.count < frameCount { converted = Array(repeating: 0, count: frameCount) }
        for channel in filtered.indices where filtered[channel].count < frameCount {
            filtered[channel] = Array(repeating: 0, count: frameCount)
        }

        for channel in filtered.indices where channelPowerWeights[channel] != 0 {
            let source = channelData[channel]
            var peak: Float = 0
            vDSP_maxmgv(source, 1, &peak, vDSP_Length(frameCount))
            converted.withUnsafeMutableBufferPointer { destination in
                if peak.isFinite {
                    vDSP_vspdp(source, 1, destination.baseAddress!, 1, vDSP_Length(frameCount))
                } else {
                    for frame in 0..<frameCount {
                        let value = source[frame]
                        destination[frame] = value.isFinite ? Double(value) : 0
                    }
                }
            }
            filtered[channel].withUnsafeMutableBufferPointer { output in
                if let setup {
                    delays[channel].withUnsafeMutableBufferPointer { delay in
                        converted.withUnsafeBufferPointer { input in
                            vDSP_biquadD(
                                setup,
                                delay.baseAddress!,
                                input.baseAddress!, 1,
                                output.baseAddress!, 1,
                                vDSP_Length(frameCount)
                            )
                        }
                    }
                } else {
                    for frame in 0..<frameCount {
                        output[frame] = fallbackFilters[channel].process(converted[frame])
                    }
                }
            }
        }

        var localStart = 0
        while localStart < frameCount {
            let runCount = min(segmentFrames - framesInSegment, frameCount - localStart)
            for channel in filtered.indices where channelPowerWeights[channel] != 0 {
                var energy: Double = 0
                filtered[channel].withUnsafeBufferPointer { values in
                    vDSP_svesqD(values.baseAddress!.advanced(by: localStart), 1, &energy, vDSP_Length(runCount))
                }
                segmentEnergy += energy * channelPowerWeights[channel]
            }
            localStart += runCount
            framesInSegment += runCount
            if framesInSegment == segmentFrames { appendSegment() }
        }
    }

    func finishStream() {
        if framesInSegment > 0 { appendSegment() }
    }

    private func appendSegment() {
        let segment = (energy: segmentEnergy, frames: max(framesInSegment, 1))
        totalEnergy += segment.energy
        totalFrames += segment.frames
        recentSegments.append(segment)
        if recentSegments.count == 4 {
            let frameCount = recentSegments.reduce(0) { $0 + $1.frames }
            if frameCount == segmentFrames * 4 {
                appendBlockPower(recentSegments.reduce(0) { $0 + $1.energy } / Double(frameCount))
            }
            recentSegments.removeFirst()
        }
        segmentEnergy = 0
        framesInSegment = 0
    }

    private func appendBlockPower(_ power: Double) {
        guard power > 0 else { return }
        let loudness = -0.691 + 10 * log10(power)
        guard loudness > -70 else { return }
        absolutePowerSum += power
        absoluteBlockCount += 1
        let index = min(120_000, max(0, Int(((loudness + 70) * 1_000).rounded(.down))))
        gatedPowerSums[index] += power
        gatedCounts[index] += 1
    }

    func integratedLUFS() -> Double? {
        if absoluteBlockCount == 0 {
            guard totalFrames > 0, totalEnergy > 0 else { return nil }
            let power = totalEnergy / Double(totalFrames)
            let loudness = -0.691 + 10 * log10(power)
            return loudness > -70 ? loudness : nil
        }
        let preliminaryPower = absolutePowerSum / Double(absoluteBlockCount)
        let relativeThreshold = -0.691 + 10 * log10(preliminaryPower) - 10
        var relativePowerSum: Double = 0
        var relativeCount = 0
        for index in gatedCounts.indices where gatedCounts[index] > 0 {
            let binCenterLUFS = -70 + (Double(index) + 0.5) / 1_000
            if binCenterLUFS > relativeThreshold {
                relativePowerSum += gatedPowerSums[index]
                relativeCount += gatedCounts[index]
            }
        }
        guard relativeCount > 0 else { return nil }
        return -0.691 + 10 * log10(relativePowerSum / Double(relativeCount))
    }
}
