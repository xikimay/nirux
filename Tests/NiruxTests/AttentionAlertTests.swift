import XCTest
@testable import Nirux

/// With a dozen agents at work, only what waits on the user or broke
/// reaches outside the app: a finished turn shows on its card.
@MainActor
final class AttentionAlertTests: XCTestCase {
    func testOnlyWaitsAndFailuresBounceAndNotify() {
        XCTAssertFalse(WorkspaceState.alertsOutsideTheApp(.turnFinished))
        let interrupting: [AgentAttentionReason?] = [
            .permission(tool: "Bash", summary: "git push"), .question("Which one?"),
            .apiError(kind: "rate_limit", detail: nil), .exitedMidTurn,
            nil // an agent without hooks fell silent: maybe its own prompt
        ]
        for reason in interrupting {
            XCTAssertTrue(WorkspaceState.alertsOutsideTheApp(reason), String(describing: reason))
        }
    }

    func testDockBadgeCountsWorkspacesThatWaitOrBroke() throws {
        let finished = WorkspaceState(title: "finished", cwd: NSTemporaryDirectory())
        let waiting = WorkspaceState(title: "waiting", cwd: NSTemporaryDirectory())
        let failed = WorkspaceState(title: "failed", cwd: NSTemporaryDirectory())
        _ = try XCTUnwrap(finished.columns.first?.pty).applyAgentHook(
            AgentHookEvent(kind: .claude, name: .stop, timestamp: 10), isUserFocused: false
        )
        finished.raiseNotification(.finished)
        _ = try XCTUnwrap(waiting.columns.first?.pty).applyAgentHook(
            AgentHookEvent(kind: .claude, name: .permissionRequest, toolName: "Bash", timestamp: 10), isUserFocused: false
        )
        failed.raiseNotification(.error)
        XCTAssertEqual(NiruxShellView.dockBadgeCount(workspaces: [finished, waiting, failed], missionQuestions: [:]), 2)
    }
}
