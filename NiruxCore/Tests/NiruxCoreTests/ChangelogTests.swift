import Foundation
import NiruxCore
import Testing

struct ChangelogTests {
    typealias Entry = Changelog.Entry

    @Test(arguments: [
        ("feat/pin-columns", [String](), ["Sources/Nirux/Views/Strip.swift", "Tests/NiruxTests/StripTests.swift"], Changelog.Kind.better),
        ("fix/hidden-quit", [], ["Sources/Nirux/NiruxApp.swift"], .fixed),
        ("feat/canary-replay", [], ["scripts/canary/run.py", "Tests/NiruxTests/CanaryTests.swift", "docs/design/canary.md"], .internal),
        ("feat/core-ledger", [], ["NiruxCore/Sources/NiruxCore/UsageLedger.swift"], .better),
        ("feat/app-icon", [], ["Resources/AppIcon.icns"], .better),
        ("ci/one-run-per-train", [], [".github/workflows/tests.yml", "Sources/Nirux/Model/MergeQueue.swift"], .internal),
        ("test/stand-in", [], ["Sources/Nirux/Model/AgentStandIn.swift"], .internal),
        ("fix/flaky-wait", [], ["Tests/NiruxTests/WaitUntil.swift"], .internal),
        ("feat/budgets", ["new"], ["Sources/Nirux/Model/TaskBudget.swift"], .new),
        ("feat/budgets", ["new", "internal"], ["Sources/Nirux/Model/TaskBudget.swift"], .internal),
        ("fix/docs-typo", ["new"], ["docs/getting-started.md"], .new),
        ("fixes", [], [], .better),
        ("feat/sidebar-crash", ["fixed"], ["Sources/Nirux/Views/SidebarView.swift"], .fixed),
        ("feat/libghostty-2-3", [], ["Package.swift", "Package.resolved"], .better),
    ])
    func kind(branch: String, labels: [String], paths: [String], expected: Changelog.Kind) {
        #expect(Changelog.kind(branch: branch, labels: Set(labels), paths: paths) == expected)
    }

    @Test func whyReadsTheSectionElseTheFirstParagraph() {
        #expect(PullRequestBody.why("## Why\nColumns moved only\nthrough menus.\n\n## How\n- a swipe", maxLength: 300)
            == "Columns moved only through menus.")
        #expect(PullRequestBody.why("\n\nNo heading here,\njust text.\n\nSecond paragraph.", maxLength: 300) == "No heading here, just text.")
        #expect(PullRequestBody.why("## why\n\u{1B}[31mred\u{1B}[0m and long text", maxLength: 12) == "[31mred[0m…")
        #expect(PullRequestBody.why("## Why\n## How\n- x", maxLength: 300) == nil)
    }

    @Test func entriesFromGitHubCountTheRidersOfATrainAndOnlyTheLandedOnes() throws {
        let json = """
        [
          {"number": 875, "title": "Train: #827", "body": "Merge train", "headRefName": "nirux-train/manual-20261125T2041",
           "labels": [], "files": [{"path": "Sources/Nirux/A.swift"}], "mergeCommit": {"oid": "main1"}},
          {"number": 827, "title": "Columns: two fingers slide the strip", "body": "## Why\\nOnly menus moved columns.\\n## How\\n- swipe",
           "headRefName": "feat/trackpad-gestures", "labels": [{"name": "new"}], "files": [{"path": "Sources/Nirux/B.swift"}],
           "mergeCommit": {"oid": "side1"}},
          {"number": 818, "title": "CI: one full test run per train", "body": null, "headRefName": "ci/one-run-per-train",
           "labels": null, "files": [{"path": ".github/workflows/tests.yml"}], "mergeCommit": {"oid": "side2"}},
          {"number": 801, "title": "Landed before the previous nightly", "body": "", "headRefName": "fix/old",
           "labels": [], "files": [], "mergeCommit": {"oid": "older"}},
          {"number": 799, "title": "Closed without merge", "body": "", "headRefName": "fix/never", "labels": [], "files": [],
           "mergeCommit": null}
        ]
        """
        let entries = try #require(Changelog.entries(fromPullRequests: Data(json.utf8), commits: ["main1", "side1", "side2"], build: 202611252041))
        #expect(entries == [
            Entry(pullRequest: 827, title: "Columns: two fingers slide the strip", why: "Only menus moved columns.", kind: .new, build: 202611252041),
            Entry(pullRequest: 818, title: "CI: one full test run per train", why: nil, kind: .internal, build: 202611252041),
        ])
        #expect(Changelog.entries(fromPullRequests: Data("{}".utf8), commits: [], build: 1) == nil)
    }

    @Test func addingReplacesAPullRequestAndDropsOldBuilds() {
        let old = Changelog(entries: [
            Entry(pullRequest: 900, title: "Kept", why: nil, kind: .fixed, build: 202611241000),
            Entry(pullRequest: 901, title: "First try", why: nil, kind: .better, build: 202611241000),
            Entry(pullRequest: 700, title: "Too old", why: nil, kind: .new, build: 202608011000),
        ])
        let added = [
            Entry(pullRequest: 903, title: "Fix", why: nil, kind: .fixed, build: 202611251854),
            Entry(pullRequest: 901, title: "Again", why: nil, kind: .better, build: 202611251854),
            Entry(pullRequest: 902, title: "New", why: nil, kind: .new, build: 202611251854),
        ]
        let merged = old.adding(added, through: "dc3366a0", keepingBuildsFrom: 202608271854)
        #expect(merged.entries.map(\.pullRequest) == [902, 901, 903, 900])
        #expect(merged.entries[1].title == "Again")
        #expect(merged.commit == "dc3366a0")
    }

    @Test func entriesBetweenTwoBuildsAndMatchingWords() {
        let log = Changelog(entries: [
            Entry(pullRequest: 913, title: "⌘P: open a pull request by its number", why: "Finding a PR meant scanning the Board.", kind: .new, build: 3),
            Entry(pullRequest: 905, title: "Columns: pin a column", why: "A spec slid away with the rest.", kind: .new, build: 2),
            Entry(pullRequest: 897, title: "Terminal: Ctrl+L redraws only a reader", why: nil, kind: .fixed, build: 1),
        ])
        #expect(log.entries(after: 1, through: 3).map(\.pullRequest) == [913, 905])
        #expect(log.entries(after: 3, through: 3).isEmpty)
        #expect(log.entries(matching: "  ").count == 3)
        #expect(log.entries(matching: "PIN spéc").map(\.pullRequest) == [905])
        #expect(log.entries(matching: "#897").map(\.pullRequest) == [897])
        #expect(log.entries(matching: "board number").map(\.pullRequest) == [913])
    }

    @Test func buildNumbersAreUTCMinutes() throws {
        let date = try #require(Changelog.date(ofBuild: 202611251854))
        #expect(date == Date(timeIntervalSince1970: 1_795_632_840))
        #expect(Changelog.build(at: date) == 202611251854)
        #expect(Changelog.build(at: date.addingTimeInterval(-90 * 86_400)) == 202608271854)
        #expect(Changelog.date(ofBuild: 202613251854) == nil)
        #expect(Changelog.date(ofBuild: 202611312400) == nil)
        #expect(Changelog.date(ofBuild: 42) == nil)
    }

    @Test func releaseNotesGroupTheBuildAndFoldTheInternalWork() {
        let log = Changelog(entries: [
            Entry(pullRequest: 916, title: "Columns: Escape keeps the card", why: nil, kind: .fixed, build: 2),
            Entry(pullRequest: 913, title: "⌘P: open a pull request", why: nil, kind: .new, build: 2),
            Entry(pullRequest: 917, title: "Tests: a calmer <details> clock", why: nil, kind: .internal, build: 2),
            Entry(pullRequest: 905, title: "Earlier build", why: nil, kind: .better, build: 1),
        ])
        #expect(log.releaseNotes(build: 2) == """
        ### New
        - ⌘P: open a pull request (#913)

        ### Fixed
        - Columns: Escape keeps the card (#916)

        <details><summary>Under the hood (1)</summary>

        - Tests: a calmer &lt;details&gt; clock (#917)

        </details>
        """)
        #expect(log.releaseNotes(build: 3) == "No pull request landed since the previous nightly.")
    }

    @Test func theFileFormatStaysReadable() throws {
        let json = """
        {"commit": "dc3366a0", "entries": [{"pullRequest": 913, "title": "⌘P: open a pull request", "why": "Finding it was slow.", "kind": "new", "build": 202611251854},
                     {"pullRequest": 917, "title": "Tests: a calmer clock", "kind": "internal", "build": 202611251854},
                     {"pullRequest": 920, "title": "A kind from a newer nightly", "kind": "security", "build": 202611251854},
                     {"pullRequest": 921, "kind": "fixed", "build": 202611251854}]}
        """
        let log = try JSONDecoder().decode(Changelog.self, from: Data(json.utf8))
        #expect(log.entries.map(\.kind) == [.new, .internal, .better])
        #expect(log.entries[1].why == nil)
        #expect(log.commit == "dc3366a0")
        #expect(try JSONDecoder().decode(Changelog.self, from: JSONEncoder().encode(log)) == log)
    }
}
