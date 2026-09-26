import XCTest
@testable import Nirux

/// Claude columns restore their own session (see ClaudeSessionTracker).
final class ClaudeRestoreTests: XCTestCase {
    @MainActor
    func testClaudeRestoreCommandsNeverContinueTheLastSession() {
        let exact = NiruxShellView.claudeCommand(
            resume: .session("5f0c8a52-6a0e-4d7c-9f0e-2b1f6d1c9a11"),
            mode: .skipPermissions
        )
        let picker = NiruxShellView.claudeCommand(resume: .picker, mode: .acceptEdits)
        let fresh = NiruxShellView.claudeCommand(mode: .default)

        XCTAssertEqual(
            exact,
            "command claude --resume '5f0c8a52-6a0e-4d7c-9f0e-2b1f6d1c9a11' --dangerously-skip-permissions"
        )
        XCTAssertEqual(picker, "command claude --resume --permission-mode acceptEdits")
        XCTAssertEqual(fresh, "command claude")
        for command in [exact, picker, fresh] {
            XCTAssertFalse(command.contains("--continue"))
        }
    }

    func testClaudeSessionIDRoundTripsAndLegacyColumnsOmitIt() throws {
        let column = PersistedColumn(
            widthPreset: 0.5, cwd: "/tmp/project",
            columnType: .claudeCode, webViewURL: nil,
            claudeLaunchMode: .auto, codexLaunchMode: nil,
            claudeSessionID: "5f0c8a52-6a0e-4d7c-9f0e-2b1f6d1c9a11"
        )
        let decoded = try JSONDecoder().decode(
            PersistedColumn.self,
            from: JSONEncoder().encode(column)
        )
        XCTAssertEqual(decoded.claudeSessionID, "5f0c8a52-6a0e-4d7c-9f0e-2b1f6d1c9a11")
        XCTAssertNil(decoded.claudeSessionIsUnprompted)
        XCTAssertNil(decoded.codexSessionID)

        let unprompted = PersistedColumn(
            widthPreset: 0.5, cwd: "/tmp/project",
            columnType: .claudeCode, webViewURL: nil,
            claudeLaunchMode: nil, codexLaunchMode: nil,
            claudeSessionIsUnprompted: true
        )
        let decodedUnprompted = try JSONDecoder().decode(PersistedColumn.self, from: JSONEncoder().encode(unprompted))
        XCTAssertEqual(decodedUnprompted.claudeSessionIsUnprompted, true)
        XCTAssertNil(decodedUnprompted.claudeSessionID)

        let legacy = try JSONDecoder().decode(
            PersistedColumn.self,
            from: Data(#"{"widthPreset":0.5,"cwd":"/tmp/project","columnType":"claudeCode","claudeLaunchMode":"plan"}"#.utf8)
        )
        XCTAssertEqual(legacy.resolvedType, .claudeCode)
        XCTAssertEqual(legacy.claudeLaunchMode, .plan)
        XCTAssertNil(legacy.claudeSessionID)
        XCTAssertNil(legacy.claudeSessionIsUnprompted)
    }

    @MainActor
    func testAgentColumnsResumeInTheirOwnDirectoryWhileItExists() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("nirux-restore-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("file")
        try Data().write(to: file)

        XCTAssertEqual(NiruxShellView.existingDirectory(directory.path), directory.path)
        XCTAssertNil(NiruxShellView.existingDirectory(file.path))
        XCTAssertNil(NiruxShellView.existingDirectory(directory.appendingPathComponent("gone").path))
    }

    @MainActor
    func testRestoredAgentStateIsKeptOnlyWhileItsLaunchCommandRuns() {
        let launchShell = ForegroundProcess(
            instance: ProcessInstance(pid: 50, startedAt: 50),
            name: "zsh",
            arguments: ["zsh", "-i", "-l", "-c", "command claude --resume 'x'; exec zsh -i -l"]
        )
        let afterExit = ForegroundProcess(
            instance: ProcessInstance(pid: 50, startedAt: 50),
            name: "zsh",
            arguments: ["zsh", "-i", "-l"]
        )
        let agent = ForegroundProcess(
            instance: ProcessInstance(pid: 51, startedAt: 51),
            name: "claude",
            arguments: ["claude", "--resume", "x"]
        )

        XCTAssertTrue(NiruxShellView.isLaunchingRestoredAgent(foreground: nil, shellPID: 0, hasExited: false))
        XCTAssertTrue(NiruxShellView.isLaunchingRestoredAgent(foreground: launchShell, shellPID: 50, hasExited: false))
        XCTAssertFalse(NiruxShellView.isLaunchingRestoredAgent(foreground: agent, shellPID: 50, hasExited: false))
        XCTAssertFalse(NiruxShellView.isLaunchingRestoredAgent(foreground: afterExit, shellPID: 50, hasExited: false))
        XCTAssertFalse(NiruxShellView.isLaunchingRestoredAgent(foreground: nil, shellPID: 0, hasExited: true))
    }

    @MainActor
    func testUnpromptedClaudeSessionRestoresFresh() {
        var claimed = Set<String>()
        let session = "5f0c8a52-6a0e-4d7c-9f0e-2b1f6d1c9a11"

        let fresh = NiruxShellView.claudeRestoreTarget(
            sessionID: nil, sessionIsUnprompted: true, claimedSessionIDs: &claimed
        )
        XCTAssertNil(fresh)
        XCTAssertEqual(NiruxShellView.claudeCommand(resume: fresh, mode: .auto), "command claude --permission-mode auto")
        XCTAssertEqual(
            NiruxShellView.claudeRestoreTarget(sessionID: session, sessionIsUnprompted: false, claimedSessionIDs: &claimed),
            .session(session)
        )
        XCTAssertEqual(
            NiruxShellView.claudeRestoreTarget(sessionID: nil, sessionIsUnprompted: false, claimedSessionIDs: &claimed),
            .picker
        )
    }

    @MainActor
    func testLegacyAndDuplicateClaudeColumnsRestoreThroughThePicker() {
        var claimed = Set<String>()
        let session = "5f0c8a52-6a0e-4d7c-9f0e-2b1f6d1c9a11"

        let first = NiruxShellView.agentRestoreTarget(sessionID: session, claimedSessionIDs: &claimed)
        let duplicate = NiruxShellView.agentRestoreTarget(sessionID: session, claimedSessionIDs: &claimed)
        let legacy = NiruxShellView.agentRestoreTarget(sessionID: nil, claimedSessionIDs: &claimed)

        XCTAssertEqual(first, .session(session))
        XCTAssertEqual(
            NiruxShellView.claudeCommand(resume: duplicate, mode: .default),
            "command claude --resume"
        )
        XCTAssertEqual(
            NiruxShellView.claudeCommand(resume: legacy, mode: .plan),
            "command claude --resume --permission-mode plan"
        )
    }

    @MainActor
    func testMalformedSessionIDsNeverReachTheCommandLine() {
        var claimed = Set<String>()
        for sessionID in ["--dangerously-skip-permissions", "thread-a", "-r"] {
            XCTAssertEqual(
                NiruxShellView.agentRestoreTarget(sessionID: sessionID, claimedSessionIDs: &claimed),
                .picker,
                sessionID
            )
        }
        XCTAssertTrue(claimed.isEmpty)
    }
}
