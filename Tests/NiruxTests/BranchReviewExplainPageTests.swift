import XCTest
@testable import Nirux

/// What the page shows of Explain (docs/branch-review.md, sections 2, 3
/// and 4.3): Claude's groups replace the path groups without hiding a
/// file, summaries say when their file changed since, and the bar counts
/// what the next Explain sends.
final class BranchReviewExplainPageTests: XCTestCase {
    /// Claude's groups in its order, most important file first. A path the
    /// branch doesn't have is dropped, a file in two groups stays in the
    /// first, what no group places goes to "Other changes"; what isn't
    /// committed and the folded groups stay as they were.
    func testExplainedGroupsFollowClaudeAndKeepEveryFile() {
        let snapshot = Self.snapshot()
        var explanation = Self.explanation()
        explanation.groups = [
            .init(intent: .feature, title: "Keep the Mac awake", paths: ["Sources/B.swift", "Sources/Gone.swift", "Sources/A.swift"]),
            .init(intent: .behaviorChange, title: "Hidden spaces tick", paths: ["Sources/A.swift", "Tests/ATests.swift"]),
            .init(intent: .refactor, title: "Untracked", paths: ["Sources/New.swift"]),
            .init(intent: .config, title: "Lockfile", paths: ["Package.resolved"]),
            // One intent and title: one group, keyed once.
            .init(intent: .feature, title: "Keep the Mac awake", paths: ["Sources/C.swift"])
        ]
        explanation.files["Sources/A.swift"] = .init(patchHash: "hA", summary: "A.", importance: 3)
        explanation.files["Sources/B.swift"] = .init(patchHash: "hB", summary: "B.", importance: 1)
        let page = BranchReview.page(for: snapshot, handover: nil, explanation: explanation)
        let paths = page.groups.map { $0.files.map { page.files[$0].path } }
        XCTAssertEqual(page.groups.map(\.key), [
            "uncommitted", "intent.feature.Keep the Mac awake", "intent.behaviorChange.Hidden spaces tick", "folded.lockfile"
        ])
        XCTAssertEqual(page.groups.map(\.intent), [nil, "feature", "behaviorChange", nil])
        XCTAssertEqual(paths, [
            ["Sources/New.swift"], ["Sources/A.swift", "Sources/B.swift", "Sources/C.swift"], ["Tests/ATests.swift"],
            ["Package.resolved"]
        ])

        explanation.groups.removeLast()
        let others = BranchReview.page(for: snapshot, handover: nil, explanation: explanation)
        XCTAssertEqual(others.groups.map(\.key).dropLast().last, "intent.other")
        XCTAssertEqual(others.groups.first { $0.key == "intent.other" }?.title, "Other changes")
        XCTAssertEqual(others.groups.first { $0.key == "intent.other" }?.files.map { others.files[$0].path }, ["Sources/C.swift"])

        // Before Explain, or without groups: the path groups.
        let unexplained = BranchReview.page(for: snapshot, handover: nil, explanation: nil)
        XCTAssertEqual(unexplained.groups.map(\.key), ["uncommitted", "code", "tests", "folded.lockfile"])
        XCTAssertEqual(unexplained.groups.compactMap(\.intent), [])
        XCTAssertNil(unexplained.explanation)
    }

    /// A summary is its file's current patch's, or marked outdated: the
    /// file changed since Claude read it. A patch not read isn't known to
    /// have changed.
    func testSummariesSayWhenTheirFileChangedSince() {
        let snapshot = Self.snapshot { files in
            files[3].patchHash = nil
            files[3].omission = .notRead
        }
        var explanation = Self.explanation()
        explanation.files["Tests/ATests.swift"] = .init(patchHash: "hT", summary: "Tests.", importance: 1)
        explanation.files["Sources/A.swift"] = .init(patchHash: "hA", summary: "Current.", importance: 2)
        explanation.files["Sources/B.swift"] = .init(patchHash: "old", summary: "Older.", importance: 1)
        explanation.files["Sources/C.swift"] = .init(patchHash: "old", summary: nil, importance: nil, notSent: "diff too large to send")
        let files = BranchReview.page(for: snapshot, handover: nil, explanation: explanation).files
        let byPath = Dictionary(uniqueKeysWithValues: files.map { ($0.path, $0) })
        XCTAssertEqual(byPath["Sources/A.swift"]?.summary, "Current.")
        XCTAssertEqual(byPath["Sources/A.swift"]?.summaryIsOutdated, false)
        XCTAssertEqual(byPath["Tests/ATests.swift"]?.summary, "Tests.")
        XCTAssertEqual(byPath["Tests/ATests.swift"]?.summaryIsOutdated, false)
        XCTAssertEqual(byPath["Sources/B.swift"]?.summary, "Older.")
        XCTAssertEqual(byPath["Sources/B.swift"]?.summaryIsOutdated, true)
        XCTAssertNil(byPath["Sources/C.swift"]?.summary)
        XCTAssertEqual(byPath["Sources/C.swift"]?.summaryIsOutdated, false)
    }

    /// The claims the code doesn't match, with their evidence; matching
    /// ones only counted. The overview says which head and model it read.
    func testTheExplanationShowsWhatDoesntMatchAndCountsTheRest() throws {
        var explanation = Self.explanation()
        explanation.claims = [
            .init(claim: "Grace of 60 s.", verdict: .matches, evidence: "KeepAwake.swift"),
            .init(claim: "Released on quit.", verdict: .partly, evidence: "Not in the background."),
            .init(claim: "No new setting.", verdict: .contradicts, evidence: "Persistence.swift adds one."),
            .init(claim: "Documented.", verdict: .notInDiff, evidence: "No doc changed.")
        ]
        explanation.questions = ["Why 60 s?"]
        let shown = try XCTUnwrap(BranchReview.page(for: Self.snapshot(), handover: nil, explanation: explanation).explanation)
        XCTAssertEqual(shown.claims.map(\.verdict), ["partly", "contradicts", "notInDiff"])
        XCTAssertEqual(shown.claims.first, .init(claim: "Released on quit.", verdict: "partly", evidence: "Not in the background."))
        XCTAssertEqual(shown.matching, 1)
        XCTAssertEqual(shown.questions, ["Why 60 s?"])
        XCTAssertEqual(shown.model, "Opus 5.5")
        XCTAssertTrue(shown.isCurrent)

        explanation.head = String(repeating: "e", count: 40)
        XCTAssertEqual(BranchReview.page(for: Self.snapshot(), handover: nil, explanation: explanation).explanation?.isCurrent, false)
        // Files only, no overview: nothing to show above the author's text.
        explanation.overview = ""
        XCTAssertNil(BranchReview.page(for: Self.snapshot(), handover: nil, explanation: explanation).explanation)
    }

    /// The bar counts what the next Explain sends: every file the first
    /// time, then the changed ones; untracked files only when included.
    /// Today's runs are summed, "at least" when one stopped.
    func testTheBarCountsWhatTheNextExplainSends() {
        let snapshot = Self.snapshot()
        var bar = BranchReview.explainBar(.init(), snapshot: snapshot, explanation: nil)
        XCTAssertFalse(bar.explained)
        // A, B, C and the test; the lockfile is folded, the new file untracked.
        XCTAssertEqual(bar.sendable, 4)
        XCTAssertEqual(bar.untracked, 1)
        XCTAssertNil(bar.usage)

        var explanation = Self.explanation()
        for file in snapshot.files { explanation.files[file.path] = .init(patchHash: file.patchHash ?? "", summary: "S.", importance: 1) }
        explanation.files["Sources/B.swift"]?.patchHash = "old"
        let now = Date()
        explanation.runs = [
            Self.run(date: now, tokens: 1000, cost: 0.5, isComplete: true),
            Self.run(date: now, tokens: 500, cost: nil, isComplete: false),
            Self.run(date: now.addingTimeInterval(-3 * 86_400), tokens: 9000, cost: 2, isComplete: true)
        ]
        bar = BranchReview.explainBar(.init(), snapshot: snapshot, explanation: explanation, now: now)
        XCTAssertTrue(bar.explained)
        XCTAssertEqual(bar.changed, 1)
        XCTAssertEqual(bar.unexplained, 0)
        XCTAssertEqual(bar.usage, .init(runs: 2, tokens: 1500, costUSD: 0.5, isComplete: false))

        var including = BranchReview.Page.ExplainBar()
        including.includeUntracked = true
        explanation.files["Sources/New.swift"] = nil
        bar = BranchReview.explainBar(including, snapshot: snapshot, explanation: explanation, now: now)
        XCTAssertEqual(bar.sendable, 5)
        XCTAssertEqual(bar.changed, 1)
        XCTAssertEqual(bar.unexplained, 1)

        // What Explain kept only for files gone from the branch counts as
        // nothing explained.
        var gone = BranchReview.Explanation()
        gone.files["Sources/Gone.swift"] = .init(patchHash: "h", summary: "S.", importance: 1)
        XCTAssertFalse(BranchReview.explainBar(.init(), snapshot: snapshot, explanation: gone).explained)
    }

    /// Explain is disabled with the reason: no claude, one too old to
    /// confine its runs, an account that can't be read or isn't logged in.
    func testAvailabilitySaysWhyExplainCantRun() {
        let cli = BranchReview.ClaudeCLI(path: "/opt/claude")
        let account = BranchReview.ExplainAccount(isLoggedIn: true, method: "claude.ai", subscription: "max", email: "a@b.c")
        func check(_ located: BranchReview.ClaudeCLI.Located, _ found: BranchReview.ExplainAccount?) -> BranchReview.ExplainAvailability {
            BranchReview.ExplainAvailability.check(locate: { located }, account: { _ in found })
        }
        XCTAssertEqual(check(.ready(cli), account), .ready(cli, account))
        XCTAssertEqual(
            check(.missing, nil), .unavailable("Explain runs Claude Code, and Nirux found no claude. Install it, then Refresh.")
        )
        XCTAssertEqual(check(.tooOld(["/usr/local/bin/claude"]), nil), .unavailable(
            "Explain needs Claude Code 2.1.284 or later: the claude at /usr/local/bin/claude is older. Update it, then Refresh."
        ))
        XCTAssertEqual(check(.unknown(["/x/claude"]), nil), .unavailable("Nirux couldn’t check the claude at /x/claude. Refresh to try again."))
        XCTAssertEqual(
            check(.ready(cli), nil), .unavailable("Nirux couldn’t read claude’s account (claude auth status). Refresh to try again.")
        )
        let loggedOut = BranchReview.ExplainAccount(isLoggedIn: false, method: "none", subscription: nil, email: nil)
        XCTAssertEqual(
            check(.ready(cli), loggedOut), .unavailable("claude isn’t logged in. Run claude in a terminal and log in, then Refresh.")
        )
    }

    /// How an Explain ended, in words that say what to do next.
    func testEndingsSayWhatToDoNext() {
        typealias Ending = BranchReview.ExplainResult.Ending
        XCTAssertNil(Ending.explained.message)
        XCTAssertEqual(Ending.cantKeep("Read-only.").message, "Read-only.")
        XCTAssertEqual(Ending.stopped(.usageLimit(resetsAt: nil)).message, "Claude’s usage limit is reached.")
        XCTAssertEqual(
            Ending.stopped(.cancelled).message, "Explain stopped. What Claude finished is kept; Explain again sends the rest."
        )
        XCTAssertEqual(Ending.stopped(.failed(.overloaded)).message, BranchReview.ExplainFailure.overloaded.message)
        XCTAssertEqual(BranchReview.ExplainSettings.displayName(of: "claude-opus-5-5"), "Opus 5.5")
        XCTAssertEqual(BranchReview.ExplainSettings.displayName(of: "claude-haiku-4-5-20251001"), "Haiku 4.5")
        XCTAssertEqual(BranchReview.ExplainSettings.displayName(of: "opus"), "opus")
    }

    // MARK: - Fixtures

    /// Three code files, a test, a folded lockfile and an untracked file.
    static func snapshot(
        branch: String = "feat/keep-awake", head: String = String(repeating: "a", count: 40),
        adjusting adjust: (inout [BranchReview.FileChange]) -> Void = { _ in }
    ) -> BranchReview.Snapshot {
        func file(_ path: String, _ hash: String, additions: Int) -> BranchReview.FileChange {
            var file = BranchReview.FileChange(path: path, status: .modified)
            file.additions = additions
            file.patchHash = hash
            file.hunks = [.init(oldStart: 1, oldCount: 1, newStart: 1, newCount: 1, section: "", lines: [
                .init(kind: .removed, text: "a"), .init(kind: .added, text: "b")
            ])]
            return file
        }
        var lockfile = file("Package.resolved", "hL", additions: 4)
        lockfile.fold = .lockfile
        var untracked = file("Sources/New.swift", "hN", additions: 6)
        untracked.status = .added
        untracked.isUntracked = true
        untracked.isUncommitted = true
        var files = [
            file("Sources/A.swift", "hA", additions: 10), file("Sources/B.swift", "hB", additions: 30),
            file("Sources/C.swift", "hC", additions: 20), file("Tests/ATests.swift", "hT", additions: 40), lockfile, untracked
        ]
        adjust(&files)
        return BranchReview.Snapshot(
            root: "/repo", branch: branch, head: head,
            base: .init(name: "main", ref: "refs/remotes/origin/main", mergeBase: String(repeating: "c", count: 40)),
            pullRequest: .notFound, fetchProblem: nil, upstream: nil, pullRequestHead: nil, hasUncommittedChanges: true,
            commits: [], files: files, testsAgainstCode: BranchReview.TestsAgainstCode()
        )
    }

    static func explanation() -> BranchReview.Explanation {
        var explanation = BranchReview.Explanation()
        explanation.overview = "Keeps the Mac awake while agents work."
        explanation.head = String(repeating: "a", count: 40)
        explanation.model = "claude-opus-5-5"
        return explanation
    }

    static func run(date: Date, tokens: Int, cost: Double?, isComplete: Bool) -> BranchReview.Explanation.RunEntry {
        .init(
            date: date, head: "h", model: "claude-opus-5-5", effort: "medium", outcome: isComplete ? "explained" : "cancelled",
            inputTokens: tokens, cacheReadTokens: 0, cacheCreationTokens: 0, outputTokens: 0, costUSD: cost,
            isComplete: isComplete, duration: 60, files: 1
        )
    }
}
