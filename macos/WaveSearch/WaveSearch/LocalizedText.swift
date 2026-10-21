import Foundation

/// Native plural rules choose the phrase; a second argument supplies the grouped
/// number. Source names, IDs, paths and serialized data never pass through here.
nonisolated enum LocalizedText {
    enum CountUnit: String {
        case files, filesDiscovered, sounds, soundsLoaded, matches, channels

        var englishForms: (String, String) {
            switch self {
            case .files: ("%2$@ file", "%2$@ files")
            case .filesDiscovered: ("%2$@ file discovered", "%2$@ files discovered")
            case .sounds: ("%2$@ sound", "%2$@ sounds")
            case .soundsLoaded: ("%2$@ sound loaded", "%2$@ sounds loaded")
            case .matches: ("%2$@ match", "%2$@ matches")
            case .channels: ("%2$@ channel", "%2$@ channels")
            }
        }
    }

    static func count(_ value: Int, _ unit: CountUnit) -> String {
        let forms = unit.englishForms
        let format = Bundle.main.localizedString(forKey: "count." + unit.rawValue,
                                                 value: value == 1 ? forms.0 : forms.1,
                                                 table: nil)
        return String(format: format, locale: Locale.current, arguments: [value, value.formatted()])
    }

    static func duration(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite else { return "—" }
        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = .abbreviated
        formatter.allowedUnits = seconds < 60 ? [.second] : seconds < 3600 ? [.minute, .second] : [.hour, .minute]
        return formatter.string(from: max(0, seconds.rounded())) ?? "—"
    }

    static func position(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds < Double(Int.max / 100) else { return "—" }
        let hundredths = Int((max(0, seconds) * 100).rounded())
        let minutes = (hundredths / 6000).formatted(.number.grouping(.never))
        let remainder = (Double(hundredths % 6000) / 100).formatted(
            .number.grouping(.never).precision(.integerAndFractionLength(integer: 2, fraction: 2)))
        return "\(minutes):\(remainder)"
    }
}
