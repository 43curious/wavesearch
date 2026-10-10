import Foundation
import OSLog

nonisolated enum WaveformSignposts {
    private static let log = OSLog(subsystem: "SPL.WaveSearch", category: "Waveform")

    static func event(_ name: StaticString, fileID: Int) {
        os_signpost(.event, log: log, name: name, "%{public}d", fileID)
    }

    static func begin(_ name: StaticString, fileID: Int) -> OSSignpostID {
        let identifier = OSSignpostID(log: log)
        os_signpost(.begin, log: log, name: name, signpostID: identifier, "%{public}d", fileID)
        return identifier
    }

    static func end(_ name: StaticString, id: OSSignpostID, fileID: Int) {
        os_signpost(.end, log: log, name: name, signpostID: id, "%{public}d", fileID)
    }
}
