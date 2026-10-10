import Foundation
@preconcurrency import AVFoundation
import AppKit

nonisolated enum AudioClipStorage {
    static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("WaveSearch/Exports", isDirectory: true)
    }
}
func itemProviderForOriginalFile(_ file: SoundFile) -> NSItemProvider {
    let provider = NSItemProvider(object: file.url as NSURL)
    provider.suggestedName = file.displayName
    return provider
}

func dragPayloadForClip(file: SoundFile, startFraction: Double, endFraction: Double) async throws -> WaveformDragPayload {
    let generation = BlockingWorkRegistry.hostFiles.generation
    let result = await BlockingWorkRegistry.hostFiles.run(priority: .userInitiated, expectedGeneration: generation) {
        Result { try renderPCMSelection(file: file, startFraction: startFraction, endFraction: endFraction) }
    }
    guard let result else { throw CancellationError() }
    let url = try result.get()
    if Task.isCancelled {
        try? FileManager.default.removeItem(at: url)
        throw CancellationError()
    }
    // Editors such as Resolve need an existing file URL, not a Finder file promise.
    return WaveformDragPayload(writer: url as NSURL)
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
