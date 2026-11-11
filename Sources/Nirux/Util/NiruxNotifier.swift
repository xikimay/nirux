import AppKit
import UserNotifications

/// Native macOS notifications for agent attention events, plus the Dock
/// badge count. In-app visuals (pulses, glows) cover the case where the
/// user is looking at Nirux; this covers the case where they aren't.
///
/// Clicking a notification routes back through `onActivate` so the shell
/// can focus the exact workspace and column that asked for attention; a CI
/// failure's buttons route through `onCIFailureAction`.
@MainActor
final class NiruxNotifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NiruxNotifier()

    /// (workspaceID, columnIndex?) — set by the app delegate at launch.
    var onActivate: ((String, Int?) -> Void)?
    /// (workspaceID, action): a button of a CI failure notification.
    var onCIFailureAction: ((String, CIFailureAction) -> Void)?
    /// A reply typed in a turn question's notification: where it goes,
    /// its text, and the workspace and column to show when it can't go.
    var onQuickReply: ((QuickReplyTarget, String, String, Int?) -> Void)?

    /// The turn end a notification's Reply answers: that agent's, then.
    struct QuickReplyTarget: Equatable {
        let agentUUID: String
        let turnEndedAt: TimeInterval

        var userInfo: [String: Any] { ["agentUUID": agentUUID, "turnEndedAt": turnEndedAt] }

        init(agentUUID: String, turnEndedAt: TimeInterval) {
            self.agentUUID = agentUUID
            self.turnEndedAt = turnEndedAt
        }

        init?(userInfo: [AnyHashable: Any]) {
            guard let agentUUID = userInfo["agentUUID"] as? String,
                  let turnEndedAt = userInfo["turnEndedAt"] as? TimeInterval else { return nil }
            self.init(agentUUID: agentUUID, turnEndedAt: turnEndedAt)
        }
    }

    /// The buttons of a CI failure notification (docs/design/ci-failure-actions.md).
    enum CIFailureAction: String {
        case whyFailed, rerunFailed
    }

    private static let ciFailureCategory = "ciFailure"
    /// A turn that asks something: Reply…, typed into that agent. Not Yes
    /// or No: a banner comes while the user does something else, and a
    /// "yes" can start a merge or a push (those wait on the card, next to
    /// the question).
    private static let turnQuestionCategory = "turnQuestion"
    nonisolated private static let quickReplyAction = "turnQuestionReply"
    /// A failure that looks flaky: the rerun comes first.
    private static let flakyCIFailureCategory = "ciFailureFlaky"

    /// UNUserNotificationCenter requires a signed bundle with an identifier;
    /// `swift run` debug binaries have neither and would raise.
    private var isAvailable: Bool {
        Bundle.main.bundleIdentifier != nil
    }

    func setup() {
        guard isAvailable else { return }
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        // Foreground: both actions act in the app, and a rerun asks first.
        let whyFailed = UNNotificationAction(identifier: CIFailureAction.whyFailed.rawValue, title: "Ask Agent Why CI Failed",
                                             options: [.foreground])
        let rerunFailed = UNNotificationAction(identifier: CIFailureAction.rerunFailed.rawValue, title: "Rerun Failed CI Jobs…",
                                               options: [.foreground])
        // A locked Mac asks for an unlock before a reply goes anywhere.
        let reply = UNTextInputNotificationAction(
            identifier: Self.quickReplyAction, title: "Reply…", options: [.authenticationRequired],
            textInputButtonTitle: "Send", textInputPlaceholder: "Your answer"
        )
        center.setNotificationCategories([
            UNNotificationCategory(identifier: Self.turnQuestionCategory, actions: [reply], intentIdentifiers: []),
            UNNotificationCategory(identifier: Self.ciFailureCategory, actions: [whyFailed, rerunFailed], intentIdentifiers: []),
            UNNotificationCategory(identifier: Self.flakyCIFailureCategory, actions: [rerunFailed, whyFailed], intentIdentifiers: [])
        ])
        // @Sendable keeps the closure nonisolated: UNUserNotificationCenter
        // invokes it on a background queue, and a MainActor-inferred closure
        // would trap the runtime isolation check there.
        center.requestAuthorization(options: [.alert, .sound]) { @Sendable _, error in
            if let error {
                NSLog("[NiruxNotifier] authorization error: \(error.localizedDescription)")
            }
        }
    }

    struct AttentionText: Equatable {
        let title: String
        let subtitle: String
        let body: String
    }

    /// "claude needs permission" / workspace / "Bash: git push origin main".
    /// Every agent-provided part is cleaned (no control characters) and
    /// bounded; without specifics the workspace title is the body.
    nonisolated static func attentionText(
        processName: String,
        workspaceTitle: String,
        reason: AgentAttentionReason?
    ) -> AttentionText {
        let name = AgentText.clean(processName, maxLength: 60) ?? "Agent"
        let headline = reason?.headline ?? "needs you"
        guard let detail = reason?.detailLine.flatMap({ AgentText.clean($0, maxLength: 200) }) else {
            return AttentionText(title: "\(name) \(headline)", subtitle: "", body: workspaceTitle)
        }
        return AttentionText(title: "\(name) \(headline)", subtitle: workspaceTitle, body: detail)
    }

    /// Post a system notification for an agent event. Suppressed while the
    /// app is active — in-app visuals already cover that case.
    func postAgentAttention(
        workspaceID: String,
        workspaceTitle: String,
        columnIndex: Int?,
        processName: String,
        reason: AgentAttentionReason?,
        quickReply: QuickReplyTarget? = nil
    ) {
        guard !NSApp.isActive else { return }
        let text = Self.attentionText(processName: processName, workspaceTitle: workspaceTitle, reason: reason)
        let content = UNMutableNotificationContent()
        content.title = text.title
        content.subtitle = text.subtitle
        content.body = text.body
        content.sound = .default
        var info: [String: Any] = ["workspaceID": workspaceID]
        if let columnIndex { info["columnIndex"] = columnIndex }
        if let quickReply {
            content.categoryIdentifier = Self.turnQuestionCategory
            info.merge(quickReply.userInfo) { current, _ in current }
        }
        content.userInfo = info
        post(content)
    }

    /// A Mission child's question that came to the user, or its completion.
    /// The child's card is the durable surface; this banner covers the user
    /// being in another app.
    func postMissionEvent(
        workspaceID: String,
        workspaceTitle: String,
        columnIndex: Int?,
        kind: MissionEvent.Kind,
        message: String
    ) {
        guard !NSApp.isActive else { return }
        let content = UNMutableNotificationContent()
        switch kind {
        case .question: content.title = "Mission needs input"
        case .completed: content.title = "Mission completed"
        case .response, .instruction, .acknowledged: return
        }
        content.subtitle = workspaceTitle
        content.body = message
        content.sound = .default
        var info: [String: Any] = ["workspaceID": workspaceID]
        if let columnIndex { info["columnIndex"] = columnIndex }
        content.userInfo = info
        post(content)
    }

    /// "CI failed" / workspace / "#52: test, lint". Check names come from
    /// GitHub: cleaned and bounded like an agent's text.
    func postCIFailure(
        workspaceID: String, workspaceTitle: String, pullRequest: Int, checkNames: [String], flakyReason: String? = nil
    ) {
        guard !NSApp.isActive else { return }
        let text = Self.ciFailureText(pullRequest: pullRequest, checkNames: checkNames, flakyReason: flakyReason)
        let content = UNMutableNotificationContent()
        content.title = text.title
        content.subtitle = workspaceTitle
        content.body = text.body
        content.sound = .default
        content.categoryIdentifier = flakyReason == nil ? Self.ciFailureCategory : Self.flakyCIFailureCategory
        content.userInfo = ["workspaceID": workspaceID]
        post(content)
    }

    /// "CI failed" and "#52: test, lint"; for a failure that looks flaky
    /// (docs/design/ci-failure-triage.md), "CI failed · likely flaky" and the
    /// reason on a line of its own. The reason is cleaned again here: it
    /// may be a model's sentence about a log.
    nonisolated static func ciFailureText(pullRequest: Int, checkNames: [String], flakyReason: String?) -> (title: String, body: String) {
        let checks = AgentText.clean("#\(pullRequest): " + checkNames.joined(separator: ", "), maxLength: 200) ?? ""
        guard let reason = flakyReason.flatMap({ AgentText.clean($0, maxLength: CITriage.reasonLength) }) else {
            return ("CI failed", checks)
        }
        return ("CI failed · likely flaky", checks + "\n" + reason)
    }

    /// "Setup script failed" / workspace: a new worktree's setup script
    /// failed (SpaceSetupScript). Clicking focuses its terminal.
    func postSetupFailure(workspaceID: String, workspaceTitle: String) {
        guard !NSApp.isActive else { return }
        let content = UNMutableNotificationContent()
        content.title = "Setup script failed"
        content.subtitle = workspaceTitle
        content.body = "The agent started anyway: its terminal shows what failed."
        content.sound = .default
        content.userInfo = ["workspaceID": workspaceID, "columnIndex": 0]
        post(content)
    }

    /// Post a "download finished" notification; clicking reveals the file
    /// in Finder. Suppressed while the app is active.
    func postDownloadFinished(filename: String, fileURL: URL) {
        guard !NSApp.isActive else { return }
        let content = UNMutableNotificationContent()
        content.title = "Download finished"
        content.body = filename
        content.userInfo = ["filePath": fileURL.path]
        post(content)
    }

    private func post(_ content: UNMutableNotificationContent) {
        guard isAvailable else { return }
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        // Same background-queue callback as requestAuthorization above.
        UNUserNotificationCenter.current().add(request) { @Sendable error in
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
        let filePath = info["filePath"] as? String
        let ciFailureAction = CIFailureAction(rawValue: response.actionIdentifier)
        let quickReply = response.actionIdentifier == Self.quickReplyAction
            ? (response as? UNTextInputNotificationResponse)?.userText : nil
        let quickReplyTarget = QuickReplyTarget(userInfo: info)
        // Answer synchronously — sending the closure into the MainActor task
        // below would risk a data race.
        completionHandler()
        Task { @MainActor in
            // Download notifications reveal the file instead of focusing a
            // workspace.
            if let filePath {
                NSWorkspace.shared.selectFile(filePath, inFileViewerRootedAtPath: "")
                return
            }
            // A reply goes in without bringing Nirux forward (the handler
            // does when it can't).
            if let quickReply, let quickReplyTarget, let workspaceID {
                self.onQuickReply?(quickReplyTarget, quickReply, workspaceID, columnIndex)
                return
            }
            NSApp.activate(ignoringOtherApps: true)
            if let workspaceID, let ciFailureAction {
                self.onCIFailureAction?(workspaceID, ciFailureAction)
            } else if let workspaceID {
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
