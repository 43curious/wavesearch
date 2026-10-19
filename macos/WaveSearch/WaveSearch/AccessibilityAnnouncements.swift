import AppKit

/// Announce completed actions and phase changes, without speaking every progress tick.
func announceAccessibility(_ message: String) {
    NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested, userInfo: [
        .announcement: message,
        .priority: NSAccessibilityPriorityLevel.low.rawValue,
    ])
}
