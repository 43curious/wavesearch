import SwiftUI

struct AppSettingsView: View {
    var body: some View {
        TabView {
            RefinementSettingsView()
                .tabItem { Label("General", systemImage: "gearshape") }
            AppearanceSettingsView()
                .tabItem { Label("Appearance", systemImage: "paintpalette") }
            RecoverySettingsView()
                .tabItem { Label("Storage & Recovery", systemImage: "externaldrive") }
        }
        .frame(width: 620, height: 650)
    }
}

private struct AppearanceSettingsView: View {
    @Bindable private var appearance = AppearancePreferences.shared

    var body: some View {
        Form {
            Section("App appearance") {
                Picker("Appearance", selection: $appearance.mode) {
                    ForEach(AppAppearanceMode.allCases) { mode in Text(mode.title).tag(mode) }
                }
                colorPicker("App accent", value: $appearance.accent)
            }
            Section("Waveform colors") {
                colorPicker("Waveform", value: $appearance.waveform)
                colorPicker("Played waveform", value: $appearance.played)
                WaveformColorPreview()
                    .frame(height: 90)
                    .accessibilityLabel("Waveform color preview: played portion on the left")
                Button("Reset Colors") { appearance.resetColors() }
            }
        }
        .formStyle(.grouped)
        .padding(12)
    }

    private func colorPicker(_ title: String, value: Binding<PreferenceColor>) -> some View {
        ColorPicker(title, selection: Binding(get: { value.wrappedValue.color }, set: { color in
            if let rgb = PreferenceColor(color) { value.wrappedValue = rgb }
        }), supportsOpacity: false)
    }
}

private struct WaveformColorPreview: View {
    var body: some View {
        let waveform = AppTheme.waveform
        let played = AppTheme.waveformPlayed
        Canvas { context, size in
            for index in 0..<80 {
                let x = CGFloat(index) / 80 * size.width
                let height = 12 + abs(sin(Double(index) * 0.47) * cos(Double(index) * 0.13)) * (size.height - 20)
                let bar = Path(roundedRect: CGRect(x: x, y: (size.height - height) / 2, width: max(1, size.width / 80 - 2), height: height), cornerRadius: 1)
                context.fill(bar, with: .color(index < 28 ? played : waveform))
            }
        }
        .padding(10)
        .background(AppTheme.panelSunken, in: RoundedRectangle(cornerRadius: 8))
    }
}
