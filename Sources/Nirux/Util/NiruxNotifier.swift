import AppKit
import UserNotifications

/// Native macOS notifications for agent attention events, plus the Dock
/// badge count. In-app visuals (pulses, glows) cover the case where the
/// user is looking at Nirux; this covers the case where they aren't.
///
/// Clicking a notification routes back through `onActivate` so the shell
/// can focus the exact workspace and column that asked for attention.
@MainActor
final class NiruxNotifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NiruxNotifier()

    /// (workspaceID, columnIndex?) — set by the app delegate at launch.
    var onActivate: ((String, Int?) -> Void)?

    /// UNUserNotificationCenter requires a signed bundle with an identifier;
    /// `swift run` debug binaries have neither and would raise.
    private var isAvailable: Bool {
        Bundle.main.bundleIdentifier != nil
    }

    func setup() {
        guard isAvailable else { return }
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { _, error in
            if let error {
                NSLog("[NiruxNotifier] authorization error: \(error.localizedDescription)")
            }
        }
    }

    /// Post a system notification for an agent event. Suppressed while the
    /// app is active — in-app visuals already cover that case.
    func postAgentAttention(workspaceID: String, workspaceTitle: String, columnIndex: Int?, processName: String) {
        guard isAvailable, !NSApp.isActive else { return }
        let content = UNMutableNotificationContent()
        content.title = "\(processName) needs you"
        content.body = workspaceTitle
        content.sound = .default
        var info: [String: Any] = ["workspaceID": workspaceID]
        if let columnIndex { info["columnIndex"] = columnIndex }
        content.userInfo = info
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                NSLog("[NiruxNotifier] post failed: \(error.localizedDescription)")
            }
        }
    }

    /// Dock tile badge: number of workspaces waiting for attention.
    func updateDockBadge(attentionCount: Int) {
        NSApp.dockTile.badgeLabel = attentionCount > 0 ? String(attentionCount) : nil
    }

    /// Drop delivered notifications once the user is back — stale banners
    /// for already-seen workspaces are noise.
    func clearDelivered() {
        guard isAvailable else { return }
        UNUserNotificationCenter.current().removeAllDeliveredNotifications()
    }

    // MARK: - UNUserNotificationCenterDelegate

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let info = response.notification.request.content.userInfo
        let workspaceID = info["workspaceID"] as? String
        let columnIndex = info["columnIndex"] as? Int
        // Answer synchronously — sending the closure into the MainActor task
        // below would risk a data race.
        completionHandler()
        Task { @MainActor in
            NSApp.activate(ignoringOtherApps: true)
            if let workspaceID {
                self.onActivate?(workspaceID, columnIndex)
            }
        }
    }

    /// Never show banners while frontmost — the in-app pulses cover it.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([])
    }
}
