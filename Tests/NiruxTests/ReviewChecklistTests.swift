import XCTest
@testable import Nirux

/// The review checklist (ReviewChecklist): the kinds a space's reviews keep
/// recording, given to the fork of each review as it starts, and the daily
/// pass's line when it stops reaching them.
final class ReviewChecklistTests: XCTestCase {
    private var state: URL!
    private let day: TimeInterval = 86_400
    private let now: TimeInterval = 1_800_000_000

    override func setUpWithError() throws {
        try super.setUpWithError()
        state = FileManager.default.temporaryDirectory.appendingPathComponent("nirux-checklist-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
        // Nirux saved workspace W1 in space S1.
        try Data(#"{"workspaces": [{"id": "W1", "profileID": "S1"}]}"#.utf8).write(to: state.appendingPathComponent("state.json"))
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: state)
        super.tearDown()
    }

    private let environment = ["NIRUX_WORKSPACE_ID": "W1", "NIRUX_PROFILE_ID": "S1"]

    private func entry(_ kinds: [String], task: String, pullRequest: Int? = nil, at time: TimeInterval) -> ReviewFindings.Entry {
        ReviewFindings.Entry(
            time: time, workspace: "W-" + task, task: task, pullRequest: pullRequest, round: 1,
            findings: kinds.map { ReviewFindings.Finding(kind: $0, text: "\($0) in \(task)") }
        )
    }

    private func record(_ entries: [ReviewFindings.Entry]) {
        for entry in entries { ReviewFindings.lines.append(entry, spaceID: "S1", stateDirectory: state) }
    }

    /// A fork of `skill` started: the file Claude Code writes beside the
    /// transcript, and the hook's payload.
    private func forkStarted(_ agent: String, skill: String?) throws -> [String: Any] {
        let transcript = state.appendingPathComponent("transcripts/session-1.jsonl")
        if let skill {
            let subagents = transcript.deletingPathExtension().appendingPathComponent("subagents")
            try FileManager.default.createDirectory(at: subagents, withIntermediateDirectories: true)
            try Data(#"{"skillName":"\#(skill)","effort":"low"}"#.utf8).write(to: subagents.appendingPathComponent("agent-\(agent).forked-skill.json"))
        }
        return [
            "hook_event_name": "SubagentStart", "session_id": "session-1", "transcript_path": transcript.path,
            "agent_id": agent, "agent_type": "general-purpose"
        ]
    }

    private func reaches() -> [ReviewChecklist.Reach] {
        ReviewChecklist.reaches.load(spaceID: "S1", stateDirectory: state)
    }

    /// The kinds seen in two tasks or more in the last 30 days, the most
    /// tasks first, each with its tasks (the latest first) and its latest
    /// finding.
    func testTheListKeepsKindsSeenInTwoTasks() throws {
        let entries = [
            entry(["unbounded-wait", "untested"], task: "feat/a", pullRequest: 1, at: now - 5 * day),
            entry(["unbounded-wait", "untested"], task: "feat/b", pullRequest: 2, at: now - 4 * day),
            entry(["unbounded-wait", "solo"], task: "feat/c", at: now - 3 * day),
            entry(["solo"], task: "feat/c", at: now - 2 * day),
            // A task seen first comes first once reviewed again.
            entry(["unbounded-wait"], task: "feat/a", pullRequest: 1, at: now - day),
            entry(["old-pair"], task: "feat/d", at: now - 31 * day),
            entry(["old-pair"], task: "feat/e", at: now - 31 * day)
        ]
        XCTAssertEqual(ReviewChecklist.text(entries, now: now), [
            ReviewChecklist.header,
            "- unbounded-wait · 3 tasks (#1, feat/c, #2) · latest: “unbounded-wait in feat/a”",
            "- untested · 2 tasks (#2, #1) · latest: “untested in feat/b”"
        ].joined(separator: "\n"))
        XCTAssertNil(ReviewChecklist.text(Array(entries.suffix(3)), now: now), "no kind in two tasks: no list")
    }

    func testTheListHoldsSevenKindsAndFiveTasksEach() throws {
        let tasks = (1...7).map { "feat/t\($0)" }
        let kinds = (1...9).map { "kind-\($0)" }
        let entries = tasks.enumerated().map { index, task in
            entry(index < 2 ? kinds : ["kind-1"], task: task, at: now - Double(10 - index) * day)
        }
        let lines = try XCTUnwrap(ReviewChecklist.text(entries, now: now)).components(separatedBy: "\n").dropFirst()
        XCTAssertEqual(lines.count, ReviewChecklist.maxKinds)
        XCTAssertEqual(lines.first, "- kind-1 · 7 tasks (feat/t7, feat/t6, feat/t5, feat/t4, feat/t3 and 2 more) · latest: “kind-1 in feat/t7”")
    }

    /// The fork of a review gets the list of its launch's space, else the
    /// one Nirux saved for its workspace, as its SubagentStart context. A
    /// code review's list is noted, a premortem's isn't (its starts aren't);
    /// the log's old lines stay for the app to trim.
    func testAReviewsForkGetsTheList() throws {
        XCTAssertTrue(AgentHookInstaller.claudeHookEvents.contains("SubagentStart"))
        let entries = [entry(["unbounded-wait"], task: "feat/a", at: now - day), entry(["unbounded-wait"], task: "feat/b", at: now - day)]
        record(entries)
        let old = ReviewChecklist.Reach(time: now - 40 * day, session: "old", kind: .started)
        ReviewChecklist.reaches.append(old, spaceID: "S1", stateDirectory: state, trims: false)
        let fork = try forkStarted("a1", skill: "code-review")
        let elsewhere = ["NIRUX_WORKSPACE_ID": "W1", "NIRUX_PROFILE_ID": "S-other"]
        XCTAssertNil(ReviewChecklist.subagentStartOutput(fork, environment: elsewhere, stateDirectory: state, now: now), "the launch's space first")
        let saved = ["NIRUX_WORKSPACE_ID": "W1"]
        let output = try XCTUnwrap(ReviewChecklist.subagentStartOutput(fork, environment: saved, stateDirectory: state, now: now))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: output) as? [String: Any])
        let hook = try XCTUnwrap(json["hookSpecificOutput"] as? [String: Any])
        XCTAssertEqual(hook["hookEventName"] as? String, "SubagentStart")
        XCTAssertEqual(hook["additionalContext"] as? String, ReviewChecklist.text(entries, now: now))
        XCTAssertNotNil(ReviewChecklist.subagentStartOutput(
            try forkStarted("a7", skill: "plugin:premortem"), environment: environment, stateDirectory: state, now: now + 1
        ))
        XCTAssertEqual(reaches(), [old, ReviewChecklist.Reach(time: now, session: "session-1", kind: .given)])
    }

    /// Any other subagent, a skill only named like a review, or a space
    /// whose switch is off: nothing given, nothing noted.
    func testOtherSubagentsGetNothing() throws {
        record([entry(["unbounded-wait"], task: "feat/a", at: now - day), entry(["unbounded-wait"], task: "feat/b", at: now - day)])
        let others: [(String, String?)] = [("a2", nil), ("a3", "simplify"), ("a4", "adversarial-review"), ("a6", "code-style-review")]
        for (agent, skill) in others {
            let payload = try forkStarted(agent, skill: skill)
            XCTAssertNil(ReviewChecklist.subagentStartOutput(payload, environment: environment, stateDirectory: state, now: now), agent)
        }
        var off = SpaceDefaults()
        off.reviewChecklist = false
        guard case .success = try XCTUnwrap(SpaceDefaultsStore(spaceID: "S1", stateDirectory: state)).save(off) else { return XCTFail("not saved") }
        let review = try forkStarted("a5", skill: "code-review")
        XCTAssertNil(ReviewChecklist.subagentStartOutput(review, environment: environment, stateDirectory: state, now: now))
        XCTAssertEqual(reaches(), [])
    }

    /// A /code-review start, typed or a Skill call run as a background fork,
    /// is noted while a list is due. Not `ultra` (the cloud), a foreground
    /// fork (no forked-skill file), a premortem (it may run inline), nor a
    /// prompt that only says "adversarial".
    func testReviewStartsAreNotedWhileAListIsDue() throws {
        let typed = AgentHookEvent(kind: .claude, name: .userPromptSubmit, sessionID: "session-1", reviewPasses: ["codeReview"])
        let note = { (event: AgentHookEvent, payload: [String: Any], time: TimeInterval) in
            ReviewChecklist.noteReviewStart(event, payload: payload, environment: self.environment, stateDirectory: self.state, now: time)
        }
        note(typed, ["prompt": "/code-review high"], now)
        XCTAssertEqual(reaches(), [], "no list due yet")
        record([entry(["unbounded-wait"], task: "feat/a", at: now - day), entry(["unbounded-wait"], task: "feat/b", at: now - day)])
        note(typed, ["prompt": "/code-review ultra 812"], now + 1)
        note(typed, ["prompt": "/code-review --comment ultra 926"], now + 1)
        let skill = { (pass: String) in
            AgentHookEvent(kind: .claude, name: .postToolUse, sessionID: "session-1", toolName: "Skill", reviewPasses: [pass])
        }
        note(skill("codeReview"), ["tool_input": ["skill": "code-review", "args": "ultra"]], now + 2)
        note(skill("premortem"), ["tool_input": ["skill": "premortem"]], now + 3)
        note(AgentHookEvent(kind: .claude, name: .userPromptSubmit, sessionID: "session-1", reviewPasses: ["adversarial"]), [:], now + 3)
        let foreground: [String: Any] = ["status": "forked", "agentId": "a1", "result": "No findings."]
        note(skill("codeReview"), ["tool_input": ["skill": "code-review", "args": "high"], "tool_response": foreground], now + 4)
        let background: [String: Any] = ["status": "forked", "background": true, "agentId": "a2"]
        note(skill("codeReview"), ["tool_input": ["skill": "code-review", "args": "high"], "tool_response": background], now + 5)
        note(typed, ["prompt": "/code-review"], now + 6)
        // A result that doesn't say how it ran counts: a new shape shows as a miss.
        note(skill("codeReview"), ["tool_input": ["skill": "code-review"], "tool_response": ["success": true]], now + 7)
        XCTAssertEqual(reaches().map(\.time), [now + 5, now + 6, now + 7])
    }

    /// Per session, a start counts as reached once a list was given there,
    /// before or after it. The digest gives the counts; only none reached in
    /// two sessions or more is news, and asks for a task.
    func testTheDailyPassSaysWhenTheListMissedAReviewer() {
        let window = DailyPass.Window(start: now - day, end: now)
        let reach = { (time: TimeInterval, session: String, kind: ReviewChecklist.Reach.Kind) in
            ReviewChecklist.Reach(time: time, session: session, kind: kind)
        }
        let reaches = [
            reach(now - 60, "s1", .given), reach(now - 59, "s1", .started),
            reach(now - 50, "s2", .started), reach(now - 40, "s3", .given),
            reach(now - 2 * day, "s4", .started)
        ]
        XCTAssertEqual(ReviewChecklist.reached(reaches, in: window), ReviewChecklist.Tally(reached: 1, started: 2, sessions: 2))

        var facts = DailyPass.Facts(
            spaceName: "Nirux", window: window, findings: [], repositories: [], triagedRuns: [], flakyTests: [], missions: [],
            proposals: [], briefRules: []
        )
        let task = "Start a task"
        for (reached, started, sessions) in [(1, 2, 2), (0, 2, 1)] {
            facts.checklistReach = ReviewChecklist.Tally(reached: reached, started: started, sessions: sessions)
            XCTAssertFalse(facts.hasNews, "a miss here and there")
            let text = DailyPass.digest(facts).text
            XCTAssertTrue(text.contains("- The review checklist reached \(reached) of \(started) /code-review starts in this window "
                + "(an approximate count: nothing to do)."), text)
            XCTAssertFalse(text.contains(task), text)
        }
        facts.checklistReach = ReviewChecklist.Tally(reached: 0, started: 3, sessions: 2)
        XCTAssertTrue(facts.hasNews, "none in two sessions: a broken hook")
        let broken = DailyPass.digest(facts).text
        XCTAssertTrue(broken.contains("- The review checklist reached none of 3 /code-review starts in this window, in 2 sessions: "), broken)
        XCTAssertTrue(broken.contains(task), broken)
        facts.checklistReach = ReviewChecklist.Tally(reached: 2, started: 2, sessions: 2)
        XCTAssertFalse(DailyPass.digest(facts).text.contains("## Review checklist"))
    }
}
