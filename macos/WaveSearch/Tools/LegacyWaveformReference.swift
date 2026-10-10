import Foundation

/// Frozen schema-v10 Swift reference used only by the differential benchmark.
/// Production μ-law and WVT3 ownership lives in libwavesearch.
nonisolated enum LegacyWaveformReference {
    private static let mu: Float = 255
    private static let denominator = log1p(mu)

    static func encode(_ waveform: WaveformData, tier: PersistentWaveformTier) throws -> Data {
        guard waveform.fidelity == .exact, waveform.loudness.analysisComplete,
              let level = tier == .universal ? waveform.levels.first : waveform.levels.last else {
            throw CocoaError(.fileWriteInvalidFileName)
        }
        var data = Data()
        append(UInt32(0x3354_5657), to: &data)
        append(UInt32(1), to: &data)
        append(UInt32(3), to: &data)
        append(tier.rawValue, to: &data)
        append(waveform.signature.analyzerVersion, to: &data)
        append(waveform.signature.fileSize, to: &data)
        append(waveform.signature.modificationNanoseconds, to: &data)
        append(waveform.signature.contentHash, to: &data)
        append(waveform.sampleRate.bitPattern, to: &data)
        append(waveform.frameCount, to: &data)
        append(UInt32(waveform.sourceChannelCount), to: &data)
        append(UInt32(level.bucketCount), to: &data)
        append(UInt32(level.channels.count), to: &data)
        append((waveform.loudness.integratedLUFS ?? .nan).bitPattern, to: &data)
        append((waveform.loudness.samplePeakDBFS ?? .nan).bitPattern, to: &data)
        for channel in level.channels {
            guard channel.count == level.bucketCount else { throw CocoaError(.fileWriteUnknown) }
            for peak in channel {
                data.append(UInt8(bitPattern: muEncode(peak.minimum)))
                data.append(UInt8(bitPattern: muEncode(peak.maximum)))
            }
        }
        append(checksum(data), to: &data)
        return data
    }

    private static func muEncode(_ sample: Float) -> Int8 {
        let value = sample.isFinite ? min(max(sample, -1), 1) : 0
        guard value != 0 else { return 0 }
        let magnitude = log1p(mu * abs(value)) / denominator
        let code = min(127, max(0, Int((magnitude * 127).rounded())))
        return Int8(value < 0 ? -code : code)
    }

    private static func checksum(_ data: Data) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in data { hash ^= UInt64(byte); hash &*= 0x0000_0100_0000_01b3 }
        return hash
    }

    private static func append<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
        var little = value.littleEndian
        withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
    }
}
