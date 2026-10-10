import SwiftUI
import AppKit

/// Exercise the native Settings scene: its Form must follow the window back to
/// System after an explicit theme. App-level appearance pins the system input.
@main
struct SettingsAppearanceCheck: App {
    @StateObject private var store = AppStore(
        storageDirectory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString),
        preferences: UserDefaults(suiteName: UUID().uuidString)!, startsRefinement: false
    )

    var body: some Scene {
        WindowGroup {
            OpenSettingsCheckView()
                .frame(width: 200, height: 100)
        }
        Settings {
            AppSettingsView()
                .environmentObject(store)
                .appAppearance()
                .task { await checkAppearance() }
        }
    }

    private func checkAppearance() async {
        let appearance = AppearancePreferences.shared
        let original = appearance.mode
        defer { appearance.mode = original }
        do {
            try await Task.sleep(for: .milliseconds(400))
            guard let window = NSApp.windows.first(where: { $0.isVisible && (600...640).contains($0.contentView!.bounds.width) }) else {
                fatalError("Settings window did not open")
            }
            for system in [NSAppearance.Name.aqua, .darkAqua] {
                NSApp.appearance = NSAppearance(named: system)
                let systemIsDark = system == .darkAqua
                appearance.mode = .system
                try await Task.sleep(for: .milliseconds(250))
                let baseline = sample(window)
                appearance.mode = systemIsDark ? .light : .dark
                try await Task.sleep(for: .milliseconds(250))
                let overridden = sample(window)
                guard abs(baseline - overridden) > 0.3 else { fatalError("Theme override did not change Settings content") }
                appearance.mode = .system
                try await Task.sleep(for: .milliseconds(250))
                let restored = sample(window)
                let windowIsDark = window.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                print("system=\(system.rawValue) baseline=\(baseline) override=\(overridden) restored=\(restored) windowDark=\(windowIsDark)")
                guard windowIsDark == systemIsDark && abs(restored - baseline) < 0.05 else {
                    FileHandle.standardError.write(Data("FAIL: Settings form retained its explicit appearance after switching back to System\n".utf8))
                    appearance.mode = original
                    exit(1)
                }
            }
            print("PASS: native Settings content and window return to system light/dark appearance")
            appearance.mode = original
            exit(0)
        } catch { fatalError(error.localizedDescription) }
    }

    private func sample(_ window: NSWindow) -> Double {
        let view = window.contentView!.superview!
        let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let color = bitmap.colorAt(x: 30, y: 200)!.usingColorSpace(.sRGB)!
        return (Double(color.redComponent) + Double(color.greenComponent) + Double(color.blueComponent)) / 3
    }
}

private struct OpenSettingsCheckView: View {
    @Environment(\.openSettings) private var openSettings
    var body: some View {
        Text("Checking Settings appearance…")
            .task {
                DispatchQueue.main.asyncAfter(deadline: .now() + 10) {
                    FileHandle.standardError.write(Data("FAIL: Settings appearance check timed out\n".utf8))
                    exit(2)
                }
                NSApp.appearance = NSAppearance(named: .aqua)
                AppearancePreferences.shared.mode = .system
                try? await Task.sleep(for: .milliseconds(100))
                openSettings()
            }
    }
}
