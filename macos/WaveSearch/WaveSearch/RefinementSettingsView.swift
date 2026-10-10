import SwiftUI
import AppKit

struct RefinementSettingsView: View {
    @EnvironmentObject private var store: AppStore
    @ObservedObject private var player = PlayerController.shared
    @AppStorage(AudioImportBehavior.preferenceKey) private var importBehavior: AudioImportBehavior = .keepInPlace

    private var modeBinding: Binding<RefinementMode> {
        Binding(get: { store.refinementMode }, set: { store.setRefinementMode($0) })
    }

    var body: some View {
        Form {
            Section("Importing into editors") {
                Picker("Files", selection: $importBehavior) {
                    ForEach(AudioImportBehavior.allCases) { behavior in
                        Text(behavior.title).tag(behavior)
                    }
                }
                .pickerStyle(.radioGroup)
                Text(importBehavior == .keepInPlace
                     ? "Import the original file from its library location. Selected ranges import the full file; trim it in your editor. Your editor can manage its own copies."
                     : "Copy whole files to WaveSearch’s Exports folder. Selected ranges create trimmed WAV files there. Originals stay in their library locations.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if importBehavior == .copyToExports {
                    Button("Show Exports in Finder") {
                        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: AudioClipStorage.directory.path)
                    }
                }
            }
            Section("Audio preview") {
                HStack {
                    Text("Preview volume")
                    Slider(value: Binding(get: { player.volume }, set: { player.setVolume($0) }), in: 0...1)
                    Text(player.volume, format: .percent.precision(.fractionLength(0)))
                        .monospacedDigit().frame(width: 45, alignment: .trailing)
                }
            }
            Section("Background refinement") {
                Picker("Mode", selection: modeBinding) {
                    ForEach(RefinementMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.radioGroup)

                Text(store.refinementMode.summary)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if store.refinementMode == .fastOnly {
                    Label(
                        "Selected sounds still generate exact waveforms and loudness analysis on demand.",
                        systemImage: "waveform"
                    )
                    .foregroundStyle(.secondary)
                } else if store.isRefinementPaused {
                    Button("Resume refinement") { store.resumeBackgroundRefinement() }
                } else {
                    Button("Pause refinement") { store.pauseBackgroundRefinement() }
                }
            }
        }
        .formStyle(.grouped)
        .padding(12)
    }
}
