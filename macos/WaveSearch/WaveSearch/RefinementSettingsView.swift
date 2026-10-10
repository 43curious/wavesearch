import SwiftUI

struct RefinementSettingsView: View {
    @EnvironmentObject private var store: AppStore
    @ObservedObject private var player = PlayerController.shared

    private var modeBinding: Binding<RefinementMode> {
        Binding(get: { store.refinementMode }, set: { store.setRefinementMode($0) })
    }

    var body: some View {
        Form {
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
