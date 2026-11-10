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

    /// The findings of a log with one job.
    private func findings(_ lines: [String]) -> CITriage.LogFindings {
        let jobs = CITriage.findings(inFailedLog: Data(lines.joined(separator: "\n").utf8))
        XCTAssertLessThanOrEqual(jobs.count, 1)
        return jobs.first?.findings ?? CITriage.LogFindings()
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
        XCTAssertEqual(found.otherErrors, ["-[WidgetTests.AxleTests testSpins] : no location, not a failure line"],
                       "an error nothing reads is kept as one")
    }

    /// XCTest's own word counts: a test it says failed is a failing test,
    /// even when the parser can read none of its failure lines (a path
    /// with a space, a file that isn't Swift).
    func testATestXCTestSaysFailedIsAFailingTest() {
        let found = findings([
            line("Test Case '-[WidgetTests.GearTests testStops]' started."),
            line("/Users/runner/work/my widgets/GearTests.swift:41: error: -[WidgetTests.GearTests testStops] : boom"),
            line("Test Case '-[WidgetTests.GearTests testStops]' failed (0.250 seconds)."),
            line("Test Case '-[WidgetTests.AxleTests testSpins]' started."),
            line("\(runnerPath)/AxleTests.swift:7: error: -[WidgetTests.AxleTests testSpins] : boom"),
            line("Test Case '-[WidgetTests.AxleTests testSpins]' failed (0.1 seconds).")
        ])
        XCTAssertEqual(found.failingTestNames, ["GearTests.testStops", "AxleTests.testSpins"])
        XCTAssertEqual(found.tests.first?.failures, [], "named, with nothing read of it")
        XCTAssertEqual(found.tests.last?.failures.count, 1, "the failure line came first: not added twice")
    }

    /// Each job of the run has its own findings: a job the parser can't
    /// read must not hide behind one it can.
    func testEachJobIsReadApart() {
        let jobs = CITriage.findings(inFailedLog: Data([
            "build\tFetch\t2026-11-09T23:09:12.1234567Z error: failed downloading 'https://example.com/Kit.zip' which is required by binary target 'kit': x",
            "web tests\tRun jest\t2026-11-09T23:09:13.1234567Z ##[error]Process completed with exit code 1.",
            "lint\tRun lint\t2026-11-09T23:09:14.1234567Z ##[error]3 files need formatting",
            "build\tFetch\t2026-11-09T23:09:15.1234567Z error: fatalError"
        ].joined(separator: "\n").utf8))
        XCTAssertEqual(jobs.map(\.job), ["build", "web tests", "lint"])
        guard jobs.count == 3 else { return }
        XCTAssertEqual(jobs[0].findings.downloadFailures.count, 1)
        XCTAssertEqual(jobs[0].findings.otherErrors, [], "SwiftPM ends a failed run on fatalError")
        XCTAssertTrue(jobs[1].findings.isEmpty, "every failed step ends on its exit code")
        XCTAssertEqual(jobs[2].findings.otherErrors, ["3 files need formatting"])
        XCTAssertEqual(CITriage.LogFindings.merged(jobs.map(\.findings)).otherErrors, ["3 files need formatting"])
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
        XCTAssertEqual(found.otherErrors, [], "the signal is read as one")
    }

    /// Where a process trapped, as the Swift runtime prints it.
    func testACrashHasItsPlace() {
        let found = findings([
            line("Test Case '-[WidgetTests.GearTests testJams]' started."),
            line("Widgets/Gear.swift:88: Fatal error: Index out of range")
        ])
        XCTAssertEqual(found.crashes, [CITriage.SourceError(file: "Widgets/Gear.swift", line: 88, message: "Index out of range")])
        XCTAssertEqual(found.unfinished, ["GearTests.testJams"])
    }

    /// A log is the pull request's own output: one line of it, however
    /// long or full of markers, is read in bounded work.
    func testOneLongLineIsReadByItsEnds() {
        let noise = String(repeating: "Test Case '-[ ", count: 20_000)
        let found = findings([
            line("Test Case '-[WidgetTests.GearTests testTurns]' started."),
            line("Test Case '-[WidgetTests.GearTests testStops]' started."),
            // The end of a megabyte printed without a newline still closes its test.
            line(noise + "Test Case '-[WidgetTests.GearTests testTurns]' passed (0.003 seconds)."),
            line((0..<40).map { "Test Case '-[WidgetTests.AxleTests test\($0)]' started." }.joined(separator: " "))
        ])
        XCTAssertFalse(found.unfinished.contains("GearTests.testTurns"))
        XCTAssertEqual(found.unfinished.count, 1 + CITriage.maxTestCasesPerLine, "so many markers a line, no more")
    }

    func testLogYieldsCompileErrorsAndFailedDownloads() {
        let found = findings([
            line("\(runnerPath)/GearTests.swift:12:9: error: cannot find 'gear' in scope", step: "Build"),
            line("error: failed downloading 'https://example.com/Kit.xcframework.zip' which is required by binary target "
                + "'kit': downloadError(\"Could not connect to the server.\")", step: "Build"),
            // A test's own words are no download failure.
            line("retrying after error: Could not connect to the server."),
            // Tabs of a test's output aren't gh's columns: the line is whole,
            // and a path with a tab in it is no Swift file's.
            line("name\tvalue\t/tmp/Gear.swift:3:1: error: printed by a test")
        ])
        XCTAssertEqual(found.compileErrors, [
            CITriage.SourceError(file: "Tests/WidgetTests/GearTests.swift", line: 12, message: "cannot find 'gear' in scope")
        ])
        XCTAssertEqual(found.downloadFailures.count, 1)
        XCTAssertEqual(found.tests, [])
        XCTAssertEqual(found.otherErrors, [])
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

    func testRunFactsTellTheRedJobsAndTheirSteps() throws {
        let facts = try XCTUnwrap(CITriage.runFacts(fromRunView: runView(
            #"{"name":"test","databaseId":41,"conclusion":"cancelled","steps":[]},"#
                + #"{"name":"build","databaseId":42,"conclusion":"failure","steps":[{"name":"Build","conclusion":"failure"},{"name":"Post","conclusion":"skipped"}]},"#
                + #"{"name":"lint","conclusion":"success","steps":[{"name":"Lint","conclusion":"success"}]}"#
        )))
        XCTAssertEqual(facts.attempt, 2)
        XCTAssertEqual(facts.redJobs.map(\.name), ["test", "build"])
        XCTAssertEqual(facts.redJobs.map(\.id), [41, 42])
        XCTAssertEqual(facts.redJobs.map(\.stepCount), [0, 2])
        XCTAssertEqual(facts.redJobs.map(\.failedSteps), [[], ["Build"]])
        // A workflow file GitHub refuses: a run that failed with no job.
        XCTAssertEqual(try XCTUnwrap(CITriage.runFacts(fromRunView: runView(""))).redJobs, [])
    }

    /// A job that ran no step is a flake only when GitHub says a runner
    /// was the reason: one it refuses to start is the pull request's.
    func testAJobThatNeverRanIsFlakyOnlyForWantOfARunner() {
        XCTAssertEqual(
            CITriage.neverRanReason(annotations: ["The job was not acquired by Runner of type hosted even after multiple attempts"]),
            "No runner took the job: no step ran."
        )
        XCTAssertEqual(
            CITriage.neverRanReason(annotations: ["Capacity note", "The hosted runner lost communication with the server. Anything…"]),
            "The runner was lost before any step ran."
        )
        XCTAssertNil(CITriage.neverRanReason(annotations: ["Error when evaluating 'runs-on' for job 'test'."]))
        XCTAssertNil(CITriage.neverRanReason(annotations: ["The run was canceled by @someone."]))
        XCTAssertNil(CITriage.neverRanReason(annotations: []))
    }

    /// The commit goes to `git`: only a commit's name does.
    func testRunFactsRefuseACommitThatIsNotOne() {
        XCTAssertNil(CITriage.runFacts(fromRunView: runView("", headSha: "--output=/tmp/x")))
        XCTAssertNil(CITriage.runFacts(fromRunView: runView("", headSha: "abc123")))
        XCTAssertNil(CITriage.runFacts(fromRunView: Data("HTTP 404".utf8)))
    }

    // MARK: - The rules

    private func failing(_ names: [String], compile: Bool = false, download: Bool = false, in file: String = "/x/F.swift")
        -> CITriage.LogFindings {
        var found = CITriage.LogFindings()
        found.tests = names.map { CITriage.FailedTest(name: $0, failures: [CITriage.TestFailure(file: file, line: 1, message: "m")]) }
        if compile { found.compileErrors = [CITriage.SourceError(file: "Sources/A.swift", line: 1, message: "m")] }
        if download { found.downloadFailures = ["error: failed downloading"] }
        return found
    }

    private func decide(
        _ found: CITriage.LogFindings, files: [String]? = ["Sources/Widgets/Gear.swift"],
        earlier: CITriage.EarlierAttempt = .none, flaky: Set<String> = []
    ) -> CITriage.Decision {
        CITriage.decide(found, changedFiles: files, earlier: earlier, knownFlaky: flaky)
    }

    private let gear = "GearTests.testStops"

    func testRulesInTheOrderMeasured() {
        // A compile error is real, whatever else the log holds.
        XCTAssertEqual(decide(failing([gear], compile: true, download: true), flaky: [gear]), .real)
        // No failing test: a failed download is the failure.
        XCTAssertEqual(decide(failing([], download: true)), .flaky(reason: CITriage.downloadReason))
        XCTAssertEqual(decide(failing([])), .unknown, "nothing recognized")
        // With a failing test, the download didn't stop the run.
        XCTAssertEqual(decide(failing([gear], download: true)), .open)
        // The same test failed in the attempt before.
        XCTAssertEqual(decide(failing([gear]), earlier: .failed(failing([gear])), flaky: [gear]), .real)
        XCTAssertEqual(decide(failing([gear]), earlier: .failed(failing(["AxleTests.testSpins"])), flaky: [gear]),
                       .flaky(reason: CITriage.knownFlakyReason([gear])), "another test failed before")
        // The pull request edits the failing test's file, wherever it is.
        XCTAssertEqual(decide(failing([gear]), files: ["Tests/Any/GearTests.swift"], flaky: [gear]), .real)
        XCTAssertEqual(decide(failing([gear]), files: ["Tests/Any/OtherGearTests.swift"]), .open)
        // Every failing test passed on a rerun before.
        XCTAssertEqual(decide(failing([gear]), flaky: [gear]), .flaky(reason: CITriage.knownFlakyReason([gear])))
        XCTAssertEqual(decide(failing([gear, "AxleTests.testSpins"]), flaky: [gear]), .open, "one of them never did")
        // Without the pull request's files nothing says it leaves the failure alone.
        XCTAssertEqual(decide(failing([gear]), files: nil, flaky: [gear]), .unknown)
        XCTAssertEqual(decide(failing([], download: true), files: nil), .unknown)
    }

    /// A test class isn't always in the file of its name: the file a
    /// failure was reported in counts as the test's too.
    func testAFailureReportedInAChangedFileIsReal() {
        let reported = "/Users/runner/work/widgets/widgets/Tests/WidgetTests/PartsTests.swift"
        XCTAssertEqual(decide(failing([gear], in: reported), files: ["Tests/WidgetTests/PartsTests.swift"], flaky: [gear]), .real)
        XCTAssertEqual(decide(failing([gear], in: reported), files: ["Tests/Other/PartsTests.swift"], flaky: [gear]),
                       .flaky(reason: CITriage.knownFlakyReason([gear])), "another file of that name")
        // A crash in a file the pull request changes, as Swift names it.
        var crashed = CITriage.LogFindings()
        crashed.unfinished = [gear]
        crashed.crashes = [CITriage.SourceError(file: "Widgets/Gear.swift", line: 88, message: "Index out of range")]
        XCTAssertEqual(decide(crashed, flaky: [gear]), .real)
        XCTAssertEqual(decide(crashed, files: ["Sources/Widgets/Axle.swift"], flaky: [gear]), .flaky(reason: CITriage.knownFlakyReason([gear])))
        XCTAssertTrue(CITriage.changes("/abs/checkout/Sources/A.swift", in: ["Sources/A.swift"]))
        XCTAssertFalse(CITriage.changes("Sources/AA.swift", in: ["A.swift"]), "a name ends another only at a folder")
        XCTAssertTrue(CITriage.changes("Nirux/Gear.swift", in: ["Sources/Nirux/Model/Gear.swift"]), "Swift's Module/File form")
        XCTAssertFalse(CITriage.changes("Nirux/Gear.swift", in: ["Sources/Nirux/Model/Gears.swift"]))
    }

    /// What a rule can't read keeps it from saying flaky.
    func testNothingIsFlakyInAJobThatHoldsMoreThanTheRulesRead() {
        var download = failing([], download: true)
        // A download that will never work is no flake.
        XCTAssertEqual(decide(download, files: ["Package.resolved"]), .unknown, "the pull request changes what is downloaded")
        XCTAssertEqual(decide(download, files: ["Kit/Package.swift"]), .unknown)
        XCTAssertEqual(decide(download, earlier: .failed(failing([], download: true))), .unknown, "it failed so before")
        XCTAssertEqual(decide(download, earlier: .failed(failing([gear]))), .flaky(reason: CITriage.downloadReason))
        XCTAssertEqual(decide(download, earlier: .unreadable), .unknown)
        // A second build after the download failed, ending on a link error.
        download.otherErrors = ["link command failed with exit code 1"]
        XCTAssertEqual(decide(download), .unknown)

        var known = failing([gear])
        XCTAssertEqual(decide(known, earlier: .unreadable, flaky: [gear]), .unknown, "it may be failing twice in a row")
        known.otherErrors = ["12 tests ran out of 14 listed"]
        XCTAssertEqual(decide(known, flaky: [gear]), .open, "something else failed too")
        known.otherErrors = []
        known.signals = [11]
        XCTAssertEqual(decide(known, flaky: [gear]), .open, "a crash no test accounts for")
        known.unfinished = [gear]
        XCTAssertEqual(decide(known, flaky: [gear]), .flaky(reason: CITriage.knownFlakyReason([gear])))
    }

    func testAnUnfinishedTestCountsAsAFailingOne() {
        var found = CITriage.LogFindings()
        found.unfinished = ["GearTests.testJams"]
        XCTAssertEqual(decide(found, files: ["Tests/GearTests.swift"]), .real)
        XCTAssertEqual(decide(found), .open)
    }

    func testARunIsFlakyOnlyWhenEveryRedJobIs() {
        let flaky = CITriage.Decision.flaky(reason: "first")
        XCTAssertEqual(CITriage.combine(jobs: [flaky, .flaky(reason: "second")]), flaky)
        XCTAssertEqual(CITriage.combine(jobs: [flaky, .open]), .open)
        XCTAssertEqual(CITriage.combine(jobs: [flaky, .open, .unknown]), .unknown, "a job nothing reads may hide a real failure")
        XCTAssertEqual(CITriage.combine(jobs: [flaky, .unknown, .real]), .real)
        XCTAssertEqual(CITriage.combine(jobs: []), .unknown)
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
        found.crashes = [CITriage.SourceError(file: "Widgets/Gear.swift", line: 88, message: "Index out of range")]
        var evidence = CITriage.Evidence(
            jobs: [CITriage.Job(name: "test", conclusion: "failure", stepCount: 4, failedSteps: ["Run tests"]),
                   CITriage.Job(name: "lint", conclusion: "success", stepCount: 1, failedSteps: []),
                   CITriage.Job(name: String(repeating: "j", count: 500), conclusion: "failure", stepCount: 1, failedSteps: [])],
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
        XCTAssertTrue(lines.contains("Crash: Widgets/Gear.swift:88: Fatal error: Index out of range"))
        XCTAssertTrue(lines.contains("Job: " + String(repeating: "j", count: CITriage.maxNameLength) + "… (attempt 2)."), "a name is bounded")
        XCTAssertTrue(lines.contains("// Tests/GearTests2.swift"))
        XCTAssertFalse(input.contains("// Tests/GearTests3.swift"), "three sources")
        XCTAssertTrue(lines.contains("    line 59"))
        XCTAssertFalse(lines.contains("    line 60"))
        XCTAssertTrue(lines.contains("    // … (cut)"))
        XCTAssertTrue(lines.contains("The pull request changes 2 files:"))
        XCTAssertTrue(lines.contains("Sources/Gear.swift: func f0; func f1; func f2; func f3; func f4; func f5; func f6; func f7; (+2)"))
        XCTAssertTrue(lines.contains("README.md"))
        XCTAssertEqual(input.components(separatedBy: "</failure>").count, 2, "closed once, at the end")

        // Whatever its parts add up to, the whole is bounded.
        evidence.changes = (0..<CITriage.promptFiles).map {
            CITriage.Change(path: "Sources/\($0)/" + String(repeating: "p", count: 400) + ".swift",
                            declarations: (0..<8).map { "func " + String(repeating: "d", count: 110) + "\($0)" })
        }
        XCTAssertLessThanOrEqual(String(decoding: CITriage.modelInput(evidence), as: UTF8.self).count, CITriage.promptLength + 30)
    }

    func testAnswerIsItsLastLineAloneAndItsFirstLine() {
        XCTAssertEqual(
            CITriage.verdict(fromAnswer: "The tests drive the gear box, which the changes leave alone.\nFLAKY\n"),
            .flaky(reason: "The tests drive the gear box, which the changes leave alone.")
        )
        XCTAssertEqual(CITriage.verdict(fromAnswer: "The tests look flaky at first, but the changes edit what they call.\nREAL"), .real)
        XCTAssertEqual(CITriage.verdict(fromAnswer: "Hard to say.\n\n**Unsure.**\n"), .unsure)
        XCTAssertEqual(CITriage.verdict(fromAnswer: "FLAKY"), .flaky(reason: CITriage.fallbackFlakyReason), "no sentence to show")
        // A verdict with words around it is no verdict: a remark after
        // REAL must not read as FLAKY.
        XCTAssertNil(CITriage.verdict(fromAnswer: "The changes edit what the tests call.\nREAL, not flaky."))
        XCTAssertNil(CITriage.verdict(fromAnswer: "The changes edit what the tests call.\nREAL (not FLAKY)"))
        XCTAssertNil(CITriage.verdict(fromAnswer: "The tests wait on a stub, so this is probably flaky."))
        XCTAssertNil(CITriage.verdict(fromAnswer: "FLAKY\nbecause the tests wait on a stub"))
        XCTAssertNil(CITriage.verdict(fromAnswer: ""))
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
        // in testStops, past its local `let box`: named once.
        XCTAssertEqual(CITriage.declarations(editedBy: patch, in: source), ["var gear", "func testStops"])

        XCTAssertEqual(CITriage.declaration(in: "    @MainActor private static func turn<T>(_ gear: T) {"), "func turn")
        XCTAssertEqual(CITriage.declaration(in: "    override class func setUp() {"), "func setUp")
        XCTAssertEqual(CITriage.declaration(in: "final class Gear: Part {"), "class Gear")
        XCTAssertEqual(CITriage.declaration(in: "extension Gear.Box {"), "extension Gear.Box")
        XCTAssertEqual(CITriage.declaration(in: "    private(set) var speed = 0"), "var speed")
        XCTAssertEqual(CITriage.declaration(in: "    required init?(coder: NSCoder) {"), "init?")
        XCTAssertNil(CITriage.declaration(in: "        if let box = gear.box {"))
        XCTAssertNil(CITriage.declaration(in: "        initialize()"))
        XCTAssertNil(CITriage.declaration(in: "        }"))
        XCTAssertEqual(CITriage.declaration(in: "func " + String(repeating: "n", count: 500) + "()")?.count, 5 + CITriage.maxNameLength)
    }

    /// What a changed line belongs to is the function or property around
    /// it, not the nearest `let` above it.
    func testAChangedLineBelongsToWhatEnclosesIt() {
        // `#if` at the margin, where Xcode puts it, inside the type.
        let lines: [Substring] = [
            "struct Gear {",
            "    var teeth = 12",
            "    var ratio: Double {",
            "        let base = Double(teeth)",
            "        return base / 4",
            "    }",
            "",
            "#if DEBUG",
            "    func turn(",
            "        by angle: Double,",
            "        times: Int",
            "    ) -> Double {",
            "        let step = angle / 2",
            "        if times > 1 {",
            "            // twice",
            "            return step * 2",
            "        }",
            "        return step",
            "    }",
            "#endif",
            "}",
            "",
            "let shared = Gear()"
        ]
        func enclosing(_ line: Int) -> String? { CITriage.enclosingDeclaration(ofLine: line - 1, in: lines) }
        XCTAssertEqual(enclosing(2), "var teeth", "a property is itself")
        XCTAssertEqual(enclosing(5), "var ratio", "in a computed property, past its local")
        XCTAssertEqual(enclosing(6), "var ratio", "its closing brace")
        XCTAssertEqual(enclosing(7), "var ratio", "a blank line takes the line above")
        XCTAssertEqual(enclosing(9), "func turn")
        XCTAssertEqual(enclosing(11), "func turn", "a parameter")
        XCTAssertEqual(enclosing(13), "func turn", "a local is its function's")
        XCTAssertEqual(enclosing(16), "func turn", "nested, past a comment, a local and the signature's end")
        XCTAssertEqual(enclosing(19), "func turn")
        XCTAssertEqual(enclosing(21), "struct Gear", "the type's closing brace, past the margin's #endif")
        XCTAssertEqual(enclosing(23), "let shared")
        XCTAssertNil(enclosing(40))
        // A generated table: nothing above within reach, and no long walk.
        let table = Array(repeating: Substring("    0x00,"), count: 2 * CITriage.maxDeclarationWalk)
        XCTAssertNil(CITriage.enclosingDeclaration(ofLine: table.count, in: [Substring("let table = [")] + table))
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

    private func record(
        _ signature: String, tests: [String], verdict: CITriage.Verdict = .unsure, isUnanswered: Bool = false,
        redChecks: [String] = ["test"], at time: TimeInterval = 100
    ) -> CITriageStore.RunRecord {
        CITriageStore.RunRecord(
            signature: signature, redChecks: redChecks, tests: tests, verdict: verdict, isUnanswered: isUnanswered, triagedAt: time
        )
    }

    private func checks(_ results: [(String, ProjectBoard.CheckResult)]) -> [(run: CIFailure.Run, name: String, result: ProjectBoard.CheckResult)] {
        results.map { (widgetsRun, $0.0, $0.1) }
    }

    func testARunThatPassesOnRerunTeachesItsTests() {
        var store = CITriageStore()
        store.keep(record("first", tests: ["GearTests.testStops"], redChecks: ["test", "lint"]), of: widgetsRun)
        XCTAssertFalse(store.learn(fromPassedRunsOf: checks([("test", .failure), ("lint", .success)]), now: 200))
        XCTAssertFalse(store.learn(fromPassedRunsOf: checks([("test", .success), ("lint", .pending)]), now: 200), "a job still going")
        XCTAssertFalse(store.learn(fromPassedRunsOf: checks([("test", .success), ("lint", .skipped)]), now: 200), "lint never passed")
        // Another run of the workflow took the red check over: this one
        // says nothing of it.
        XCTAssertFalse(store.learn(fromPassedRunsOf: checks([("lint", .success), ("report", .success)]), now: 200), "test isn't there")
        XCTAssertEqual(store.knownFlaky(in: widgetsRun.repository, now: 200), [])

        XCTAssertTrue(store.learn(fromPassedRunsOf: checks([("test", .success), ("lint", .success), ("docs", .skipped)]), now: 200))
        XCTAssertEqual(store.knownFlaky(in: "github.com/acme/widgets", now: 200), ["GearTests.testStops"], "whatever the case")
        XCTAssertNil(store.record(of: widgetsRun), "learned once")
        XCTAssertFalse(store.learn(fromPassedRunsOf: checks([("test", .success), ("lint", .success)]), now: 300))
        // A test fixed since is read afresh.
        XCTAssertEqual(store.knownFlaky(in: widgetsRun.repository, now: 200 + CITriageStore.flakyLifetime), [])
        XCTAssertEqual(store.knownFlaky(in: "github.com/acme/gadgets", now: 200), [], "each repository its own")
    }

    func testALaterAttemptKeepsWhatFailedBefore() throws {
        var store = CITriageStore()
        store.keep(record("first", tests: ["GearTests.testStops"]), of: widgetsRun)
        store.keep(record("second", tests: ["AxleTests.testSpins"], verdict: .flaky(reason: "why")), of: widgetsRun)
        let second = try XCTUnwrap(store.record(of: widgetsRun))
        XCTAssertEqual(second.earlierTests, ["GearTests.testStops"])
        XCTAssertEqual(second.shown, .flaky(reason: "why"))
        // The same attempt, read again (a second Nirux, a retry): what
        // failed before stays.
        store.keep(record("second", tests: ["AxleTests.testSpins"], verdict: .real), of: widgetsRun)
        XCTAssertEqual(store.record(of: widgetsRun)?.earlierTests, ["GearTests.testStops"])
        XCTAssertEqual(store.record(of: widgetsRun)?.shown, .real)

        XCTAssertTrue(store.learn(fromPassedRunsOf: checks([("test", .success)]), now: 200))
        XCTAssertEqual(store.knownFlaky(in: widgetsRun.repository, now: 200), ["GearTests.testStops", "AxleTests.testSpins"])
    }

    /// The model couldn't run: the run is remembered, not its answer.
    func testAnAnswerStillOwedIsNotFinal() throws {
        let owed = record("first", tests: ["GearTests.testStops"], isUnanswered: true)
        XCTAssertFalse(owed.isFinal)
        XCTAssertEqual(owed.shown, .unsure)
        XCTAssertTrue(record("first", tests: [], verdict: .unsure).isFinal, "the rules found nothing to say: that is an answer")
        XCTAssertTrue(record("first", tests: [], verdict: .real, isUnanswered: true).isFinal, "a verdict came")
        var store = CITriageStore()
        store.keep(owed, of: widgetsRun)
        XCTAssertTrue(store.learn(fromPassedRunsOf: checks([("test", .success)]), now: 200), "its tests still teach")
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
