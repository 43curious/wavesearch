import SwiftUI

struct CLAPInstallationView: View {
    @EnvironmentObject private var store: AppStore
    @ObservedObject var installer: CLAPInstallationController
    @State private var showsTerms = false

    var body: some View {
        Section("Optional semantic search") {
            Text("CLAP adds local sound-description search. Download about 800 MB of model files plus ONNX Runtime; allow 1.5 GB of free disk space. The pinned runtime supports Apple silicon Macs. Lexical search works without it.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text(status).accessibilityLabel("Semantic installation: \(status)")
            if ProcessInfo.processInfo.environment["WS_CLAP_MODEL_DIR"] != nil || ProcessInfo.processInfo.environment["WS_ORT_LIBRARY"] != nil {
                Text("Custom semantic provider paths are configured. Installing the default pack does not change them.")
                    .foregroundStyle(.secondary)
            }
            if installer.phase == .working || installer.phase == .cancelling {
                if let expected = installer.progress.expected, expected > 0 {
                    ProgressView(value: Double(min(installer.progress.bytes, expected)), total: Double(expected))
                        .accessibilityLabel(installer.progress.detail)
                    Text("\(installer.progress.bytes.formatted(.byteCount(style: .file))) of \(expected.formatted(.byteCount(style: .file)))")
                        .font(.caption).monospacedDigit()
                } else { ProgressView().controlSize(.small) }
                Button("Cancel installation") { installer.cancel() }
                    .disabled(installer.phase == .cancelling)
            } else if installer.phase != .unsupported {
                Button(actionTitle) { showsTerms = true }
                    .disabled(installer.isBusy || !store.canUseLibrary)
                if installationFound {
                    Button("Retry semantic provider") { store.retrySemanticProvider() }
                        .disabled(!store.canUseLibrary)
                    Text(store.refinementSnapshot.semanticConfigured && store.refinementSnapshot.semanticAvailable ? "Semantic provider is loaded." : "Provider is not loaded. Background refinement policy controls when loading is allowed.")
                        .foregroundStyle(.secondary)
                    if let error = store.refinementSnapshot.semanticProviderError {
                        Text(error).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                }
            }
            Button("Show installation in Finder") {
                NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: installer.root.deletingLastPathComponent().path)
            }
        }
        .sheet(isPresented: $showsTerms) {
            VStack(alignment: .leading, spacing: 16) {
                Text("Download optional semantic search").font(.headline)
                Text("This explicitly downloads the pinned CLAP model from Hugging Face and ONNX Runtime 1.29.0 from Microsoft. Files are verified before activation. Cancelled downloads are discarded; repairs retain the previous bundle. No audio is uploaded.")
                Text("Review the model card and licensing terms before continuing. WaveSearch does not relicense model weights or their source datasets.")
                Link("Model card and terms", destination: URL(string: "https://huggingface.co/muzaiten/clap-htsat-base-onnx/tree/d4d4372c9894b975ec118589b4f4328103796e15")!)
                Link("LAION CLAP · Apache 2.0", destination: URL(string: "https://github.com/LAION-AI/CLAP")!)
                Link("ONNX Runtime · MIT and third-party notices", destination: URL(string: "https://github.com/microsoft/onnxruntime/releases/tag/v1.29.0")!)
                HStack {
                    Spacer()
                    Button("Cancel", role: .cancel) { showsTerms = false }
                        .keyboardShortcut(.cancelAction)
                    Button("Agree and download") { showsTerms = false; store.installSemanticModel() }
                        .keyboardShortcut(.defaultAction)
                }
            }
            .padding(24).frame(width: 500)
        }
    }

    private var installationFound: Bool { installer.phase == .present || installer.phase == .installed }
    private var actionTitle: String {
        if case .failed = installer.phase { return "Retry installation…" }
        return installationFound ? "Verify or repair installation…" : "Download semantic search…"
    }
    private var status: String {
        switch installer.phase {
        case .checking: "Checking installation…"
        case .absent: "Not installed. Downloads start only when you choose them."
        case .present: "Installation found. Verify or repair it if semantic loading fails."
        case .installed: "Model files verified. Provider loading checks runtime compatibility."
        case .working: installer.progress.detail
        case .cancelling: "Cancelling and cleaning up…"
        case .unsupported: "This pinned runtime is unavailable for Intel Macs. Lexical search remains available."
        case .failed(let error): error
        }
    }
}
