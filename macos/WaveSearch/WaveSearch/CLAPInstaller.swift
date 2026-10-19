import Foundation
import CryptoKit
import Darwin
import os

nonisolated struct CLAPArtifact: Sendable {
    let path: String
    let url: URL
    let sha256: String
    let size: Int64?
    let maximumBytes: Int64
}

/// Matches the pinned CLI installer. Downloads are never part of startup or builds.
nonisolated struct CLAPInstallPlan: Sendable {
    let artifacts: [CLAPArtifact]
    let runtimePath: String
    let supported: Bool

    static let pinned: CLAPInstallPlan = {
        let base = "https://huggingface.co/muzaiten/clap-htsat-base-onnx/resolve/d4d4372c9894b975ec118589b4f4328103796e15"
        func model(_ name: String, _ sha: String, _ size: Int64? = nil) -> CLAPArtifact {
            .init(path: "model/" + name, url: URL(string: base + "/" + name)!, sha256: sha,
                  size: size, maximumBytes: size ?? 65536)
        }
        #if arch(arm64)
        let supported = true
        #else
        let supported = false
        #endif
        return .init(artifacts: [
            model("manifest.json", "520b7ae740d9b634680c1f1af0735ca227b2fc80c9c33c006f53f1b8242ea83e"),
            model("audio.onnx", "9533ed823c150fb13c91ecd7359aa3bff1aa6da7b44099a21ccea10c0adba2d6", 285177239),
            model("text.onnx", "069e323e309284ae9aca6587b884afcd38f943fa1cba260823f4673b18f09a26", 501450229),
            model("tokenizer.json", "2bb1a22cfbe25b8e5a232b7fc4d7fc5073923b45724a5f813b00811bb6620f66", 3558642),
            .init(path: "runtime.tgz", url: URL(string: "https://github.com/microsoft/onnxruntime/releases/download/v1.29.0/onnxruntime-osx-arm64-1.29.0.tgz")!,
                  sha256: "d0706fc34f315d8c88639d0a8c81f2e09e815f282cabed3493c06a054352cf92", size: nil, maximumBytes: 64 * 1024 * 1024)
        ], runtimePath: "onnxruntime-osx-arm64-1.29.0/lib/libonnxruntime.dylib", supported: supported)
    }()
}

nonisolated struct CLAPInstallProgress: Sendable {
    let detail: String
    var bytes: Int64 = 0
    var expected: Int64? = nil
}

nonisolated struct CLAPInstallFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

nonisolated private final class CLAPDownloadProgress: NSObject, URLSessionDownloadDelegate {
    let artifact: CLAPArtifact
    let report: @Sendable (CLAPInstallProgress) -> Void
    private let lastReported = OSAllocatedUnfairLock(initialState: Int64(-1024 * 1024))
    init(_ artifact: CLAPArtifact, report: @escaping @Sendable (CLAPInstallProgress) -> Void) {
        self.artifact = artifact
        self.report = report
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        if totalBytesWritten > artifact.maximumBytes { downloadTask.cancel() }
        let shouldReport = lastReported.withLock { last in
            guard totalBytesWritten - last >= 1024 * 1024 || totalBytesWritten == totalBytesExpectedToWrite else { return false }
            last = totalBytesWritten
            return true
        }
        guard shouldReport else { return }
        report(.init(detail: "Downloading " + (artifact.path as NSString).lastPathComponent,
                     bytes: totalBytesWritten, expected: artifact.size ?? (totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : nil)))
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(request.url?.scheme == "https" ? request : nil)
    }
}

/// Owns filesystem/network work only. Provider loading remains with refinement.
nonisolated struct CLAPInstaller: Sendable {
    typealias Report = @Sendable (CLAPInstallProgress) -> Void
    typealias Download = @Sendable (CLAPArtifact, URL, @escaping Report) async throws -> Void
    let plan: CLAPInstallPlan
    var download: Download = { try await downloadLive($0, to: $1, report: $2) }

    private static func downloadLive(_ artifact: CLAPArtifact, to destination: URL, report: @escaping Report) async throws {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 3600
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let delegate = CLAPDownloadProgress(artifact, report: report)
        let (temporary, response) = try await session.download(for: URLRequest(url: artifact.url), delegate: delegate)
        defer { try? FileManager.default.removeItem(at: temporary) }
        guard let response = response as? HTTPURLResponse, response.statusCode == 200 else {
            throw CLAPInstallFailure(message: "Download failed for \(artifact.path). Check the connection and retry.")
        }
        try Task.checkCancellation()
        try FileManager.default.moveItem(at: temporary, to: destination)
    }

    static func digest(_ url: URL, maximumBytes: Int64) throws -> (String, Int64) {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        var sha = SHA256()
        var count: Int64 = 0
        while let data = try file.read(upToCount: 1024 * 1024), !data.isEmpty {
            try Task.checkCancellation()
            count += Int64(data.count)
            guard count <= maximumBytes else { throw CLAPInstallFailure(message: "Artifact exceeds its pinned size limit: \(url.lastPathComponent)") }
            sha.update(data: data)
        }
        return (sha.finalize().map { String(format: "%02x", $0) }.joined(), count)
    }

    private func verify(_ artifact: CLAPArtifact, at root: URL) throws {
        let (sha, count) = try Self.digest(root.appendingPathComponent(artifact.path), maximumBytes: artifact.maximumBytes)
        guard sha == artifact.sha256, artifact.size == nil || artifact.size == count else {
            throw CLAPInstallFailure(message: "Integrity check failed for \(artifact.path). Retry to download a fresh copy.")
        }
    }

    private func verifyInstalled(_ root: URL) throws {
        for artifact in plan.artifacts where artifact.path != "runtime.tgz" { try verify(artifact, at: root) }
        let runtime = root.appendingPathComponent(plan.runtimePath).resolvingSymlinksInPath()
        let prefix = root.resolvingSymlinksInPath().path + "/"
        guard runtime.path.hasPrefix(prefix) else { throw CLAPInstallFailure(message: "ONNX Runtime resolves outside its installation.") }
        let info = try runtime.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard info.isRegularFile == true, (info.fileSize ?? 0) > 0 else {
            throw CLAPInstallFailure(message: "ONNX Runtime is missing or empty.")
        }
        // Native installs retain a digest of the library extracted from the verified
        // archive. CLI installations predate this receipt and are checked at load.
        let receipt = root.appendingPathComponent("runtime.sha256")
        if FileManager.default.fileExists(atPath: receipt.path) {
            let receiptFile = try FileHandle(forReadingFrom: receipt)
            defer { try? receiptFile.close() }
            guard let bytes = try receiptFile.read(upToCount: 65), bytes.count == 64,
                  let expected = String(data: bytes, encoding: .utf8) else {
                throw CLAPInstallFailure(message: "ONNX Runtime receipt is corrupt. Retry to repair it.")
            }
            let (actual, _) = try Self.digest(runtime, maximumBytes: 128 * 1024 * 1024)
            guard actual == expected else { throw CLAPInstallFailure(message: "ONNX Runtime integrity check failed. Retry to repair it.") }
        }
    }

    /// Complete validation precedes one atomic rename/exchange on the destination
    /// filesystem. Repairs retain the old bundle beside the new installation.
    func install(at root: URL, report: @escaping Report) async throws {
        guard plan.supported else { throw CLAPInstallFailure(message: "The pinned runtime supports Apple silicon Macs only. Intel Macs can continue using lexical search.") }
        try Task.checkCancellation()
        let fm = FileManager.default
        if fm.fileExists(atPath: root.path) {
            report(.init(detail: "Verifying existing installation…"))
            do { try verifyInstalled(root); return }
            catch is CancellationError { throw CancellationError() }
            catch { /* A fully verified replacement is staged before repair. */ }
        }
        let parent = root.deletingLastPathComponent()
        try fm.createDirectory(at: parent, withIntermediateDirectories: true)
        let stage = parent.appendingPathComponent(".wavesearch-clap-\(UUID().uuidString)")
        try fm.createDirectory(at: stage, withIntermediateDirectories: false)
        var discardStage = true
        defer { if discardStage { try? fm.removeItem(at: stage) } }
        for artifact in plan.artifacts {
            try Task.checkCancellation()
            let target = stage.appendingPathComponent(artifact.path)
            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            report(.init(detail: "Downloading " + target.lastPathComponent))
            try await download(artifact, target, report)
            report(.init(detail: "Verifying " + target.lastPathComponent))
            try verify(artifact, at: stage)
        }
        try Task.checkCancellation()
        report(.init(detail: "Unpacking verified runtime…"))
        let extraction = Process()
        extraction.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        extraction.arguments = ["-xzf", stage.appendingPathComponent("runtime.tgz").path, "-C", stage.path]
        extraction.standardOutput = FileHandle.nullDevice
        extraction.standardError = FileHandle.nullDevice
        try extraction.run()
        extraction.waitUntilExit() // Worker owns/drains the process even after cancellation.
        try Task.checkCancellation()
        guard extraction.terminationStatus == 0 else { throw CLAPInstallFailure(message: "Could not unpack ONNX Runtime. Retry the installation.") }
        try verifyInstalled(stage)
        let (sha, _) = try Self.digest(stage.appendingPathComponent(plan.runtimePath), maximumBytes: 128 * 1024 * 1024)
        try sha.write(to: stage.appendingPathComponent("runtime.sha256"), atomically: true, encoding: .utf8)
        try fm.removeItem(at: stage.appendingPathComponent("runtime.tgz"))
        try Task.checkCancellation()
        report(.init(detail: "Activating verified installation…"))
        if fm.fileExists(atPath: root.path) {
            // Preserve the previous installation, including anything installed by CLI.
            let backup = parent.appendingPathComponent("wavesearch-clap.previous-\(UUID().uuidString)")
            guard renameatx_np(AT_FDCWD, stage.path, AT_FDCWD, root.path, UInt32(RENAME_SWAP)) == 0 else {
                throw CLAPInstallFailure(message: "Could not activate the replacement installation (\(errno)). Previous files are intact.")
            }
            discardStage = false
            // Swap succeeded: stage now owns the old bundle. Never delete it if
            // keeping the backup fails; its hidden staging path remains recoverable.
            do { try fm.moveItem(at: stage, to: backup) }
            catch { throw CLAPInstallFailure(message: "Installed successfully; the previous bundle remains at \(stage.path).") }
        } else {
            guard renameatx_np(AT_FDCWD, stage.path, AT_FDCWD, root.path, UInt32(RENAME_EXCL)) == 0 else {
                throw CLAPInstallFailure(message: "Could not activate the installation (\(errno)). Retry after checking the destination.")
            }
        }
    }
}

@MainActor
final class CLAPInstallationController: ObservableObject {
    enum Phase: Equatable {
        case checking, absent, present, installed, working, cancelling, failed(String), unsupported
    }
    @Published private(set) var phase: Phase = .checking
    @Published private(set) var progress = CLAPInstallProgress(detail: "Checking installation…")
    private let installer: CLAPInstaller
    let root: URL
    private var task: Task<Void, Never>?
    private var generation = UUID()

    init(root: URL, installer: CLAPInstaller = .init(plan: .pinned)) {
        self.root = root
        self.installer = installer
    }
    var isBusy: Bool { phase == .working || phase == .cancelling || phase == .checking }

    func refresh() {
        guard task == nil else { return }
        let root = root
        let supported = installer.plan.supported
        task = Task {
            let present = await Task.detached { FileManager.default.fileExists(atPath: root.path) }.value
            phase = supported ? (present ? .present : .absent) : .unsupported
            task = nil
        }
    }

    func install(completion: @escaping () -> Void) {
        guard task == nil, installer.plan.supported else { return }
        generation = UUID()
        let generation = generation
        let previousPhase: Phase = (phase == .present || phase == .installed) ? .present : .absent
        phase = .working
        progress = .init(detail: "Preparing installation…")
        let installer = installer
        let root = root
        task = Task {
            let work = Task.detached(priority: .utility) {
                try await installer.install(at: root) { [weak self] update in
                    Task { @MainActor in
                        guard let self, self.phase == .working, self.generation == generation else { return }
                        self.progress = update
                    }
                }
            }
            do {
                try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
                phase = .installed
                completion()
            } catch {
                if Task.isCancelled || error is CancellationError {
                    phase = previousPhase
                } else { phase = .failed(error.localizedDescription) }
            }
            task = nil
        }
    }
    func cancel() { guard task != nil else { return }; phase = .cancelling; task?.cancel() }
    func cancelAndDrain() async { cancel(); await task?.value }
    func wait() async { await task?.value }
}
