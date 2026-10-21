import SwiftUI
import AppKit
import Observation
import Combine

enum AppAppearanceMode: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }
    var title: String {
        switch self {
        case .system: String(localized: "System")
        case .light: String(localized: "Light")
        case .dark: String(localized: "Dark")
        }
    }
    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

extension View {
    func appAppearance() -> some View { modifier(AppAppearanceModifier()) }
}

private struct AppAppearanceModifier: ViewModifier {
    @State private var systemScheme = scheme(for: NSApplication.shared.effectiveAppearance)

    func body(content: Content) -> some View {
        // Clearing preferredColorScheme to nil resets native window chrome but
        // can leave a hosted Settings Form in its previous scheme. Resolve
        // System explicitly and observe the app's unoverridden OS appearance.
        content
            .preferredColorScheme(AppearancePreferences.shared.mode.colorScheme ?? systemScheme)
            .onReceive(NSApplication.shared.publisher(for: \.effectiveAppearance)) { appearance in
                systemScheme = Self.scheme(for: appearance)
            }
    }

    private static func scheme(for appearance: NSAppearance) -> ColorScheme {
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? .dark : .light
    }
}

/// Store RGB components instead of archiving platform color objects.
nonisolated struct PreferenceColor: Codable, Equatable, Sendable {
    let red: Double
    let green: Double
    let blue: Double

    var isValid: Bool { [red, green, blue].allSatisfy { $0.isFinite && (0...1).contains($0) } }

    @MainActor var color: Color { Color(red: red, green: green, blue: blue) }

    @MainActor init?(_ color: Color) {
        guard let rgb = NSColor(color).usingColorSpace(.sRGB) else { return nil }
        self.init(red: min(max(Double(rgb.redComponent), 0), 1),
                  green: min(max(Double(rgb.greenComponent), 0), 1),
                  blue: min(max(Double(rgb.blueComponent), 0), 1))
    }

    init(red: Double, green: Double, blue: Double) {
        self.red = red
        self.green = green
        self.blue = blue
    }
}

/// Observable reads through AppTheme also invalidate the views using its colors.
@MainActor @Observable
final class AppearancePreferences {
    static let shared = AppearancePreferences()
    static let defaultAccent = PreferenceColor(red: 0.20, green: 0.62, blue: 1.0)
    static let defaultWaveform = PreferenceColor(red: 0.30, green: 0.78, blue: 0.96)
    static let defaultPlayed = PreferenceColor(red: 0.25, green: 0.86, blue: 0.55)

    @ObservationIgnored private let preferences: UserDefaults
    var mode: AppAppearanceMode { didSet { preferences.set(mode.rawValue, forKey: "ws_appearance_v1") } }
    var accent: PreferenceColor { didSet { save(accent, key: "ws_accent_color_v1") } }
    var waveform: PreferenceColor { didSet { save(waveform, key: "ws_waveform_color_v1") } }
    var played: PreferenceColor { didSet { save(played, key: "ws_waveform_played_color_v1") } }

    init(preferences: UserDefaults = .standard) {
        self.preferences = preferences
        mode = AppAppearanceMode(rawValue: preferences.string(forKey: "ws_appearance_v1") ?? "") ?? .system
        accent = Self.load(preferences, key: "ws_accent_color_v1", fallback: Self.defaultAccent)
        waveform = Self.load(preferences, key: "ws_waveform_color_v1", fallback: Self.defaultWaveform)
        played = Self.load(preferences, key: "ws_waveform_played_color_v1", fallback: Self.defaultPlayed)
    }

    func resetColors() {
        accent = Self.defaultAccent
        waveform = Self.defaultWaveform
        played = Self.defaultPlayed
    }

    private func save(_ color: PreferenceColor, key: String) {
        guard let data = try? JSONEncoder().encode(color) else { return }
        preferences.set(data, forKey: key)
    }

    private static func load(_ preferences: UserDefaults, key: String, fallback: PreferenceColor) -> PreferenceColor {
        guard let data = preferences.data(forKey: key),
              let color = try? JSONDecoder().decode(PreferenceColor.self, from: data), color.isValid else { return fallback }
        return color
    }
}
