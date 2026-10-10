import Foundation
import WaveSearchKit

nonisolated struct SoundFile: Identifiable, Hashable, Sendable {
    let id: Int
    let folderId: Int
    let path: String
    let name: String
    let durationMs: Int
    let contentHash: Int64
    var acousticGroupId: Int64 = 0
    var url: URL { URL(fileURLWithPath: path) }
}

@main
struct WaveformBenchmark {
    static func elapsedMilliseconds(since start: ContinuousClock.Instant) -> Double {
        let components = start.duration(to: .now).components
        return Double(components.seconds) * 1_000 + Double(components.attoseconds) / 1e15
    }

    static func percentile(_ values: [Double], _ fraction: Double) -> Double {
        let sorted = values.sorted()
        return sorted[min(sorted.count - 1, Int(Double(sorted.count - 1) * fraction))]
    }

    static func main() async throws {
        guard CommandLine.arguments.count == 2 else {
            FileHandle.standardError.write(Data("usage: waveform-benchmark AUDIO_FILE\n".utf8))
            exit(2)
        }
        let path = URL(fileURLWithPath: CommandLine.arguments[1]).standardizedFileURL.path
        let folder = URL(fileURLWithPath: path).deletingLastPathComponent().path
        let database = FileManager.default.temporaryDirectory.appendingPathComponent("wavesearch-waveform-benchmark-\(UUID().uuidString).sqlite").path
        defer { try? FileManager.default.removeItem(atPath: database) }
        guard database.withCString({ ws_init($0) }) == 0 else { throw CocoaError(.fileWriteUnknown) }
        defer { ws_deinit() }
        guard folder.withCString({ ws_index_folder_ex(1, $0, UInt32(WS_INDEX_FAST)) }) == 0 else { throw CocoaError(.fileReadUnknown) }

        var rows = [WSResult](repeating: WSResult(), count: 10_000)
        let count = rows.withUnsafeMutableBufferPointer { ws_list_folder(1, $0.baseAddress, Int32($0.count)) }
        guard count > 0 else { throw CocoaError(.fileNoSuchFile) }
        guard let raw = rows.prefix(Int(count)).first(where: { result in
            withUnsafeBytes(of: result.path) { String(cString: $0.baseAddress!.assumingMemoryBound(to: CChar.self)) == path }
        }) else { throw CocoaError(.fileNoSuchFile) }
        let file = SoundFile(
            id: Int(raw.file_id),
            folderId: Int(raw.folder_id),
            path: path,
            name: URL(fileURLWithPath: path).lastPathComponent,
            durationMs: Int(raw.duration_ms),
            contentHash: raw.content_hash
        )

        let analysisRuns = max(1, Int(ProcessInfo.processInfo.environment["WS_WAVEFORM_BENCH_RUNS"] ?? "5") ?? 5)
        var previewMilliseconds: [Double] = []
        for _ in 0..<30 {
            let start = ContinuousClock.now
            let signature = try WaveformSourceSignature.capture(file, analyzerVersion: AudioAnalyzer.version)
            _ = try AudioAnalyzer.preview(file: file, signature: signature)
            previewMilliseconds.append(elapsedMilliseconds(since: start))
        }

        let benchmarkSignature = try WaveformSourceSignature.capture(file, analyzerVersion: AudioAnalyzer.version)
        var envelopeMilliseconds: [Double] = []
        var loudnessMilliseconds: [Double] = []
        var totalMilliseconds: [Double] = []
        var selectedCompleteMilliseconds: [Double] = []
        var portableMilliseconds: [Double] = []
        var backgroundMilliseconds: [Double] = []
        var referenceWaveform: WaveformData?
        for _ in 0..<analysisRuns {
            var start = ContinuousClock.now
            let envelope = try AudioAnalyzer.analyze(file: file, signature: benchmarkSignature, includeLoudness: false)
            envelopeMilliseconds.append(elapsedMilliseconds(since: start))
            start = .now
            let completed = try AudioAnalyzer.refineLoudness(file: file, signature: benchmarkSignature, envelope: envelope)
            loudnessMilliseconds.append(elapsedMilliseconds(since: start))
            guard completed.fidelity == .exact, completed.loudness.analysisComplete else { throw CocoaError(.fileReadCorruptFile) }
            totalMilliseconds.append(envelopeMilliseconds.last! + loudnessMilliseconds.last!)
            start = .now
            let selectedComplete = try AudioAnalyzer.exact(file: file, signature: benchmarkSignature, purpose: .selectedLoudnessComplete)
            selectedCompleteMilliseconds.append(elapsedMilliseconds(since: start))
            guard selectedComplete.levels.last?.bucketCount == envelope.levels.last?.bucketCount,
                  selectedComplete.loudness.analysisComplete else { throw CocoaError(.fileReadCorruptFile) }
            referenceWaveform = selectedComplete
            start = .now
            let portable = try AudioAnalyzer.exact(
                file: file,
                signature: benchmarkSignature,
                purpose: .selectedLoudnessComplete,
                backend: .zigPortable
            )
            portableMilliseconds.append(elapsedMilliseconds(since: start))
            let lufsDelta = abs((portable.loudness.integratedLUFS ?? 0) - (selectedComplete.loudness.integratedLUFS ?? 0))
            let peakDelta = abs((portable.loudness.samplePeakDBFS ?? 0) - (selectedComplete.loudness.samplePeakDBFS ?? 0))
            guard portable.levels == selectedComplete.levels,
                  lufsDelta <= 0.000_001,
                  peakDelta <= 0.000_001 else {
                FileHandle.standardError.write(Data(
                    "waveform zig_parity=failed levels=\(portable.levels == selectedComplete.levels) lufs_delta=\(lufsDelta) peak_delta=\(peakDelta)\n".utf8
                ))
                throw CocoaError(.fileReadCorruptFile)
            }
            start = .now
            let universal = try AudioAnalyzer.exact(file: file, signature: benchmarkSignature, purpose: .backgroundUniversal)
            backgroundMilliseconds.append(elapsedMilliseconds(since: start))
            guard universal.levels.count == 1,
                  universal.levels[0].bucketCount <= 512,
                  universal.levels[0] == envelope.levels[0],
                  universal.loudness.analysisComplete else { throw CocoaError(.fileReadCorruptFile) }
        }

        guard let referenceWaveform else { throw CocoaError(.fileReadCorruptFile) }
        for tier in [PersistentWaveformTier.universal, .detailed] {
            let coreBytes = try WaveformTierCodec.encode(referenceWaveform, tier: tier)
            let legacyBytes = try LegacyWaveformReference.encode(referenceWaveform, tier: tier)
            guard coreBytes == legacyBytes else { throw CocoaError(.fileReadCorruptFile) }
        }
        print("waveform zig_parity=passed wvt3_byte_parity=passed")

        if ProcessInfo.processInfo.environment["WS_WAVEFORM_MAPPED_PARITY"] == "1" {
            let av = try AudioAnalyzer.analyze(
                file: file,
                signature: benchmarkSignature,
                includeLoudness: true,
                readerPreference: .avFoundation
            )
            let mapped = try AudioAnalyzer.analyze(
                file: file,
                signature: benchmarkSignature,
                includeLoudness: true,
                readerPreference: .mappedPCM
            )
            let lufsDelta = abs((av.loudness.integratedLUFS ?? 0) - (mapped.loudness.integratedLUFS ?? 0))
            let peakDelta = abs((av.loudness.samplePeakDBFS ?? 0) - (mapped.loudness.samplePeakDBFS ?? 0))
            guard av.levels == mapped.levels,
                  av.frameCount == mapped.frameCount,
                  av.sourceChannelCount == mapped.sourceChannelCount,
                  lufsDelta <= 0.000_001,
                  peakDelta <= 0.000_001 else { throw CocoaError(.fileReadCorruptFile) }
            print(String(format: "waveform mapped_parity=passed lufs_delta=%.9f peak_delta=%.9f", lufsDelta, peakDelta))
        }

        var stages: [WaveformData] = []
        for try await stage in AudioAnalysisRepository.shared.analysisStages(for: file) { stages.append(stage) }
        guard let firstStage = stages.first, let finalStage = stages.last,
              finalStage.fidelity == .exact,
              finalStage.loudness.analysisComplete else { throw CocoaError(.fileReadCorruptFile) }
        if benchmarkSignature.fileSize > 0, finalStage.frameCount <= AudioAnalyzer.sparsePreviewThresholdFrames {
            guard stages.count == 2,
                  firstStage.fidelity == .exact,
                  !firstStage.loudness.analysisComplete,
                  firstStage.levels == finalStage.levels else { throw CocoaError(.fileReadCorruptFile) }
        } else {
            guard firstStage.fidelity == .provisional else { throw CocoaError(.fileReadCorruptFile) }
        }

        var cacheMilliseconds: [Double] = []
        for _ in 0..<30 {
            let start = ContinuousClock.now
            _ = try await AudioAnalysisRepository().analysis(for: file)
            cacheMilliseconds.append(elapsedMilliseconds(since: start))
        }

        let previewP95 = percentile(previewMilliseconds, 0.95)
        let cacheP95 = percentile(cacheMilliseconds, 0.95)
        let durationSeconds = max(Double(finalStage.frameCount) / finalStage.sampleRate, 0.001)
        print(String(format: "waveform preview_ms p50=%.3f p95=%.3f", percentile(previewMilliseconds, 0.50), previewP95))
        print(String(format: "waveform exact_envelope_ms p50=%.3f p95=%.3f", percentile(envelopeMilliseconds, 0.50), percentile(envelopeMilliseconds, 0.95)))
        print(String(format: "waveform lufs_refine_ms p50=%.3f p95=%.3f", percentile(loudnessMilliseconds, 0.50), percentile(loudnessMilliseconds, 0.95)))
        print(String(format: "waveform envelope_then_lufs_ms p50=%.3f p95=%.3f realtime_x=%.1f", percentile(totalMilliseconds, 0.50), percentile(totalMilliseconds, 0.95), durationSeconds * 1_000 / percentile(totalMilliseconds, 0.50)))
        print(String(format: "waveform selected_complete_ms p50=%.3f p95=%.3f", percentile(selectedCompleteMilliseconds, 0.50), percentile(selectedCompleteMilliseconds, 0.95)))
        print(String(format: "waveform zig_portable_ms p50=%.3f p95=%.3f", percentile(portableMilliseconds, 0.50), percentile(portableMilliseconds, 0.95)))
        print(String(format: "waveform background_universal_ms p50=%.3f p95=%.3f", percentile(backgroundMilliseconds, 0.50), percentile(backgroundMilliseconds, 0.95)))
        print(String(format: "waveform sqlite_ms p50=%.3f p95=%.3f", percentile(cacheMilliseconds, 0.50), cacheP95))
        guard previewP95 <= 50, cacheP95 <= 16 else { exit(1) }
    }
}
