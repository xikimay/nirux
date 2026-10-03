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
        func shell(_ bodies: [String]) -> String {
            """
            @main
            struct Shell {
                func applicationWillTerminate(_ notification: Notification) {
            \(bodies[0])    }

            \(filler())
                static func main() {
            \(bodies[1])    }

            \(filler())
                func main() {
            \(bodies[2])    }

            \(filler())
                func applicationShouldTerminate(_ sender: NSApplication)
                    -> NSApplication.TerminateReply {
            \(bodies[3])    }

            \(filler())
                func applicationDidFinishLaunching(_ notification: Notification)
                {
            \(bodies[4])    }

            \(filler())
                func applicationWillFinishLaunching(_ notification: Notification) {
            \(bodies[5])    }

            \(filler())
                func other() {
            \(bodies[6])    }
            }

            \(filler())
            enum Tool {
                static func main() {
            \(bodies[7])    }
            }

            """
        }
        let base = ["        save()\n", "        run()\n", "        work()\n", "        .terminateNow\n", "        start()\n",
                    "        prepare()\n", "        work()\n", "        work()\n"]
        try write("Sources/Shell+Launch.swift", shell(base))
        try commitToMain("shell")
        var branch = base
        branch[0] = ""
        for index in [1, 2, 4, 6, 7] { branch[index] += "        more()\n" }
        branch[3] = "        log()\n" + base[3]
        branch[5] += "        // A note.\n\n"
        try write("Sources/Shell+Launch.swift", shell(branch))

        let shell = try file("Sources/Shell+Launch.swift", in: try snapshot())

        XCTAssertEqual(shell.hunks.count, 8)
        // A removal is read on the old side, a signature may wrap, and a
        // note changes nothing. An instance `main`, or one outside an
        // `@main` type, isn't an entry point.
        XCTAssertEqual(shell.signals, [
            BranchReview.RiskSignal(
                kind: .launch,
                reasons: [
                    "inside applicationDidFinishLaunching", "inside applicationShouldTerminate",
                    "inside applicationWillTerminate", "inside main"
                ],
                hunks: [0, 1, 3, 4], byPath: false
            )
        ])
    }

    func testCommentsRaiseNothingButStringsStillDo() throws {
        try write("Sources/Notes.swift", "struct Notes {\n}\n")
        try commitToMain("notes")
        try write("Sources/Notes.swift", """
        struct Notes {
            func send() { post() } // DispatchQueue, later
            /*
             DispatchQueue
             */
            let scheme = "nirux://open" // DispatchQueue
            let help = \"\"\"
                // Telegram bot
                \"\"\"
        }

        """)

        let notes = try file("Sources/Notes.swift", in: try snapshot())

        // A string's line that reads like a comment still counts.
        XCTAssertEqual(notes.signals, [
            BranchReview.RiskSignal(kind: .security, reasons: ["Telegram", "nirux://"], hunks: [0], byPath: false)
        ])
    }

    func testMultiLineStringTextKeepsItsWhitespace() throws {
        try write("Sources/Template.swift", "let template = \"\"\"\n    name: nirux\n    \"\"\"\n")
        try write("Sources/Blank.swift", "let text = \"\"\"\n    a\n    b\n    \"\"\"\n")
        try write("Sources/Worker.swift", "func run() {\nwork()\n}\n")
        try write("Sources/Moved.swift", "struct A {\n  let s = \"\"\"\n    x\n    \"\"\"\n}\n")
        try write("Sources/Trimmed.swift", "let s = \"\"\"\n    a\n    \n    b\n    \"\"\"\n")
        try write("Sources/Ends.swift", "let s = \"\"\"\n    a\n    \"\"\"\n")
        try commitToMain("strings")
        try write("Sources/Template.swift", "let template = \"\"\"\n        name: nirux\n    \"\"\"\n")
        try write("Sources/Blank.swift", "let text = \"\"\"\n    a\n\n    b\n    \"\"\"\n")
        try write("Sources/Worker.swift", "func run() {\n    work()\n}\n")
        // As Swift reads them, these strings don't change: the text moved
        // with its closing delimiter, a line of blanks emptied, line
        // endings.
        try write("Sources/Moved.swift", "struct A {\n    let s = \"\"\"\n      x\n      \"\"\"\n}\n")
        try write("Sources/Trimmed.swift", "let s = \"\"\"\n    a\n\n    b\n    \"\"\"\n")
        try write("Sources/Ends.swift", "let s = \"\"\"\r\n    a\r\n    \"\"\"\r\n")

        let snapshot = try snapshot()

        XCTAssertNil(try file("Sources/Template.swift", in: snapshot).fold, "the string's text moved")
        XCTAssertEqual(try file("Sources/Template.swift", in: snapshot).symbols, .read([]))
        XCTAssertNil(try file("Sources/Blank.swift", in: snapshot).fold, "the string gained a line")
        for path in ["Sources/Worker.swift", "Sources/Moved.swift", "Sources/Trimmed.swift", "Sources/Ends.swift"] {
            XCTAssertEqual(try file(path, in: snapshot).fold, .whitespaceOnly, path)
        }
    }

    func testTypeChangeKeepsItsFirstPassSignalsAndGivesItsSymbols() throws {
        try FileManager.default.createDirectory(atPath: repo + "/Sources", withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: repo + "/Sources/Link.swift", withDestinationPath: "App.swift")
        try commitToMain("link")
        try FileManager.default.removeItem(atPath: repo + "/Sources/Link.swift")
        try write("Sources/Link.swift", "let queue = DispatchQueue.main\n")

        let link = try file("Sources/Link.swift", in: try snapshot())

        XCTAssertEqual(link.status, .typeChanged)
        XCTAssertEqual(link.signals, [
            BranchReview.RiskSignal(kind: .concurrency, reasons: ["DispatchQueue"], hunks: [1], byPath: false)
        ])
        XCTAssertEqual(link.symbols, .read([BranchReview.Symbol(name: "queue", line: 1, kind: .variable, container: nil)]))
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
