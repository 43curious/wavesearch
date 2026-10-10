import Foundation
import WaveSearchKit

nonisolated struct LibraryFolder: Identifiable, Codable, Sendable {
    let id: Int
    var name: String
    var path: String
    var fileCount: Int = 0
    var bookmark: Data?
    // Availability is a runtime observation, never a filesystem operation in a view.
    var isMissing = true

    private enum CodingKeys: String, CodingKey {
        case id, name, path, fileCount, bookmark
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

/// Blocking host/core boundary. Call these operations on a worker, not MainActor.
/// Injectable to exercise lifecycle ordering without touching a user's database.
nonisolated struct LibraryBackend: Sendable {
    var open: @Sendable (String, Data?) -> LibraryOpenResult
    var remove: @Sendable (Int32) -> String?
    var authorize: @Sendable (LibraryFolder) -> LibraryAccess
    var availability: @Sendable ([LibraryFolder]) -> [LibraryAvailability]
    var releaseScope: @Sendable (URL) -> Void
    var close: @Sendable () -> Void

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
                return .init(opened: false, error: ifBackendError() ?? "Database initialization failed")
            }
            let saved = savedData.flatMap { try? JSONDecoder().decode([LibraryFolder].self, from: $0) } ?? []
            var result = LibraryOpenResult(opened: true)
            for folder in saved {
                var access = resolveAccess(folder)
                let count = ws_folder_count(Int32(folder.id))
                if count < 0 { result.error = ifBackendError() ?? "Failed to read library count" }
                access.folder.fileCount = max(0, Int(count))
                result.folders.append(access.folder)
                if let scope = access.scope { result.scopes[folder.id] = scope }
            }
            return result
        },
        remove: { id in
            ws_remove_folder(id) == 0 ? nil : (ifBackendError() ?? "Failed to remove indexed folder")
        },
        authorize: { resolveAccess($0) },
        availability: { folders in
            folders.map { .init(id: $0.id, path: $0.path, isMissing: !FileManager.default.fileExists(atPath: $0.path)) }
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
        folder.isMissing = !FileManager.default.fileExists(atPath: folder.path)
        return .init(folder: folder, scope: scoped ? url : nil)
    }
}
