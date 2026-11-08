import Foundation
@preconcurrency import AVFoundation
import CryptoKit

nonisolated struct ImportFacts: Codable, Sendable {
    let frames: Int64
    let sampleRate: Double
    let channels: UInt32
    let bitDepth: Int
    let sha256: String
}

nonisolated struct EditorPayload: Codable, Sendable {
    let id: Int
    let source: String
    let sourceSHA256: String
    let behavior: String
    let scope: String
    let path: String
    let expectedSeconds: Double
    let facts: ImportFacts
}

/// Opt-in synthetic editor acceptance, using the same persistent import URLs as
/// the app. Run through prepare-editor-import-payloads.sh after fixture creation.
@main struct EditorImportPayloads {
    @MainActor static func main() async throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let sources = try await Task.detached {
            try FileManager.default.contentsOfDirectory(at: root.appendingPathComponent("Sources café 東京"), includingPropertiesForKeys: nil)
                .filter { ["wav", "aiff", "m4a"].contains($0.pathExtension) }
                .sorted { $0.path < $1.path }
        }.value
        BlockingWorkRegistry.hostFiles.resume()
        var payloads: [EditorPayload] = []
        for source in sources {
            let sourceHash = try await Task.detached { SHA256.hash(data: try Data(contentsOf: source)).map { String(format: "%02x", $0) }.joined() }.value
            let file = SoundFile(id: payloads.count + 1, folderId: -1, path: source.path, name: source.lastPathComponent, durationMs: 4000, contentHash: 0)
            for behavior in AudioImportBehavior.allCases {
                for selected in [false, true] {
                    let url = try await audioImportURL(file: file, startFraction: selected ? 0.25 : 0,
                                                      endFraction: selected ? 0.625 : 1, behavior: behavior)
                    let facts = try await Task.detached {
                        let audio = try AVAudioFile(forReading: url)
                        return ImportFacts(frames: audio.length, sampleRate: audio.fileFormat.sampleRate,
                                           channels: audio.fileFormat.channelCount,
                                           bitDepth: audio.fileFormat.settings[AVLinearPCMBitDepthKey] as? Int ?? 0,
                                           sha256: SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined())
                    }.value
                    let trimmed = selected && behavior == .copyToExports
                    precondition(facts.frames == (trimmed ? 72000 : 192000) && facts.sampleRate == 48000 && facts.channels == 2)
                    if trimmed { precondition(facts.bitDepth == 24) }
                    else { precondition(facts.sha256 == sourceHash) }
                    payloads.append(EditorPayload(id: payloads.count + 1, source: source.path, sourceSHA256: sourceHash,
                                                  behavior: behavior.rawValue, scope: selected ? "selectedRange" : "wholeFile",
                                                  path: url.path, expectedSeconds: trimmed ? 1.5 : 4, facts: facts))
                }
            }
        }
        let snapshot = payloads
        try await Task.detached {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            try encoder.encode(snapshot).write(to: root.appendingPathComponent("payloads.json"), options: .atomic)
        }.value
        print("PASS: \(payloads.count) production editor URLs; whole bytes, selected PCM24, sample rate and channels verified")
    }
}
