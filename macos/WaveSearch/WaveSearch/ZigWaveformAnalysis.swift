import Foundation
@preconcurrency import AVFoundation
import WaveSearchKit

nonisolated struct WaveformCoreError: Error, CustomStringConvertible, Sendable {
    let status: Int32
    let message: String

    init(status: Int32) {
        self.status = status
        self.message = ws_last_error_message().map { String(cString: $0) } ?? "Waveform core error \(status)"
    }

    var description: String { message }
}

nonisolated enum ZigWaveformCore {
    static let analyzerVersion: UInt32 = 3
    static let codecVersion: UInt32 = 3
    private static let chunkFrames: AVAudioFrameCount = 32_768

    static func analyze(
        file: SoundFile,
        signature: WaveformSourceSignature,
        purpose: ExactAnalysisPurpose,
        readerPreference: PCMReaderPreference = .automatic
    ) throws -> WaveformData {
        let reader = try SequentialPCMReaderFactory.open(
            url: URL(fileURLWithPath: file.path),
            signature: signature,
            preference: readerPreference
        )
        let sourceChannels = reader.channelCount
        let format = reader.processingFormat
        guard sourceChannels > 0, sourceChannels <= 256,
              reader.frameCount > 0,
              format.sampleRate == reader.sampleRate,
              Int(format.channelCount) == sourceChannels,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunkFrames) else {
            throw CocoaError(.fileReadCorruptFile)
        }

        var config = WSWaveformAnalyzerConfig()
        config.struct_size = UInt32(MemoryLayout<WSWaveformAnalyzerConfig>.size)
        config.version = 1
        config.purpose = purpose == .backgroundUniversal ? 2 : 1
        config.flags = purpose == .selectedEnvelopeOnly ? 0 : 1
        config.backend = 1
        config.sample_rate = reader.sampleRate
        config.total_frames = UInt64(reader.frameCount)
        config.channel_count = UInt32(sourceChannels)
        config.source_file_size = signature.fileSize
        config.source_mtime_ns = signature.modificationNanoseconds
        config.source_content_hash = signature.contentHash

        var analyzer: OpaquePointer?
        var status = ws_waveform_analyzer_create_v1(&config, &analyzer)
        guard status == 0, let analyzer else { throw WaveformCoreError(status: status) }
        defer { ws_waveform_analyzer_destroy(analyzer) }

        var consumed: Int64 = 0
        while consumed < reader.frameCount {
            do {
                try Task.checkCancellation()
            } catch {
                _ = ws_waveform_analyzer_cancel(analyzer)
                throw error
            }
            buffer.frameLength = 0
            let requested = AVAudioFrameCount(min(Int64(chunkFrames), reader.frameCount - consumed))
            try reader.read(into: buffer, frameCount: requested)
            let frameCount = Int(buffer.frameLength)
            guard frameCount > 0, let sourcePlanes = buffer.floatChannelData else {
                throw CocoaError(.fileReadCorruptFile)
            }
            let planes = (0..<sourceChannels).map { UnsafePointer<Float>(sourcePlanes[$0]) as UnsafePointer<Float>? }
            var pcm = WSWaveformPCMBuffer()
            pcm.struct_size = UInt32(MemoryLayout<WSWaveformPCMBuffer>.size)
            pcm.version = 1
            pcm.layout = 1
            pcm.channel_count = UInt32(sourceChannels)
            pcm.frame_count = UInt64(frameCount)
            status = planes.withUnsafeBufferPointer { planeBuffer in
                pcm.planes = planeBuffer.baseAddress
                return ws_waveform_analyzer_push_v1(analyzer, &pcm)
            }
            guard status == 0 else { throw WaveformCoreError(status: status) }
            consumed += Int64(frameCount)
        }
        guard consumed == reader.frameCount else { throw CocoaError(.fileReadCorruptFile) }
        do {
            try Task.checkCancellation()
        } catch {
            _ = ws_waveform_analyzer_cancel(analyzer)
            throw error
        }

        var result: OpaquePointer?
        status = ws_waveform_analyzer_finish_v1(analyzer, &result)
        guard status == 0, let result else { throw WaveformCoreError(status: status) }
        defer { ws_waveform_result_destroy(result) }

        let after = try WaveformSourceSignature.capture(file, analyzerVersion: analyzerVersion)
        guard after == signature else { throw CocoaError(.fileReadUnknown) }
        return try waveformData(from: result, standardizedPath: signature.standardizedPath)
    }

    static func canonicalize(_ waveform: WaveformData, purpose: ExactAnalysisPurpose) throws -> WaveformData {
        guard let highest = waveform.levels.last else { throw CocoaError(.fileReadCorruptFile) }
        let tier: PersistentWaveformTier = purpose == .backgroundUniversal ? .universal : .detailed
        let result = try makeResult(from: waveform, level: highest, tier: tier)
        defer { ws_waveform_result_destroy(result) }
        return try waveformData(from: result, standardizedPath: waveform.signature.standardizedPath)
    }

    static func encode(_ waveform: WaveformData, tier: PersistentWaveformTier) throws -> Data {
        guard waveform.fidelity == .exact, waveform.loudness.analysisComplete,
              let level = tier == .universal ? waveform.levels.first : waveform.levels.last else {
            throw CocoaError(.fileWriteInvalidFileName)
        }
        let result = try makeResult(from: waveform, level: level, tier: tier)
        defer { ws_waveform_result_destroy(result) }
        var required: UInt64 = 0
        var status = ws_waveform_result_serialize_wvt3_v1(result, tier.rawValue, nil, 0, &required)
        guard status == 0, required > 0, required <= 4 * 1024 * 1024 else {
            throw WaveformCoreError(status: status)
        }
        var output = Data(count: Int(required))
        status = output.withUnsafeMutableBytes { raw in
            ws_waveform_result_serialize_wvt3_v1(
                result,
                tier.rawValue,
                raw.baseAddress?.assumingMemoryBound(to: UInt8.self),
                UInt64(raw.count),
                &required
            )
        }
        guard status == 0 else { throw WaveformCoreError(status: status) }
        return output
    }

    static func decode(_ blob: Data, standardizedPath: String) throws -> (PersistentWaveformTier, WaveformData) {
        var result: OpaquePointer?
        let status = blob.withUnsafeBytes { raw in
            ws_waveform_result_deserialize_wvt3_v1(
                raw.baseAddress?.assumingMemoryBound(to: UInt8.self),
                UInt64(raw.count),
                &result
            )
        }
        guard status == 0, let result else { throw WaveformCoreError(status: status) }
        defer { ws_waveform_result_destroy(result) }
        let data = try waveformData(from: result, standardizedPath: standardizedPath)
        var info = WSWaveformResultInfo()
        info.struct_size = UInt32(MemoryLayout<WSWaveformResultInfo>.size)
        info.version = 1
        let infoStatus = ws_waveform_result_info_v1(result, &info)
        guard infoStatus == 0 else { throw WaveformCoreError(status: infoStatus) }
        let tier: PersistentWaveformTier
        switch info.purpose {
        case 1: tier = .detailed
        case 2: tier = .universal
        default: throw CocoaError(.fileReadCorruptFile)
        }
        return (tier, data)
    }

    private static func makeResult(
        from waveform: WaveformData,
        level: WaveformLevel,
        tier: PersistentWaveformTier
    ) throws -> OpaquePointer {
        guard waveform.sampleRate.isFinite, waveform.sampleRate >= 1, waveform.sampleRate <= 768_000,
              waveform.frameCount > 0,
              waveform.sourceChannelCount > 0, waveform.sourceChannelCount <= 256,
              waveform.signature.fileSize >= 0, waveform.signature.modificationNanoseconds >= 0,
              level.bucketCount > 0, level.bucketCount <= 4_096,
              !level.channels.isEmpty, level.channels.count <= 2 else {
            throw CocoaError(.fileWriteUnknown)
        }
        var info = WSWaveformResultInfo()
        info.struct_size = UInt32(MemoryLayout<WSWaveformResultInfo>.size)
        info.version = 1
        info.analyzer_version = analyzerVersion
        info.codec_version = codecVersion
        info.purpose = tier == .universal ? 2 : 1
        info.resolved_backend = 2 // Host Accelerate adapter.
        info.flags = 8 | (tier == .detailed ? 16 : 0)
        if waveform.loudness.analysisComplete { info.flags |= 1 }
        if let lufs = waveform.loudness.integratedLUFS {
            info.flags |= 2
            info.integrated_lufs = lufs
        }
        if let peak = waveform.loudness.samplePeakDBFS {
            info.flags |= 4
            info.sample_peak_dbfs = peak
        }
        info.level_count = 1
        setBucketCount(&info, index: 0, value: UInt32(level.bucketCount))
        info.sample_rate = waveform.sampleRate
        info.frame_count = UInt64(waveform.frameCount)
        info.source_channel_count = UInt32(waveform.sourceChannelCount)
        info.rendered_channel_count = UInt32(level.channels.count)
        info.source_file_size = waveform.signature.fileSize
        info.source_mtime_ns = waveform.signature.modificationNanoseconds
        info.source_content_hash = waveform.signature.contentHash

        var peaks: [WSWaveformPeak] = []
        peaks.reserveCapacity(level.bucketCount * level.channels.count)
        for channel in level.channels {
            guard channel.count == level.bucketCount else { throw CocoaError(.fileWriteUnknown) }
            peaks.append(contentsOf: channel.map { WSWaveformPeak(minimum: $0.minimum, maximum: $0.maximum) })
        }
        var result: OpaquePointer?
        let status = peaks.withUnsafeBufferPointer {
            ws_waveform_result_create_v1(&info, $0.baseAddress, UInt64($0.count), &result)
        }
        guard status == 0, let result else { throw WaveformCoreError(status: status) }
        return result
    }

    private static func waveformData(
        from result: OpaquePointer,
        standardizedPath: String
    ) throws -> WaveformData {
        var info = WSWaveformResultInfo()
        info.struct_size = UInt32(MemoryLayout<WSWaveformResultInfo>.size)
        info.version = 1
        var status = ws_waveform_result_info_v1(result, &info)
        guard status == 0, info.level_count > 0, info.level_count <= 4 else {
            throw WaveformCoreError(status: status)
        }
        var levels: [WaveformLevel] = []
        levels.reserveCapacity(Int(info.level_count))
        for index in 0..<Int(info.level_count) {
            let bucketCount = Int(getBucketCount(info, index: index))
            let renderedChannels = Int(info.rendered_channel_count)
            guard bucketCount > 0, renderedChannels > 0 else { throw CocoaError(.fileReadCorruptFile) }
            var required: UInt64 = 0
            status = ws_waveform_result_copy_level_v1(result, UInt32(index), nil, 0, &required)
            guard status == 0, required == UInt64(bucketCount * renderedChannels) else {
                throw WaveformCoreError(status: status)
            }
            var peaks = [WSWaveformPeak](repeating: .init(minimum: 0, maximum: 0), count: Int(required))
            status = peaks.withUnsafeMutableBufferPointer {
                ws_waveform_result_copy_level_v1(result, UInt32(index), $0.baseAddress, UInt64($0.count), &required)
            }
            guard status == 0 else { throw WaveformCoreError(status: status) }
            let channels = (0..<renderedChannels).map { channel in
                (0..<bucketCount).map { bucket in
                    let peak = peaks[channel * bucketCount + bucket]
                    return WaveformPeak(minimum: peak.minimum, maximum: peak.maximum)
                }
            }
            levels.append(.init(bucketCount: bucketCount, channels: channels))
        }
        let lufsValid = (info.flags & 2) != 0
        let peakValid = (info.flags & 4) != 0
        return WaveformData(
            signature: .init(
                standardizedPath: standardizedPath,
                fileSize: info.source_file_size,
                modificationNanoseconds: info.source_mtime_ns,
                contentHash: info.source_content_hash,
                analyzerVersion: info.analyzer_version
            ),
            sampleRate: info.sample_rate,
            frameCount: Int64(info.frame_count),
            sourceChannelCount: Int(info.source_channel_count),
            levels: levels,
            fidelity: .exact,
            loudness: .init(
                integratedLUFS: lufsValid && info.integrated_lufs.isFinite ? info.integrated_lufs : nil,
                samplePeakDBFS: peakValid && info.sample_peak_dbfs.isFinite ? info.sample_peak_dbfs : nil,
                analysisComplete: (info.flags & 1) != 0
            )
        )
    }

    private static func setBucketCount(_ info: inout WSWaveformResultInfo, index: Int, value: UInt32) {
        withUnsafeMutableBytes(of: &info.level_bucket_counts) { raw in
            raw.bindMemory(to: UInt32.self)[index] = value
        }
    }

    private static func getBucketCount(_ info: WSWaveformResultInfo, index: Int) -> UInt32 {
        var counts = info.level_bucket_counts
        return withUnsafeBytes(of: &counts) { $0.bindMemory(to: UInt32.self)[index] }
    }
}
