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

    /// A silence past its threshold (as `PtySession` passes it), that began
    /// at `since` on the awake clock and `startedAt` on the wall's.
    private func silence(since: TimeInterval = 50, startedAt: TimeInterval = 1_100) -> AgentSilence {
        AgentSilence(since: since, startedAt: startedAt)
    }

    private func stuck(_ silence: AgentSilence, now: TimeInterval = 9_999, foreground: ForegroundProcess? = nil) -> AgentStuckState? {
        machine.stuckState(now: now, waitThreshold: nil, silence: silence, foreground: foreground ?? claude)
    }

    private func isSilent() -> Bool {
        if case .silent? = stuck(silence()) { return true }
        return false
    }

    // MARK: - The threshold

    func testTheThresholdIsTheStuckAgentSettingWithATwentyMinuteFloor() {
        XCTAssertEqual(AgentSilence.threshold(waitThreshold: nil), 1_200, "the dialog check off: hangs are still watched")
        XCTAssertEqual(AgentSilence.threshold(waitThreshold: 300), 1_200, "14 minutes of thinking were measured")
        XCTAssertEqual(AgentSilence.threshold(waitThreshold: 3_600), 3_600)
    }

    func testASilenceShowsWhileTheTurnWaitsOnTheModel() {
        promptIn()
        XCTAssertEqual(stuck(silence()), .silent(silence()))
        XCTAssertEqual(stuck(silence(), now: 20_000), stuck(silence()), "the same state tick after tick")
        XCTAssertNil(stuck(silence(), foreground: shell), "claude is not in front")
        XCTAssertNil(machine.stuckState(now: t0 + 9_999, waitThreshold: waitThreshold, foreground: claude), "none past its threshold")
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

    func testAnEscAtItsDialogEndsTheCall() {
        promptIn()
        apply(.preToolUse, at: 2, id: "ask")
        apply(.permissionRequest, at: 3, id: "ask")
        // Esc at its dialog: no hook, no Stop. The user types on at once.
        pressEsc(at: 5)
        machine.noteKeystroke(now: Date(timeIntervalSince1970: t0 + 19), keys: Data("go on\r".utf8))
        apply(.userPromptSubmit, at: 20)
        XCTAssertTrue(isSilent())
    }

    func testAnEscThatClosesNoDialogLeavesTheCallRunning() {
        promptIn()
        apply(.preToolUse, at: 2, id: "build")
        // An Esc that leaves vim's insert mode, or closes a menu.
        pressEsc(at: 5)
        // A peer's message, submitted as a prompt while the build runs.
        apply(.userPromptSubmit, at: 300)
        XCTAssertFalse(isSilent())
    }

    func testAnEscThatStoppedNothingLetsTheResultWakeTheTurn() {
        promptIn()
        apply(.preToolUse, at: 2, id: "build")
        pressEsc(at: 5)
        apply(.postToolUse, at: 600, id: "build")
        XCTAssertTrue(isSilent(), "the build's result went to the model")
    }

    func testCallsEndingAfterAnInterruptWakeNothing() {
        promptIn()
        apply(.preToolUse, at: 2, id: "build")
        apply(.preToolUse, at: 3, id: "fetch")
        apply(.preToolUse, at: 4, id: "rm")
        pressEsc(at: 5)
        apply(.postToolUse, at: 6, id: "build", end: .interrupted)
        // Its siblings end without saying they were stopped.
        apply(.postToolUse, at: 7, id: "fetch", end: .failed)
        apply(.permissionDenied, at: 8, id: "rm")
        XCTAssertFalse(isSilent())
    }

    func testAPermissionDeniedOutsideATurnSaysNothing() {
        promptIn()
        apply(.stop, at: 5)
        apply(.permissionDenied, at: 6, id: "late")
        XCTAssertFalse(machine.hookTurnInFlight)
        XCTAssertNotEqual(machine.state, .working)
        XCTAssertFalse(isSilent())
    }

    func testAPermissionDeniedIsProgressPastItsAgentsDialogs() {
        promptIn()
        _ = machine.apply(
            AgentHookEvent(kind: .claude, name: .permissionRequest, sessionID: "lead", toolName: "Bash", toolKey: "k", agentID: "sub", timestamp: t0 + 2),
            isUserFocused: false
        )
        apply(.permissionDenied, at: 3, id: "rm", agent: "sub")
        XCTAssertEqual(machine.openDialogs, [], "the subagent went on: its dialog was answered")
    }

    func testAPeersMessageHidesNoKeysTypedBefore() {
        promptIn()
        apply(.preToolUse, at: 2, id: "ls")
        apply(.postToolUse, at: 3, id: "ls")
        machine.noteKeystroke(now: Date(timeIntervalSince1970: t0 + 4), keys: Data("x".utf8))
        _ = machine.apply(
            AgentHookEvent(kind: .claude, name: .userPromptSubmit, sessionID: "lead", source: "poll_event", timestamp: t0 + 5),
            isUserFocused: false
        )
        XCTAssertEqual(machine.silentInterruptRefusal(foreground: claude), .typed)
        // Nor from the Lead's Esc, once Claude went on.
        apply(.preToolUse, at: 6, id: "cat")
        XCTAssertEqual(machine.interruptRefusal(foreground: claude), .typed)
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

    func testAnEscNiruxSendsIsAnInterruptToo() {
        promptIn()
        XCTAssertNotNil(machine.noteInterruptSent(now: t0 + 5))
        XCTAssertFalse(isSilent(), "the Lead's interrupt_task, or the Interrupt button")
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
        XCTAssertNil(stuck(silence(), foreground: later))
    }

    // MARK: - The alert and ⌘J

    func testOneAlertPerSilence() {
        promptIn()
        @MainActor func alert(_ silence: AgentSilence?, at now: TimeInterval) -> AgentAttentionReason? {
            machine.takeStuckAlert(now: now, waitThreshold: waitThreshold, silence: silence, foreground: claude)
        }
        XCTAssertNil(alert(nil, at: 2_299), "none past its threshold yet")
        XCTAssertEqual(alert(silence(startedAt: 1_100), at: 2_300), .silent(1_200))
        XCTAssertNil(alert(silence(startedAt: 1_100), at: 9_000), "the same silence, hours on")
        XCTAssertEqual(alert(silence(since: 9_100, startedAt: 9_000), at: 10_300), .silent(1_300), "a sign of life since: a new silence")
    }

    func testASilentTurnBlocksTheAgentLikeAFailure() throws {
        promptIn()
        let wait = try XCTUnwrap(machine.blockedWait(now: 4_700, silence: silence(startedAt: 1_100), foreground: claude))
        XCTAssertEqual(wait, AgentWait(reason: .silent(3_600), since: 1_100))
        XCTAssertEqual(machine.blockedWait(now: 4_800, silence: silence(startedAt: 1_100), foreground: claude)?.since, 1_100, "it stays put")
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
        signs.note(awake: 10, wall: 1_010)
        signs.noteTranscript(path: "/t.jsonl", size: 100, awake: 20, wall: 1_020)
        XCTAssertEqual(signs.lastAt, 10, "a first look only takes its measure")
        signs.noteAwaited(.prompt)
        signs.noteTranscript(path: "/t.jsonl", size: 100, awake: 30, wall: 1_030)
        XCTAssertEqual(signs.lastAt, 10)
        XCTAssertEqual(signs.transcript?.awaited, .prompt, "read once per size")
        signs.noteTranscript(path: "/t.jsonl", size: 180, awake: 40, wall: 1_040)
        XCTAssertEqual(signs.lastAt, 40)
        XCTAssertEqual(signs.lastWallAt, 1_040)
        XCTAssertNil(signs.transcript?.awaited, "read again at its new size")
        signs.noteTranscript(path: "/other.jsonl", size: 500, awake: 50, wall: 1_050)
        XCTAssertEqual(signs.lastAt, 40, "another transcript is measured anew")
    }

    /// What tells a request in flight: the transcript's last word is a
    /// prompt or a tool result, not Claude's.
    func testTheTranscriptsEndSaysWhetherAReplyIsAwaited() {
        func awaits(_ lines: [String]) -> TranscriptLastMessage.AwaitedReply? {
            TranscriptLastMessage.awaitedReply(in: Data((lines.joined(separator: "\n") + "\n").utf8))
        }
        let prompt = #"{"type":"user","origin":{"kind":"human"},"message":{"role":"user","content":"fix it"}}"#
        let reply = #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"thinking","thinking":"…"}]}}"#
        let result = #"{"type":"user","message":{"role":"user","content":[{"tool_use_id":"t1","type":"tool_result","content":"ok"}]}}"#
        let interrupt = #"{"type":"user","message":{"role":"user","content":[{"type":"text","text":"[Request interrupted by user]"}]}}"#
        let meta = #"{"type":"user","isMeta":true,"message":{"role":"user","content":"Caveat"}}"#
        let request = #"{"type":"api-request"}"#
        let poll = #"{"type":"attachment","attachment":{"type":"poll_events"}}"#
        let apiError = #"{"type":"assistant","isApiErrorMessage":true,"message":{"role":"assistant","content":[{"type":"text","text":"API Error"}]}}"#
        let quoting = #"{"type":"user","message":{"role":"user","content":[{"tool_use_id":"t2","type":"tool_result","content":"grep: \"text\":\"[Request interrupted by user\""}]}}"#
        XCTAssertEqual(awaits([prompt, request]), .prompt, "the incident: a prompt, its request, nothing")
        XCTAssertEqual(awaits([prompt, reply, result]), .toolResult, "a tool result went in")
        XCTAssertEqual(awaits([prompt, reply]), TranscriptLastMessage.AwaitedReply.none, "Claude answered: a lost Stop, or a long reply")
        XCTAssertEqual(awaits([prompt, interrupt]), TranscriptLastMessage.AwaitedReply.none)
        XCTAssertEqual(awaits([prompt, reply, meta]), TranscriptLastMessage.AwaitedReply.none, "a harness note says nothing")
        XCTAssertEqual(awaits([prompt, apiError]), TranscriptLastMessage.AwaitedReply.none, "the turn ended on an API error")
        XCTAssertEqual(awaits([prompt, reply, quoting]), .toolResult, "tool output quoting the interrupt's words")
        XCTAssertEqual(awaits([prompt, reply, result, poll]), .toolResult, "a peer's message Claude took in mid-turn is no prompt")
        XCTAssertNil(awaits([request, meta]))
    }

    /// The column measures silence on the awake clock from its hook events
    /// and its transcript's size, and reads it against the setting.
    func testTheColumnHearsHookEventsAndItsTranscript() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("nirux-silent-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let transcript = directory.appendingPathComponent("conv.jsonl")
        try Data((#"{"type":"user","origin":{"kind":"human"},"message":{"role":"user","content":"go"}}"# + "\n").utf8).write(to: transcript)
        @MainActor func append(_ line: String) throws {
            let handle = try FileHandle(forWritingTo: transcript)
            try handle.seekToEnd()
            try handle.write(contentsOf: Data((line + "\n").utf8))
            try handle.close()
        }

        let column = ColumnState(cwd: "/tmp")
        let pty = try XCTUnwrap(column.pty)
        let clock = AwakeClock()
        pty.awakeClock = { clock.now }
        let front = ForegroundProcess(instance: ProcessInstance(pid: 500, startedAt: 10), name: "claude", arguments: ["claude"])
        let snapshot = ProcessSnapshot(entries: [ProcessSnapshot.Entry(
            pid: 500, parentPID: 1, processGroupID: 500, terminalForegroundProcessGroupID: 0, name: "claude",
            startedAt: 10, arguments: ["claude"]
        )])
        @MainActor func hook(_ name: AgentHookEvent.Name) {
            let event = AgentHookEvent(
                kind: .claude, name: name, agentUUID: column.agentUUID, sessionID: "conv", emitterProcess: front.instance,
                source: name == .sessionStart ? "startup" : nil, transcriptPath: transcript.path, timestamp: 90
            )
            _ = column.admitClaudeHook(event, foregroundProcess: front, snapshot: snapshot)
            pty.applyAgentHook(event, isUserFocused: false)
        }
        @MainActor func silent(waitThreshold: TimeInterval? = 600) -> Bool {
            column.noteTranscriptGrowth(foreground: front, now: 5_000)
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
        XCTAssertTrue(silent(waitThreshold: nil), "the dialog check off: 20 minutes still")
        XCTAssertFalse(silent(waitThreshold: 3_600), "an hour's setting waits an hour")
        XCTAssertEqual(pty.takeAgentStuckAlert(now: 1_290, waitThreshold: waitThreshold, foreground: front), .silent(1_200))
        XCTAssertNil(pty.takeAgentStuckAlert(now: 1_290, waitThreshold: waitThreshold, foreground: front), "once")
        XCTAssertEqual(pty.agentBlockedWait(now: 1_290, waitThreshold: waitThreshold, foreground: front)?.since, 90, "its hook's time")

        // A line written: alive.
        try append(#"{"type":"system"}"#)
        clock.now = 1_400
        XCTAssertFalse(silent())
        clock.now = 2_600
        XCTAssertTrue(silent(), "nothing since that line")

        // Claude's reply written, then its Stop lost: no proof of a
        // request in flight, whatever the hooks believe.
        try append(#"{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"Done."}]}}"#)
        clock.now = 2_700
        XCTAssertFalse(silent())
        clock.now = 9_000
        XCTAssertFalse(silent(), "the transcript ends on Claude's words")

        // Another claude in front, whose transcript Nirux can't measure: the
        // last one's proof is forgotten.
        try append(#"{"type":"user","origin":{"kind":"human"},"message":{"role":"user","content":"again"}}"#)
        clock.now = 9_100
        XCTAssertFalse(silent())
        clock.now = 10_400
        XCTAssertTrue(silent())
        let other = ForegroundProcess(instance: ProcessInstance(pid: 501, startedAt: 10), name: "claude", arguments: ["claude"])
        column.noteTranscriptGrowth(foreground: other, now: 5_000)
        XCTAssertNil(pty.agentStuckState(now: 9_999, waitThreshold: 600, foreground: other))
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
        let silent = column(.silent(duration: "4h45m", since: 100, interruptible: true))
        XCTAssertEqual(silent.attentionSummary?.detail, AgentAttentionReason.silentAdvice, "the rail's tooltip says what to do")
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

    func testInterruptIsOfferedUnderTheRowAndClicksOnlyForItsSilence() throws {
        let info = workspace([column(.silent(duration: "4h45m", since: 100, interruptible: true))])
        XCTAssertEqual(info.cardActions, [.interrupt(columnIndex: 0, since: 100)])
        let result = SidebarWorkspaceCardRenderer(workspace: info, sidebarWidth: 260, yOffset: 800).render()
        let region = SidebarHitRegion.agentInterrupt(workspaceIndex: 0, columnIndex: 0, since: 100)
        XCTAssertTrue(result.hitAreas.contains {
            if case .agentInterrupt(0, 0, 100) = $0.region { return true }
            return false
        })
        XCTAssertEqual(
            Array(result.approvalButtons.keys), [SidebarHoverTarget.interruptButtonKey(workspaceIndex: 0, columnIndex: 0, since: 100)],
            "armed and hovered like Resume"
        )
        XCTAssertEqual(800 - result.bottomY, SidebarExpandedMetrics.workspaceHeight(for: info, sidebarWidth: 260), accuracy: 0.5)

        func click(released: SidebarHitRegion?, count: Int = 1) -> SidebarInterruptClick? {
            SidebarView.interruptClick(pressed: region, released: released, clickCount: count, armedAtPress: true, armedAtRelease: true)
        }
        XCTAssertEqual(click(released: region), SidebarInterruptClick(workspaceIndex: 0, columnIndex: 0, since: 100))
        XCTAssertNil(click(released: .agentInterrupt(workspaceIndex: 0, columnIndex: 0, since: 900)), "another silence came there")
        XCTAssertNil(click(released: region, count: 2))

        let refused = workspace([column(.silent(duration: "4h45m", since: 100, interruptible: false))])
        XCTAssertEqual(refused.cardActions, [], "no button that can't press Esc")
    }

    /// Esc, once, and only into the silence the button showed: never Enter.
    /// The turn ends with it; the prompt Claude gives back is a draft no
    /// Mission message joins.
    func testInterruptPressesEscOnceIntoTheSilenceItShows() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("nirux-interrupt-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let pty = PtySession()
        let agent = AgentStandIn()
        defer { agent.remove() }
        pty.start(shell: "/bin/zsh", args: ["-f", "-c", agent.command()], cwd: directory.path)
        try await waitUntil("claude in front", timeout: 3) { pty.foregroundProcess(snapshot: ProcessSnapshot())?.name == "claude" }
        let front = try XCTUnwrap(pty.foregroundProcess(snapshot: ProcessSnapshot()))
        let clock = AwakeClock()
        pty.awakeClock = { clock.now }
        @MainActor func hook(_ name: AgentHookEvent.Name, at time: TimeInterval, call: String? = nil) {
            pty.applyAgentHook(
                AgentHookEvent(
                    kind: .claude, name: name, sessionID: "lead", emitterProcess: front.instance,
                    toolName: call.map { _ in "Bash" }, toolUseID: call, timestamp: time
                ),
                isUserFocused: false
            )
        }
        @MainActor func interrupt(since: TimeInterval) -> SilentInterrupt {
            pty.interruptSilentTurn(since: since, waitThreshold: waitThreshold, snapshot: ProcessSnapshot(), now: Date().timeIntervalSince1970)
        }

        clock.now = 100
        hook(.sessionStart, at: Date().timeIntervalSince1970)
        hook(.userPromptSubmit, at: Date().timeIntervalSince1970)
        // Its transcript ends on the prompt: the proof a reply is awaited.
        let transcript = directory.appendingPathComponent("lead.jsonl")
        let line = Data((#"{"type":"user","origin":{"kind":"human"},"message":{"role":"user","content":"go"}}"# + "\n").utf8)
        try line.write(to: transcript)
        pty.noteAgentTranscript(path: transcript.path, size: Int64(line.count), now: Date().timeIntervalSince1970)
        clock.now = 1_299
        XCTAssertEqual(interrupt(since: 100), .notSilent, "not silent yet")
        clock.now = 1_300
        XCTAssertEqual(
            pty.interruptSilentTurn(since: 100, waitThreshold: waitThreshold, snapshot: ProcessSnapshot(entries: []), now: Date().timeIntervalSince1970),
            .noProcesses, "a process table that couldn't be read isn't Claude moving on"
        )
        XCTAssertEqual(interrupt(since: 99), .notSilent, "not the silence the button showed")
        XCTAssertEqual(pty.silentInterruptPlan(foreground: front), .givesBackPrompt)
        XCTAssertEqual(interrupt(since: 100), .promptGivenBack)
        try await waitUntil("Esc typed", timeout: 3) { !agent.input.isEmpty }
        XCTAssertNil(pty.agentStuckState(now: Date().timeIntervalSince1970, waitThreshold: waitThreshold, foreground: front), "the turn is over")
        XCTAssertEqual(
            pty.missionPromptRefusal(runningSince: front.instance.startedAt, snapshot: ProcessSnapshot()), .draft,
            "the prompt given back waits for the user's Enter"
        )
        XCTAssertEqual(interrupt(since: 100), .notSilent, "a second click")

        // Silent after a tool result and a peer's message Claude took in:
        // no prompt of the user's to give back. The turn ends only once
        // Claude writes its interrupt.
        clock.now = 2_000
        pty.sendRaw("\r") // the user sends the prompt given back
        hook(.userPromptSubmit, at: Date().timeIntervalSince1970)
        hook(.preToolUse, at: Date().timeIntervalSince1970, call: "ls")
        hook(.postToolUse, at: Date().timeIntervalSince1970, call: "ls")
        let peerAt = Date().timeIntervalSince1970
        hook(.userPromptSubmit, at: peerAt)
        let tail = Data((#"{"type":"user","message":{"role":"user","content":[{"tool_use_id":"t1","type":"tool_result","content":"ok"}]}}"#
            + "\n" + #"{"type":"attachment","attachment":{"type":"poll_events"}}"# + "\n").utf8)
        let handle = try FileHandle(forWritingTo: transcript)
        try handle.seekToEnd()
        try handle.write(contentsOf: tail)
        try handle.close()
        pty.noteAgentTranscript(path: transcript.path, size: Int64(line.count + tail.count), now: Date().timeIntervalSince1970)
        clock.now = 3_200
        XCTAssertEqual(interrupt(since: 2_000), .stopping(promptAt: peerAt))
        try await waitUntil("the second Esc", timeout: 3) { agent.input.count == 3 }
        XCTAssertEqual(
            pty.missionPromptRefusal(runningSince: front.instance.startedAt, snapshot: ProcessSnapshot()), .working,
            "no draft given back, and no message until Claude shows it stopped"
        )
        // Ignored by a Claude that hangs on: its silence shows again.
        pty.noteInterruptIgnored(promptAt: peerAt)
        guard case .silent? = pty.agentStuckState(now: Date().timeIntervalSince1970, waitThreshold: waitThreshold, foreground: front)
        else { return XCTFail("silent again once the Esc went unanswered") }
        XCTAssertEqual(interrupt(since: 2_000), .refused(.alreadySent), "a second Esc would open the rewind")
        XCTAssertTrue(pty.noteInterrupted(promptAt: peerAt))
        XCTAssertNil(pty.missionPromptRefusal(runningSince: front.instance.startedAt, snapshot: ProcessSnapshot()), "free for a message")

        // Keys typed since its prompt: Esc could close a screen they opened,
        // and would give them back.
        clock.now = 4_000
        hook(.userPromptSubmit, at: Date().timeIntervalSince1970)
        hook(.preToolUse, at: Date().timeIntervalSince1970, call: "ls2")
        hook(.postToolUse, at: Date().timeIntervalSince1970, call: "ls2")
        pty.sendRaw("x")
        clock.now = 5_200
        XCTAssertEqual(pty.silentInterruptPlan(foreground: front), .refused(.typed))
        XCTAssertEqual(interrupt(since: 4_000), .refused(.typed))

        // A turn Claude started by itself: no prompt to give back.
        let later = Date().timeIntervalSince1970 + 10
        hook(.stop, at: later)
        hook(.preToolUse, at: later + 1, call: "own")
        hook(.postToolUse, at: later + 2, call: "own")
        clock.now = 6_400
        XCTAssertEqual(interrupt(since: 5_200), .refused(.notWorking))
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(agent.input, "\u{1B}\n\u{1B}x", "an Esc per interrupt, never Enter but the user's")
    }

    /// Keys typed before Claude answered: the Esc could close a screen they
    /// opened, and the turn hang on.
    func testKeysTypedBeforeAnyReplyLeaveTheEscToTheUser() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("nirux-interrupt-typed-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let pty = PtySession()
        let agent = AgentStandIn()
        defer { agent.remove() }
        pty.start(shell: "/bin/zsh", args: ["-f", "-c", agent.command()], cwd: directory.path)
        try await waitUntil("claude in front", timeout: 3) { pty.foregroundProcess(snapshot: ProcessSnapshot())?.name == "claude" }
        let front = try XCTUnwrap(pty.foregroundProcess(snapshot: ProcessSnapshot()))
        let clock = AwakeClock()
        clock.now = 100
        pty.awakeClock = { clock.now }
        for name in [AgentHookEvent.Name.sessionStart, .userPromptSubmit] {
            pty.applyAgentHook(
                AgentHookEvent(kind: .claude, name: name, sessionID: "lead", emitterProcess: front.instance, timestamp: Date().timeIntervalSince1970),
                isUserFocused: false
            )
        }
        let transcript = directory.appendingPathComponent("lead.jsonl")
        let line = Data((#"{"type":"user","origin":{"kind":"human"},"message":{"role":"user","content":"go"}}"# + "\n").utf8)
        try line.write(to: transcript)
        pty.noteAgentTranscript(path: transcript.path, size: Int64(line.count), now: Date().timeIntervalSince1970)
        pty.sendRaw("/")
        clock.now = 1_300
        XCTAssertEqual(pty.silentInterruptPlan(foreground: front), .refused(.typed))
        XCTAssertEqual(
            pty.interruptSilentTurn(since: 100, waitThreshold: waitThreshold, snapshot: ProcessSnapshot(), now: Date().timeIntervalSince1970),
            .refused(.typed)
        )
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(agent.input, "/", "no Esc")
    }

    func testTheBoardAndTheMergeQueueReadIt() {
        let state = ProjectBoard.agentState(
            stuck: .silent(duration: "25m", since: 100, interruptible: true), hasAgent: true, agentInFront: true, status: .working, openDialog: nil
        )
        XCTAssertEqual(state, .silent(duration: "25m"))
        XCTAssertEqual(MergeQueue.busyLabel(state), "silent", "its turn may still answer: no merge under it")
        let agents = [ProjectBoard.AgentState.working(duration: "3h"), state, .waitingLong(.question(nil), duration: "1h")]
            .enumerated().map { ProjectBoard.Agent(state: $1, workspaceID: "ws\($0)") }
        XCTAssertEqual(ProjectBoard.Agent.mostUrgent(agents).workspaceID, "ws1", "past a long wait, before failures")
    }
}

/// An awake clock a test moves by hand.
final class AwakeClock: @unchecked Sendable {
    var now: TimeInterval = 0
}
