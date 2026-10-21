import Foundation
import AVFoundation

/// Temporary host PCM for compressed examples. No catalog import or export is
/// created. Keep the core's 60-second PCM contract and a separate memory ceiling.
nonisolated enum ExampleAudio {
    struct PCM {
        let samples: [Float]
        let frames: Int
        let channels: UInt32
        let sampleRate: UInt32
    }

    enum DecodeError: LocalizedError {
        case unsupported, tooLong, tooLarge, truncated, nonfinite, changed

        var errorDescription: String? {
            switch self {
            case .unsupported: return String(localized: "This audio format is unavailable or has no readable audio.")
            case .tooLong: return String(localized: "Choose a compressed audio example of 60 seconds or less.")
            case .tooLarge: return String(localized: "The decoded example exceeds the 64 MiB limit. Choose a shorter clip.")
            case .truncated: return String(localized: "The audio ended before its declared length.")
            case .nonfinite: return String(localized: "The audio contains invalid samples.")
            case .changed: return String(localized: "The source changed while it was being decoded. Try again.")
            }
        }
    }

    static func decode(_ url: URL, checkCancellation: () throws -> Void) throws -> PCM {
        try checkCancellation()
        let before = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        let format = file.processingFormat
        let channels = Int(format.channelCount)
        let rate = format.sampleRate
        guard rate.isFinite, rate >= 1, rate <= 384_000, rate.rounded() == rate,
              channels > 0, channels <= 256, file.length > 0 else { throw DecodeError.unsupported }
        guard Double(file.length) <= rate * 60 else { throw DecodeError.tooLong }
        let maxSamples = 64 * 1024 * 1024 / MemoryLayout<Float>.size
        guard file.length <= maxSamples / channels else { throw DecodeError.tooLarge }
        let frames = Int(file.length)
        let capacity = AVAudioFrameCount(min(32_768, frames))
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { throw DecodeError.unsupported }
        var samples = [Float](repeating: 0, count: frames * channels)
        var offset = 0
        while offset < frames {
            try checkCancellation()
            try file.read(into: buffer, frameCount: AVAudioFrameCount(min(Int(capacity), frames - offset)))
            let count = Int(buffer.frameLength)
            guard count > 0, let source = buffer.floatChannelData else { throw DecodeError.truncated }
            for frame in 0..<count {
                for channel in 0..<channels {
                    let value = source[channel][frame]
                    guard value.isFinite else { throw DecodeError.nonfinite }
                    samples[(offset + frame) * channels + channel] = value
                }
            }
            offset += count
        }
        try checkCancellation()
        let after = try URL(fileURLWithPath: url.path).resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        guard before.fileSize == after.fileSize, before.contentModificationDate == after.contentModificationDate else {
            throw DecodeError.changed
        }
        return PCM(samples: samples, frames: frames, channels: UInt32(channels), sampleRate: UInt32(rate))
    }
}
