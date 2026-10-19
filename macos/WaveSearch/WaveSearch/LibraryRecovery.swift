import Foundation
import WaveSearchKit

nonisolated struct RecoveryFailure: LocalizedError, Sendable {
    let message: String
    var errorDescription: String? { message }
}

/// A backup couples the SQLite snapshot with the host's library identities.
/// Original audio, installed models, and exported clips remain separate files.
nonisolated struct LibraryBackupManifest: Codable, Sendable {
    var version = 1
    var createdAt = Date()
    var folders: [LibraryFolder]
    var favourites: [String]

    func validate() throws {
        guard version == 1,
              folders.allSatisfy({ $0.id > 0 && $0.id < Int(Int32.max) && $0.path.hasPrefix("/") }),
              Set(folders.map(\.id)).count == folders.count,
              Set(folders.map { URL(fileURLWithPath: $0.path).standardizedFileURL.path }).count == folders.count,
              favourites.allSatisfy({ $0.hasPrefix("/") }) else {
            throw RecoveryFailure(message: "This backup has an unsupported or invalid library manifest.")
        }
    }
}

nonisolated struct LibraryStorageUsage: Sendable {
    let indexBytes: Int64
    let journalBytes: Int64
    let universalBytes: Int64
    let detailedBytes: Int64
    let detailedBudgetBytes: Int64
    let exportBytes: Int64
    let recoveryBytes: Int64
}

/// Synchronous recovery boundary. The store drains readers/producers before use.
nonisolated enum LibraryRecovery {
    static func checkIntegrity() throws -> String {
        var report = WSIntegrityReport()
        report.struct_size = UInt32(MemoryLayout<WSIntegrityReport>.size)
        let rc = ws_integrity_check(UInt32(WS_INTEGRITY_FULL), &report)
        guard rc >= 0 else { throw backendFailure("Integrity check failed") }
        if report.errors_found > 0 {
            throw RecoveryFailure(message: "Integrity check found \(report.errors_found) inconsistencies across \(report.checks_run) checks. Restore a known good backup or re-index the affected libraries.")
        }
        return "Passed \(report.checks_run) integrity checks (schema \(report.schema_version))."
    }

    static func createBackup(at destination: URL, manifest: LibraryBackupManifest) throws {
        try manifest.validate()
        let fm = FileManager.default
        // Publish a complete folder only after both snapshot and manifest exist.
        let staging = destination.deletingLastPathComponent().appendingPathComponent(".wavesearch-backup-\(UUID().uuidString)")
        try fm.createDirectory(at: staging, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: staging) }
        let catalog = staging.appendingPathComponent("catalog.sqlite")
        guard catalog.path.withCString({ ws_backup_create($0) }) == 0 else {
            throw backendFailure("Backup failed")
        }
        try JSONEncoder().encode(manifest).write(to: staging.appendingPathComponent("manifest.json"), options: .atomic)
        try fm.moveItem(at: staging, to: destination)
    }

    static func readManifest(at source: URL) throws -> LibraryBackupManifest {
        let manifest = try JSONDecoder().decode(LibraryBackupManifest.self,
            from: Data(contentsOf: source.appendingPathComponent("manifest.json")))
        try manifest.validate()
        return manifest
    }

    static func restore(at source: URL) throws {
        let catalog = source.appendingPathComponent("catalog.sqlite")
        guard catalog.path.withCString({ ws_backup_restore($0) }) == 0 else {
            throw backendFailure("Restore failed")
        }
    }

    /// When startup cannot open the index, validate/migrate in an isolated
    /// catalog first. Retain the closed original and its journals before publish.
    static func recoverUnopened(at source: URL, index: URL, recovery: URL,
                                previous: LibraryBackupManifest) throws -> URL {
        let fm = FileManager.default
        let staging = index.deletingLastPathComponent().appendingPathComponent(".restore-\(UUID().uuidString)")
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }
        let candidate = staging.appendingPathComponent("validated.sqlite")
        try prepareRecoveredCopy(source: source, staging: staging, candidate: candidate)

        let safety = recovery.appendingPathComponent("Unopened-Catalog-\(UUID().uuidString)")
        try fm.createDirectory(at: safety, withIntermediateDirectories: true)
        try JSONEncoder().encode(previous).write(to: safety.appendingPathComponent("manifest.json"), options: .atomic)
        var moved: [(original: URL, retained: URL)] = []
        do {
            for suffix in ["", "-wal", "-shm"] {
                let original = URL(fileURLWithPath: index.path + suffix)
                guard fm.fileExists(atPath: original.path) else { continue }
                let retained = safety.appendingPathComponent(original.lastPathComponent)
                try fm.moveItem(at: original, to: retained)
                moved.append((original, retained))
            }
            try fm.moveItem(at: candidate, to: index)
        } catch {
            // No core reader exists here. Restore every file already moved if
            // publication fails; the safety folder still retains any leftovers.
            for entry in moved.reversed() { try? fm.moveItem(at: entry.retained, to: entry.original) }
            throw RecoveryFailure(message: "Recovery could not publish the catalog: \(error.localizedDescription). Retained files are at \(safety.path).")
        }
        return safety
    }

    private static func prepareRecoveredCopy(source: URL, staging: URL, candidate: URL) throws {
        let work = staging.appendingPathComponent("work.sqlite")
        guard work.path.withCString({ ws_init($0) }) == 0 else { throw backendFailure("Could not open recovery workspace") }
        defer { ws_deinit() }
        try restore(at: source)
        _ = try checkIntegrity()
        guard candidate.path.withCString({ ws_backup_create($0) }) == 0 else { throw backendFailure("Could not prepare recovered catalog") }
    }

    /// Re-scan the replacement root using the same ID. The core publishes all
    /// paths atomically and preserves identities for unchanged relative files.
    static func reconnect(_ folder: LibraryFolder, to url: URL, backend: LibraryBackend) throws -> LibraryAccess {
        var replacement = folder
        replacement.path = url.standardizedFileURL.path
        replacement.bookmark = nil
        replacement.volumeUUID = nil // Reconnect explicitly adopts the selected volume.
        var access = backend.authorize(replacement)
        var succeeded = false
        defer {
            if !succeeded, let scope = access.scope { backend.releaseScope(scope) }
        }
        guard !access.folder.isMissing else { throw RecoveryFailure(message: "The selected library folder is unavailable.") }
        guard replacement.path.withCString({ ws_index_folder_ex(Int32(folder.id), $0, UInt32(WS_INDEX_FAST)) }) == 0 else {
            throw backendFailure("Reconnect failed; the previous index was preserved")
        }
        access.folder.fileCount = max(0, Int(ws_folder_count(Int32(folder.id))))
        succeeded = true
        return access
    }

    static func storage(index: URL, exports: URL, recovery: URL) throws -> LibraryStorageUsage {
        var cache = WSWaveformCacheStatus()
        cache.struct_size = UInt32(MemoryLayout<WSWaveformCacheStatus>.size)
        guard ws_waveform_cache_status(&cache) == 0 else { throw backendFailure("Could not read cache storage") }
        return try .init(indexBytes: fileBytes(index),
                         journalBytes: fileBytes(URL(fileURLWithPath: index.path + "-wal")) + fileBytes(URL(fileURLWithPath: index.path + "-shm")),
                         universalBytes: cache.universal_bytes, detailedBytes: cache.detailed_bytes,
                         detailedBudgetBytes: cache.detailed_budget_bytes,
                         exportBytes: directoryBytes(exports), recoveryBytes: directoryBytes(recovery))
    }

    private static func fileBytes(_ url: URL) throws -> Int64 {
        do {
            let values = try url.resourceValues(forKeys: [.fileSizeKey])
            return Int64(values.fileSize ?? 0)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile { return 0 }
    }

    private static func directoryBytes(_ url: URL) throws -> Int64 {
        guard FileManager.default.fileExists(atPath: url.path) else { return 0 }
        var enumerationError: Error?
        guard let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            errorHandler: { _, error in enumerationError = error; return false }) else {
            throw RecoveryFailure(message: "Could not read storage at \(url.path)")
        }
        var bytes: Int64 = 0
        for case let file as URL in enumerator {
            let values = try file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            if values.isRegularFile == true { bytes += Int64(values.fileSize ?? 0) }
        }
        if let enumerationError { throw enumerationError }
        return bytes
    }

    private static func backendFailure(_ fallback: String) -> RecoveryFailure {
        .init(message: ifBackendError() ?? fallback)
    }
}
