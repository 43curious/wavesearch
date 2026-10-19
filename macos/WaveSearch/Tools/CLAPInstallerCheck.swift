import Foundation
import CryptoKit
import WaveSearchKit

private actor DownloadProbe {
    var calls = 0
    func record() { calls += 1 }
}

@main
struct CLAPInstallerCheck {
    static func sha(_ bytes: Data) -> String { SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined() }

    @MainActor static func main() async throws {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent("wavesearch-installer-check-\(UUID().uuidString)")
        try fm.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: base) }
        let runtimePath = "runtime/lib/libonnxruntime.dylib"
        let fixture = base.appendingPathComponent("fixture")
        try fm.createDirectory(at: fixture.appendingPathComponent("runtime/lib"), withIntermediateDirectories: true)
        try Data("runtime fixture".utf8).write(to: fixture.appendingPathComponent("runtime/lib/libonnxruntime.1.29.0.dylib"))
        try fm.createSymbolicLink(atPath: fixture.appendingPathComponent(runtimePath).path,
                                  withDestinationPath: "libonnxruntime.1.29.0.dylib")
        let tar = Process()
        tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        let archive = base.appendingPathComponent("fixture.tgz")
        tar.arguments = ["-czf", archive.path, "-C", fixture.path, "runtime"]
        try tar.run(); tar.waitUntilExit()
        precondition(tar.terminationStatus == 0)
        let payloads = ["model/manifest.json": Data("manifest fixture".utf8),
                        "model/audio.onnx": Data("model fixture".utf8), "runtime.tgz": try Data(contentsOf: archive)]
        let artifacts = payloads.keys.sorted().map { path in
            CLAPArtifact(path: path, url: URL(string: "https://example.invalid/" + path)!, sha256: sha(payloads[path]!),
                         size: Int64(payloads[path]!.count), maximumBytes: 1024 * 1024)
        }
        let plan = CLAPInstallPlan(artifacts: artifacts, runtimePath: runtimePath, supported: true)
        let probe = DownloadProbe()
        let installer = CLAPInstaller(plan: plan, download: { artifact, target, report in
            precondition(!Thread.isMainThread, "Installation I/O belongs off-main")
            await probe.record()
            try Task.checkCancellation()
            try payloads[artifact.path]!.write(to: target)
            report(.init(detail: "Fixture downloaded", bytes: Int64(payloads[artifact.path]!.count)))
        })
        let root = base.appendingPathComponent("wavesearch-clap")
        let controller = CLAPInstallationController(root: root, installer: installer)
        controller.refresh(); await controller.wait()
        precondition(controller.phase == .absent)
        var activated = 0
        controller.install { activated += 1 }
        await controller.wait()
        precondition(controller.phase == .installed && activated == 1)
        precondition(fm.fileExists(atPath: root.appendingPathComponent("runtime.sha256").path))
        precondition(!fm.fileExists(atPath: root.appendingPathComponent("runtime.tgz").path))
        controller.install { activated += 1 }; await controller.wait()
        let initialCalls = await probe.calls
        precondition(initialCalls == artifacts.count, "A valid existing install must not redownload")
        // Corrupt runtime and model bytes are repaired with atomic replacement;
        // the previous bundle is preserved for inspection rather than removed.
        try Data("broken".utf8).write(to: root.appendingPathComponent(runtimePath))
        controller.install { activated += 1 }; await controller.wait()
        precondition(controller.phase == .installed && activated == 3)
        let backups = try fm.contentsOfDirectory(at: base, includingPropertiesForKeys: nil).filter { $0.lastPathComponent.hasPrefix("wavesearch-clap.previous-") }
        precondition(backups.count == 1)
        let oldBytes = try Data(contentsOf: backups[0].appendingPathComponent(runtimePath))
        precondition(oldBytes == Data("broken".utf8))
        print("PASS: install, existing validation, corrupt repair and retained previous bundle")

        for failure in ["network", "corrupt", "partial"] {
            let target = base.appendingPathComponent(failure)
            let failing = CLAPInstaller(plan: plan, download: { _, destination, _ in
                try Data("partial".utf8).write(to: destination)
                if failure == "network" { throw URLError(.notConnectedToInternet) }
                if failure == "partial" { throw CancellationError() }
            })
            do {
                try await Task.detached { try await failing.install(at: target) { _ in } }.value
                preconditionFailure("Failure must not activate a partial installation")
            } catch {}
            precondition(!fm.fileExists(atPath: target.path))
            let stages = try fm.contentsOfDirectory(atPath: base.path).filter { $0.hasPrefix(".wavesearch-clap-") }
            precondition(stages.isEmpty, "Failed/cancelled staging must be removed")
        }
        // An unsupported platform must reject before filesystem/network work.
        let unsupported = CLAPInstaller(plan: .init(artifacts: artifacts, runtimePath: runtimePath, supported: false),
                                        download: { _, _, _ in preconditionFailure("Unsupported download") })
        let unavailable = CLAPInstallationController(root: base.appendingPathComponent("unsupported"), installer: unsupported)
        unavailable.refresh(); await unavailable.wait()
        precondition(unavailable.phase == .unsupported)
        unavailable.install { preconditionFailure("Unsupported activation") }
        precondition(!fm.fileExists(atPath: unavailable.root.path))
        print("PASS: absent, partial, corrupt, network-error and unsupported-platform handling")

        let retryProbe = DownloadProbe()
        let retrying = CLAPInstaller(plan: plan, download: { artifact, destination, _ in
            await retryProbe.record()
            if await retryProbe.calls == 1 { throw URLError(.timedOut) }
            try payloads[artifact.path]!.write(to: destination)
        })
        let retried = CLAPInstallationController(root: base.appendingPathComponent("retry"), installer: retrying)
        retried.refresh(); await retried.wait()
        retried.install { preconditionFailure("Failed attempt must not activate") }; await retried.wait()
        guard case .failed = retried.phase else { preconditionFailure("Network failure needs retry feedback") }
        retried.install {}; await retried.wait()
        precondition(retried.phase == .installed)
        // A failed repair must leave the old bundle's bytes untouched.
        try Data("retain this".utf8).write(to: retried.root.appendingPathComponent("model/audio.onnx"))
        let failedRepair = CLAPInstaller(plan: plan, download: { _, _, _ in throw URLError(.networkConnectionLost) })
        do {
            try await Task.detached { try await failedRepair.install(at: retried.root) { _ in } }.value
            preconditionFailure("Repair should fail")
        } catch {}
        let retained = try Data(contentsOf: retried.root.appendingPathComponent("model/audio.onnx"))
        precondition(retained == Data("retain this".utf8))
        print("PASS: retry after network failure and preservation after failed repair")

        let cancellationProbe = DownloadProbe()
        let cancellable = CLAPInstaller(plan: plan, download: { _, destination, _ in
            try Data("partial".utf8).write(to: destination)
            await cancellationProbe.record()
            try await Task.sleep(for: .seconds(30))
        })
        let cancelled = CLAPInstallationController(root: base.appendingPathComponent("cancelled"), installer: cancellable)
        cancelled.refresh(); await cancelled.wait()
        cancelled.install { preconditionFailure("Cancelled activation") }
        while await cancellationProbe.calls == 0 { try await Task.sleep(for: .milliseconds(5)) }
        await cancelled.cancelAndDrain()
        precondition(cancelled.phase == .absent && !fm.fileExists(atPath: cancelled.root.path))
        let remaining = try fm.contentsOfDirectory(atPath: base.path).filter { $0.hasPrefix(".wavesearch-clap-") }
        precondition(remaining.isEmpty, "Shutdown drain waits for cleanup")
        print("PASS: cancellation drains download and removes staging before returning")

        // Native and CLI plans must keep the exact pinned artifact contract.
        let script = try String(contentsOfFile: "scripts/install-clap-model.sh", encoding: .utf8)
        for artifact in CLAPInstallPlan.pinned.artifacts { precondition(script.contains(artifact.sha256)) }
        precondition(script.contains("d4d4372c9894b975ec118589b4f4328103796e15"))
        try await lexicalFallback(base: base, runtime: root.appendingPathComponent(runtimePath))
        print("PASS: pinned CLI compatibility and lexical fallback after provider-load failure")
    }

    nonisolated static func lexicalFallback(base: URL, runtime: URL) async throws {
        try await Task.detached {
            let catalog = base.appendingPathComponent("lexical.sqlite")
            precondition(catalog.path.withCString { ws_init($0) } == 0)
            defer { ws_deinit() }
            let sources = base.appendingPathComponent("sounds")
            try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
            // Discoverable file: no decoder/model download is needed for filename search.
            try Data("fixture".utf8).write(to: sources.appendingPathComponent("door.wav"))
            precondition(sources.path.withCString { ws_index_folder_ex(1, $0, UInt32(WS_INDEX_FAST)) } == 0)
            precondition(runtime.path.withCString { runtime in
                base.appendingPathComponent("absent-model").path.withCString { ws_clap_load(runtime, $0, 1) }
            } != 0)
            var result = WSResult()
            precondition(ws_search("door", -1, &result, 1) == 1)
        }.value
    }
}
