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

    func testOlderReplayedEventDoesNotReplaceANewerRun() {
        let workspace = WorkspaceState(title: "reviews", cwd: "/tmp")
        workspace.recordReviewPasses([.codeReview], head: "bbb", at: 20)
        XCTAssertFalse(workspace.recordReviewPasses([.codeReview], head: "aaa", at: 10))
        XCTAssertEqual(workspace.reviewRuns[.codeReview], ReviewRun(head: "bbb", at: 20))
    }

    func testRunsDecodeAsReadAndLegacyWorkspacesHaveNone() throws {
        let json = #"""
        {"title":"w","cwd":"/tmp","columns":[],"focusedColumnIndex":0,"isInactive":false,
         "lastSummaryIsManual":false,
         "reviewRuns":{"codeReview":{"head":"aaa","at":10},"futurePass":{"head":"bbb","at":11}}}
        """#
        let persisted = try JSONDecoder().decode(PersistedWorkspace.self, from: Data(json.utf8))
        XCTAssertEqual(persisted.reviewRuns?["codeReview"], ReviewRun(head: "aaa", at: 10))
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

    func testCardShowsTheRowUnderItsMetadata() throws {
        let badges = ReviewBadges(
            runs: [.codeReview: ReviewRun(head: "aaa", at: 0), .premortem: ReviewRun(head: "old1234567", at: 0)],
            head: "aaa"
        )
        let workspace = makeWorkspaceInfo(reviewBadges: badges)
        XCTAssertEqual(
            SidebarExpandedMetrics.workspaceHeight(for: workspace)
                - SidebarExpandedMetrics.workspaceHeight(for: makeWorkspaceInfo()),
            SidebarExpandedMetrics.reviewAdvance
        )

        let labels = SidebarWorkspaceCardRenderer(workspace: workspace, sidebarWidth: 260, padding: 20, yOffset: 400)
            .render().views.compactMap { $0 as? NSTextField }
        let row = try XCTUnwrap(labels.first { $0.stringValue == "CR ✓  PM ✓  CS ·  ADV ·" })
        let toolTip = try XCTUnwrap(row.toolTip)
        XCTAssertTrue(toolTip.contains("Premortem: ran"))
        XCTAssertTrue(toolTip.contains("on old1234, not the current HEAD"))
        XCTAssertTrue(toolTip.contains("Adversarial review: not run"))
    }

    private func context(head: String) -> GitContext {
        GitContext(branch: "feat/x", identity: GitIdentity(repositoryRoot: "/tmp", head: head))
    }

    private func makeWorkspaceInfo(reviewBadges: ReviewBadges? = nil) -> WorkspaceInfo {
        WorkspaceInfo(
            id: "workspace", index: 0, title: "reviews", profileID: WorkspaceProfile.defaultID,
            isInactive: false, columnCount: 0, focusedColumn: 0, gitBranch: nil, hasNotification: false,
            isActive: true, columns: [], prInfo: nil, diffStats: nil, purpose: nil, nextStep: nil,
            blocker: nil, phase: .active, lastSummary: nil, lastActivityAt: nil, reviewBadges: reviewBadges
        )
    }
}
