import XCTest
@testable import Nirux

/// The prompts Nirux types into an agent for the user (PR Feedback's
/// Address, "Ask Agent Why CI Failed"): which terminals take one, what is
/// typed, and the dialog that holds one back.
final class RemotePromptTests: XCTestCase {
    @MainActor
    func testPtyRemotePromptGateRechecksLiveForegroundProcess() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("nirux-remote-prompt-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let agentSession = PtySession()
        let idleShellSession = PtySession()
        agentSession.start(
            shell: "/bin/zsh",
            args: ["-f", "-c", "exec -a codex /bin/cat"],
            cwd: directory.path
        )
        idleShellSession.start(shell: "/bin/zsh", args: ["-f"], cwd: directory.path)

        let processesReady = try await waitUntil {
            let snapshot = ProcessSnapshot()
            return agentSession.acceptsRemotePrompts(snapshot: snapshot)
                && !idleShellSession.acceptsRemotePrompts(snapshot: snapshot)
        }
        XCTAssertTrue(processesReady)

        let terminalInput = try XCTUnwrap(RemotePromptSanitizer.terminalInput(for: "remote prompt verified"))
        agentSession.sendRaw(terminalInput)
        let delivered = try await waitUntil {
            agentSession.recentOutput().contains("remote prompt verified")
        }
        XCTAssertTrue(delivered)
    }

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
        XCTAssertEqual(RemotePromptSanitizer.sanitize(input), "explain[31m this\ncarefully")
        let framed = RemotePromptSanitizer.terminalInput(for: input)
        XCTAssertEqual(framed, "\u{1B}[200~explain[31m this\ncarefully\u{1B}[201~\r")
        XCTAssertNil(RemotePromptSanitizer.terminalInput(for: "\u{1B}\u{0}"))
    }

    func testTerminalPlainTextStripsCSIAndOSCSequences() {
        let raw = Data("\u{1B}[31mred\u{1B}[0m\r\nnext\u{1B}]0;secret title\u{07}\nvisible".utf8)
        let rendered = TerminalPlainText.render(raw)
        XCTAssertEqual(rendered, "red\nnext\nvisible")
        XCTAssertFalse(rendered.contains("secret title"))
    }

    func testTerminalOutputBufferKeepsRequestedLineTail() {
        let buffer = TerminalOutputBuffer(maxBytes: 1_024)
        buffer.append(Data("one\ntwo\nthree".utf8))
        XCTAssertEqual(buffer.tail(maxLines: 2), "two\nthree")
    }

    @MainActor
    private func waitUntil(
        timeout: TimeInterval = 10,
        condition: @escaping () -> Bool
    ) async throws -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() >= deadline {
                return false
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        return true
    }
}
