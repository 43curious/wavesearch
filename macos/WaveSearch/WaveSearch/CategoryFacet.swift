import Foundation
import WaveSearchKit

nonisolated struct CategoryFacet: Identifiable, Sendable {
    let id: String
    let category: String
    let subcategory: String
    let count: UInt32

    struct Group: Sendable {
        let name: String
        let facets: [CategoryFacet]
    }

    static func groups(_ facets: [CategoryFacet]) -> [Group] {
        Dictionary(grouping: facets, by: \.category).map { Group(name: $0.key, facets: $0.value) }.sorted { $0.name < $1.name }
    }

    static func load(folder: Int32) -> Result<[CategoryFacet], NSError> {
        var raw = [WSCategory](repeating: WSCategory(), count: 753)
        for i in raw.indices { raw[i].struct_size = UInt32(MemoryLayout<WSCategory>.size) }
        let count = raw.withUnsafeMutableBufferPointer { ws_category_list_v1(folder, $0.baseAddress, Int32($0.count)) }
        guard count >= 0 else {
            return .failure(NSError(domain: "WaveSearch", code: Int(count), userInfo: [NSLocalizedDescriptionKey: ifBackendError() ?? "Cannot read UCS categories"]))
        }
        return .success(raw.prefix(Int(count)).map { value in
            func string<T>(_ bytes: T) -> String {
                withUnsafeBytes(of: bytes) { String(cString: $0.baseAddress!.assumingMemoryBound(to: CChar.self)) }
            }
            return CategoryFacet(id: string(value.cat_id), category: string(value.category), subcategory: string(value.subcategory), count: value.file_count)
        })
    }
}
