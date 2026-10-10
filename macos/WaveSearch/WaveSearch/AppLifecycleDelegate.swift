import AppKit

@MainActor
final class AppLifecycleDelegate: NSObject, NSApplicationDelegate {
    weak var store: AppStore?
    private var terminating = false

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let store else { return .terminateNow }
        guard !terminating else { return .terminateLater }
        terminating = true
        Task {
            // Keep the process and store alive while workers unwind. Never block
            // AppKit's main thread waiting for SQLite, storage, or ONNX teardown.
            await store.shutdown()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
