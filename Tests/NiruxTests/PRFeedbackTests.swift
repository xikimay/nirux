import XCTest
@testable import Nirux

final class PRFeedbackTests: XCTestCase {
    private func author(_ login: String, bot: Bool = false) -> [String: Any] {
        ["__typename": bot ? "Bot" : "User", "login": login]
    }

    private func comment(_ login: String, bot: Bool = false, body: String = "Please fix", at createdAt: String) -> [String: Any] {
        ["author": author(login, bot: bot), "body": body, "url": "https://github.com/o/r/pull/7#\(login)-\(createdAt)",
         "createdAt": createdAt]
    }

    private func thread(_ first: [String: Any], resolved: Bool = false, outdated: Bool = false,
                        line: Any = 12) -> [String: Any] {
        ["isResolved": resolved, "isOutdated": outdated, "path": "Sources/A.swift", "line": line,
         "comments": ["nodes": [first]]]
    }

    private func review(_ login: String, bot: Bool = false, state: String = "COMMENTED", body: String = "Summary",
                        at createdAt: String) -> [String: Any] {
        var node = comment(login, bot: bot, body: body, at: createdAt)
        node["state"] = state
        return node
    }

    private func feedback(
        threads: [[String: Any]] = [],
        comments: [[String: Any]] = [],
        reviews: [[String: Any]] = [],
        headCommittedAt: String = "2026-10-01T10:00:00Z"
    ) throws -> PRFeedback {
        let json: [String: Any] = ["data": ["resource": [
            "author": ["login": "me"],
            "commits": ["nodes": [["commit": ["committedDate": headCommittedAt]]]],
            "reviewThreads": ["nodes": threads],
            "comments": ["nodes": comments],
            "reviews": ["nodes": reviews]
        ]]]
        let data = try JSONSerialization.data(withJSONObject: json)
        return try XCTUnwrap(PRFeedbackReader.feedback(from: data))
    }

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

    func testTheAuthorsOwnThreadsAndCommentsNeverCount() throws {
        let result = try feedback(
            threads: [thread(comment("me", at: "2026-10-01T12:00:00Z"))],
            comments: [comment("me", at: "2026-10-01T12:00:00Z")]
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

    func testConversationCommentCountsOnlyWhenNewerThanTheHeadCommit() throws {
        let result = try feedback(comments: [
            comment("alice", at: "2026-10-01T09:00:00Z"),
            comment("github-actions", bot: true, at: "2026-10-01T11:00:00Z")
        ])
        XCTAssertEqual(result.items.map(\.author), ["github-actions"])
        XCTAssertEqual(result.items.first?.location, "comment")
    }

    func testAnAuthorReplyDealsWithTheCommentsBeforeIt() throws {
        let result = try feedback(comments: [
            comment("alice", at: "2026-10-01T11:00:00Z"),
            comment("me", at: "2026-10-01T12:00:00Z"),
            comment("bob", at: "2026-10-01T13:00:00Z")
        ])
        XCTAssertEqual(result.items.map(\.author), ["bob"])
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

    func testAddressPromptNamesThePullRequestAndTheScope() {
        let pullRequest = PRInfo(
            number: 52, state: "OPEN", isDraft: true, ciStatus: nil, failedCheckUrl: nil, reviewDecision: nil,
            mergeable: nil, url: "https://github.com/o/r/pull/52", additions: nil, deletions: nil, changedFiles: nil
        )
        XCTAssertEqual(
            PRFeedbackReader.addressPrompt(for: pullRequest, botsOnly: false),
            "/receiving-code-review Address the unresolved review threads and new comments on PR #52 (https://github.com/o/r/pull/52)."
        )
        XCTAssertEqual(
            PRFeedbackReader.addressPrompt(for: pullRequest, botsOnly: true),
            "/receiving-code-review Address the bots' unresolved review threads and new comments on PR #52 (https://github.com/o/r/pull/52)."
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
