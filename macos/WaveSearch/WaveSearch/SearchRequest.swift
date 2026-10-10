import Foundation
import WaveSearchKit

nonisolated struct SearchOutcome: Sendable {
    var files: [SoundFile] = []
    var error: String?
    var cancelled = false
    var needsRefinement = true
    var hasMore = false
}

/// Immutable request + one atomic C cancellation flag. Every operation and
/// canceller retains this owner, so destroy cannot race either of them.
nonisolated final class SearchRequest: @unchecked Sendable {
    enum Kind: Sendable {
        case text(String)
        case browse
        case browseMore(after: SoundFile)
        case example(String)
    }
    let id = UUID()
    let kind: Kind
    let folderID: Int32
    private let handle: OpaquePointer

    init?(kind: Kind, folderID: Int32) {
        guard let handle = ws_query_create() else { return nil }
        self.handle = handle
        self.kind = kind
        self.folderID = folderID
    }

    deinit { ws_query_destroy(handle) }
    func cancel() { ws_query_cancel(handle) }

    typealias Backend = @Sendable (SearchRequest, Bool) -> SearchOutcome
    typealias RefinementWait = @Sendable (ContinuousClock.Instant) async throws -> Void

    static func waitForRefinement(until deadline: ContinuousClock.Instant) async throws {
        try await Task.sleep(until: deadline, clock: .continuous)
    }

    func run(lexicalOnly: Bool, backend: @escaping Backend) async -> SearchOutcome {
        let task = Task.detached(priority: .userInitiated) { backend(self, lexicalOnly) }
        return await withTaskCancellationHandler {
            await task.value // Keep the worker slot until the native call really returns.
        } onCancel: {
            self.cancel()
            task.cancel()
        }
    }

    static func execute(_ request: SearchRequest, lexicalOnly: Bool) -> SearchOutcome {
        if case .example(let path) = request.kind {
            var raw = [WSExampleResult](repeating: WSExampleResult(), count: 200)
            for index in raw.indices { raw[index].struct_size = UInt32(MemoryLayout<WSExampleResult>.size) }
            let count = path.withCString { path in
                raw.withUnsafeMutableBufferPointer {
                    ws_search_by_example_v2(request.handle, path, request.folderID, $0.baseAddress, Int32($0.count))
                }
            }
            guard count >= 0 else { return failure(count) }
            return SearchOutcome(files: raw.prefix(Int(count)).map { file($0.result, group: $0.acoustic_group_id) })
        }
        let browsing: Bool
        switch request.kind { case .browse, .browseMore: browsing = true; default: browsing = false }
        let pageSize = 200
        let capacity = browsing ? pageSize + 1 : 500
        var raw = [WSResult](repeating: WSResult(), count: capacity)
        let count = raw.withUnsafeMutableBufferPointer { buffer -> Int32 in
            switch request.kind {
            case .text(let text):
                return text.withCString {
                    ws_search_v2(request.handle, $0, request.folderID, buffer.baseAddress, Int32(buffer.count),
                                 lexicalOnly ? UInt32(WS_SEARCH_LEXICAL_ONLY) : UInt32(WS_SEARCH_HYBRID))
                }
            case .browse:
                return ws_list_folder_page_v2(request.handle, request.folderID, nil, 0, buffer.baseAddress, Int32(buffer.count))
            case .browseMore(let after):
                return after.name.withCString {
                    ws_list_folder_page_v2(request.handle, request.folderID, $0, Int32(after.id), buffer.baseAddress, Int32(buffer.count))
                }
            case .example: preconditionFailure("Handled above")
            }
        }
        guard count >= 0 else { return failure(count) }
        let needsRefinement: Bool
        if case .text(let text) = request.kind {
            needsRefinement = lexicalOnly && text.withCString { ws_search_needs_refinement($0) != 0 }
        } else {
            needsRefinement = false
        }
        return SearchOutcome(files: raw.prefix(browsing ? min(Int(count), pageSize) : Int(count)).map { file($0) },
                             needsRefinement: needsRefinement, hasMore: browsing && count > pageSize)
    }

    private static func failure(_ code: Int32) -> SearchOutcome {
        // This function runs on the same thread as the failing C call.
        SearchOutcome(error: ifBackendError() ?? "Search failed", cancelled: code == WS_QUERY_CANCELLED)
    }

    private static func file(_ result: WSResult, group: Int64 = 0) -> SoundFile {
        SoundFile(
            id: Int(result.file_id), folderId: Int(result.folder_id),
            path: withUnsafeBytes(of: result.path) { String(cString: $0.baseAddress!.assumingMemoryBound(to: CChar.self)) },
            name: withUnsafeBytes(of: result.name) { String(cString: $0.baseAddress!.assumingMemoryBound(to: CChar.self)) },
            durationMs: Int(result.duration_ms), contentHash: result.content_hash, acousticGroupId: group
        )
    }
}
