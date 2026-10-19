import AppKit

@MainActor
final class AppLifecycleDelegate: NSObject, NSApplicationDelegate {
    weak var store: AppStore?
    private var terminating = false

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Library tabs belong to WaveSearch; native window tabs add unrelated
        // Show Tab Bar / Show All Tabs commands to the menu bar.
        NSWindow.allowsAutomaticWindowTabbing = false
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // Keep the registered search shortcut available to reopen the window.
        false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        GlobalSearchShortcut.shared.stop()
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
