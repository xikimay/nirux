import XCTest
@testable import Nirux

/// Sidebar approvals: what may be approved, the decision channel, and the
/// receiver's wait (decision, timeout, wrong session or column, replay).
final class PermissionApprovalTests: XCTestCase {
    private var directory: URL!
    private var channel: PermissionApprovalChannel!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("nirux-approvals-\(UUID().uuidString)", isDirectory: true)
        channel = PermissionApprovalChannel(directory: directory)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: - What the sidebar may approve

    private func approvalText(_ tool: String, _ input: [String: Any]) -> String? {
        AgentToolInput.approvalText(toolName: tool, input: input, home: "/Users/me")
    }

    func testShortSingleLineCommandsAreApprovableVerbatim() {
        XCTAssertEqual(approvalText("Bash", ["command": "git push origin main"]), "git push origin main")
        XCTAssertEqual(approvalText("PowerShell", ["command": "Get-ChildItem"]), "Get-ChildItem")
        XCTAssertEqual(approvalText("WebFetch", ["url": "https://example.com/a?b=1", "prompt": "x"]), "https://example.com/a?b=1")
        XCTAssertEqual(approvalText("WebSearch", ["query": "swift concurrency"]), "swift concurrency")
        let longest = String(repeating: "a", count: AgentToolInput.maxSummaryLength)
        XCTAssertEqual(approvalText("Bash", ["command": longest]), longest)
    }

    /// Never relative to a working directory the card doesn't show.
    func testReadShowsAnAbsoluteOrHomePath() {
        XCTAssertEqual(approvalText("Read", ["file_path": "/proj/Sources/a.swift"]), "/proj/Sources/a.swift")
        XCTAssertEqual(approvalText("Read", ["file_path": "/Users/me/.ssh/config"]), "~/.ssh/config")
        XCTAssertEqual(approvalText("Read", ["file_path": "/Users/meow/x"]), "/Users/meow/x")
        XCTAssertEqual(approvalText("Read", ["file_path": "/etc/hosts"]), "/etc/hosts")
        XCTAssertNil(approvalText("Read", ["file_path": ".env"]), "relative to a directory the card doesn't show")
        XCTAssertNil(approvalText("Read", ["file_path": "~/x"]))
    }

    /// Anything the screen would alter, fold or cut is not approvable.
    func testTextThatWouldNotReachTheScreenUnchangedIsRefused() {
        let refused = [
            "echo hi\nrm -rf ~", // a newline would read as a space
            "echo\thi",
            "echo  hi", // folded spaces
            " ls",
            "ls ",
            "ls \u{202E}txt.exe", // bidi override
            "rm\u{200D} -rf x", // zero-width joiner
            "cat caf\u{00E9}.txt", // non-ASCII
            "echo \u{0007}",
            String(repeating: "a", count: AgentToolInput.maxSummaryLength + 1)
        ]
        for command in refused {
            XCTAssertNil(approvalText("Bash", ["command": command]), command.debugDescription)
        }
        XCTAssertNil(approvalText("Bash", ["command": ""]))
        XCTAssertNil(approvalText("Bash", [:]))
    }

    func testOnlyToolsWhoseWholeMeaningIsShownQualify() {
        XCTAssertNil(approvalText("Bash", ["command": "curl example.com", "dangerouslyDisableSandbox": true]))
        XCTAssertNil(approvalText("Bash", ["command": "curl example.com", "dangerouslyDisableSandbox": "true"]))
        XCTAssertNil(approvalText("Bash", ["command": "curl example.com", "dangerouslyDisableSandbox": "yes"]))
        XCTAssertNil(approvalText("Bash", ["command": "curl example.com", "dangerouslyDisableSandbox": NSNull()]))
        XCTAssertEqual(approvalText("Bash", ["command": "ls", "dangerouslyDisableSandbox": false]), "ls")
        XCTAssertEqual(approvalText("Bash", ["command": "ls", "dangerouslyDisableSandbox": "false"]), "ls")
        XCTAssertEqual(approvalText("Bash", ["command": "sleep 60", "run_in_background": true]), "sleep 60")
        for tool in ["Edit", "MultiEdit", "Write", "NotebookEdit"] {
            XCTAssertNil(approvalText(tool, ["file_path": "/proj/a.swift", "content": "x"]), tool)
        }
        XCTAssertNil(approvalText("Grep", ["pattern": "TODO", "path": "/etc"]))
        XCTAssertNil(approvalText("Glob", ["pattern": "*", "path": "/etc"]))
        XCTAssertNil(approvalText("AskUserQuestion", ["questions": [["question": "Pick?"]]]))
        XCTAssertNil(approvalText("ExitPlanMode", ["plan": "do it"]))
        XCTAssertNil(approvalText("Task", ["description": "review"]))
        XCTAssertNil(approvalText("mcp__github__create_issue", ["title": "x"]))
    }

    // MARK: - Hook output

    private func decision(in output: Data?) throws -> [String: Any] {
        let object = try JSONSerialization.jsonObject(with: try XCTUnwrap(output)) as? [String: Any]
        let specific = try XCTUnwrap(object?["hookSpecificOutput"] as? [String: Any])
        XCTAssertEqual(specific["hookEventName"] as? String, "PermissionRequest")
        XCTAssertEqual(object?.keys.sorted(), ["hookSpecificOutput"])
        return try XCTUnwrap(specific["decision"] as? [String: Any])
    }

    func testAllowNeverCarriesPermanentRulesOrInputChanges() throws {
        let allow = try decision(in: PermissionApproval.hookOutput(for: .allow))
        XCTAssertEqual(allow.keys.sorted(), ["behavior"])
        XCTAssertEqual(allow["behavior"] as? String, "allow")
    }

    /// A denial tells the agent and lets it go on, like "No" with feedback
    /// in the terminal: it never stops a run nobody is watching.
    func testDenyNeverInterruptsTheTurn() throws {
        let deny = try decision(in: PermissionApproval.hookOutput(for: .deny))
        XCTAssertEqual(deny["behavior"] as? String, "deny")
        XCTAssertEqual(deny["interrupt"] as? Bool, false)
        XCTAssertEqual(deny["message"] as? String, PermissionApproval.denyMessage)
        XCTAssertNil(PermissionApproval.hookOutput(for: .release))
    }

    /// The app checks what a queued request asks it to show itself: the
    /// receiver may be another build.
    func testAppOnlyShowsTextItCanShowExactly() {
        XCTAssertTrue(PermissionApproval.isDisplayable(toolName: "Bash", text: "git push"))
        XCTAssertFalse(PermissionApproval.isDisplayable(toolName: "Edit", text: "a.swift"))
        XCTAssertFalse(PermissionApproval.isDisplayable(toolName: "Bash", text: "echo hi\nrm -rf ~"))
        XCTAssertFalse(PermissionApproval.isDisplayable(toolName: "Bash", text: "caf\u{00E9}"))
        XCTAssertFalse(PermissionApproval.isDisplayable(toolName: "Bash", text: nil))
        XCTAssertFalse(PermissionApproval.isDisplayable(toolName: nil, text: "ls"))
    }

    // MARK: - Which requests a receiver holds

    private let env = ["NIRUX_AGENT_UUID": "uuid-1", "HOME": "/Users/me"]

    private let session = "0b6c1c56-5a4f-4f3e-9f1a-7d2f3c4b5a69"

    private func payload(
        tool: String = "Bash",
        input: [String: Any] = ["command": "git push"],
        session: String? = "0b6c1c56-5a4f-4f3e-9f1a-7d2f3c4b5a69",
        agent: String? = nil,
        mode: String? = "default"
    ) -> [String: Any] {
        var payload: [String: Any] = [
            "hook_event_name": "PermissionRequest", "tool_name": tool, "tool_input": input, "cwd": "/proj"
        ]
        payload["session_id"] = session
        payload["agent_id"] = agent
        payload["permission_mode"] = mode
        return payload
    }

    func testReceiverHoldsApprovableRequestsWhileTheAppListens() throws {
        let main = try XCTUnwrap(PermissionApprovalWait.prepare(payload: payload(), env: env, now: 100) { true })
        XCTAssertNotNil(UUID(uuidString: main.requestID))
        XCTAssertEqual(main.sessionID, session)
        XCTAssertEqual(main.text, "git push")
        XCTAssertEqual(main.agentUUID, "uuid-1")
        XCTAssertFalse(main.isSubagent)
        XCTAssertEqual(main.deadline, 100 + PermissionApproval.mainThreadWindow)

        let sub = try XCTUnwrap(PermissionApprovalWait.prepare(payload: payload(agent: "a1"), env: env, now: 100) { true })
        XCTAssertTrue(sub.isSubagent)
        XCTAssertEqual(sub.deadline, 100 + PermissionApproval.subagentWindow)
        XCTAssertNotEqual(sub.requestID, main.requestID)
    }

    func testReceiverDoesNotWaitWhenNothingCanAnswer() {
        XCTAssertNil(PermissionApprovalWait.prepare(payload: payload(), env: env, now: 1) { false }, "option off")
        XCTAssertNil(PermissionApprovalWait.prepare(payload: payload(session: nil), env: env, now: 1) { true })
        XCTAssertNil(PermissionApprovalWait.prepare(payload: payload(session: ""), env: env, now: 1) { true })
        // A call served to a cloud session reports "served:<caller>".
        XCTAssertNil(PermissionApprovalWait.prepare(payload: payload(session: "served:abc"), env: env, now: 1) { true })
        XCTAssertNil(PermissionApprovalWait.prepare(payload: payload(), env: ["HOME": "/Users/me"], now: 1) { true })
        XCTAssertNil(PermissionApprovalWait.prepare(
            payload: payload(tool: "Edit", input: ["file_path": "/proj/a"]), env: env, now: 1
        ) { true })
        var stop = payload()
        stop["hook_event_name"] = "PreToolUse"
        XCTAssertNil(PermissionApprovalWait.prepare(payload: stop, env: env, now: 1) { true })
    }

    /// Under bypass and auto modes, the dialogs left are Claude's safety
    /// checks (a dangerous rm): they stay in the terminal, with their warning.
    func testOnlySessionsAskingForOrdinaryApprovalAreHeld() {
        for mode in ["default", "acceptEdits", "plan"] {
            XCTAssertNotNil(PermissionApprovalWait.prepare(payload: payload(mode: mode), env: env, now: 1) { true }, mode)
        }
        for mode in ["bypassPermissions", "auto", "dontAsk", "", "future"] {
            XCTAssertNil(PermissionApprovalWait.prepare(payload: payload(mode: mode), env: env, now: 1) { true }, mode)
        }
        XCTAssertNil(PermissionApprovalWait.prepare(payload: payload(mode: nil), env: env, now: 1) { true })
    }

    func testTheAppIsAskedOnlyForApprovableRequests() {
        var asked = 0
        _ = PermissionApprovalWait.prepare(payload: payload(tool: "Write", input: [:]), env: env, now: 1) {
            asked += 1
            return true
        }
        XCTAssertEqual(asked, 0, "no marker read for requests the sidebar can't show")
    }

    // MARK: - Channel

    private func wait(session: String = "sess", agent: String = "uuid-1", at start: TimeInterval = 1_000) -> PermissionApprovalWait {
        PermissionApprovalWait(
            requestID: UUID().uuidString, sessionID: session, agentUUID: agent, text: "ls", isSubagent: false,
            startedAt: start, deadline: start + 55
        )
    }

    private func decision(
        for wait: PermissionApprovalWait,
        _ behavior: PermissionApproval.Behavior = .allow,
        session: String? = nil,
        agent: String? = nil,
        version: Int = PermissionApproval.protocolVersion
    ) -> PermissionApprovalDecision {
        PermissionApprovalDecision(
            requestID: wait.requestID,
            sessionID: session ?? wait.sessionID,
            agentUUID: agent ?? wait.agentUUID,
            behavior: behavior,
            issuedAt: wait.startedAt + 2,
            version: version
        )
    }

    func testDecisionIsClaimedAtMostOnce() throws {
        let request = wait()
        XCTAssertTrue(channel.send(decision(for: request)))
        XCTAssertEqual(channel.claimDecision(requestID: request.requestID), decision(for: request))
        XCTAssertNil(channel.claimDecision(requestID: request.requestID), "single use")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), [])
    }

    func testChannelFilesAreOwnerOnly() throws {
        let request = wait()
        XCTAssertTrue(channel.send(decision(for: request)))
        let fm = FileManager.default
        let directoryMode = try fm.attributesOfItem(atPath: directory.path)[.posixPermissions] as? Int
        XCTAssertEqual(directoryMode, 0o700)
        let url = try XCTUnwrap(channel.decisionURL(requestID: request.requestID))
        XCTAssertEqual(try fm.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int, 0o600)
    }

    /// Request IDs come back from the event queue: only a UUID may become a path.
    func testRequestIDsNeverBecomeArbitraryPaths() {
        for bad in ["../state", "a/b", "", "x.json", "\(UUID().uuidString)/.."] {
            XCTAssertNil(channel.decisionURL(requestID: bad), bad)
            XCTAssertFalse(channel.send(PermissionApprovalDecision(
                requestID: bad, sessionID: "s", agentUUID: "u", behavior: .allow, issuedAt: 1
            )), bad)
            XCTAssertNil(channel.claimDecision(requestID: bad))
        }
        let lowercase = UUID().uuidString.lowercased()
        XCTAssertEqual(channel.decisionURL(requestID: lowercase)?.lastPathComponent, "\(lowercase.uppercased()).json")
    }

    func testMarkerOfAnotherProtocolIsIgnored() throws {
        let me = try XCTUnwrap(ProcessInstance.running(pid: getpid()))
        XCTAssertTrue(channel.setListening(me))
        let other = PermissionApprovalMarker(version: PermissionApproval.protocolVersion + 1, app: me)
        try JSONEncoder().encode(other).write(to: channel.markerURL)
        XCTAssertFalse(channel.isAppListening(), "a receiver of another build never waits on this app")
    }

    func testMarkerNamesTheListeningAppProcess() throws {
        XCTAssertFalse(channel.isAppListening(), "no marker: option off")
        let me = try XCTUnwrap(ProcessInstance.running(pid: getpid()))
        XCTAssertTrue(channel.setListening(me))
        XCTAssertTrue(channel.isAppListening())
        // A crash left the marker and the PID now names another process.
        XCTAssertFalse(channel.isAppListening { pid in ProcessInstance(pid: pid, startedAt: me.startedAt + 1) })
        XCTAssertFalse(channel.isAppListening { _ in nil })
        channel.stopListening(for: me)
        XCTAssertFalse(channel.isAppListening())
    }

    /// Another Nirux on the same state directory keeps its marker; a stale
    /// one (crashed app) goes.
    func testStoppingLeavesAnotherRunningAppsMarker() throws {
        let me = try XCTUnwrap(ProcessInstance.running(pid: getpid()))
        let other = ProcessInstance(pid: 4_242, startedAt: 42)
        XCTAssertTrue(channel.setListening(other))
        channel.stopListening(for: me) { pid in pid == other.pid ? other : nil }
        XCTAssertTrue(FileManager.default.fileExists(atPath: channel.markerURL.path), "still running")
        channel.stopListening(for: me) { _ in nil }
        XCTAssertFalse(FileManager.default.fileExists(atPath: channel.markerURL.path), "gone: stale")
    }

    func testSweepRemovesUnclaimedDecisionsButNotTheMarker() throws {
        let me = try XCTUnwrap(ProcessInstance.running(pid: getpid()))
        channel.setListening(me)
        let stale = wait()
        let fresh = wait()
        channel.send(decision(for: stale))
        channel.send(decision(for: fresh))
        let staleURL = try XCTUnwrap(channel.decisionURL(requestID: stale.requestID))
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-3_600)], ofItemAtPath: staleURL.path
        )

        channel.sweep()
        XCTAssertFalse(FileManager.default.fileExists(atPath: staleURL.path))
        XCTAssertNotNil(channel.claimDecision(requestID: fresh.requestID))
        XCTAssertTrue(channel.isAppListening())
    }

    // MARK: - Trust

    /// A state directory another account could write (a shared
    /// NIRUX_STATE_DIR under /tmp): nothing there may pass for a decision.
    private func stateChannel() throws -> (state: URL, channel: PermissionApprovalChannel) {
        let state = directory.appendingPathComponent("state", isDirectory: true)
        try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
        return (state, PermissionApprovalChannel(directory: state.appendingPathComponent("permission-approvals")))
    }

    func testChannelInADirectoryOthersCanWriteIsNotTrusted() throws {
        let (state, channel) = try stateChannel()
        let me = try XCTUnwrap(ProcessInstance.running(pid: getpid()))
        XCTAssertTrue(channel.setListening(me))
        XCTAssertTrue(channel.isAppListening())

        chmod(state.path, 0o777)
        XCTAssertFalse(channel.isTrusted())
        XCTAssertFalse(channel.isAppListening(), "receivers don't wait")
        XCTAssertFalse(channel.send(decision(for: wait())), "the app doesn't write")
        XCTAssertFalse(channel.setListening(me))
        chmod(state.path, 0o755)
        XCTAssertTrue(channel.isTrusted())
    }

    func testSymlinkedChannelIsNotTrusted() throws {
        let (state, channel) = try stateChannel()
        let elsewhere = directory.appendingPathComponent("elsewhere", isDirectory: true)
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        chmod(elsewhere.path, 0o700)
        try FileManager.default.createSymbolicLink(
            at: state.appendingPathComponent("permission-approvals"), withDestinationURL: elsewhere
        )
        XCTAssertFalse(channel.isTrusted())
        XCTAssertFalse(channel.send(decision(for: wait())))
    }

    /// A planted FIFO or link never blocks nor redirects the receiver.
    func testOnlySmallRegularFilesAreRead() throws {
        channel.setListening(try XCTUnwrap(ProcessInstance.running(pid: getpid())))
        let fifo = wait()
        XCTAssertEqual(mkfifo(try XCTUnwrap(channel.decisionURL(requestID: fifo.requestID)).path, 0o600), 0)
        XCTAssertNil(channel.claimDecision(requestID: fifo.requestID), "returns at once")

        let linked = wait()
        let target = directory.appendingPathComponent("target.json")
        try JSONEncoder().encode(decision(for: linked)).write(to: target)
        try FileManager.default.createSymbolicLink(
            at: try XCTUnwrap(channel.decisionURL(requestID: linked.requestID)), withDestinationURL: target
        )
        XCTAssertNil(channel.claimDecision(requestID: linked.requestID))

        let large = wait()
        try Data(repeating: 0x20, count: 5_000).write(to: try XCTUnwrap(channel.decisionURL(requestID: large.requestID)))
        XCTAssertNil(channel.claimDecision(requestID: large.requestID))
    }

    // MARK: - Receiver wait

    /// Drives `waitForDecision` on a fake clock; `onPoll` runs at each
    /// sleep, like the app writing in the meantime.
    private func run(
        _ request: PermissionApprovalWait,
        abandonedAfter: Int? = nil,
        onPoll: (Int) -> Void = { _ in }
    ) -> (PermissionApproval.Outcome, polls: Int) {
        var clock = request.startedAt
        var polls = 0
        let outcome = request.waitForDecision(
            on: channel,
            now: { clock },
            sleep: { interval in
                XCTAssertLessThanOrEqual(interval, PermissionApproval.pollInterval)
                XCTAssertGreaterThan(interval, 0)
                clock += interval
                polls += 1
                onPoll(polls)
            },
            isAbandoned: { abandonedAfter.map { polls >= $0 } ?? false }
        )
        return (outcome, polls)
    }

    func testReceiverReturnsTheDecisionWrittenWhileItWaits() {
        let request = wait()
        let (outcome, polls) = run(request) { poll in
            if poll == 3 { self.channel.send(self.decision(for: request, .deny)) }
        }
        XCTAssertEqual(outcome, .deny)
        XCTAssertEqual(polls, 3)
        XCTAssertNil(channel.claimDecision(requestID: request.requestID), "consumed")
    }

    func testReceiverGivesUpAtTheDeadlineWithoutDeciding() {
        let request = wait()
        let (outcome, polls) = run(request)
        XCTAssertEqual(outcome, .expired)
        XCTAssertEqual(polls, Int((55 / PermissionApproval.pollInterval).rounded()), accuracy: 1)
    }

    func testDecisionWrittenAtTheLastInstantStillCounts() {
        let request = wait()
        let lastPoll = run(wait()).polls
        let (outcome, polls) = run(request) { poll in
            if poll == lastPoll { self.channel.send(self.decision(for: request)) }
        }
        XCTAssertEqual(outcome, .allow)
        XCTAssertEqual(polls, lastPoll, "written during the final sleep")
    }

    func testReceiverStopsWhenClaudeAbandonsTheHook() {
        let (outcome, polls) = run(wait(), abandonedAfter: 4)
        XCTAssertEqual(outcome, .expired)
        XCTAssertEqual(polls, 4)
    }

    func testReleaseDecidesNothing() {
        let request = wait()
        channel.send(decision(for: request, .release))
        XCTAssertEqual(run(request).0, .release)
    }

    func testDecisionForAnotherSessionColumnOrProtocolIsRejected() {
        for bad in [
            decision(for: wait(), session: "teammate"),
            decision(for: wait(), agent: "uuid-2"),
            decision(for: wait(), version: PermissionApproval.protocolVersion + 1)
        ] {
            let request = PermissionApprovalWait(
                requestID: bad.requestID, sessionID: "sess", agentUUID: "uuid-1", text: "ls", isSubagent: false,
                startedAt: 1_000, deadline: 1_055
            )
            channel.send(bad)
            XCTAssertEqual(run(request).0, .invalid, "\(bad)")
        }
    }

    /// A decision names one request: it can't answer another, nor twice.
    func testDecisionsCannotBeReplayed() throws {
        let first = wait()
        let second = wait()
        channel.send(decision(for: first))
        XCTAssertEqual(run(first).0, .allow)

        // The first decision, written again and copied under the second ID.
        channel.send(decision(for: first))
        let url = try XCTUnwrap(channel.decisionURL(requestID: second.requestID))
        try JSONEncoder().encode(decision(for: first)).write(to: url)
        XCTAssertEqual(run(second).0, .invalid, "a file under the second ID naming the first request")
        XCTAssertEqual(run(wait()).0, .expired, "the replayed first decision answers nobody else")
    }
}

// MARK: - Event, gate and session

extension PermissionApprovalTests {
    func testApprovalFieldsSurviveTheQueueAndOldLinesStillDecode() throws {
        let request = AgentHookEvent(
            kind: .claude, name: .permissionRequest, agentUUID: "uuid-1", sessionID: "sess",
            toolName: "Bash", toolSummary: "git push", agentID: "a1",
            approvalRequestID: "ID", approvalDeadline: 55, approvalText: "git push", timestamp: 1
        )
        let decoded = try JSONDecoder().decode(AgentHookEvent.self, from: JSONEncoder().encode(request))
        XCTAssertEqual(decoded, request)

        let old = #"{"kind":"claude","name":"permissionRequest","sessionID":"s","timestamp":1}"#
        let legacy = try JSONDecoder().decode(AgentHookEvent.self, from: Data(old.utf8))
        XCTAssertNil(legacy.approvalRequestID)
        XCTAssertNil(legacy.approvalDeadline)
        XCTAssertNil(legacy.approvalText)

        let resolved = AgentHookEvent.approvalResolved(request, outcome: .allow, now: 9)
        XCTAssertEqual(resolved.name, .approvalResolved)
        XCTAssertEqual(resolved.approvalRequestID, "ID")
        XCTAssertEqual(resolved.approvalOutcome, .allow)
        XCTAssertEqual(resolved.agentUUID, "uuid-1")
        XCTAssertEqual(resolved.sessionID, "sess")
        XCTAssertEqual(resolved.agentID, "a1")
        XCTAssertEqual(resolved.timestamp, 9)
        XCTAssertNil(ActivityEntry(event: resolved, workspaceTitle: "w", columnIndex: 0), "no feed row")
    }

    func testSidebarHoldsARequestOnlyWhenEverythingAllowsIt() {
        let shown = PermissionApprovalHold(cardShown: true, userSeesSidebar: true)
        func keeps(
            eligible: Bool = true, hold: PermissionApprovalHold? = nil,
            subagent: Bool = false, deadline: TimeInterval? = 100
        ) -> Bool {
            AgentHookCenter.keepsApproval(
                eligible: eligible, hold: hold ?? shown, isSubagent: subagent, deadline: deadline, now: 50
            )
        }
        XCTAssertTrue(keeps())
        XCTAssertTrue(keeps(subagent: true))
        XCTAssertFalse(keeps(eligible: false), "option off, or not the column's claude or session")
        XCTAssertFalse(keeps(hold: .never), "no card, or the column is on screen")
        XCTAssertFalse(keeps(deadline: nil))
        XCTAssertFalse(keeps(deadline: 51), "about to expire")
        XCTAssertFalse(keeps(deadline: 20), "replayed after its receiver left")
    }

    /// A background subagent's dialog waits for the hook: its request is
    /// held only while the user can see the buttons.
    func testSubagentRequestsNeedTheUserAtTheSidebar() {
        let unseen = PermissionApprovalHold(cardShown: true, userSeesSidebar: false)
        XCTAssertTrue(unseen.holds(isSubagent: false), "the main thread's dialog never waits")
        XCTAssertFalse(unseen.holds(isSubagent: true))
        let seen = PermissionApprovalHold(cardShown: true, userSeesSidebar: true)
        XCTAssertTrue(seen.holds(isSubagent: true))
        let noCard = PermissionApprovalHold(cardShown: false, userSeesSidebar: true)
        XCTAssertFalse(noCard.holds(isSubagent: false))
    }

    func testOnlyTheColumnsOwnClaudeMayBeAnsweredForItsSession() {
        let claude = ForegroundProcess(instance: ProcessInstance(pid: 700, startedAt: 70), name: "claude", arguments: ["claude"])
        var tracker = ClaudeSessionTracker()
        XCTAssertNil(tracker.approvableSessionID(emitter: .foregroundProcess, foregroundProcess: claude), "unbound")

        _ = tracker.admit(.sessionStart, sessionID: "lead", source: "startup", emitter: .foregroundProcess, foregroundProcess: claude)
        XCTAssertEqual(tracker.approvableSessionID(emitter: .foregroundProcess, foregroundProcess: claude), "lead")
        for emitter: ClaudeSessionTracker.Emitter in [.foregroundJob, .elsewhere, .unknown] {
            XCTAssertNil(tracker.approvableSessionID(emitter: emitter, foregroundProcess: claude), "\(emitter)")
        }
        // The foreground fires hooks itself: its children are job members.
        XCTAssertNil(tracker.approvableSessionID(emitter: .foregroundChild, foregroundProcess: claude))

        let replacement = ForegroundProcess(instance: ProcessInstance(pid: 701, startedAt: 71), name: "claude", arguments: ["claude"])
        XCTAssertNil(tracker.approvableSessionID(emitter: .foregroundProcess, foregroundProcess: replacement))
    }

    func testRealClaudeUnderALauncherMayBeAnswered() {
        let shim = ForegroundProcess(instance: ProcessInstance(pid: 700, startedAt: 70), name: "claude", arguments: ["claude"])
        var tracker = ClaudeSessionTracker()
        _ = tracker.admit(.sessionStart, sessionID: "lead", source: "startup", emitter: .foregroundChild, foregroundProcess: shim)
        XCTAssertEqual(tracker.approvableSessionID(emitter: .foregroundChild, foregroundProcess: shim), "lead")
    }
}
