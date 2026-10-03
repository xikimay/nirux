import AppKit
import XCTest
@testable import Nirux

final class PRFeedbackTests: XCTestCase {
    private func comment(
        _ login: String?, bot: Bool = false, association: String = "MEMBER", minimized: Bool = false,
        body: String = "Please fix", at createdAt: String
    ) -> [String: Any] {
        var node: [String: Any] = [
            "authorAssociation": bot ? "NONE" : association, "isMinimized": minimized, "body": body,
            "url": "https://github.com/o/r/pull/7#\(login ?? "ghost")-\(createdAt)", "createdAt": createdAt
        ]
        node["author"] = login.map { ["__typename": bot ? "Bot" : "User", "login": $0] } ?? NSNull()
        return node
    }

    private func thread(_ first: [String: Any], resolved: Bool = false, outdated: Bool = false,
                        line: Any = 12) -> [String: Any] {
        ["isResolved": resolved, "isOutdated": outdated, "path": "Sources/A.swift", "line": line,
         "comments": ["nodes": [first]]]
    }

    private func review(_ login: String, state: String = "COMMENTED", body: String = "Summary",
                        at createdAt: String) -> [String: Any] {
        var node = comment(login, body: body, at: createdAt)
        node["state"] = state
        return node
    }

    private func feedback(
        threads: [[String: Any]] = [],
        comments: [[String: Any]] = [],
        reviews: [[String: Any]] = [],
        viewer: String = "me",
        headCommittedAt: String = "2026-10-01T10:00:00Z"
    ) throws -> PRFeedback {
        let json: [String: Any] = ["data": [
            "viewer": ["login": viewer],
            "resource": [
                "author": ["login": "me"],
                "commits": ["nodes": [["commit": ["committedDate": headCommittedAt]]]],
                "reviewThreads": ["nodes": threads],
                "comments": ["nodes": comments],
                "reviews": ["nodes": reviews]
            ]
        ]]
        let data = try JSONSerialization.data(withJSONObject: json)
        return try XCTUnwrap(PRFeedbackReader.feedback(from: data))
    }

    private let pullRequest = PRInfo(
        number: 52, state: "OPEN", isDraft: true, ciStatus: nil, checks: [], reviewDecision: nil,
        mergeable: nil, url: "https://github.com/o/r/pull/52", additions: nil, deletions: nil, changedFiles: nil
    )

    // MARK: - What counts

    func testUnresolvedThreadsCountWhateverTheirAgeAndResolvedOnesDont() throws {
        let result = try feedback(threads: [
            thread(comment("alice", at: "2026-09-01T10:00:00Z")),
            thread(comment("claude", bot: true, at: "2026-09-02T10:00:00Z"), resolved: true)
        ])
        XCTAssertEqual(result.items.map(\.author), ["alice"])
        XCTAssertEqual(result.items.first?.location, "Sources/A.swift:12")
    }

    func testOutdatedThreadStillCountsAndSaysSo() throws {
        let result = try feedback(threads: [thread(comment("alice", at: "2026-09-01T10:00:00Z"), outdated: true, line: NSNull())])
        XCTAssertEqual(result.items.first?.isOutdated, true)
        XCTAssertEqual(result.items.first?.location, "Sources/A.swift")
    }

    func testTheAuthorsAndTheViewersOwnFeedbackNeverCounts() throws {
        let result = try feedback(
            threads: [thread(comment("me", at: "2026-10-01T12:00:00Z")), thread(comment("you", at: "2026-10-01T12:00:00Z"))],
            comments: [comment("me", at: "2026-10-01T12:00:00Z"), comment("you", at: "2026-10-01T12:00:00Z")],
            viewer: "you"
        )
        XCTAssertEqual(result.items, [])
    }

    func testOnlyRolesOnTheRepositoryAndBotsCount() throws {
        let result = try feedback(threads: [
            thread(comment("owner", association: "OWNER", at: "2026-09-01T10:00:00Z")),
            thread(comment("collaborator", association: "COLLABORATOR", at: "2026-09-01T10:00:00Z")),
            thread(comment("drive-by", association: "NONE", at: "2026-09-01T10:00:00Z")),
            thread(comment("past-contributor", association: "CONTRIBUTOR", at: "2026-09-01T10:00:00Z")),
            thread(comment(nil, association: "NONE", at: "2026-09-01T10:00:00Z")),
            thread(comment("claude", bot: true, at: "2026-09-01T10:00:00Z"))
        ])
        XCTAssertEqual(Set(result.items.map(\.author)), ["owner", "collaborator", "claude"])
    }

    func testMinimizedFeedbackNeverCounts() throws {
        let result = try feedback(
            threads: [thread(comment("alice", minimized: true, at: "2026-09-01T10:00:00Z"))],
            comments: [comment("bob", minimized: true, at: "2026-10-01T11:00:00Z")]
        )
        XCTAssertEqual(result.items, [])
    }

    func testBotIsTheGraphQLTypenameNotTheLogin() throws {
        let result = try feedback(threads: [
            thread(comment("claude", bot: true, at: "2026-09-01T10:00:00Z")),
            thread(comment("robot-fan", at: "2026-09-02T10:00:00Z"))
        ])
        XCTAssertEqual(result.botCount, 1)
        XCTAssertEqual(result.humanCount, 1)
        XCTAssertEqual(result.items.map(\.author), ["robot-fan", "claude"], "newest first")
    }

    // MARK: - Conversation cutoff

    func testConversationCommentCountsOnlyWhenNewerThanTheHeadCommit() throws {
        let result = try feedback(comments: [
            comment("alice", at: "2026-10-01T09:00:00Z"),
            comment("github-actions", bot: true, at: "2026-10-01T11:00:00Z")
        ])
        XCTAssertEqual(result.items.map(\.author), ["github-actions"])
        XCTAssertEqual(result.items.first?.location, "comment")
    }

    func testOurReplyDealsWithTheCommentsBeforeIt() throws {
        let afterComment = try feedback(comments: [
            comment("alice", at: "2026-10-01T11:00:00Z"),
            comment("me", at: "2026-10-01T12:00:00Z"),
            comment("bob", at: "2026-10-01T13:00:00Z")
        ])
        XCTAssertEqual(afterComment.items.map(\.author), ["bob"])
        let afterReview = try feedback(
            comments: [comment("alice", at: "2026-10-01T11:00:00Z")],
            reviews: [review("me", at: "2026-10-01T12:00:00Z")]
        )
        XCTAssertEqual(afterReview.items, [])
    }

    func testAnInlineReplysEmptyReviewDoesntMoveTheCutoff() throws {
        let result = try feedback(
            comments: [comment("alice", at: "2026-10-01T11:00:00Z")],
            reviews: [review("me", body: "", at: "2026-10-01T12:00:00Z")]
        )
        XCTAssertEqual(result.items.map(\.author), ["alice"])
    }

    func testReviewBodiesCountButNotPendingOrEmptyOnes() throws {
        let result = try feedback(reviews: [
            review("alice", at: "2026-10-01T11:00:00Z"),
            review("bob", state: "PENDING", at: "2026-10-01T11:00:00Z"),
            review("carol", state: "APPROVED", body: "", at: "2026-10-01T11:00:00Z")
        ])
        XCTAssertEqual(result.items.map(\.author), ["alice"])
    }

    func testExcerptIsTheFirstNonEmptyLine() throws {
        let result = try feedback(threads: [
            thread(comment("claude", bot: true, body: "\n  🔴 Crash on nil\n\n<details>", at: "2026-09-01T10:00:00Z"))
        ])
        XCTAssertEqual(result.items.first?.excerpt, "🔴 Crash on nil")
    }

    func testUnreadableAnswerIsNil() {
        XCTAssertNil(PRFeedbackReader.feedback(from: Data(#"{"data":{"resource":null}}"#.utf8)))
    }

    func testTheQueryGoesToThePullRequestsOwnHost() {
        let arguments = PRFeedbackReader.arguments(pullRequestURL: "https://ghe.example.com/o/r/pull/7")
        XCTAssertEqual(Array(arguments.prefix(4)), ["api", "graphql", "--hostname", "ghe.example.com"])
        XCTAssertEqual(arguments.last, "url=https://ghe.example.com/o/r/pull/7")
    }

    /// GitHub lists threads oldest first: past 100, the newest must stay.
    func testTheQueryReadsTheNewestThreads() {
        let arguments = PRFeedbackReader.arguments(pullRequestURL: "https://github.com/o/r/pull/7")
        XCTAssertTrue(arguments.contains { $0.contains("reviewThreads(last: 100)") })
    }

    // MARK: - Card and Address

    func testSummaryPutsHumansFirstAndHidesZeroes() throws {
        let both = try feedback(threads: [
            thread(comment("claude", bot: true, at: "2026-09-01T10:00:00Z")),
            thread(comment("alice", at: "2026-09-01T10:00:00Z"))
        ])
        XCTAssertEqual(both.summary, "💬 1 · 🤖 1")
        let bots = try feedback(threads: [thread(comment("claude", bot: true, at: "2026-09-01T10:00:00Z"))])
        XCTAssertEqual(bots.summary, "🤖 1")
        XCTAssertNil(PRFeedback(items: []).summary)
    }

    @MainActor
    func testCardShowsTheSummaryRowWithItsMenuActionAndHeight() {
        func info(summary: String?) -> WorkspaceInfo {
            WorkspaceInfo(
                id: "ws-1", index: 0, title: "t", profileID: WorkspaceProfile.defaultID, isInactive: false,
                columnCount: 0, focusedColumn: 0, gitBranch: nil, hasNotification: false, isActive: true,
                columns: [], prInfo: pullRequest, prFeedbackSummary: summary, diffStats: nil, purpose: nil,
                nextStep: nil, blocker: nil, phase: .active, lastSummary: nil, lastActivityAt: nil
            )
        }
        let workspace = info(summary: "💬 1 · 🤖 2")
        let result = SidebarWorkspaceCardRenderer(workspace: workspace, sidebarWidth: 260, padding: 20, yOffset: 400).render()

        let label = result.views.compactMap { $0 as? NSTextField }.first { $0.stringValue == "💬 1 · 🤖 2" }
        XCTAssertNotNil(label)
        XCTAssertTrue(result.hitAreas.contains {
            if case .link(let url, _) = $0.region { return url == "action:pr-feedback:ws-1" }
            return false
        })
        XCTAssertEqual(
            SidebarExpandedMetrics.workspaceHeight(for: workspace)
                - SidebarExpandedMetrics.workspaceHeight(for: info(summary: nil)),
            SidebarExpandedMetrics.prDetailAdvance
        )
    }

    @MainActor
    func testFeedbackIsDroppedWhenThePullRequestChangesOrCloses() throws {
        let workspace = WorkspaceState(title: "t", cwd: "/tmp")
        let feedback = try feedback(threads: [thread(comment("alice", at: "2026-09-01T10:00:00Z"))])
        workspace.prInfo = pullRequest
        workspace.prFeedback = feedback

        workspace.prInfo = pullRequest
        XCTAssertEqual(workspace.prFeedback, feedback, "the same open PR read again keeps it")

        workspace.prInfo = PRInfo(
            number: 52, state: "MERGED", isDraft: false, ciStatus: nil, checks: [], reviewDecision: nil,
            mergeable: nil, url: pullRequest.url, additions: nil, deletions: nil, changedFiles: nil
        )
        XCTAssertNil(workspace.prFeedback)

        workspace.prInfo = pullRequest
        workspace.prFeedback = feedback
        workspace.prInfo = nil
        XCTAssertNil(workspace.prFeedback)
    }

    @MainActor
    func testAddressPromptNamesTheItemsTheUserSaw() throws {
        let feedback = try feedback(threads: [
            thread(comment("claude", bot: true, at: "2026-09-02T10:00:00Z")),
            thread(comment("alice", at: "2026-09-01T10:00:00Z"))
        ])
        XCTAssertEqual(
            NiruxShellView.prFeedbackAddressPrompt(for: pullRequest, items: feedback.items),
            "/receiving-code-review Address this feedback on PR #52 (https://github.com/o/r/pull/52): "
                + "https://github.com/o/r/pull/7#claude-2026-09-02T10:00:00Z https://github.com/o/r/pull/7#alice-2026-09-01T10:00:00Z"
        )
    }

    @MainActor
    func testAddressIsRefusedWithoutAnIdleAgent() {
        func session(status: AgentStatus, dialog: AgentAttentionReason? = nil) -> RemoteAgentSession {
            RemoteAgentSession(
                id: "a", workspaceID: "w", workspaceTitle: "w", columnIndex: 0, displayName: "claude", cwd: "/",
                status: status, recentOutput: "", pendingDialog: dialog
            )
        }
        XCTAssertEqual(NiruxShellView.prFeedbackAddressRefusal(nil), "no Claude agent running")
        XCTAssertEqual(NiruxShellView.prFeedbackAddressRefusal(session(status: .working)), "the agent is working")
        XCTAssertEqual(
            NiruxShellView.prFeedbackAddressRefusal(session(status: .idle, dialog: .permission(tool: "Bash", summary: nil))),
            "the agent is waiting on a dialog"
        )
        XCTAssertNil(NiruxShellView.prFeedbackAddressRefusal(session(status: .idle)))
    }
}
