import AppKit
import XCTest
@testable import Nirux

/// A Claude turn that waits on the model with no sign of life (#55's fourth
/// stuck state): a request that hangs without an error, its row reading
/// "Working" for hours while the prompt is lost.
@MainActor
final class SilentTurnTests: XCTestCase {
    private var machine = AgentStatusMachine()
    private let t0: TimeInterval = 1_000
    private let claude = ForegroundProcess(instance: ProcessInstance(pid: 4242, startedAt: 900), name: "claude", arguments: ["claude"])
    private let shell = ForegroundProcess(instance: ProcessInstance(pid: 4000, startedAt: 800), name: "zsh", arguments: ["zsh"])
    /// The stuck-agent setting's default, 10 minutes.
    private let waitThreshold: TimeInterval = 600

    private func event(
        _ name: AgentHookEvent.Name, at offset: TimeInterval, id: String? = nil, agent: String? = nil, end: AgentToolEnd? = nil,
        type: String? = nil
    ) -> AgentHookEvent {
        AgentHookEvent(
            kind: .claude, name: name, sessionID: "lead", toolName: id == nil ? nil : "Bash", toolKey: id, toolEnd: end?.rawValue,
            toolUseID: id, agentID: agent, notificationType: type, timestamp: t0 + offset
        )
    }

    private func apply(
        _ name: AgentHookEvent.Name, at offset: TimeInterval, id: String? = nil, agent: String? = nil, end: AgentToolEnd? = nil,
        type: String? = nil
    ) {
        _ = machine.apply(event(name, at: offset, id: id, agent: agent, end: end, type: type), isUserFocused: false)
    }

    private func pressEsc(at offset: TimeInterval) {
        machine.noteKeystroke(now: Date(timeIntervalSince1970: t0 + offset), keys: Data([0x1B]))
    }

    /// A prompt went in at t0+1.
    private func promptIn() {
        _ = machine.tick(fgName: "claude", isUserFocused: false, now: Date(timeIntervalSince1970: t0))
        apply(.sessionStart, at: 0)
        apply(.userPromptSubmit, at: 1)
    }

    /// Silent for `quiet` awake seconds since a sign at `since`, against the
    /// threshold the default setting gives (20 minutes).
    private func silence(_ quiet: TimeInterval, since: TimeInterval = 50) -> AgentSilence {
        AgentSilence(since: since, now: since + quiet, threshold: AgentSilence.threshold(waitThreshold: waitThreshold) ?? 0)
    }

    private func stuck(_ silence: AgentSilence, foreground: ForegroundProcess? = nil) -> AgentStuckState? {
        machine.stuckState(now: t0 + 9_999, waitThreshold: nil, silence: silence, foreground: foreground ?? claude)
    }

    private func isSilent(_ quiet: TimeInterval = 7_200) -> Bool {
        if case .silent? = stuck(silence(quiet)) { return true }
        return false
    }

    // MARK: - The threshold

    func testTheThresholdIsTheStuckAgentSettingWithATwentyMinuteFloor() {
        XCTAssertNil(AgentSilence.threshold(waitThreshold: nil), "the setting off: no silence either")
        XCTAssertEqual(AgentSilence.threshold(waitThreshold: 300), 1_200, "14 minutes of thinking were measured")
        XCTAssertEqual(AgentSilence.threshold(waitThreshold: 3_600), 3_600)
    }

    func testATurnWaitingOnTheModelReadsSilentPastTheThreshold() {
        promptIn()
        XCTAssertNil(stuck(silence(1_199)), "a long think is no silence")
        let silent = silence(1_200)
        XCTAssertEqual(stuck(silent), .silent(silent))
        XCTAssertNil(stuck(silent, foreground: shell), "claude is not in front")
        XCTAssertNil(machine.stuckState(now: t0 + 9_999, waitThreshold: waitThreshold, foreground: claude), "nothing measured")
    }

    // MARK: - What is no silence

    func testAToolCallStillRunningIsNoSilence() {
        promptIn()
        apply(.preToolUse, at: 2, id: "build")
        XCTAssertFalse(isSilent(), "a two-hour build")
        apply(.preToolUse, at: 3, id: "lookup", agent: "sub")
        apply(.postToolUse, at: 4, id: "lookup", agent: "sub")
        apply(.postToolUse, at: 5, id: "another")
        XCTAssertFalse(isSilent(), "another call's end isn't the build's")
        apply(.postToolUse, at: 7_202, id: "build")
        XCTAssertTrue(isSilent(), "its result went in: the turn waits on the model again")
    }

    func testACallAutoModeRefusedEndsWithItsPermissionDenied() {
        promptIn()
        apply(.preToolUse, at: 2, id: "rm")
        apply(.permissionDenied, at: 3, id: "rm")
        XCTAssertTrue(isSilent())
    }

    func testACallDeniedAtItsDialogIsForgottenWhenTheTurnEnds() {
        promptIn()
        apply(.preToolUse, at: 2, id: "push")
        // Denied at its dialog: no hook says so.
        XCTAssertFalse(isSilent())
        apply(.stop, at: 50)
        apply(.userPromptSubmit, at: 60)
        XCTAssertTrue(isSilent())
    }

    func testAPromptWhileACallRunsLeavesItRunning() {
        promptIn()
        apply(.preToolUse, at: 2, id: "build")
        // A peer's message, submitted as a prompt while the build runs.
        apply(.userPromptSubmit, at: 300)
        XCTAssertFalse(isSilent())
    }

    func testAnOpenDialogIsAWaitOnTheUser() {
        promptIn()
        _ = machine.apply(
            AgentHookEvent(kind: .claude, name: .permissionRequest, sessionID: "lead", toolName: "Bash", toolKey: "k", timestamp: t0 + 2),
            isUserFocused: false
        )
        XCTAssertFalse(machine.awaitsModel(foreground: claude))
    }

    func testAnEscSinceThePromptIsNoSilence() {
        promptIn()
        pressEsc(at: 5)
        XCTAssertFalse(isSilent(), "interrupted: Claude fires no hook, and its idle reminder may never come")
        apply(.userPromptSubmit, at: 10)
        XCTAssertTrue(isSilent(), "the next prompt is watched again")
    }

    func testAnInterruptedCallIsNoSilence() {
        promptIn()
        apply(.preToolUse, at: 2, id: "build")
        pressEsc(at: 5)
        apply(.postToolUse, at: 6, id: "build", end: .interrupted)
        XCTAssertFalse(isSilent(), "the call's end comes after the Esc")
        // A stop Nirux didn't type (Remote Control): the end alone says so.
        apply(.userPromptSubmit, at: 10)
        apply(.preToolUse, at: 11, id: "test")
        apply(.postToolUse, at: 12, id: "test", end: .interrupted)
        XCTAssertFalse(isSilent())
    }

    func testADialogsReminderDoesNotTakeAnEscBack() {
        promptIn()
        pressEsc(at: 5)
        // A background subagent's dialog, its reminder, then its answer.
        _ = machine.apply(
            AgentHookEvent(kind: .claude, name: .permissionRequest, sessionID: "lead", toolName: "Bash", toolKey: "k", agentID: "sub", timestamp: t0 + 6),
            isUserFocused: false
        )
        apply(.notification, at: 12, agent: "sub", type: "permission_prompt")
        apply(.postToolUse, at: 20, id: "k", agent: "sub")
        XCTAssertFalse(isSilent())
    }

    func testATurnItsIdleReminderEndedStaysEnded() {
        promptIn()
        apply(.preToolUse, at: 2, id: "read")
        apply(.postToolUse, at: 3, id: "read")
        // Its Stop got lost: Claude's idle reminder ends the turn.
        apply(.notification, at: 70, type: "idle_prompt")
        apply(.preToolUse, at: 80, id: "review", agent: "reviewer")
        apply(.postToolUse, at: 81, id: "review", agent: "reviewer")
        XCTAssertFalse(isSilent(), "a background subagent at work since")
    }

    func testAnEndedTurnIsNoSilenceWhateverItsSubagentsDo() {
        promptIn()
        apply(.stop, at: 5)
        XCTAssertFalse(isSilent())
        apply(.preToolUse, at: 6, id: "review", agent: "reviewer")
        apply(.postToolUse, at: 7, id: "review", agent: "reviewer")
        XCTAssertFalse(isSilent(), "a background subagent at work after the turn's end")
        // A turn Claude starts by itself shows from its first call on.
        apply(.preToolUse, at: 8, id: "own")
        apply(.postToolUse, at: 9, id: "own")
        XCTAssertTrue(isSilent())
    }

    func testAnEarlierClaudesTurnIsNotTheOneInFront() {
        promptIn()
        let later = ForegroundProcess(instance: ProcessInstance(pid: 5000, startedAt: t0 + 30), name: "claude", arguments: ["claude"])
        XCTAssertNil(stuck(silence(7_200), foreground: later))
    }

    // MARK: - The alert and ⌘J

    func testOneAlertPerSilence() {
        promptIn()
        func alert(_ silence: AgentSilence) -> AgentAttentionReason? {
            machine.takeStuckAlert(now: t0 + 9_999, waitThreshold: waitThreshold, silence: silence, foreground: claude)
        }
        XCTAssertNil(alert(silence(1_199)))
        XCTAssertEqual(alert(silence(1_200)), .silent(1_200))
        XCTAssertNil(alert(silence(9_000)), "the same silence, hours on")
        XCTAssertEqual(alert(silence(1_300, since: 9_100)), .silent(1_300), "a sign of life since: a new silence")
    }

    func testASilentTurnBlocksTheAgentLikeAFailure() throws {
        promptIn()
        let wait = try XCTUnwrap(machine.blockedWait(now: t0 + 5_000, silence: silence(3_600), foreground: claude))
        XCTAssertEqual(wait, AgentWait(reason: .silent(3_600), since: t0 + 1_400))
        XCTAssertTrue(wait.blocks(whileStatus: .working), "its status still reads working")
        XCTAssertEqual(wait.reason.signal, .error)
    }

    func testSilentReasonTexts() {
        let reason = AgentAttentionReason.silent(17_100)
        XCTAssertEqual(reason.shortLabel, "silent 4h45m")
        XCTAssertTrue(reason.isFailure)
        XCTAssertFalse(reason.isBlockingDialog)
        XCTAssertNil(StateIcon.Reason(reason), "red, not an amber wait")
        let text = NiruxNotifier.attentionText(processName: "claude", workspaceTitle: "ws", reason: reason)
        XCTAssertEqual(text.title, "claude has been silent for 4h45m")
        XCTAssertEqual(text.body, AgentAttentionReason.silentAdvice)
    }

    // MARK: - Signs of life

    func testATranscriptThatGrowsIsASignOfLife() {
        var signs = AgentLifeSigns()
        signs.note(at: 10)
        signs.noteTranscript(path: "/t.jsonl", size: 100, at: 20)
        XCTAssertEqual(signs.lastAt, 10, "a first look only takes its measure")
        signs.noteTranscript(path: "/t.jsonl", size: 100, at: 30)
        XCTAssertEqual(signs.lastAt, 10)
        signs.noteTranscript(path: "/t.jsonl", size: 180, at: 40)
        XCTAssertEqual(signs.lastAt, 40)
        signs.noteTranscript(path: "/other.jsonl", size: 500, at: 50)
        XCTAssertEqual(signs.lastAt, 40, "another transcript is measured anew")
    }

    /// The column measures silence on the awake clock from its hook events
    /// and its transcript's size, and reads it against the setting.
    func testTheColumnHearsHookEventsAndItsTranscript() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("nirux-silent-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let transcript = directory.appendingPathComponent("conv.jsonl")
        try Data("{}\n".utf8).write(to: transcript)

        let column = ColumnState(cwd: "/tmp")
        let pty = try XCTUnwrap(column.pty)
        let clock = AwakeClock()
        pty.awakeClock = { clock.now }
        let front = ForegroundProcess(instance: ProcessInstance(pid: 500, startedAt: 10), name: "claude", arguments: ["claude"])
        let snapshot = ProcessSnapshot(entries: [ProcessSnapshot.Entry(
            pid: 500, parentPID: 1, processGroupID: 500, terminalForegroundProcessGroupID: 0, name: "claude",
            startedAt: 10, arguments: ["claude"]
        )])
        func hook(_ name: AgentHookEvent.Name) {
            let event = AgentHookEvent(
                kind: .claude, name: name, agentUUID: column.agentUUID, sessionID: "conv", emitterProcess: front.instance,
                source: name == .sessionStart ? "startup" : nil, transcriptPath: transcript.path, timestamp: 90
            )
            _ = column.admitClaudeHook(event, foregroundProcess: front, snapshot: snapshot)
            pty.applyAgentHook(event, isUserFocused: false)
        }
        func silent() -> Bool {
            column.noteTranscriptGrowth(foreground: front)
            if case .silent? = pty.agentStuckState(now: 9_999, waitThreshold: waitThreshold, foreground: front) { return true }
            return false
        }

        clock.now = 100
        hook(.sessionStart)
        hook(.userPromptSubmit)
        clock.now = 1_299
        XCTAssertFalse(silent())
        clock.now = 1_300
        XCTAssertTrue(silent(), "20 awake minutes since the prompt")
        XCTAssertNil(pty.agentStuckState(now: 9_999, waitThreshold: nil, foreground: front), "the setting off")
        XCTAssertEqual(pty.takeAgentStuckAlert(now: 9_999, waitThreshold: waitThreshold, foreground: front), .silent(1_200))
        XCTAssertNil(pty.takeAgentStuckAlert(now: 9_999, waitThreshold: waitThreshold, foreground: front), "once")
        XCTAssertEqual(pty.agentBlockedWait(now: 9_999, waitThreshold: waitThreshold, foreground: front)?.reason, .silent(1_200))

        // A line written: alive.
        let handle = try FileHandle(forWritingTo: transcript)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("{\"type\":\"system\"}\n".utf8))
        try handle.close()
        clock.now = 1_400
        XCTAssertFalse(silent())
        clock.now = 2_600
        XCTAssertTrue(silent(), "nothing since that line")
    }

    /// The stuck pass, as the heartbeat and the background watch run it,
    /// hears the transcript grow and sends the silence's one alert.
    func testTheStuckPassHearsTheTranscriptAndAlertsOnce() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("nirux-silent-pass-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let previousStateDirectory = ProcessInfo.processInfo.environment["NIRUX_STATE_DIR"]
        setenv("NIRUX_STATE_DIR", root.path, 1)
        defer {
            if let previousStateDirectory { setenv("NIRUX_STATE_DIR", previousStateDirectory, 1) } else { unsetenv("NIRUX_STATE_DIR") }
            try? FileManager.default.removeItem(at: root)
        }
        let transcript = root.appendingPathComponent("lead.jsonl")
        try Data("{}\n".utf8).write(to: transcript)
        _ = NSApplication.shared
        let shell = NiruxShellView(frame: NSRect(x: 0, y: 0, width: 1200, height: 800))
        shell.stopHeartbeat()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800), styleMask: [.titled], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = shell
        defer { window.close() }

        let column = try XCTUnwrap(shell.workspaces.first?.columns.first)
        let pty = try XCTUnwrap(column.pty)
        try await waitUntil("the column's shell", timeout: 10) { pty.shellPID != nil }
        let shellPID = try XCTUnwrap(pty.shellPID)
        let now = Date().timeIntervalSince1970
        let snapshot = ProcessSnapshot(entries: [
            ProcessSnapshot.Entry(
                pid: shellPID, parentPID: 1, processGroupID: shellPID, terminalForegroundProcessGroupID: 99_999,
                name: "zsh", startedAt: now - 8_000, arguments: ["zsh"]
            ),
            ProcessSnapshot.Entry(
                pid: 99_999, parentPID: shellPID, processGroupID: 99_999, terminalForegroundProcessGroupID: 99_999,
                name: "claude", startedAt: now - 7_200, arguments: ["claude"]
            )
        ])
        let front = try XCTUnwrap(pty.foregroundProcess(snapshot: snapshot))
        let clock = AwakeClock()
        clock.now = 100
        pty.awakeClock = { clock.now }
        for name in [AgentHookEvent.Name.sessionStart, .userPromptSubmit] {
            let event = AgentHookEvent(
                kind: .claude, name: name, agentUUID: column.agentUUID, sessionID: "lead", emitterProcess: front.instance,
                source: name == .sessionStart ? "startup" : nil, transcriptPath: transcript.path, timestamp: now - 3_000
            )
            _ = column.admitClaudeHook(event, foregroundProcess: front, snapshot: snapshot)
            pty.applyAgentHook(event, isUserFocused: false)
        }
        var notified: [AgentAttentionReason?] = []
        column.onAgentAttention = { notified.append($0) }
        shell.stuckAgentWaitThreshold = waitThreshold
        func pass(at awake: TimeInterval) {
            clock.now = awake
            shell.refreshStuckAgents(snapshot: snapshot, now: now, appIsActive: false)
        }

        pass(at: 100)
        let handle = try FileHandle(forWritingTo: transcript)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("{}\n".utf8))
        try handle.close()
        pass(at: 1_000)
        pass(at: 2_199)
        XCTAssertEqual(notified, [], "20 minutes from the last line, not from the prompt")
        pass(at: 2_200)
        pass(at: 2_300)
        XCTAssertEqual(notified, [.silent(1_200)], "once")
    }

    // MARK: - The row

    private func column(_ stuck: SidebarStuckState?) -> ColumnInfo {
        ColumnInfo(
            index: 0, processName: "claude", abbreviatedCwd: "~/p", isFocused: false, isWebView: false,
            webTitle: nil, terminalTitle: nil, agentStatus: .working, isEditor: false, editorFileName: nil,
            agentElapsedSeconds: 17_100, stuck: stuck
        )
    }

    private func workspace(_ columns: [ColumnInfo]) -> WorkspaceInfo {
        WorkspaceInfo(
            id: "ws", index: 0, title: "check-video", profileID: WorkspaceProfile.defaultID, isInactive: false,
            columnCount: columns.count, focusedColumn: 0, gitBranch: nil, notification: nil, isActive: false,
            columns: columns, prInfo: nil, diffStats: nil, purpose: nil, nextStep: nil, blocker: nil,
            phase: .active, lastSummary: nil, lastActivityAt: nil
        )
    }

    func testTheRowSaysSilentInRedInsteadOfWorking() {
        let silent = column(.silent(duration: "4h45m"))
        XCTAssertEqual(silent.attention, .error)
        XCTAssertEqual(SidebarColumnChip(silent).text.string.replacingOccurrences(of: "\u{FFFC}", with: ""), "silent 4h45m")
        XCTAssertEqual(SidebarColumnChip(silent).style, .error)
        XCTAssertEqual(
            SidebarRenderer.attentionTooltip(for: silent),
            "Claude has been silent for 4h45m. \(AgentAttentionReason.silentAdvice)"
        )
        let summary = workspace([silent]).rowSummary
        XCTAssertEqual(summary.mark, .error)
        XCTAssertEqual(summary.status.text, "Silent for 4h45m")
        XCTAssertEqual(workspace([silent]).cardState, .error)
        XCTAssertEqual(workspace([column(nil)]).rowSummary.status.text, "Working", "the same column without it")
    }

    func testTheBoardAndTheMergeQueueReadIt() {
        let state = ProjectBoard.agentState(
            stuck: .silent(duration: "25m"), hasAgent: true, agentInFront: true, status: .working, openDialog: nil
        )
        XCTAssertEqual(state, .silent(duration: "25m"))
        XCTAssertEqual(MergeQueue.busyLabel(state), "silent", "its turn may still answer: no merge under it")
        let agents = [ProjectBoard.AgentState.working(duration: "3h"), state, .waitingLong(.question(nil), duration: "1h")]
            .enumerated().map { ProjectBoard.Agent(state: $1, workspaceID: "ws\($0)") }
        XCTAssertEqual(ProjectBoard.Agent.mostUrgent(agents).workspaceID, "ws1", "past a long wait, before failures")
    }
}

/// An awake clock a test moves by hand.
private final class AwakeClock: @unchecked Sendable {
    var now: TimeInterval = 0
}
