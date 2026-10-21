import Foundation
import WaveSearchKit

nonisolated struct LibraryFolder: Identifiable, Codable, Sendable {
    let id: Int
    var name: String
    var path: String
    var fileCount: Int = 0
    var bookmark: Data?
    var volumeUUID: String?
    // Availability is a runtime observation, never a filesystem operation in a view.
    var isMissing = true

    private enum CodingKeys: String, CodingKey {
        case id, name, path, fileCount, bookmark, volumeUUID
    }
}

nonisolated struct LibraryOpenResult: Sendable {
    var opened: Bool
    var folders: [LibraryFolder] = []
    var scopes: [Int: URL] = [:]
    var error: String?
}

nonisolated struct LibraryAccess: Sendable {
    var folder: LibraryFolder
    var scope: URL?
}

nonisolated struct LibraryAvailability: Sendable {
    let id: Int
    let path: String
    let isMissing: Bool
}

nonisolated struct LibraryScanResult: Sendable {
    var result: Int32
    var count: Int32
    var error: String?
    var favouriteMoves: [String: String] = [:]
    var selectedFile: SoundFile?
}

/// Blocking host/core boundary. Call these operations on a worker, not MainActor.
/// Injectable to exercise lifecycle ordering without touching a user's database.
nonisolated struct LibraryBackend: Sendable {
    var open: @Sendable (String, Data?) -> LibraryOpenResult
    var remove: @Sendable (Int32) -> String?
    var authorize: @Sendable (LibraryFolder) -> LibraryAccess
    var availability: @Sendable ([LibraryFolder]) -> [LibraryAvailability]
    var releaseScope: @Sendable (URL) -> Void
    var close: @Sendable () -> Void
    var scan: @Sendable (Int32, String, Bool, [String], Int?) -> LibraryScanResult = {
        scanLive(id: $0, path: $1, deep: $2, favourites: $3, selectedID: $4)
    }

    private static func scanLive(id: Int32, path: String, deep: Bool, favourites: [String], selectedID: Int?) -> LibraryScanResult {
        var references: [String: Int32] = [:]
        let prefix = path.hasSuffix("/") ? path : path + "/"
        for favourite in favourites where favourite.hasPrefix(prefix) {
            var row = WSResult()
            if favourite.withCString({ ws_file_lookup_path_v1($0, &row) }) == 1, row.folder_id == id {
                references[favourite] = row.file_id
            }
        }
        let flags = deep ? UInt32(WS_INDEX_DEEP) : UInt32(WS_INDEX_FAST)
        guard !Task.isCancelled else { return .init(result: -1, count: 0, error: "Cancelled") }
        let code = path.withCString { ws_index_folder_ex(id, $0, flags) }
        let error = code < 0 ? ifBackendError() : nil
        let count = ws_folder_count(id)
        var result = LibraryScanResult(result: code, count: count, error: error ?? (count < 0 ? ifBackendError() : nil))
        guard code == 0, count >= 0 else { return result }
        for (oldPath, fileID) in references {
            var row = WSResult()
            if ws_file_lookup_v1(fileID, &row) == 1, row.folder_id == id {
                let current = SearchRequest.file(row)
                if current.path != oldPath { result.favouriteMoves[oldPath] = current.path }
            }
        }
        if let selectedID {
            var row = WSResult()
            if ws_file_lookup_v1(Int32(selectedID), &row) == 1, row.folder_id == id {
                result.selectedFile = SearchRequest.file(row)
            }
        }
        return result
    }

    static let live = LibraryBackend(
        open: { path, savedData in
            do {
                try FileManager.default.createDirectory(
                    at: URL(fileURLWithPath: path).deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
            } catch {
                return .init(opened: false, error: error.localizedDescription)
            }
            guard path.withCString({ ws_init($0) }) == 0 else {
                return .init(opened: false, error: ifBackendError() ?? String(localized: "Database initialization failed"))
            }
            let saved = savedData.flatMap { try? JSONDecoder().decode([LibraryFolder].self, from: $0) } ?? []
            var result = LibraryOpenResult(opened: true)
            for folder in saved {
                var access = resolveAccess(folder)
                let count = ws_folder_count(Int32(folder.id))
                if count < 0 { result.error = ifBackendError() ?? String(localized: "Failed to read library count") }
                access.folder.fileCount = max(0, Int(count))
                result.folders.append(access.folder)
                if let scope = access.scope { result.scopes[folder.id] = scope }
            }
            return result
        },
        remove: { id in
            ws_remove_folder(id) == 0 ? nil : (ifBackendError() ?? String(localized: "Failed to remove indexed folder"))
        },
        authorize: { resolveAccess($0) },
        availability: { folders in
            folders.map { folder in
                let volume = volumeUUID(at: folder.path)
                return .init(id: folder.id, path: folder.path,
                             isMissing: !FileManager.default.fileExists(atPath: folder.path)
                                || (folder.volumeUUID.map { $0 != volume } ?? false))
            }
        },
        releaseScope: { $0.stopAccessingSecurityScopedResource() },
        close: { ws_deinit() }
    )

    private static func resolveAccess(_ original: LibraryFolder) -> LibraryAccess {
        var folder = original
        var url = URL(fileURLWithPath: folder.path)
        var stale = false
        if let bookmark = folder.bookmark,
           let resolved = try? URL(resolvingBookmarkData: bookmark, options: [.withSecurityScope, .withoutUI],
                                   relativeTo: nil, bookmarkDataIsStale: &stale) {
            url = resolved
        }
        let scoped = url.startAccessingSecurityScopedResource()
        if folder.bookmark == nil || stale {
            folder.bookmark = try? url.bookmarkData(options: .withSecurityScope,
                                                   includingResourceValuesForKeys: nil, relativeTo: nil)
        }
        // Do not silently change catalog paths when a bookmark resolves elsewhere.
        let volume = volumeUUID(at: folder.path)
        if folder.volumeUUID == nil { folder.volumeUUID = volume }
        folder.isMissing = !FileManager.default.fileExists(atPath: folder.path)
            || (folder.volumeUUID.map { $0 != volume } ?? false)
        return .init(folder: folder, scope: scoped ? url : nil)
    }

    private static func volumeUUID(at path: String) -> String? {
        try? URL(fileURLWithPath: path).resourceValues(forKeys: [.volumeUUIDStringKey]).volumeUUIDString
    }
}
