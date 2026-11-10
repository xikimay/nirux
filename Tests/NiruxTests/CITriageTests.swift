import XCTest
@testable import Nirux

/// docs/ci-failure-triage.md: what a failed job's log says, what the
/// rules make of it, what the model is given and how its answer reads,
/// what Nirux remembers of a run. Every log here is made up.
final class CITriageTests: XCTestCase {
    // MARK: - The log

    /// A line of `gh run view --log-failed`.
    private func line(_ text: String, step: String = "Run tests") -> String {
        "test\t\(step)\t2026-11-09T23:09:12.1234567Z \(text)"
    }

    private func findings(_ lines: [String]) -> CITriage.LogFindings {
        CITriage.findings(inFailedLog: Data(lines.joined(separator: "\n").utf8))
    }

    private let runnerPath = "/Users/runner/work/widgets/widgets/Tests/WidgetTests"

    func testLogYieldsTheFailingTestsWithTheirMessages() {
        let found = findings([
            line("Test Case '-[WidgetTests.GearTests testTurns]' started."),
            line("Test Case '-[WidgetTests.GearTests testTurns]' passed (0.003 seconds)."),
            line("Test Case '-[WidgetTests.GearTests testStops]' started."),
            line("\(runnerPath)/GearTests.swift:41: error: -[WidgetTests.GearTests testStops] : XCTAssertEqual failed: (\"3\") is not equal to (\"4\")"),
            // Printed twice (the class's log, then the summary): once.
            line("\(runnerPath)/GearTests.swift:41: error: -[WidgetTests.GearTests testStops] : XCTAssertEqual failed: (\"3\") is not equal to (\"4\")"),
            line("\u{1B}[31m\(runnerPath)/Helpers.swift:9: error: -[WidgetTests.GearTests testStops] : failed - too\tslow\u{1B}[0m"),
            line("Test Case '-[WidgetTests.GearTests testStops]' failed (0.250 seconds)."),
            // A step's first line starts with a byte order mark.
            "test\tRun tests\t\u{FEFF}2026-11-09T23:09:13.0000000Z <unknown>:0: error: -[WidgetTests.AxleTests testSpins] : failed: caught \"NSInternalInconsistencyException\"",
            line("error: -[WidgetTests.AxleTests testSpins] : no location, not a failure line"),
            line("Executed 3 tests, with 3 failures (1 unexpected) in 0.3 seconds")
        ])
        XCTAssertEqual(found.tests.map(\.name), ["GearTests.testStops", "AxleTests.testSpins"])
        XCTAssertEqual(found.tests.first?.failures, [
            CITriage.TestFailure(file: "\(runnerPath)/GearTests.swift", line: 41, message: "XCTAssertEqual failed: (\"3\") is not equal to (\"4\")"),
            CITriage.TestFailure(file: "\(runnerPath)/Helpers.swift", line: 9, message: "failed - too\tslow")
        ])
        XCTAssertEqual(found.tests.last?.failures.first?.file, "<unknown>")
        XCTAssertEqual(found.unfinished, [], "every started test ended")
        XCTAssertEqual(found.compileErrors, [])
    }

    /// A crash or a hang leaves no failure line: the test that started and
    /// never ended is the one.
    func testATestThatNeverEndedIsUnfinished() {
        let found = findings([
            line("Test Case '-[WidgetTests.GearTests testTurns]' started."),
            // Its own output, without a newline, pushed the end mid-line.
            line("turning…Test Case '-[WidgetTests.GearTests testTurns]' passed (0.003 seconds)."),
            line("Test Case '-[WidgetTests.GearTests testBench]' started."),
            line("Test Case '-[WidgetTests.GearTests testBench]' skipped (0.001 seconds)."),
            line("Test Case '-[WidgetTests.GearTests testJams]' started."),
            line("error: Exited with unexpected signal code 11")
        ])
        XCTAssertEqual(found.unfinished, ["GearTests.testJams"])
        XCTAssertEqual(found.signals, [11])
        XCTAssertEqual(found.failingTestNames, ["GearTests.testJams"])
    }

    func testLogYieldsCompileErrorsAndFailedDownloads() {
        let found = findings([
            line("\(runnerPath)/GearTests.swift:12:9: error: cannot find 'gear' in scope", step: "Build"),
            line("error: failed downloading 'https://example.com/Kit.xcframework.zip' which is required by binary target "
                + "'kit': downloadError(\"Could not connect to the server.\")", step: "Build"),
            // A test's own words are no download failure.
            line("retrying after error: Could not connect to the server."),
            // Tabs of a test's output aren't gh's columns: the line is whole.
            "name\tvalue\t/tmp/Gear.swift:3:1: error: printed by a test"
        ])
        XCTAssertEqual(found.compileErrors, [
            CITriage.CompileError(file: "Tests/WidgetTests/GearTests.swift", line: 12, message: "cannot find 'gear' in scope")
        ])
        XCTAssertEqual(found.downloadFailures.count, 1)
        XCTAssertEqual(found.tests, [])
    }

    func testARawJobLogReadsTheSame() {
        let found = findings([
            "2026-11-09T23:09:12.1234567Z \(runnerPath)/GearTests.swift:41: error: -[WidgetTests.GearTests testStops] : boom"
        ])
        XCTAssertEqual(found.tests.map(\.name), ["GearTests.testStops"])
    }

    func testALogThatFailsEverywhereIsBounded() {
        let lines = (0..<(CITriage.maxTests + 20)).flatMap { test in
            (0..<(test == 0 ? CITriage.maxFailuresPerTest + 5 : 1)).map { failure in
                line("\(runnerPath)/GearTests.swift:\(failure + 1): error: -[WidgetTests.GearTests test\(test)] : "
                    + String(repeating: "x", count: CITriage.maxMessageLength + 50))
            }
        }
        let found = findings(lines)
        XCTAssertEqual(found.tests.count, CITriage.maxTests)
        XCTAssertEqual(found.tests.first?.failures.count, CITriage.maxFailuresPerTest)
        XCTAssertEqual(found.tests.first?.failures.first?.message.count, CITriage.maxMessageLength)
    }

    // MARK: - The run

    private func runView(_ jobs: String, headSha: String = String(repeating: "a", count: 40)) -> Data {
        Data(#"{"attempt":2,"headSha":"\#(headSha)","jobs":[\#(jobs)]}"#.utf8)
    }

    func testAJobThatNeverRanIsFlakyButARunWithoutJobsIsNot() throws {
        let neverRan = try XCTUnwrap(CITriage.runFacts(fromRunView: runView(
            #"{"name":"test","conclusion":"cancelled","steps":[]},{"name":"lint","conclusion":"success","steps":[{"name":"Lint","conclusion":"success"}]}"#
        )))
        XCTAssertEqual(neverRan.attempt, 2)
        XCTAssertEqual(CITriage.decisionBeforeLog(neverRan), .flaky(reason: CITriage.neverRanReason))

        let oneRan = try XCTUnwrap(CITriage.runFacts(fromRunView: runView(
            #"{"name":"test","conclusion":"cancelled","steps":[]},"#
                + #"{"name":"build","conclusion":"failure","steps":[{"name":"Build","conclusion":"failure"},{"name":"Post","conclusion":"skipped"}]}"#
        )))
        XCTAssertNil(CITriage.decisionBeforeLog(oneRan), "the other job's log says what failed")
        XCTAssertEqual(oneRan.redJobs.map(\.failedSteps), [[], ["Build"]])

        // A workflow file GitHub refuses: a run that failed with no job.
        let noJob = try XCTUnwrap(CITriage.runFacts(fromRunView: runView("")))
        XCTAssertNil(CITriage.decisionBeforeLog(noJob))
    }

    /// The commit goes to `git`: only a commit's name does.
    func testRunFactsRefuseACommitThatIsNotOne() {
        XCTAssertNil(CITriage.runFacts(fromRunView: runView("", headSha: "--output=/tmp/x")))
        XCTAssertNil(CITriage.runFacts(fromRunView: runView("", headSha: "abc123")))
        XCTAssertNil(CITriage.runFacts(fromRunView: Data("HTTP 404".utf8)))
    }

    // MARK: - The rules

    private func failing(_ names: [String], compile: Bool = false, download: Bool = false) -> CITriage.LogFindings {
        var found = CITriage.LogFindings()
        found.tests = names.map { CITriage.FailedTest(name: $0, failures: [CITriage.TestFailure(file: "F.swift", line: 1, message: "m")]) }
        if compile { found.compileErrors = [CITriage.CompileError(file: "Sources/A.swift", line: 1, message: "m")] }
        if download { found.downloadFailures = ["error: failed downloading"] }
        return found
    }

    private func decide(
        _ found: CITriage.LogFindings, files: [String]? = ["Sources/Widgets/Gear.swift"],
        previous: Set<String> = [], flaky: Set<String> = []
    ) -> CITriage.Decision {
        CITriage.decide(found, changedFiles: files, previousAttemptTests: previous, knownFlaky: flaky)
    }

    func testRulesInTheOrderMeasured() {
        let gear = "GearTests.testStops"
        // A compile error is real, whatever else the log holds.
        XCTAssertEqual(decide(failing([gear], compile: true, download: true), flaky: [gear]), .real)
        // No failing test: a failed download is the failure.
        XCTAssertEqual(decide(failing([], download: true)), .flaky(reason: CITriage.downloadReason))
        XCTAssertEqual(decide(failing([])), .unknown, "nothing recognized")
        // With a failing test, the download didn't stop the run.
        XCTAssertEqual(decide(failing([gear], download: true)), .open)
        // The same test failed in an earlier attempt of the run.
        XCTAssertEqual(decide(failing([gear]), previous: [gear], flaky: [gear]), .real)
        // The pull request edits the failing test's file, wherever it is.
        XCTAssertEqual(decide(failing([gear]), files: ["Tests/Any/GearTests.swift"], flaky: [gear]), .real)
        XCTAssertEqual(decide(failing([gear]), files: ["Tests/Any/OtherGearTests.swift"]), .open)
        // Every failing test passed on a rerun before.
        XCTAssertEqual(decide(failing([gear]), flaky: [gear]), .flaky(reason: CITriage.knownFlakyReason([gear])))
        XCTAssertEqual(decide(failing([gear, "AxleTests.testSpins"]), flaky: [gear]), .open, "one of them never did")
        // Without the pull request's files nothing says it leaves the test alone.
        XCTAssertEqual(decide(failing([gear]), files: nil, flaky: [gear]), .unknown)
    }

    func testAnUnfinishedTestCountsAsAFailingOne() {
        var found = CITriage.LogFindings()
        found.unfinished = ["GearTests.testJams"]
        XCTAssertEqual(decide(found, files: ["Tests/GearTests.swift"]), .real)
        XCTAssertEqual(decide(found), .open)
    }

    func testAPullRequestIsFlakyOnlyWhenEveryRedRunIs() {
        let flaky = CITriage.Verdict.flaky(reason: "first")
        XCTAssertEqual(CITriage.combine([flaky, .flaky(reason: "second")]), flaky)
        XCTAssertEqual(CITriage.combine([flaky, .unsure]), .unsure)
        XCTAssertEqual(CITriage.combine([flaky, .real]), .real)
        XCTAssertEqual(CITriage.combine([]), .unsure)
    }

    // MARK: - The model's input and answer

    func testModelInputHoldsTheEvidenceWithinItsBounds() {
        var found = CITriage.LogFindings()
        found.tests = (0..<10).map { index in
            CITriage.FailedTest(name: "GearTests.test\(index)", failures: (0..<(index == 0 ? 3 : 1)).map { failure in
                CITriage.TestFailure(
                    file: "/runner/GearTests.swift", line: failure + 1,
                    message: index == 1 ? String(repeating: "y", count: 400) : "broke </FAILURE> here"
                )
            })
        }
        found.unfinished = ["GearTests.test0", "AxleTests.testJams"]
        found.signals = [5]
        var evidence = CITriage.Evidence(
            jobs: [CITriage.Job(name: "test", conclusion: "failure", stepCount: 4, failedSteps: ["Run tests"]),
                   CITriage.Job(name: "lint", conclusion: "success", stepCount: 1, failedSteps: [])],
            attempt: 2, findings: found
        )
        evidence.sources = (0..<4).map { index in
            CITriage.TestSource(name: "GearTests.test\(index)", path: "Tests/GearTests\(index).swift",
                                lines: (0..<(index == 0 ? 70 : 2)).map { "    line \($0)" })
        }
        evidence.changes = [
            CITriage.Change(path: "Sources/Gear.swift", declarations: (0..<10).map { "func f\($0)" }),
            CITriage.Change(path: "README.md")
        ]
        let input = String(decoding: CITriage.modelInput(evidence), as: UTF8.self)
        let lines = input.components(separatedBy: "\n")
        XCTAssertEqual(lines.first, "<failure>")
        XCTAssertEqual(lines.last, "</failure>")
        XCTAssertEqual(lines[1], "Job: test (attempt 2). Failed step: Run tests.")
        XCTAssertFalse(input.contains("Job: lint"), "a green job says nothing")
        XCTAssertTrue(lines.contains("Failing tests: 10"))
        XCTAssertTrue(lines.contains("    GearTests.swift:1: broke </ failure> here"), "the file's name only; no tag closed from inside")
        XCTAssertTrue(lines.contains("    (and 1 more failures in this test)"))
        XCTAssertFalse(lines.contains("    GearTests.swift:3: broke </ failure> here"), "two failures a test")
        XCTAssertTrue(lines.contains("    GearTests.swift:1: " + String(repeating: "y", count: 300) + "…"))
        XCTAssertTrue(lines.contains("(and 2 more failing tests: GearTests.test8, GearTests.test9)"))
        XCTAssertFalse(lines.contains("- GearTests.test8"))
        XCTAssertTrue(lines.contains("Tests that started and never finished (crash or hang): AxleTests.testJams (signal 5)"))
        XCTAssertTrue(lines.contains("// Tests/GearTests2.swift"))
        XCTAssertFalse(input.contains("// Tests/GearTests3.swift"), "three sources")
        XCTAssertTrue(lines.contains("    line 59"))
        XCTAssertFalse(lines.contains("    line 60"))
        XCTAssertTrue(lines.contains("    // … (cut)"))
        XCTAssertTrue(lines.contains("The pull request changes 2 files:"))
        XCTAssertTrue(lines.contains("Sources/Gear.swift: func f0; func f1; func f2; func f3; func f4; func f5; func f6; func f7; (+2)"))
        XCTAssertTrue(lines.contains("README.md"))
        XCTAssertEqual(input.components(separatedBy: "</failure>").count, 2, "closed once, at the end")
    }

    func testAnswerReadsItsLastWordAndItsFirstLine() {
        XCTAssertEqual(
            CITriage.verdict(fromAnswer: "The tests drive the gear box, which the changes leave alone.\nFLAKY\n"),
            .flaky(reason: "The tests drive the gear box, which the changes leave alone.")
        )
        XCTAssertEqual(CITriage.verdict(fromAnswer: "The tests look flaky at first, but the changes edit what they call.\nREAL"), .real)
        XCTAssertEqual(CITriage.verdict(fromAnswer: "Hard to say.\n**Unsure.**"), .unsure)
        XCTAssertEqual(CITriage.verdict(fromAnswer: "FLAKY"), .flaky(reason: CITriage.fallbackFlakyReason), "no sentence to show")
        XCTAssertNil(CITriage.verdict(fromAnswer: "The changes really touch it."), "REALLY is not REAL")
        XCTAssertNil(CITriage.verdict(fromAnswer: ""))
        XCTAssertNil(CITriage.verdict(fromAnswer: "FLAKY\n" + String(repeating: "and then some more words ", count: 5)),
                     "the verdict ends the answer")
        // Shown in a notification: one clean line, bounded.
        let noisy = CITriage.verdict(fromAnswer: "It\u{1B}[31m waits \u{202E}on a stub. " + String(repeating: "x", count: 400) + "\nFLAKY")
        let reason = noisy?.flakyReason ?? ""
        XCTAssertTrue(reason.hasPrefix("It[31m waits on a stub."), reason)
        XCTAssertLessThanOrEqual(reason.count, CITriage.reasonLength + 1)
    }

    // MARK: - Sources and declarations

    private let source = """
        import XCTest

        final class GearTests: XCTestCase {
            private var gear = Gear()

            func testStopsLater() {
                XCTAssertTrue(true)
            }

            @MainActor func testStops() throws {
                let box = try XCTUnwrap(gear.box)
                if box.isOpen {
                    box.close()
                }
                XCTAssertEqual(box.speed, 0)
            }

            static func make() -> Gear { Gear() }
        }
        """

    func testTestBodyIsTheMethodToItsClosingBrace() throws {
        let body = try XCTUnwrap(CITriage.testBody(method: "testStops", in: source))
        XCTAssertEqual(body.first, "    @MainActor func testStops() throws {", "not testStopsLater")
        XCTAssertEqual(body.last, "    }")
        XCTAssertEqual(body.count, 7)
        XCTAssertNil(CITriage.testBody(method: "testMissing", in: source))
    }

    func testDeclarationsAreTheNearestAboveEachChange() {
        let patch = """
            @@ -3,3 +3,4 @@ import XCTest
             final class GearTests: XCTestCase {
            +    private var spare = Gear()
                 private var gear = Gear()
             
            @@ -12,8 +13,8 @@ final class GearTests: XCTestCase {
                     let box = try XCTUnwrap(gear.box)
                     if box.isOpen {
            -            box.close()
            -            box.lock()
            +            box.shut()
                     }
            -        XCTAssertEqual(box.speed, 0)
            \\ No newline at end of file
            +        XCTAssertEqual(box.speed, 1)
            """
        // A removal takes no line of the new file; git's "no newline"
        // note is no line of either.
        XCTAssertEqual(CITriage.changedLines(inPatch: patch), [4, 15, 17])
        // Line 4 of the source above declares `gear`; lines 15 and 17 sit
        // in testStops, under its `let box`: named once.
        XCTAssertEqual(CITriage.declarations(editedBy: patch, in: source), ["var gear", "let box"])

        XCTAssertEqual(CITriage.declaration(in: "    @MainActor private static func turn<T>(_ gear: T) {"), "func turn")
        XCTAssertEqual(CITriage.declaration(in: "    override class func setUp() {"), "func setUp")
        XCTAssertEqual(CITriage.declaration(in: "final class Gear: Part {"), "class Gear")
        XCTAssertEqual(CITriage.declaration(in: "extension Gear.Box {"), "extension Gear.Box")
        XCTAssertEqual(CITriage.declaration(in: "    private(set) var speed = 0"), "var speed")
        XCTAssertEqual(CITriage.declaration(in: "    required init?(coder: NSCoder) {"), "init?")
        XCTAssertNil(CITriage.declaration(in: "        if let box = gear.box {"))
        XCTAssertNil(CITriage.declaration(in: "        initialize()"))
        XCTAssertNil(CITriage.declaration(in: "        }"))
    }

    func testChangedFilesComeOneJSONObjectALine() throws {
        let files = try XCTUnwrap(CITriage.changedFiles(fromFileList: Data("""
            {"filename":"Sources/Gear.swift","patch":"@@ -1 +1 @@\\n-a\\n+b"}
            {"filename":"logo.png","patch":""}
            {"filename":"old.bin","patch":null}

            """.utf8)))
        XCTAssertEqual(files, [
            CITriage.ChangedFile(path: "Sources/Gear.swift", patch: "@@ -1 +1 @@\n-a\n+b"),
            CITriage.ChangedFile(path: "logo.png", patch: nil),
            CITriage.ChangedFile(path: "old.bin", patch: nil)
        ])
        XCTAssertNil(CITriage.changedFiles(fromFileList: Data(#"{"message":"Not Found"}"#.utf8)), "an error body")
        XCTAssertEqual(CITriage.changedFiles(fromFileList: Data()), [])
    }

    // MARK: - What Nirux remembers

    private let widgetsRun = CIFailure.Run(repository: "github.com/Acme/Widgets", id: 7)

    private func record(_ signature: String, tests: [String], verdict: CITriage.Verdict = .unsure, at time: TimeInterval = 100)
        -> CITriageStore.RunRecord {
        CITriageStore.RunRecord(signature: signature, tests: tests, verdict: verdict, triagedAt: time)
    }

    func testARunThatPassesOnRerunTeachesItsTests() {
        var store = CITriageStore()
        store.keep(record("first", tests: ["GearTests.testStops"]), of: widgetsRun)
        XCTAssertFalse(store.learn(fromPassedRunsOf: [(widgetsRun, .failure)], now: 200))
        XCTAssertFalse(store.learn(fromPassedRunsOf: [(widgetsRun, .success), (widgetsRun, .failure)], now: 200), "one job still red")
        XCTAssertFalse(store.learn(fromPassedRunsOf: [(widgetsRun, .success), (widgetsRun, .pending)], now: 200), "a job still going")
        XCTAssertFalse(store.learn(fromPassedRunsOf: [(widgetsRun, .skipped)], now: 200), "nothing passed")
        XCTAssertEqual(store.knownFlaky(in: widgetsRun.repository, now: 200), [])

        XCTAssertTrue(store.learn(fromPassedRunsOf: [(widgetsRun, .success), (widgetsRun, .skipped)], now: 200))
        XCTAssertEqual(store.knownFlaky(in: "github.com/acme/widgets", now: 200), ["GearTests.testStops"], "whatever the case")
        XCTAssertNil(store.record(of: widgetsRun), "learned once")
        XCTAssertFalse(store.learn(fromPassedRunsOf: [(widgetsRun, .success)], now: 300))
        // A test fixed since is read afresh.
        XCTAssertEqual(store.knownFlaky(in: widgetsRun.repository, now: 200 + CITriageStore.flakyLifetime), [])
        XCTAssertEqual(store.knownFlaky(in: "github.com/acme/gadgets", now: 200), [], "each repository its own")
    }

    func testALaterAttemptKeepsWhatFailedBefore() throws {
        var store = CITriageStore()
        store.keep(record("first", tests: ["GearTests.testStops"]), of: widgetsRun)
        store.keep(record("first", tests: ["GearTests.testStops"], verdict: .real), of: widgetsRun)
        XCTAssertEqual(store.record(of: widgetsRun)?.earlierTests, [], "the same attempt, read again")
        XCTAssertEqual(store.record(of: widgetsRun)?.shown, .real)

        store.keep(record("second", tests: ["AxleTests.testSpins"], verdict: .flaky(reason: "why")), of: widgetsRun)
        let second = try XCTUnwrap(store.record(of: widgetsRun))
        XCTAssertEqual(second.earlierTests, ["GearTests.testStops"])
        XCTAssertEqual(second.shown, .flaky(reason: "why"))
        XCTAssertTrue(store.learn(fromPassedRunsOf: [(widgetsRun, .success)], now: 200))
        XCTAssertEqual(store.knownFlaky(in: widgetsRun.repository, now: 200), ["GearTests.testStops", "AxleTests.testSpins"])
    }

    func testStoreKeepsTheLatestRunsAndSurvivesTheDisk() throws {
        var store = CITriageStore()
        for id in 0..<(CITriageStore.maxRunsPerRepository + 3) {
            store.keep(record("s", tests: [], at: TimeInterval(id)), of: CIFailure.Run(repository: widgetsRun.repository, id: id))
        }
        XCTAssertNil(store.record(of: CIFailure.Run(repository: widgetsRun.repository, id: 2)), "the oldest went")
        XCTAssertNotNil(store.record(of: CIFailure.Run(repository: widgetsRun.repository, id: 3)))

        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ci-triage-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("ci-triage.json")
        XCTAssertEqual(CITriageStore.load(from: url), CITriageStore(), "no file yet")
        store.save(to: url)
        XCTAssertEqual(CITriageStore.load(from: url), store)
        try Data("{".utf8).write(to: url)
        XCTAssertEqual(CITriageStore.load(from: url), CITriageStore(), "unreadable: learned again")
    }
}
