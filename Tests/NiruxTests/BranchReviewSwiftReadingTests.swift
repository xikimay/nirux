import XCTest
@testable import Nirux

/// Swift files read in context (`BranchReview.readSwift`) on real,
/// temporary git repositories: the function a change is in, its comments,
/// and a multi-line string's whitespace.
final class BranchReviewSwiftReadingTests: BranchReviewRepositoryTestCase {
    private func filler(_ count: Int = 7) -> String {
        (1...count).map { "    // \($0)\n" }.joined()
    }

    func testChangeInsideALifecycleFunctionRaisesLaunch() throws {
        let base = """
        extension Shell {
            func applicationWillTerminate(_ notification: Notification) {
                save()
            }

        \(filler())
            static func main() {
                run()
            }

        \(filler())
            func main() {
                work()
            }

        \(filler())
            func other() {
                work()
            }
        }

        """
        try write("Sources/Shell+Launch.swift", base)
        try commitToMain("shell")
        let branch = base
            .replacingOccurrences(of: "        save()\n", with: "")
            .replacingOccurrences(of: "        run()\n", with: "        run()\n        check()\n")
            .replacingOccurrences(of: "        work()\n    }\n\n", with: "        work()\n        more()\n    }\n\n")
            .replacingOccurrences(of: "        work()\n    }\n}\n", with: "        work()\n        more()\n    }\n}\n")
        try write("Sources/Shell+Launch.swift", branch)

        let shell = try file("Sources/Shell+Launch.swift", in: try snapshot())

        XCTAssertEqual(shell.hunks.count, 4)
        // A removal is read on the old side; an instance `main` isn't an
        // entry point.
        XCTAssertEqual(shell.signals, [
            BranchReview.RiskSignal(
                kind: .launch, reasons: ["inside applicationWillTerminate", "inside main"], hunks: [0, 1], byPath: false
            )
        ])
    }

    func testCommentsRaiseNothingButStringsStillDo() throws {
        try write("Sources/Notes.swift", "struct Notes {\n}\n")
        try commitToMain("notes")
        try write("Sources/Notes.swift", """
        struct Notes {
            func send() { post() } // Telegram, later
            /*
             Telegram
             */
            let scheme = "nirux://open" // DispatchQueue
        }

        """)

        let notes = try file("Sources/Notes.swift", in: try snapshot())

        XCTAssertEqual(notes.signals, [
            BranchReview.RiskSignal(kind: .security, reasons: ["nirux://"], hunks: [0], byPath: false)
        ])
    }

    func testMultiLineStringTextKeepsItsWhitespace() throws {
        try write("Sources/Template.swift", "let template = \"\"\"\n    name: nirux\n    \"\"\"\n")
        try write("Sources/Blank.swift", "let text = \"\"\"\n    a\n    b\n    \"\"\"\n")
        try write("Sources/Worker.swift", "func run() {\nwork()\n}\n")
        try commitToMain("strings")
        try write("Sources/Template.swift", "let template = \"\"\"\n        name: nirux\n    \"\"\"\n")
        try write("Sources/Blank.swift", "let text = \"\"\"\n    a\n\n    b\n    \"\"\"\n")
        try write("Sources/Worker.swift", "func run() {\n    work()\n}\n")

        let snapshot = try snapshot()

        XCTAssertNil(try file("Sources/Template.swift", in: snapshot).fold, "the string's text moved")
        XCTAssertNil(try file("Sources/Blank.swift", in: snapshot).fold, "the string gained a line")
        XCTAssertEqual(try file("Sources/Worker.swift", in: snapshot).fold, .whitespaceOnly)
    }

    /// #57 wires keep-awake into launch and quit; #65 checks the release
    /// signature at launch and in the entry point's modes.
    func testMergedPullRequestsRaiseLaunchInsideTheirLifecycleFunctions() throws {
        let keepAwake = try snapshotOfMergedPullRequest("fa74b4c", branch: "feat/keep-awake")
        let releaseCheck = try snapshotOfMergedPullRequest("a804dc3", branch: "fix/queue-release-signature")

        func launch(_ snapshot: BranchReview.Snapshot) throws -> BranchReview.RiskSignal? {
            try file("Sources/Nirux/NiruxApp.swift", in: snapshot).signals.first { $0.kind == .launch }
        }
        // `setUpKeepAwake(...)` and `keepAwakeController?.shutdown()` name
        // neither function.
        XCTAssertEqual(try launch(keepAwake), BranchReview.RiskSignal(
            kind: .launch, reasons: ["app delegate", "inside applicationDidFinishLaunching", "inside applicationWillTerminate"],
            hunks: [2, 3, 5], byPath: true
        ))
        XCTAssertEqual(try launch(releaseCheck), BranchReview.RiskSignal(
            kind: .launch, reasons: ["app delegate", "inside applicationDidFinishLaunching", "inside main"],
            hunks: [0, 1], byPath: true
        ))
    }
}
