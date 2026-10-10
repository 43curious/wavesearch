import Foundation
import OSLog
import WaveSearchKit

nonisolated enum PersistentWaveformTier: UInt32, Sendable {
    case universal = 1
    case detailed = 2
}

actor AudioAnalysisRepository {
    static let shared = AudioAnalysisRepository()

    private var memory: [String: WaveformData] = [:]
    private var order: [String] = []
    private enum ExactWorkKind: String, Sendable {
        case selectedFull
        case selectedLoudness
        case backgroundUniversal
    }

    private struct InFlightExact {
        let task: Task<WaveformData, Error>
        var background: Bool
        var consumers: Set<UUID>
    }

    private var inFlight: [String: InFlightExact] = [:]
    private let memoryLimit = 8
    private let admissionGate = WorkAdmissionGate()

    nonisolated func analysisStages(for file: SoundFile) -> AsyncThrowingStream<WaveformData, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                await self.produceStages(for: file, continuation: continuation)
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func analysis(for file: SoundFile) async throws -> WaveformData {
        var latest: WaveformData?
        for try await stage in analysisStages(for: file) { latest = stage }
        guard let latest else { throw CocoaError(.fileReadUnknown) }
        return latest
    }

    func backfillUniversal(for file: SoundFile) async throws {
        guard admissionGate.admit() else { throw CancellationError() }
        defer { admissionGate.release() }

        let signature = try await captureSignature(file)
        try await refreshLegacyIdentity(file: file, signature: signature)
        if try await loadTier(.universal, file: file, signature: signature) != nil { return }
        let exact = try await sharedExactAnalysis(
            file: file,
            signature: signature,
            kind: .backgroundUniversal,
            envelope: nil,
            priority: .background
        )
        try Task.checkCancellation()
        try await persist(exact, fileID: file.id, includeDetailed: false)
    }

    func prioritizeForeground(fileID _: Int) async {
        // A 512-bucket background pass cannot be promoted into selected 4096
        // detail after samples have already been consumed. Cancel it and wait
        // for its decoder to unwind before foreground work starts.
        await cancelBackgroundAnalysis()
    }

    func cancelBackgroundAnalysis() async {
        guard admissionGate.admit() else { return }
        defer { admissionGate.release() }

        let work = inFlight.compactMap { key, value in
            value.background ? (key, value.task) : nil
        }
        for (_, task) in work { task.cancel() }
        for (_, task) in work { _ = try? await task.value }
        for (key, _) in work where inFlight[key]?.background == true {
            inFlight.removeValue(forKey: key)
        }
    }

    func suspendAndDrain() async {
        await cancelBackgroundAnalysis()
        admissionGate.suspend()
        await admissionGate.suspendAndDrain()
    }

    func resume() {
        admissionGate.resume()
    }

    func clearMemory() {
        memory.removeAll()
        order.removeAll()
    }

    func invalidate(path: String) {
        let standardized = URL(fileURLWithPath: path).standardizedFileURL.path
        for key in memory.keys where key.hasSuffix("|\(standardized)") { memory.removeValue(forKey: key) }
        order.removeAll { $0.hasSuffix("|\(standardized)") }
    }

    private func produceStages(
        for file: SoundFile,
        continuation: AsyncThrowingStream<WaveformData, Error>.Continuation
    ) async {
        guard admissionGate.admit() else {
            continuation.finish(throwing: CancellationError())
            return
        }
        defer { admissionGate.release() }
        do {
            let signature = try await captureSignature(file)
            try await refreshLegacyIdentity(file: file, signature: signature)
            let key = cacheKey(file: file, signature: signature)
            if let cached = memory[key], cached.signature == signature {
                touchMemory(key)
                continuation.yield(cached)
                continuation.finish()
                return
            }

            if let detailed = try await loadTier(.detailed, file: file, signature: signature) {
                WaveformSignposts.event("DetailedCacheHit", fileID: file.id)
                insertMemory(detailed, key: key)
                continuation.yield(detailed)
                continuation.finish()
                launchTrackedDetached(priority: .utility) {
                    _ = ws_waveform_tier_touch(Int32(file.id), UInt32(WS_WAVEFORM_TIER_DETAILED))
                }
                return
            }

            if let universal = try await loadTier(.universal, file: file, signature: signature) {
                WaveformSignposts.event("UniversalCacheHit", fileID: file.id)
                continuation.yield(universal)
                try Task.checkCancellation()
                let exact = try await sharedExactAnalysis(
                    file: file,
                    signature: signature,
                    kind: .selectedFull,
                    envelope: nil,
                    priority: .userInitiated
                )
                try Task.checkCancellation()
                try await persist(exact, fileID: file.id, includeDetailed: true)
                insertMemory(exact, key: key)
                continuation.yield(exact)
                continuation.finish()
                return
            }

            let previewInterval = WaveformSignposts.begin("SparsePreview", fileID: file.id)
            let preview = try await runTrackedDetached(priority: .userInitiated) {
                try AudioAnalyzer.preview(file: file, signature: signature)
            }
            try Task.checkCancellation()
            WaveformSignposts.end("SparsePreview", id: previewInterval, fileID: file.id)
            continuation.yield(preview)

            if preview.fidelity == .exact, preview.loudness.analysisComplete {
                try await persist(preview, fileID: file.id, includeDetailed: true)
                insertMemory(preview, key: key)
                continuation.finish()
                return
            }

            let workKind: ExactWorkKind = preview.fidelity == .exact ? .selectedLoudness : .selectedFull
            let exact = try await sharedExactAnalysis(
                file: file,
                signature: signature,
                kind: workKind,
                envelope: workKind == .selectedLoudness ? preview : nil,
                priority: .userInitiated
            )
            try Task.checkCancellation()
            try await persist(exact, fileID: file.id, includeDetailed: true)
            insertMemory(exact, key: key)
            continuation.yield(exact)
            continuation.finish()
        } catch is CancellationError {
            continuation.finish(throwing: CancellationError())
        } catch {
            continuation.finish(throwing: error)
        }
    }

    private func captureSignature(_ file: SoundFile) async throws -> WaveformSourceSignature {
        let signature = try await runTrackedDetached(priority: .utility) {
            try WaveformSourceSignature.capture(file, analyzerVersion: AudioAnalyzer.version)
        }
        try Task.checkCancellation()
        return signature
    }

    private func refreshLegacyIdentity(file: SoundFile, signature: WaveformSourceSignature) async throws {
        let result = try await runTrackedDetached(priority: .utility) {
            ws_waveform_identity_refresh(
                Int32(file.id),
                signature.contentHash,
                signature.fileSize,
                signature.modificationNanoseconds
            )
        }
        guard result == 0 else { throw CocoaError(.fileReadUnknown) }
    }

    private func sharedExactAnalysis(
        file: SoundFile,
        signature: WaveformSourceSignature,
        kind: ExactWorkKind,
        envelope: WaveformData?,
        priority: TaskPriority
    ) async throws -> WaveformData {
        guard admissionGate.admit() else { throw CancellationError() }
        defer { admissionGate.release() }

        let key = cacheKey(file: file, signature: signature) + "#" + kind.rawValue
        let consumer = UUID()
        let task: Task<WaveformData, Error>
        let interval: OSSignpostID?
        if var existing = inFlight[key] {
            WaveformSignposts.event("JoinInFlight", fileID: file.id)
            existing.consumers.insert(consumer)
            inFlight[key] = existing
            task = existing.task
            interval = nil
        } else {
            let newInterval = WaveformSignposts.begin("ExactAndLUFS", fileID: file.id)
            task = Task.detached(priority: priority) {
                switch kind {
                case .selectedFull:
                    return try AudioAnalyzer.exact(file: file, signature: signature, purpose: .selectedLoudnessComplete)
                case .selectedLoudness:
                    guard let envelope else { throw CocoaError(.fileReadCorruptFile) }
                    return try AudioAnalyzer.refineLoudness(file: file, signature: signature, envelope: envelope)
                case .backgroundUniversal:
                    return try AudioAnalyzer.exact(file: file, signature: signature, purpose: .backgroundUniversal)
                }
            }
            inFlight[key] = .init(task: task, background: priority == .background, consumers: [consumer])
            interval = newInterval
        }

        return try await withTaskCancellationHandler {
            do {
                let value = try await task.value
                if let interval { WaveformSignposts.end("ExactAndLUFS", id: interval, fileID: file.id) }
                releaseExactConsumer(key: key, consumer: consumer, cancelIfEmpty: false)
                return value
            } catch {
                if let interval { WaveformSignposts.end("ExactAndLUFS", id: interval, fileID: file.id) }
                releaseExactConsumer(key: key, consumer: consumer, cancelIfEmpty: false)
                throw error
            }
        } onCancel: {
            Task { await self.cancelExactConsumer(key: key, consumer: consumer) }
        }
    }

    private func runTrackedDetached<Value: Sendable>(
        priority: TaskPriority,
        _ operation: @escaping @Sendable () throws -> Value
    ) async throws -> Value {
        guard !Task.isCancelled, admissionGate.admit() else { throw CancellationError() }
        let task = Task.detached(priority: priority) {
            try operation()
        }
        defer { admissionGate.release() }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    private func launchTrackedDetached(
        priority: TaskPriority,
        _ operation: @escaping @Sendable () -> Void
    ) {
        guard !Task.isCancelled, admissionGate.admit() else { return }
        let gate = admissionGate
        Task.detached(priority: priority) {
            defer { gate.release() }
            operation()
        }
    }

    private func cancelExactConsumer(key: String, consumer: UUID) {
        releaseExactConsumer(key: key, consumer: consumer, cancelIfEmpty: true)
    }

    private func releaseExactConsumer(key: String, consumer: UUID, cancelIfEmpty: Bool) {
        guard var flight = inFlight[key] else { return }
        flight.consumers.remove(consumer)
        if flight.consumers.isEmpty {
            if cancelIfEmpty { flight.task.cancel() }
            inFlight.removeValue(forKey: key)
        } else {
            inFlight[key] = flight
        }
    }

    private func loadTier(
        _ tier: PersistentWaveformTier,
        file: SoundFile,
        signature: WaveformSourceSignature
    ) async throws -> WaveformData? {
        let blob = try await runTrackedDetached(priority: .utility) { () -> Data? in
            let size = ws_waveform_tier_size(Int32(file.id), tier.rawValue)
            guard size > 0, size <= 4 * 1024 * 1024 else { return nil }
            var data = Data(count: Int(size))
            let loaded = data.withUnsafeMutableBytes { raw in
                ws_waveform_tier_load(
                    Int32(file.id),
                    tier.rawValue,
                    raw.baseAddress?.assumingMemoryBound(to: UInt8.self),
                    UInt64(raw.count)
                )
            }
            return loaded == size ? data : nil
        }
        try Task.checkCancellation()
        guard let blob else { return nil }
        guard let decoded = try? WaveformTierCodec.decode(blob, standardizedPath: signature.standardizedPath),
              decoded.tier == tier, decoded.data.signature == signature else { return nil }
        return decoded.data
    }

    private func persist(_ value: WaveformData, fileID: Int, includeDetailed: Bool) async throws {
        guard value.fidelity == .exact, value.loudness.analysisComplete else {
            throw CocoaError(.fileWriteInvalidFileName)
        }
        let interval = WaveformSignposts.begin("TierStore", fileID: fileID)
        let universal = try WaveformTierCodec.encode(value, tier: .universal)
        let detailed = includeDetailed ? try WaveformTierCodec.encode(value, tier: .detailed) : nil
        let result = try await runTrackedDetached(priority: .utility) {
            universal.withUnsafeBytes { universalRaw in
                if let detailed {
                    return detailed.withUnsafeBytes { detailedRaw in
                        ws_waveform_tiers_store(
                            Int32(fileID),
                            value.signature.contentHash,
                            value.signature.fileSize,
                            value.signature.modificationNanoseconds,
                            WaveformTierCodec.codecVersion,
                            universalRaw.baseAddress?.assumingMemoryBound(to: UInt8.self),
                            UInt64(universalRaw.count),
                            detailedRaw.baseAddress?.assumingMemoryBound(to: UInt8.self),
                            UInt64(detailedRaw.count)
                        )
                    }
                }
                return ws_waveform_tiers_store(
                    Int32(fileID),
                    value.signature.contentHash,
                    value.signature.fileSize,
                    value.signature.modificationNanoseconds,
                    WaveformTierCodec.codecVersion,
                    universalRaw.baseAddress?.assumingMemoryBound(to: UInt8.self),
                    UInt64(universalRaw.count),
                    nil,
                    0
                )
            }
        }
        guard result == 0 else { throw CocoaError(.fileWriteUnknown) }
        WaveformSignposts.end("TierStore", id: interval, fileID: fileID)
    }

    private func cacheKey(file: SoundFile, signature: WaveformSourceSignature) -> String {
        "\(file.id):\(signature.contentHash):\(signature.fileSize):\(signature.modificationNanoseconds)|\(signature.standardizedPath)"
    }

    private func insertMemory(_ value: WaveformData, key: String) {
        memory[key] = value
        touchMemory(key)
        while order.count > memoryLimit { memory.removeValue(forKey: order.removeFirst()) }
    }

    private func touchMemory(_ key: String) {
        order.removeAll { $0 == key }
        order.append(key)
    }
}

private nonisolated final class WorkAdmissionGate: @unchecked Sendable {
    private let lock = NSLock()
    private var accepting = true
    private var active = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func admit() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard accepting else { return false }
        active += 1
        return true
    }

    func release() {
        let waitersToResume: [CheckedContinuation<Void, Never>]
        lock.lock()
        precondition(active > 0, "Release without admission")
        active -= 1
        if active == 0, !waiters.isEmpty {
            waitersToResume = waiters
            waiters.removeAll()
        } else {
            waitersToResume = []
        }
        lock.unlock()
        for waiter in waitersToResume { waiter.resume() }
    }

    func suspend() {
        lock.lock()
        accepting = false
        lock.unlock()
    }

    func suspendAndDrain() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            accepting = false
            if active == 0 {
                lock.unlock()
                continuation.resume()
            } else {
                waiters.append(continuation)
                lock.unlock()
            }
        }
    }

    func resume() {
        lock.lock()
        precondition(active == 0, "Drain repository work before resuming")
        accepting = true
        lock.unlock()
    }
}

nonisolated enum WaveformTierCodec {
    static let codecVersion: UInt32 = 3
    struct Decoded: Sendable {
        let tier: PersistentWaveformTier
        let data: WaveformData
    }

    static func encode(_ waveform: WaveformData, tier: PersistentWaveformTier) throws -> Data {
        try ZigWaveformCore.encode(waveform, tier: tier)
    }

    static func decode(_ blob: Data, standardizedPath: String) throws -> Decoded {
        let (tier, data) = try ZigWaveformCore.decode(blob, standardizedPath: standardizedPath)
        return .init(tier: tier, data: data)
    }

}

nonisolated enum WaveformCacheCodec {
    private static let magic: UInt32 = 0x3246_5757 // WWF2, little endian
    private static let formatVersion: UInt32 = 2
    private static let maximumBytes = 64 * 1024 * 1024

    static func encode(_ waveform: WaveformData) throws -> Data {
        guard waveform.fidelity == .exact, waveform.loudness.analysisComplete else {
            throw CocoaError(.fileWriteInvalidFileName)
        }
        var writer = BinaryWriter()
        writer.u32(magic)
        writer.u32(formatVersion)
        writer.u32(waveform.signature.analyzerVersion)
        writer.u32(waveform.fidelity.rawValue)
        writer.u32(1)
        writer.string(waveform.signature.standardizedPath)
        writer.i64(waveform.signature.fileSize)
        writer.i64(waveform.signature.modificationNanoseconds)
        writer.i64(waveform.signature.contentHash)
        writer.f64(waveform.sampleRate)
        writer.i64(waveform.frameCount)
        writer.u32(UInt32(waveform.sourceChannelCount))
        writer.u32(UInt32(waveform.levels.count))
        writer.f64(waveform.loudness.integratedLUFS ?? .nan)
        writer.f64(waveform.loudness.samplePeakDBFS ?? .nan)
        for level in waveform.levels {
            writer.u32(UInt32(level.bucketCount))
            writer.u32(UInt32(level.channels.count))
            for channel in level.channels {
                guard channel.count == level.bucketCount else { throw CocoaError(.fileWriteInvalidFileName) }
                for peak in channel {
                    writer.f32(peak.minimum)
                    writer.f32(peak.maximum)
                }
            }
        }
        let checksum = checksum64(writer.data)
        writer.u64(checksum)
        guard writer.data.count <= maximumBytes else { throw CocoaError(.fileWriteOutOfSpace) }
        return writer.data
    }

    static func decode(_ data: Data) throws -> WaveformData {
        guard data.count >= 16, data.count <= maximumBytes else { throw CocoaError(.fileReadCorruptFile) }
        let payload = Data(data.dropLast(8))
        var checksumReader = BinaryReader(Data(data.suffix(8)))
        guard try checksumReader.u64() == checksum64(payload) else { throw CocoaError(.fileReadCorruptFile) }
        var reader = BinaryReader(payload)
        guard try reader.u32() == magic, try reader.u32() == formatVersion else { throw CocoaError(.fileReadCorruptFile) }
        let analyzerVersion = try reader.u32()
        guard try reader.u32() == WaveformFidelity.exact.rawValue,
              try reader.u32() == 1 else { throw CocoaError(.fileReadCorruptFile) }
        let path = try reader.string(maximumBytes: 16 * 1024)
        let signature = WaveformSourceSignature(
            standardizedPath: path,
            fileSize: try reader.i64(),
            modificationNanoseconds: try reader.i64(),
            contentHash: try reader.i64(),
            analyzerVersion: analyzerVersion
        )
        let sampleRate = try reader.f64()
        let frameCount = try reader.i64()
        let sourceChannels = Int(try reader.u32())
        let levelCount = Int(try reader.u32())
        let lufsRaw = try reader.f64()
        let peakRaw = try reader.f64()
        guard sampleRate.isFinite, sampleRate >= 1, sampleRate <= 768_000,
              frameCount >= 0, Double(frameCount) <= sampleRate * 7 * 24 * 60 * 60,
              sourceChannels > 0, sourceChannels <= 256,
              levelCount > 0, levelCount <= 16 else { throw CocoaError(.fileReadCorruptFile) }

        var levels: [WaveformLevel] = []
        levels.reserveCapacity(levelCount)
        var previousCount = 0
        for _ in 0..<levelCount {
            let bucketCount = Int(try reader.u32())
            let channelCount = Int(try reader.u32())
            guard bucketCount >= 1, bucketCount <= 131_072, bucketCount >= previousCount,
                  channelCount >= 1, channelCount <= 2 else { throw CocoaError(.fileReadCorruptFile) }
            previousCount = bucketCount
            var channels: [[WaveformPeak]] = []
            channels.reserveCapacity(channelCount)
            for _ in 0..<channelCount {
                var peaks: [WaveformPeak] = []
                peaks.reserveCapacity(bucketCount)
                for _ in 0..<bucketCount {
                    let minimum = try reader.f32()
                    let maximum = try reader.f32()
                    guard minimum.isFinite, maximum.isFinite, minimum <= maximum else { throw CocoaError(.fileReadCorruptFile) }
                    peaks.append(.init(minimum: minimum, maximum: maximum))
                }
                channels.append(peaks)
            }
            levels.append(.init(bucketCount: bucketCount, channels: channels))
        }
        guard reader.isAtEnd else { throw CocoaError(.fileReadCorruptFile) }
        return WaveformData(
            signature: signature,
            sampleRate: sampleRate,
            frameCount: frameCount,
            sourceChannelCount: sourceChannels,
            levels: levels,
            fidelity: .exact,
            loudness: .init(
                integratedLUFS: lufsRaw.isFinite ? lufsRaw : nil,
                samplePeakDBFS: peakRaw.isFinite ? peakRaw : nil,
                analysisComplete: true
            )
        )
    }

    private static func checksum64(_ data: Data) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in data {
            hash ^= UInt64(byte)
            hash &*= 0x0000_0100_0000_01b3
        }
        return hash
    }
}

private nonisolated struct BinaryWriter {
    var data = Data()

    mutating func u32(_ value: UInt32) {
        data.append(UInt8(truncatingIfNeeded: value))
        data.append(UInt8(truncatingIfNeeded: value >> 8))
        data.append(UInt8(truncatingIfNeeded: value >> 16))
        data.append(UInt8(truncatingIfNeeded: value >> 24))
    }

    mutating func u64(_ value: UInt64) {
        for shift in stride(from: 0, through: 56, by: 8) { data.append(UInt8(truncatingIfNeeded: value >> UInt64(shift))) }
    }

    mutating func i8(_ value: Int8) { data.append(UInt8(bitPattern: value)) }
    mutating func i64(_ value: Int64) { u64(UInt64(bitPattern: value)) }
    mutating func f32(_ value: Float) { u32(value.bitPattern) }
    mutating func f64(_ value: Double) { u64(value.bitPattern) }

    mutating func string(_ value: String) {
        let bytes = Data(value.utf8)
        u32(UInt32(bytes.count))
        data.append(bytes)
    }
}

private nonisolated struct BinaryReader {
    let bytes: Data
    var offset = 0

    init(_ data: Data) { bytes = data }
    var isAtEnd: Bool { offset == bytes.count }

    mutating func u32() throws -> UInt32 {
        guard offset + 4 <= bytes.count else { throw CocoaError(.fileReadCorruptFile) }
        defer { offset += 4 }
        return UInt32(bytes[offset]) |
            UInt32(bytes[offset + 1]) << 8 |
            UInt32(bytes[offset + 2]) << 16 |
            UInt32(bytes[offset + 3]) << 24
    }

    mutating func u64() throws -> UInt64 {
        guard offset + 8 <= bytes.count else { throw CocoaError(.fileReadCorruptFile) }
        defer { offset += 8 }
        var value: UInt64 = 0
        for index in 0..<8 { value |= UInt64(bytes[offset + index]) << UInt64(index * 8) }
        return value
    }

    mutating func i8() throws -> Int8 {
        guard offset < bytes.count else { throw CocoaError(.fileReadCorruptFile) }
        defer { offset += 1 }
        return Int8(bitPattern: bytes[offset])
    }

    mutating func i64() throws -> Int64 { Int64(bitPattern: try u64()) }
    mutating func f32() throws -> Float { Float(bitPattern: try u32()) }
    mutating func f64() throws -> Double { Double(bitPattern: try u64()) }

    mutating func string(maximumBytes: Int) throws -> String {
        let count = Int(try u32())
        guard count >= 0, count <= maximumBytes, offset + count <= bytes.count else { throw CocoaError(.fileReadCorruptFile) }
        defer { offset += count }
        guard let value = String(bytes: bytes[offset..<(offset + count)], encoding: .utf8) else { throw CocoaError(.fileReadCorruptFile) }
        return value
    }
}
