import XCTest
@testable import Nirux

/// The prompts Nirux types into an agent for the user (PR Feedback's
/// Address, "Ask Agent Why CI Failed"): what is typed, and the dialog that
/// holds one back.
final class TypedPromptTests: XCTestCase {
    /// The gate's source of truth: a PermissionRequest leaves a pending
    /// dialog on the column's PTY until hooks prove it closed.
    func testPtyKeepsPendingDialogUntilItsCallRuns() {
        let pty = PtySession()
        let request = AgentHookEvent(
            kind: .claude, name: .permissionRequest, toolName: "Bash", toolSummary: "make", toolKey: "k", timestamp: 1
        )
        _ = pty.applyAgentHook(request, isUserFocused: true)
        XCTAssertEqual(pty.pendingAgentDialog?.reason, .permission(tool: "Bash", summary: "make"))
        _ = pty.applyAgentHook(
            AgentHookEvent(kind: .claude, name: .preToolUse, toolName: "Read", timestamp: 2), isUserFocused: true
        )
        XCTAssertNotNil(pty.pendingAgentDialog, "another call starting proves nothing")
        _ = pty.applyAgentHook(
            AgentHookEvent(kind: .claude, name: .postToolUse, toolName: "Bash", toolKey: "k", timestamp: 3),
            isUserFocused: true
        )
        XCTAssertNil(pty.pendingAgentDialog)
    }

    func testPromptSanitizerDropsTerminalControlBytesAndFramesPaste() {
        let input = "  explain\u{1B}[31m this\u{0}\r\ncarefully  "
        XCTAssertEqual(TypedPromptSanitizer.sanitize(input), "explain[31m this\ncarefully")
        let framed = TypedPromptSanitizer.terminalInput(for: input)
        XCTAssertEqual(framed, "\u{1B}[200~explain[31m this\ncarefully\u{1B}[201~\r")
        XCTAssertNil(TypedPromptSanitizer.terminalInput(for: "\u{1B}\u{0}"))
    }
}
