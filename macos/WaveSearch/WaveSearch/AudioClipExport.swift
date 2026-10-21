import Foundation
@preconcurrency import AVFoundation
import AppKit

nonisolated enum AudioImportBehavior: String, CaseIterable, Identifiable {
    case keepInPlace
    case copyToExports

    static let preferenceKey = "ws_audio_import_behavior_v1"
    var id: String { rawValue }
    var title: String {
        switch self {
        case .keepInPlace: String(localized: "Keep the files in place")
        case .copyToExports: String(localized: "Copy files to Exports")
        }
    }

    @MainActor static func current(preferences: UserDefaults = .standard) -> Self {
        Self(rawValue: preferences.string(forKey: preferenceKey) ?? "") ?? .keepInPlace
    }
}

nonisolated enum AudioClipStorage {
    static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("WaveSearch/Exports", isDirectory: true)
    }
}
/// Resolve a persistent file URL only when the receiving editor requests it.
func itemProviderForAudioImport(_ file: SoundFile, behavior: AudioImportBehavior? = nil) -> NSItemProvider {
    let behavior = behavior ?? .current()
    let provider: NSItemProvider
    if behavior == .keepInPlace {
        provider = NSItemProvider(object: file.url as NSURL)
    } else {
        provider = NSItemProvider()
        let generation = BlockingWorkRegistry.hostFiles.generation
        provider.registerObject(ofClass: NSURL.self, visibility: .all) { completion in
            let progress = Progress(totalUnitCount: 1)
            let task = Task { @MainActor in
                do {
                    let url = try await audioImportURL(file: file, behavior: behavior, expectedGeneration: generation)
                    completion(url as NSURL, nil)
                    progress.completedUnitCount = 1
                } catch {
                    completion(nil, error)
                }
            }
            progress.cancellationHandler = { task.cancel() }
            return progress
        }
    }
    provider.suggestedName = file.displayName
    return provider
}

func dragPayloadForClip(
    file: SoundFile, startFraction: Double, endFraction: Double,
    behavior: AudioImportBehavior? = nil
) async throws -> WaveformDragPayload {
    let url = try await audioImportURL(
        file: file, startFraction: startFraction, endFraction: endFraction, behavior: behavior
    )
    // Editors such as Resolve need an existing file URL, not a Finder file promise.
    return WaveformDragPayload(writer: url as NSURL)
}

/// Referencing media never writes a file. Copies and trimmed selections remain
/// in Exports because an editor project may reference them indefinitely.
func audioImportURL(
    file: SoundFile, startFraction: Double = 0, endFraction: Double = 1,
    behavior: AudioImportBehavior? = nil, expectedGeneration: UInt64? = nil
) async throws -> URL {
    try Task.checkCancellation()
    let behavior = behavior ?? .current()
    if behavior == .keepInPlace { return file.url }
    let generation = expectedGeneration ?? BlockingWorkRegistry.hostFiles.generation
    let result = await BlockingWorkRegistry.hostFiles.run(priority: .userInitiated, expectedGeneration: generation) {
        Result {
            if startFraction == 0 && endFraction == 1 {
                return try copyAudioForImport(file)
            }
            return try renderPCMSelection(file: file, startFraction: startFraction, endFraction: endFraction)
        }
    }
    guard let result else { throw CancellationError() }
    let url = try result.get()
    if Task.isCancelled {
        try? FileManager.default.removeItem(at: url)
        throw CancellationError()
    }
    return url
}

nonisolated private func copyAudioForImport(_ file: SoundFile) throws -> URL {
    try Task.checkCancellation()
    let directory = AudioClipStorage.directory
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let baseName = String(decoding: file.url.deletingPathExtension().lastPathComponent.utf8.prefix(160), as: UTF8.self)
    var outputURL = directory.appendingPathComponent("\(baseName)-\(UUID().uuidString)")
    if !file.url.pathExtension.isEmpty { outputURL.appendPathExtension(file.url.pathExtension) }
    do {
        try FileManager.default.copyItem(at: file.url, to: outputURL)
        try Task.checkCancellation()
        return outputURL
    } catch {
        try? FileManager.default.removeItem(at: outputURL)
        throw error
    }
}

nonisolated func renderPCMSelection(
    file: SoundFile,
    startFraction: Double,
    endFraction: Double,
    outputURL requestedOutputURL: URL? = nil
) throws -> URL {
    try Task.checkCancellation()
    let input = try AVAudioFile(
        forReading: file.url,
        commonFormat: .pcmFormatFloat32,
        interleaved: false
    )
    let format = input.processingFormat
    guard input.length > 0, startFraction.isFinite, endFraction.isFinite,
          startFraction >= 0, startFraction < endFraction, endFraction <= 1 else {
        throw CocoaError(.fileReadCorruptFile)
    }
    let totalFrames = input.length
    let startFrame = min(totalFrames - 1, max(0, AVAudioFramePosition(Double(totalFrames) * startFraction)))
    let endFrame = min(totalFrames, max(startFrame + 1, AVAudioFramePosition(ceil(Double(totalFrames) * endFraction))))
    input.framePosition = startFrame

    let outputURL: URL
    if let requestedOutputURL {
        outputURL = requestedOutputURL
    } else {
        let directory = AudioClipStorage.directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let originalName = file.url.deletingPathExtension().lastPathComponent.replacingOccurrences(of: "/", with: "-")
        let baseName = String(decoding: originalName.utf8.prefix(160), as: UTF8.self)
        // A Resolve project can reference this media; never prune it as a cache.
        outputURL = directory.appendingPathComponent("\(baseName)-selection-\(UUID().uuidString).wav")
    }
    let settings: [String: Any] = [
        AVFormatIDKey: kAudioFormatLinearPCM,
        AVSampleRateKey: format.sampleRate,
        AVNumberOfChannelsKey: Int(format.channelCount),
        AVLinearPCMBitDepthKey: 24,
        AVLinearPCMIsFloatKey: false,
        AVLinearPCMIsBigEndianKey: false,
        AVLinearPCMIsNonInterleaved: false,
    ]
    do {
        let output = try AVAudioFile(
            forWriting: outputURL,
            settings: settings,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
        let chunkFrames: AVAudioFrameCount = 32_768
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunkFrames) else {
            throw CocoaError(.fileWriteUnknown)
        }
        var remaining = endFrame - startFrame
        while remaining > 0 {
            try Task.checkCancellation()
            buffer.frameLength = 0
            let requested = AVAudioFrameCount(min(AVAudioFramePosition(chunkFrames), remaining))
            try input.read(into: buffer, frameCount: requested)
            guard buffer.frameLength > 0 else { break }
            try output.write(from: buffer)
            remaining -= AVAudioFramePosition(buffer.frameLength)
        }
        guard remaining == 0 else { throw CocoaError(.fileReadCorruptFile) }
        return outputURL
    } catch {
        try? FileManager.default.removeItem(at: outputURL)
        throw error
    }
}
