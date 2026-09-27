import XCTest
@testable import Nirux

/// Which agents the close confirmation sees: anything that dies with the
/// PTY, not just the foreground process the status machine tracks.
final class CloseAgentDetectionTests: XCTestCase {
    private let isAgent = AgentStatusMachine.isRecognizedAgentProcess

    private func entry(
        _ pid: pid_t, parent: pid_t, group: pid_t, foreground: pid_t = 10,
        name: String, _ arguments: [String]
    ) -> ProcessSnapshot.Entry {
        .init(
            pid: pid, parentPID: parent, processGroupID: group,
            terminalForegroundProcessGroupID: foreground,
            name: name, startedAt: TimeInterval(pid), arguments: arguments
        )
    }

    func testSuspendedAgentIsFoundBehindTheShell() {
        // ^Z: the shell is back in the foreground, the stopped claude job
        // still dies with the PTY.
        let snapshot = ProcessSnapshot(entries: [
            entry(10, parent: 1, group: 10, name: "zsh", ["zsh"]),
            entry(20, parent: 10, group: 20, name: "2.1.283", ["claude", "--continue"])
        ])
        XCTAssertEqual(snapshot.foregroundProcess(shellPID: 10)?.name, "zsh")
        XCTAssertEqual(snapshot.firstDescendantName(of: 10, where: isAgent), "claude")
    }

    func testAgentUnderAWrapperIsFound() {
        let snapshot = ProcessSnapshot(entries: [
            entry(10, parent: 1, group: 10, foreground: 20, name: "zsh", ["zsh"]),
            entry(20, parent: 10, group: 20, foreground: 20, name: "caffeinate", ["caffeinate", "-i", "claude"]),
            entry(30, parent: 20, group: 20, foreground: 20, name: "2.1.283", ["claude"])
        ])
        XCTAssertEqual(snapshot.foregroundProcess(shellPID: 10)?.name, "caffeinate")
        XCTAssertEqual(snapshot.firstDescendantName(of: 10, where: isAgent), "claude")
    }

    func testNodeWrappedCodexIsFound() {
        let snapshot = ProcessSnapshot(entries: [
            entry(10, parent: 1, group: 10, name: "zsh", ["zsh"]),
            entry(20, parent: 10, group: 20, name: "npx", ["npx", "codex"]),
            entry(30, parent: 20, group: 20, name: "node", ["node", "/usr/local/lib/node_modules/.bin/codex"])
        ])
        XCTAssertEqual(snapshot.firstDescendantName(of: 10, where: isAgent), "codex")
    }

    func testShellWithoutAgentFindsNothing() {
        let snapshot = ProcessSnapshot(entries: [
            entry(10, parent: 1, group: 10, name: "zsh", ["zsh"]),
            entry(20, parent: 10, group: 20, name: "vim", ["vim", "claude.md"]),
            entry(30, parent: 1, group: 30, name: "2.1.283", ["claude"]) // another terminal's agent
        ])
        XCTAssertNil(snapshot.firstDescendantName(of: 10, where: isAgent))
        XCTAssertFalse(snapshot.isEmpty)
        XCTAssertTrue(ProcessSnapshot(entries: []).isEmpty)
    }

    func testShellJobsAreCheckedBeforeADeepForegroundTree() {
        // A suspended claude next to a big build: breadth-first reaches it
        // before the build's workers use up the budget.
        var entries = [
            entry(10, parent: 1, group: 10, name: "zsh", ["zsh"]),
            entry(20, parent: 10, group: 20, name: "2.1.283", ["claude"]),
            entry(30, parent: 10, group: 30, name: "make", ["make", "-j"])
        ]
        for pid in pid_t(100)..<120 {
            entries.append(entry(pid, parent: 30, group: 30, name: "cc", ["cc"]))
        }
        let snapshot = ProcessSnapshot(entries: entries)
        XCTAssertEqual(snapshot.firstDescendantName(of: 10, limit: 5, where: isAgent), "claude")
    }

    // MARK: - Real PTY

    /// Runs `body` with NIRUX_STATE_DIR pointed at a scratch directory,
    /// like every test that starts a real shell.
    @MainActor
    private func withScratchStateDirectory(_ body: (String) async throws -> Void) async throws {
        let stateDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("nirux-close-agent-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: stateDirectory, withIntermediateDirectories: true)
        let previousStateDirectory = ProcessInfo.processInfo.environment["NIRUX_STATE_DIR"]
        setenv("NIRUX_STATE_DIR", stateDirectory.path, 1)
        defer {
            if let previousStateDirectory {
                setenv("NIRUX_STATE_DIR", previousStateDirectory, 1)
            } else {
                unsetenv("NIRUX_STATE_DIR")
            }
            try? FileManager.default.removeItem(at: stateDirectory)
        }
        try await body(stateDirectory.path)
    }

    @MainActor
    func testPtyReportsForegroundAndBackgroundAgentsButNotABareShell() async throws {
        try await withScratchStateDirectory { cwd in
            try await assertAgentsReported(cwd: cwd)
        }
    }

    @MainActor
    private func assertAgentsReported(cwd: String) async throws {
        let foregroundAgent = PtySession()
        let backgroundAgent = PtySession()
        let bareShell = PtySession()
        foregroundAgent.start(shell: "/bin/zsh", args: ["-f", "-c", "exec -a claude /bin/cat"], cwd: cwd)
        // No job control under -c: the shell stays the foreground process,
        // the agent only shows up as its descendant.
        backgroundAgent.start(
            shell: "/bin/zsh",
            args: ["-f", "-c", "(exec -a codex /bin/sleep 30) & wait"],
            cwd: cwd
        )
        bareShell.start(shell: "/bin/zsh", args: ["-f"], cwd: cwd)

        var names: [String?] = []
        let deadline = Date().addingTimeInterval(3)
        repeat {
            let snapshot = ProcessSnapshot()
            names = [foregroundAgent, backgroundAgent, bareShell].map { $0.agentProcessName(snapshot: snapshot) }
            if names == ["claude", "codex", nil] { break }
            try await Task.sleep(for: .milliseconds(20))
        } while Date() < deadline
        XCTAssertEqual(names, ["claude", "codex", nil])
        // The background agent came from the descendant scan, not the foreground.
        XCTAssertEqual(backgroundAgent.foregroundProcessName(snapshot: ProcessSnapshot()), "zsh")
    }

    /// Gemini CLI runs as `node --no-warnings=… …/gemini`: the live argv
    /// read must reach past the runtime flags, in the foreground and in the
    /// descendant scan. (`bash --norc` stands in for node's flags; `exec -a`
    /// sets argv[0].) Recognized for close, yet never a remote-prompt target.
    @MainActor
    func testFlaggedRuntimeLaunchOfGeminiIsProtectedButNotRemote() async throws {
        try await withScratchStateDirectory { cwd in
            let script = (cwd as NSString).appendingPathComponent("gemini")
            try "sleep 30; :\n".write(toFile: script, atomically: true, encoding: .utf8)
            let foreground = PtySession()
            let background = PtySession()
            let claude = PtySession()
            foreground.start(shell: "/bin/zsh", args: ["-f", "-c", "exec -a node /bin/bash --norc gemini"], cwd: cwd)
            background.start(
                shell: "/bin/zsh",
                args: ["-f", "-c", "(exec -a node /bin/bash --norc gemini) & wait"],
                cwd: cwd
            )
            claude.start(shell: "/bin/zsh", args: ["-f", "-c", "exec -a claude /bin/cat"], cwd: cwd)

            let expected: [String?] = ["gemini", "gemini", "claude"]
            var names: [String?] = []
            let deadline = Date().addingTimeInterval(3)
            repeat {
                let snapshot = ProcessSnapshot()
                names = [foreground, background, claude].map { $0.agentProcessName(snapshot: snapshot) }
                if names == expected { break }
                try await Task.sleep(for: .milliseconds(20))
            } while Date() < deadline
            XCTAssertEqual(names, expected)
            let snapshot = ProcessSnapshot()
            XCTAssertEqual(foreground.foregroundProcessName(snapshot: snapshot), "gemini")
            XCTAssertFalse(foreground.acceptsRemotePrompts(snapshot: snapshot))
            XCTAssertTrue(claude.acceptsRemotePrompts(snapshot: snapshot))
        }
    }

    @MainActor
    func testEmptySnapshotFallsBackToTheHeartbeatsView() async throws {
        try await withScratchStateDirectory { cwd in
            let session = PtySession()
            session.start(shell: "/bin/zsh", args: ["-f"], cwd: cwd)
            let emptySnapshot = ProcessSnapshot(entries: [])
            // Nothing seen yet: nothing to fall back on.
            XCTAssertNil(session.agentProcessName(snapshot: emptySnapshot))

            // The last heartbeat saw claude in the foreground; then the
            // process-table sysctl fails — fail closed.
            _ = session.agentStatus(
                foregroundProcess: ForegroundProcess(
                    instance: ProcessInstance(pid: 99_999, startedAt: 0), name: "claude", arguments: ["claude"]
                ),
                isUserFocused: true
            )
            XCTAssertEqual(session.agentProcessName(snapshot: emptySnapshot), "claude")
            // A snapshot that captured the table wins: the shell runs no agent.
            XCTAssertNil(session.agentProcessName(snapshot: ProcessSnapshot()))
        }
    }
}
