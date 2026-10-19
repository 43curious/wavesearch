import Foundation
import AVFoundation
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
        case example(URL)
    }
    let id = UUID()
    let kind: Kind
    let folderID: Int32
    private let handle: OpaquePointer
    private let cancellationLock = NSLock()
    private var cancelled = false

    init?(kind: Kind, folderID: Int32) {
        guard let handle = ws_query_create() else { return nil }
        self.handle = handle
        self.kind = kind
        self.folderID = folderID
    }

    deinit { ws_query_destroy(handle) }
    func cancel() {
        cancellationLock.lock()
        cancelled = true
        cancellationLock.unlock()
        ws_query_cancel(handle)
    }

    func checkCancellation() throws {
        cancellationLock.lock()
        let stopped = cancelled
        cancellationLock.unlock()
        if stopped || Task.isCancelled { throw CancellationError() }
    }

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
        do { try request.checkCancellation() }
        catch { return SearchOutcome(cancelled: true) }
        if case .example(let url) = request.kind {
            // Retain the original chooser/drop URL and its permission through
            // decoding AND the native call. Worker draining precedes core close.
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            var raw = [WSExampleResult](repeating: WSExampleResult(), count: 200)
            for index in raw.indices { raw[index].struct_size = UInt32(MemoryLayout<WSExampleResult>.size) }
            let count: Int32
            if ["wav", "aif", "aiff", "aifc"].contains(url.pathExtension.lowercased()) {
                count = url.path.withCString { path in
                    raw.withUnsafeMutableBufferPointer {
                        ws_search_by_example_v2(request.handle, path, request.folderID, $0.baseAddress, Int32($0.count))
                    }
                }
            } else {
                do {
                    let pcm = try ExampleAudio.decode(url, checkCancellation: request.checkCancellation)
                    try request.checkCancellation()
                    count = pcm.samples.withUnsafeBufferPointer { samples in
                        raw.withUnsafeMutableBufferPointer {
                            ws_search_by_example_pcm_v2(request.handle, samples.baseAddress, UInt64(pcm.frames),
                                                       pcm.channels, pcm.sampleRate, request.folderID,
                                                       $0.baseAddress, Int32($0.count))
                        }
                    }
                } catch is CancellationError {
                    return SearchOutcome(cancelled: true)
                } catch {
                    return SearchOutcome(error: "Cannot use \(url.lastPathComponent): \(error.localizedDescription)")
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
