import SwiftUI
import AppKit

/// Shared visual language: dense, neutral, DAW-inspired surfaces with a deeper dark mode.
enum AppTheme {
    static let panel = adaptive(light: (0.95, 0.96, 0.97, 1), dark: (0.035, 0.039, 0.047, 1))
    static let panelRaised = adaptive(light: (1, 1, 1, 1), dark: (0.060, 0.067, 0.080, 1))
    static let panelSunken = adaptive(light: (0.90, 0.92, 0.94, 1), dark: (0.020, 0.024, 0.030, 1))
    static let chrome = adaptive(light: (0.88, 0.90, 0.93, 1), dark: (0.025, 0.029, 0.036, 1))
    static let hairline = adaptive(light: (0, 0, 0, 0.12), dark: (1, 1, 1, 0.10))
    static let softLine = adaptive(light: (0, 0, 0, 0.06), dark: (1, 1, 1, 0.055))
    static var accent: Color { AppearancePreferences.shared.accent.color }
    static var waveform: Color { AppearancePreferences.shared.waveform.color }
    static var waveformPlayed: Color { AppearancePreferences.shared.played.color }

    private static func adaptive(
        light: (Double, Double, Double, Double),
        dark: (Double, Double, Double, Double)
    ) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let useDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let c = useDark ? dark : light
            return NSColor(calibratedRed: c.0, green: c.1, blue: c.2, alpha: c.3)
        })
    }
}
