import Foundation
import WaveSearchKit

nonisolated struct SelectsDocument: Codable, Sendable {
    var version = 1
    var sources: [SelectsSource] = []
}

nonisolated struct SelectsMembership: Codable, Hashable, Sendable {
    let name: String
    let start_ms: Int64?
    let end_ms: Int64?
    var identity: String { Data(name.utf8).base64EncodedString() + "|\(start_ms ?? -1)|\(end_ms ?? -1)" }
}

nonisolated struct SelectsSource: Codable, Identifiable, Sendable {
    let id: String
    let file_id: Int32?
    let path: String
    let file_size: Int64
    let mtime_ns: Int64
    let content_hash: Int64
    let identity_kind: UInt32
    let hash_algorithm: UInt32
    let sha256: String?
    let favourite: Bool
    let tags: [String]
    let collections: [SelectsMembership]
}

nonisolated struct SelectsFilter: Equatable, Sendable {
    let kind: UInt32
    let name: String
    var title: String { kind == WS_SELECTS_FAVOURITE ? String(localized: "Favourites") : name }
}

/// Blocking catalog/document boundary; callers provide work admission and drain.
nonisolated enum PortableSelects {
    static let limit = 16 * 1024 * 1024

    static func failure() -> NSError {
        let message: String
        switch ifBackendError() {
        case "InvalidSelectsName": message = String(localized: "Use a shorter, non-empty tag or collection name.")
        case "InvalidSelectsRange": message = String(localized: "Choose a valid preview range.")
        case "SelectsLimit": message = String(localized: "This exceeds the supported document or annotation limit.")
        case "UnsupportedSelectsVersion": message = String(localized: "This JSON uses an unsupported WaveSearch selects version.")
        case "InvalidNumber", "UnexpectedToken", "MissingField", "UnknownField", "SyntaxError": message = String(localized: "This is not a valid WaveSearch selects document.")
        default: message = ifBackendError() ?? String(localized: "Cannot update tags and collections")
        }
        return NSError(domain: "WaveSearch.Selects", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }

    static func snapshot(legacyFavourites: [String]? = nil) throws -> SelectsDocument {
        if let legacyFavourites {
            let data = try JSONEncoder().encode(legacyFavourites)
            let result = data.withUnsafeBytes { ws_selects_seed_favourites_v1($0.baseAddress?.assumingMemoryBound(to: CChar.self), UInt64($0.count)) }
            guard result == 0 else { throw failure() }
        }
        return try JSONDecoder().decode(SelectsDocument.self, from: exportData())
    }

    static func exportData() throws -> Data {
        guard let json = ws_selects_export_v1() else { throw failure() }
        defer { ws_selects_json_free_v1(json) }
        return Data(String(cString: json).utf8)
    }

    static func edit(file: Int32, kind: UInt32, name: String, range: SelectsMembership?, enabled: Bool) throws {
        guard !name.utf8.contains(0) else {
            throw NSError(domain: "WaveSearch.Selects", code: 2, userInfo: [NSLocalizedDescriptionKey: "Use a valid tag or collection name."])
        }
        let result = name.withCString { ws_selects_edit_v1(file, kind, $0, range?.start_ms ?? -1, range?.end_ms ?? -1, enabled ? 1 : 0) }
        guard result == 0 else { throw failure() }
    }

    static func importData(_ data: Data) throws -> String {
        guard data.count <= limit else { throw CocoaError(.fileReadTooLarge) }
        var report = WSSelectsImportReport()
        report.struct_size = UInt32(MemoryLayout<WSSelectsImportReport>.size)
        let result = data.withUnsafeBytes { ws_selects_import_v1($0.baseAddress?.assumingMemoryBound(to: CChar.self), UInt64($0.count), &report) }
        guard result == 0 else { throw failure() }
        return String(localized: "Imported \(report.imported), merged \(report.merged), unresolved \(report.unresolved), ID conflicts preserved \(report.conflicts).")
    }

    static func readImport(_ url: URL) throws -> Data {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        var data = Data()
        while let part = try file.read(upToCount: min(64 * 1024, limit + 1 - data.count)), !part.isEmpty {
            try Task.checkCancellation()
            data.append(part)
            guard data.count <= limit else { throw CocoaError(.fileReadTooLarge) }
        }
        return data
    }

    static func writeExport(_ url: URL) throws {
        guard url.pathExtension.lowercased() == "json" else { throw CocoaError(.fileWriteInvalidFileName) }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let data = try exportData()
        try Task.checkCancellation()
        try data.write(to: url, options: .atomic)
    }
}
