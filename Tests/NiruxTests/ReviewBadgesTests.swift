import AppKit
import XCTest
@testable import Nirux

@MainActor
final class ReviewBadgesTests: XCTestCase {
    private let env = ["NIRUX_AGENT_UUID": "uuid-1", "NIRUX_WORKSPACE_ID": "ws-1"]

    func testPromptStartingWithAReviewCommandRunsThatPass() {
        XCTAssertEqual(ReviewPass.passes(inPrompt: "/code-review"), [.codeReview])
        XCTAssertEqual(ReviewPass.passes(inPrompt: "  /premortem focus on the queue"), [.premortem])
        XCTAssertEqual(ReviewPass.passes(inPrompt: "/code-style-review\nthen fix"), [.codeStyleReview])
        XCTAssertEqual(ReviewPass.passes(inPrompt: "/plugin:code-review"), [.codeReview])
    }

    func testOnlyALeadingCommandCounts() {
        XCTAssertNil(ReviewPass.passes(inPrompt: "did we run /code-review in that session?"))
        XCTAssertNil(ReviewPass.passes(inPrompt: "/code-reviewer"))
        XCTAssertNil(ReviewPass.passes(inPrompt: "/clear"))
        XCTAssertNil(ReviewPass.passes(inPrompt: ""))
    }

    func testAnyMentionOfAdversarialRunsThatPass() {
        XCTAssertEqual(ReviewPass.passes(inPrompt: "/codex:adversarial-review --wait"), [.adversarial])
        XCTAssertEqual(ReviewPass.passes(inPrompt: "run an adverseriak review"), [.adversarial])
        XCTAssertEqual(ReviewPass.passes(inPrompt: "Fais une review ADVERSARIALE"), [.adversarial])
        XCTAssertEqual(ReviewPass.passes(inPrompt: "/code-review then adversarial"), [.codeReview, .adversarial])
    }

    func testSkillNamesItsPass() {
        XCTAssertEqual(ReviewPass.passes(inSkill: "code-review"), [.codeReview])
        XCTAssertEqual(ReviewPass.passes(inSkill: "plugin:premortem"), [.premortem])
        XCTAssertEqual(ReviewPass.passes(inSkill: "adversarial-review"), [.adversarial])
        XCTAssertNil(ReviewPass.passes(inSkill: "simplify"))
    }

    func testPromptSubmitCarriesItsPassesButNeverThePrompt() throws {
        let prompt = "/code-review secret-token-in-the-prompt"
        let event = try XCTUnwrap(AgentHookEvent(
            kind: .claude,
            payload: ["hook_event_name": "UserPromptSubmit", "session_id": "s", "prompt": prompt],
            env: env,
            now: 1
        ))
        XCTAssertEqual(event.reviewPasses, ["codeReview"])

        let line = try XCTUnwrap(String(data: JSONEncoder().encode(event), encoding: .utf8))
        XCTAssertFalse(line.contains("secret-token-in-the-prompt"))
        XCTAssertEqual(try JSONDecoder().decode(AgentHookEvent.self, from: Data(line.utf8)).reviewPasses, ["codeReview"])
    }

    func testSkillCallCarriesItsPass() {
        let skill = AgentHookEvent(
            kind: .claude,
            payload: [
                "hook_event_name": "PostToolUse",
                "tool_name": "Skill",
                "tool_input": ["skill": "premortem", "args": "x"]
            ],
            env: env,
            now: 1
        )
        XCTAssertEqual(skill?.reviewPasses, ["premortem"])
        XCTAssertEqual(skill?.passes, [.premortem])
        // Its start says nothing: a failed call ran nothing.
        let start = AgentHookEvent(
            kind: .claude, payload: ["hook_event_name": "PreToolUse", "tool_name": "Skill", "tool_input": ["skill": "premortem"]],
            env: env, now: 1
        )
        XCTAssertNil(start?.reviewPasses)
        // A main-thread Stop lists the subagents still at work (as Claude 2.1.325 sends `background_tasks`), not its shells.
        let stop = AgentHookEvent(
            kind: .claude,
            payload: ["hook_event_name": "Stop", "stop_hook_active": false, "background_tasks": [
                ["id": "a8216c90441fb4bd9", "type": "subagent", "status": "running", "description": "wait", "agent_type": "general-purpose"],
                ["id": "b00onxsi1", "type": "shell", "status": "running", "description": "Sleep", "command": "sleep 25"]
            ]],
            env: env, now: 1
        )
        XCTAssertEqual(stop?.backgroundAgents, ["a8216c90441fb4bd9"])
        let done = AgentHookEvent(
            kind: .claude, payload: ["hook_event_name": "Stop", "stop_hook_active": false, "background_tasks": [[String: Any]]()],
            env: env, now: 1
        )
        XCTAssertEqual(done?.backgroundAgents, [], "none at work any more")
        XCTAssertNil(skill?.backgroundAgents)

        let bash = AgentHookEvent(
            kind: .claude,
            payload: ["hook_event_name": "PostToolUse", "tool_name": "Bash", "tool_input": ["command": "/code-review"]],
            env: env,
            now: 1
        )
        XCTAssertNil(bash?.reviewPasses)

        let failedSkill = AgentHookEvent(
            kind: .claude,
            payload: ["hook_event_name": "PostToolUseFailure", "tool_name": "Skill", "tool_input": ["skill": "premortem"]],
            env: env,
            now: 1
        )
        XCTAssertNil(failedSkill?.reviewPasses, "a failed Skill call ran nothing")
    }

    func testPassRecordsTheHeadItRanOnAndGoesStaleAfterACommit() {
        let workspace = WorkspaceState(title: "reviews", cwd: "/tmp")
        XCTAssertNil(workspace.reviewBadges, "no pull request, no run: no row")

        workspace.updateGitContext(context(head: "aaa"))
        XCTAssertTrue(workspace.recordReviewPasses([.codeReview], head: "aaa", at: 10))
        XCTAssertEqual(workspace.reviewRuns[.codeReview], ReviewRun(head: "aaa", at: 10))
        XCTAssertEqual(workspace.reviewBadges?.isFresh(.codeReview), true)
        XCTAssertEqual(workspace.reviewBadges?.isFresh(.premortem), false)

        workspace.updateGitContext(context(head: "bbb"))
        XCTAssertEqual(workspace.reviewBadges?.isFresh(.codeReview), false)
    }

    func testAPassRecordsItsBranchAndCountsOnlyThere() {
        let workspace = WorkspaceState(title: "reviews", cwd: "/tmp")
        XCTAssertTrue(workspace.recordReviewPasses([.codeReview], head: "aaa", branch: "feat/x", at: 10))
        let run = ReviewRun(head: "aaa", at: 10, branch: "feat/x")
        XCTAssertEqual(workspace.reviewRuns[.codeReview], run)
        // It counts for the pull request of the branch it was recorded on, through a rebase or an amend (its commit
        // aside); not for another branch, nor where no branch is known.
        XCTAssertTrue(run.counts(onBranch: "feat/x"))
        XCTAssertFalse(run.counts(onBranch: "feat/y"))
        XCTAssertFalse(run.counts(onBranch: nil))
        XCTAssertFalse(ReviewRun(head: "aaa", at: 10).counts(onBranch: "feat/x"), "one recorded before Nirux kept the branch")
        XCTAssertFalse(ReviewRun(head: "aaa", at: 10).counts(onBranch: nil))
        let badges = ReviewBadges(runs: [.codeReview: run, .premortem: ReviewRun(head: "bbb", at: 11, branch: "feat/earlier")],
                                  head: "aaa", branch: "feat/x")
        XCTAssertEqual(badges.counted, [.codeReview: run])
        // A detached HEAD is on no branch.
        XCTAssertNil(GitContext(branch: "HEAD", identity: GitIdentity(repositoryRoot: "/tmp", head: "aaa")).branchName)
        XCTAssertEqual(GitContext(branch: "feat/x", identity: GitIdentity(repositoryRoot: "/tmp", head: "aaa")).branchName, "feat/x")
    }

    func testOlderReplayedEventDoesNotReplaceANewerRun() {
        let workspace = WorkspaceState(title: "reviews", cwd: "/tmp")
        workspace.recordReviewPasses([.codeReview], head: "bbb", at: 20)
        XCTAssertFalse(workspace.recordReviewPasses([.codeReview], head: "aaa", at: 10))
        XCTAssertEqual(workspace.reviewRuns[.codeReview], ReviewRun(head: "bbb", at: 20))
    }

    /// A pass runs from its own main-thread event until its column's main
    /// turn ends (a Stop that lists subagents at work makes it wait for
    /// each until its SubagentStop or a later Stop that no longer lists it),
    /// its session ends, or (`followReviewPasses`) its process exits: in the
    /// order events come, whatever git finds.
    func testAPassRunsFromItsEventUntilItsColumnsTurnEnds() {
        let workspace = WorkspaceState(title: "reviews", cwd: "/tmp")
        let column = UUID(), other = UUID()
        let now: TimeInterval = 1_000
        let event = { (name: AgentHookEvent.Name, passes: [String]?, agent: String?, notification: String?) in
            AgentHookEvent(kind: .claude, name: name, agentID: agent, notificationType: notification, reviewPasses: passes, timestamp: now - 1)
        }
        let typed = event(.userPromptSubmit, ["codeReview"], nil, nil)
        let stop = event(.stop, nil, nil, nil)
        let note = { (events: [AgentHookEvent], id: UUID) in
            for event in events { workspace.noteReviewPasses(of: event, in: id, now: now) }
        }
        let running = { workspace.reviewsRunning.map { "\($0.pass) \($0.column == column ? "A" : "B")" }.sorted() }
        // One drain: the pass, its turn's end, the next prompt.
        note([typed, stop, event(.userPromptSubmit, nil, nil, nil)], column)
        XCTAssertEqual(running(), [], "its turn ended within the drain")
        // Typed, then a message queued mid-turn: it still runs. Another column's end changes nothing.
        note([typed, event(.userPromptSubmit, nil, nil, nil)], column)
        note([stop], other)
        XCTAssertEqual(running(), ["codeReview A"])
        // The same pass in another column runs there too; each ends with its own column's turn.
        note([event(.postToolUse, ["codeReview"], nil, nil)], other)
        XCTAssertEqual(running(), ["codeReview A", "codeReview B"])
        note([stop], other)
        XCTAssertEqual(running(), ["codeReview A"])
        // Any failed turn there ends it, as do idle and the session's end; a subagent's events end and start nothing.
        note([event(.stopFailure, nil, "sub", nil), event(.postToolUse, ["premortem"], "sub", nil), event(.stop, nil, "sub", nil),
              event(.subagentStop, nil, "sub", nil)], column)
        XCTAssertEqual(running(), ["codeReview A"], "a subagent stopping mid-turn ends nothing")
        for end in [event(.stopFailure, nil, nil, nil), event(.notification, nil, nil, "idle_prompt"), event(.sessionEnd, nil, nil, nil)] {
            note([typed], column)
            note([end], column)
            XCTAssertEqual(running(), [], "\(end.name)")
        }
        // Run in the background: its Stop lists subagents at work; it waits for those, each gone at its SubagentStop or at a later
        // Stop that no longer lists it, whichever comes first (a lost SubagentStop can't keep it). One listed later, idle, a failed
        // turn or a permission asked meanwhile change nothing.
        let listing = { (ids: [String]) in
            var made = stop
            made.backgroundAgents = ids
            return made
        }
        note([event(.postToolUse, ["codeReview"], nil, nil), event(.notification, nil, nil, "permission_prompt"), listing(["a1", "a2"])],
             column)
        XCTAssertEqual(running(), ["codeReview A"])
        note([event(.subagentStop, nil, "a1", nil)], column)
        XCTAssertEqual(running(), ["codeReview A"], "a2 still at work")
        // a2 at work, another column's Stop listing none: neither ends the wait.
        note([event(.postToolUse, nil, "a2", nil)], column)
        note([listing([])], other)
        XCTAssertEqual(running(), ["codeReview A"])
        note([event(.notification, nil, nil, "idle_prompt"), event(.stopFailure, nil, nil, nil), listing(["a2", "a3"])], column)
        XCTAssertEqual(running(), ["codeReview A"])
        note([listing(["a3"])], column)
        XCTAssertEqual(running(), [], "a2 no longer listed, its SubagentStop lost; a3 isn't its own")
        note([event(.postToolUse, ["codeReview"], nil, nil), listing(["a1", "a2"]), event(.subagentStop, nil, "a1", nil)], column)
        XCTAssertEqual(running(), ["codeReview A"])
        note([event(.subagentStop, nil, "a2", nil)], column)
        XCTAssertEqual(running(), [], "both stopped")
        note([event(.postToolUse, ["codeReview"], nil, nil), listing([])], column)
        XCTAssertEqual(running(), [], "a Stop listing none ends it")
        // A replayed start says nothing; a replayed end ends all the same (nothing it ends can be newer).
        let replayed = AgentHookEvent(kind: .claude, name: .userPromptSubmit, reviewPasses: ["codeReview"], timestamp: now - 61)
        XCTAssertFalse(workspace.noteReviewPasses(of: replayed, in: column, now: now))
        note([typed], column)
        XCTAssertTrue(workspace.noteReviewPasses(of: AgentHookEvent(kind: .claude, name: .stop, timestamp: now - 120), in: column, now: now))
        // Its process: kept with it, then what the table says of it.
        let emitter = ProcessInstance(pid: 42, startedAt: 7)
        workspace.noteReviewPasses(
            of: AgentHookEvent(kind: .claude, name: .userPromptSubmit, emitterProcess: emitter, reviewPasses: ["codeReview"], timestamp: now),
            in: column, now: now
        )
        XCTAssertEqual(workspace.reviewsRunning, [RunningPass(pass: .codeReview, column: column, emitter: emitter)])
        XCTAssertFalse(workspace.followReviewPasses { _ in true })
        XCTAssertTrue(workspace.followReviewPasses { _ in false })
        XCTAssertEqual(running(), [])
    }

    func testRunsDecodeAsReadAndLegacyWorkspacesHaveNone() throws {
        let json = #"""
        {"title":"w","cwd":"/tmp","columns":[],"focusedColumnIndex":0,"isInactive":false,
         "lastSummaryIsManual":false,
         "reviewRuns":{"codeReview":{"head":"aaa","at":10},"futurePass":{"head":"bbb","at":11,"branch":"feat/x"}}}
        """#
        let persisted = try JSONDecoder().decode(PersistedWorkspace.self, from: Data(json.utf8))
        XCTAssertEqual(persisted.reviewRuns?["codeReview"], ReviewRun(head: "aaa", at: 10), "one from before the branch: none")
        XCTAssertEqual(persisted.reviewRuns?["futurePass"], ReviewRun(head: "bbb", at: 11, branch: "feat/x"))
        XCTAssertEqual(persisted.reviewRuns?.count, 2, "kept as read")

        let legacy = try JSONDecoder().decode(PersistedWorkspace.self, from: Data(#"""
        {"title":"w","cwd":"/tmp","columns":[],"focusedColumnIndex":0}
        """#.utf8))
        XCTAssertNil(legacy.reviewRuns)

        let malformed = try JSONDecoder().decode(PersistedWorkspace.self, from: Data(#"""
        {"title":"w","cwd":"/tmp","columns":[],"focusedColumnIndex":0,"reviewRuns":{"codeReview":"aaa"}}
        """#.utf8))
        XCTAssertNil(malformed.reviewRuns, "badges only: never a reason to lose the workspace")
        XCTAssertEqual(malformed.title, "w")
    }

    /// The selected card shows the passes under its chips; the others keep
    /// two lines.
    func testSelectedCardShowsTheRow() throws {
        let badges = ReviewBadges(
            runs: [.codeReview: ReviewRun(head: "aaa", at: 0), .premortem: ReviewRun(head: "old1234567", at: 0)],
            head: "aaa"
        )
        let workspace = makeWorkspaceInfo(reviewBadges: badges)
        XCTAssertEqual(
            SidebarExpandedMetrics.workspaceHeight(for: workspace, sidebarWidth: 260)
                - SidebarExpandedMetrics.workspaceHeight(for: makeWorkspaceInfo(), sidebarWidth: 260),
            SidebarExpandedMetrics.actionBlockHeight([.reviewBadges(badges)], width: 224, textWidth: 208)
        )

        let labels = SidebarWorkspaceCardRenderer(workspace: workspace, sidebarWidth: 260, yOffset: 400)
            .render().views.compactMap { $0 as? NSTextField }
        let row = try XCTUnwrap(labels.first { $0.stringValue == "CR ✓  PM ✓  CS ·  ADV ·" })
        let toolTip = try XCTUnwrap(row.toolTip)
        XCTAssertTrue(toolTip.contains("Premortem: ran"))
        XCTAssertTrue(toolTip.contains("on old1234, not the current HEAD"))
        XCTAssertTrue(toolTip.contains("Adversarial review: not run"))

        let other = makeWorkspaceInfo(reviewBadges: badges, isActive: false)
        XCTAssertEqual(
            SidebarExpandedMetrics.workspaceHeight(for: other, sidebarWidth: 260),
            SidebarExpandedMetrics.workspaceHeight(for: makeWorkspaceInfo(isActive: false), sidebarWidth: 260)
        )
    }

    private func context(head: String) -> GitContext {
        GitContext(branch: "feat/x", identity: GitIdentity(repositoryRoot: "/tmp", head: head))
    }

    private func makeWorkspaceInfo(reviewBadges: ReviewBadges? = nil, isActive: Bool = true) -> WorkspaceInfo {
        WorkspaceInfo(
            id: "workspace", index: 0, title: "reviews", profileID: WorkspaceProfile.defaultID,
            isInactive: false, columnCount: 0, focusedColumn: 0, gitBranch: nil, notification: nil,
            isActive: isActive, columns: [], prInfo: nil, diffStats: nil, purpose: nil, nextStep: nil,
            blocker: nil, phase: .active, lastSummary: nil, lastActivityAt: nil, reviewBadges: reviewBadges
        )
    }
}
