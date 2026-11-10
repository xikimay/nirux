import XCTest
@testable import Nirux

/// docs/ci-failure-triage.md: what reading one failed run asks of `gh`,
/// of the local repository and of the model, and when it asks nothing.
/// `gh`, `git` and the model are doubles; every log is made up.
final class CITriageInvestigationTests: XCTestCase {
    private static let commit = String(repeating: "c", count: 40)
    private static let runnerPath = "/Users/runner/work/widgets/widgets/Tests/WidgetTests"
    private static func failureLine(_ test: String = "testStops", job: String = "test") -> String {
        "\(job)\tRun tests\t2026-11-09T23:09:12.1234567Z \(runnerPath)/GearTests.swift:41: "
            + "error: -[WidgetTests.GearTests \(test)] : XCTAssertEqual failed"
    }

    private static func runView(attempt: Int = 1, jobs: String = #"{"name":"test","databaseId":11,"conclusion":"failure","steps":[{"name":"Run tests","conclusion":"failure"}]}"#)
        -> String {
        #"{"attempt":\#(attempt),"headSha":"\#(commit)","jobs":[\#(jobs)]}"#
    }

    /// What the doubles answer.
    private struct World: Sendable {
        var attempt = 1
        var runView: String? = CITriageInvestigationTests.runView()
        var log: String? = CITriageInvestigationTests.failureLine()
        /// The attempt before's, asked with `--attempt <attempt - 1>`.
        var earlierRunView: String?
        var earlierLog: String?
        var annotations: String?
        var files: String? = #"{"filename":"Sources/Widgets/Axle.swift","patch":"@@ -1,2 +1,2 @@\n struct Axle {\n-    var speed = 1\n+    var speed = 2"}"#
        var commitIsLocal = true
        var isPartialClone = false
        var tree = ["Sources/Widgets/Axle.swift", "Tests/WidgetTests/GearTests.swift"]
        /// What `git grep` finds declaring a class.
        var declaring: [String] = []
        var blobs: [String: String] = [
            "Tests/WidgetTests/GearTests.swift": "final class GearTests {\n    func testStops() {\n        stop()\n    }\n}\n",
            "Sources/Widgets/Axle.swift": "struct Axle {\n    var speed = 2\n}\n"
        ]
        var answer: CITriage.Verdict? = .flaky(reason: "The tests drive gears; the changes edit an axle.")
    }

    private final class Calls: @unchecked Sendable {
        private let lock = NSLock()
        private var ghCalls: [[String]] = []
        private var gitCalls: [[String]] = []
        private var blobCalls: [[String]] = []
        private var modelInputs: [String] = []

        func gh(_ arguments: [String]) { lock.withLock { ghCalls.append(arguments) } }
        func git(_ arguments: [String]) { lock.withLock { gitCalls.append(arguments) } }
        func blobs(_ objects: [String]) { lock.withLock { blobCalls.append(objects) } }
        func model(_ input: String) { lock.withLock { modelInputs.append(input) } }
        var gh: [[String]] { lock.withLock { ghCalls } }
        var git: [[String]] { lock.withLock { gitCalls } }
        var blobsAsked: [[String]] { lock.withLock { blobCalls } }
        var inputs: [String] { lock.withLock { modelInputs } }
        /// What was asked of `gh`, in order: "run", "log", "files",
        /// "annotations", with "@n" for an attempt named.
        var asked: [String] {
            gh.map { arguments in
                let attempt = arguments.firstIndex(of: "--attempt").map { "@" + arguments[$0 + 1] } ?? ""
                if arguments.contains("--log-failed") { return "log" + attempt }
                if arguments.first == "api" { return arguments.contains { $0.hasSuffix("/annotations") } ? "annotations" : "files" }
                return "run" + attempt
            }
        }
    }

    private func effects(_ world: World, _ calls: Calls) -> CITriageInvestigation.Effects {
        CITriageInvestigation.Effects(
            gh: { arguments, _, _ in
                calls.gh(arguments)
                let attempt = arguments.firstIndex(of: "--attempt").flatMap { Int(arguments[$0 + 1]) }
                let answer: String?
                if arguments.contains("--log-failed") {
                    answer = attempt == world.attempt ? world.log : world.earlierLog
                } else if arguments.first == "api" {
                    answer = arguments.contains { $0.hasSuffix("/annotations") } ? world.annotations : world.files
                } else {
                    answer = attempt == nil ? world.runView : world.earlierRunView
                }
                return answer.map { Data($0.utf8) }
            },
            git: { arguments, _ in
                calls.git(arguments)
                switch arguments.first {
                case "config": return world.isPartialClone && arguments.last == "extensions.partialClone" ? Data("origin\n".utf8) : nil
                case "cat-file": return world.commitIsLocal ? Data() : nil
                case "ls-tree": return Data(world.tree.map { $0 + "\u{0}" }.joined().utf8)
                case "grep": return Data(world.declaring.map { "\(Self.commit):\($0)\u{0}" }.joined().utf8)
                default: return nil
                }
            },
            blobs: { objects, _ in
                calls.blobs(objects)
                return objects.map { object in
                    guard object.hasPrefix(Self.commit + ":") else { return nil }
                    return world.blobs[String(object.dropFirst(Self.commit.count + 1))].map { Data($0.utf8) }
                }
            },
            model: { input in
                calls.model(String(decoding: input, as: UTF8.self))
                return world.answer
            }
        )
    }

    private func request(
        isModelAllowed: Bool = true, flaky: Set<String> = [], root: String? = "/repo", redChecks: Set<String> = []
    ) -> CITriageInvestigation.Request {
        CITriageInvestigation.Request(
            run: CIFailure.Run(repository: "github.com/acme/widgets", id: 7), pullRequest: 52, repositoryRoot: root,
            isModelAllowed: isModelAllowed, knownFlaky: flaky, redChecks: redChecks
        )
    }

    private func investigate(
        _ world: World, _ request: CITriageInvestigation.Request? = nil, isStillWanted: @escaping @Sendable () async -> Bool = { true }
    ) async -> (outcome: CITriageInvestigation.Outcome, calls: Calls) {
        let calls = Calls()
        let outcome = await CITriageInvestigation.investigate(
            request ?? self.request(), effects: effects(world, calls), isStillWanted: isStillWanted
        )
        return (outcome, calls)
    }

    private static let gear = "GearTests.testStops"

    // MARK: - What the rules settle asks no model

    func testAJobThatNeverRanIsSettledByWhyItDidnt() async {
        var world = World()
        world.runView = Self.runView(jobs: #"{"name":"test","databaseId":99,"conclusion":"cancelled","steps":[]}"#)
        world.annotations = "Due to capacity constraints…\nThe job was not acquired by Runner of type hosted even after multiple attempts"
        let (outcome, calls) = await investigate(world)
        XCTAssertEqual(outcome, CITriageInvestigation.Outcome(verdict: .flaky(reason: "No runner took the job: no step ran."), wasRead: true))
        XCTAssertEqual(calls.asked, ["run", "annotations"], "no log to read")
        XCTAssertEqual(calls.gh.last, ["api", "--hostname", "github.com", "repos/acme/widgets/check-runs/99/annotations", "--jq", ".[].message"])

        // GitHub refused to start it: the workflow, so the pull request's doing.
        world.annotations = "Error when evaluating 'runs-on' for job 'test'."
        let refused = await investigate(world)
        XCTAssertEqual(refused.outcome, CITriageInvestigation.Outcome(verdict: .unsure, wasRead: true))
        XCTAssertEqual(refused.calls.inputs, [])
    }

    func testACompileErrorIsRealWithoutThePullRequestsFiles() async {
        var world = World()
        world.log = "test\tBuild\t2026-11-09T23:09:12.1234567Z /Users/runner/work/widgets/widgets/Sources/Widgets/Axle.swift:3:5: error: nope"
        let (outcome, calls) = await investigate(world)
        XCTAssertEqual(outcome.verdict, .real)
        XCTAssertEqual(calls.asked, ["run", "log@1"], "the log of the attempt whose jobs were read")
        XCTAssertEqual(calls.inputs, [])
    }

    func testAnEditedTestFileIsRealAndARerunCuredTestIsFlaky() async {
        var world = World()
        world.files = #"{"filename":"Tests/WidgetTests/GearTests.swift","patch":null}"#
        let edited = await investigate(world, request(flaky: [Self.gear]))
        XCTAssertEqual(edited.outcome.verdict, .real)
        XCTAssertEqual(edited.outcome.tests, [Self.gear])
        XCTAssertEqual(edited.calls.asked, ["run", "log@1", "files"])
        XCTAssertEqual(edited.calls.gh.last, [
            "api", "--hostname", "github.com", "--paginate", "repos/acme/widgets/pulls/52/files?per_page=100",
            "--jq", #".[] | {filename, patch: ((.patch // "") | .[0:20000])}"#
        ])

        let cured = await investigate(World(), request(flaky: [Self.gear]))
        XCTAssertEqual(cured.outcome.verdict, .flaky(reason: CITriage.knownFlakyReason([Self.gear])))
        XCTAssertEqual(edited.calls.inputs + cured.calls.inputs, [], "the rules settled them")
    }

    /// A rerun that fails is read with the attempt before: what failed
    /// there failing again is real, whatever Nirux saw or missed.
    func testASecondAttemptIsReadWithTheOneBefore() async {
        var world = World()
        world.attempt = 2
        world.runView = Self.runView(attempt: 2, jobs: #"{"name":"test","databaseId":12,"conclusion":"failure","steps":[{"name":"Run tests","conclusion":"failure"}]}"#)
        world.earlierRunView = Self.runView(attempt: 1)
        world.earlierLog = Self.failureLine()
        let again = await investigate(world, request(flaky: [Self.gear]))
        XCTAssertEqual(again.outcome.verdict, .real)
        XCTAssertEqual(again.calls.asked, ["run", "log@2", "files", "run@1", "log@1"])

        world.earlierLog = Self.failureLine("testTurns")
        let other = await investigate(world, request(flaky: [Self.gear]))
        XCTAssertEqual(other.outcome.verdict, .flaky(reason: CITriage.knownFlakyReason([Self.gear])), "another test failed before")

        // A job GitHub carried over from attempt 1 keeps its id: it is
        // the same failure, not a second one.
        world.earlierRunView = Self.runView(attempt: 1, jobs: #"{"name":"test","databaseId":12,"conclusion":"failure","steps":[{"name":"Run tests","conclusion":"failure"}]}"#)
        let carried = await investigate(world, request(flaky: [Self.gear]))
        XCTAssertEqual(carried.outcome.verdict, .flaky(reason: CITriage.knownFlakyReason([Self.gear])))
        XCTAssertEqual(carried.calls.asked, ["run", "log@2", "files", "run@1"], "no earlier log to read")

        // The attempt before can't be read: it may have failed the same way.
        world.earlierRunView = nil
        let unknown = await investigate(world, request(flaky: [Self.gear]))
        XCTAssertEqual(unknown.outcome.verdict, .unsure)
        XCTAssertFalse(unknown.outcome.isUnanswered, "the rules' answer, not the model's")

        // Nor when the job failed then and left nothing the parser reads
        // (a hang cancelled at its timeout has no failed step).
        world.earlierRunView = Self.runView(attempt: 1)
        world.earlierLog = "test\tRun tests\t2026-11-09T23:09:12.1234567Z ##[error]Process completed with exit code 1."
        let silent = await investigate(world, request(flaky: [Self.gear]))
        XCTAssertEqual(silent.outcome.verdict, .unsure)
        world.earlierLog = "lint\tLint\t2026-11-09T23:09:12.1234567Z ##[error]1 file needs formatting"
        let elsewhere = await investigate(world, request(flaky: [Self.gear]))
        XCTAssertEqual(elsewhere.outcome.verdict, .unsure, "the job has no line in that log at all")
    }

    /// The verdict is shown for the checks the pull request showed red: a
    /// job rerun since (running now) would leave it made of the others.
    func testARunWhoseRedJobsChangedSinceIsReadLater() async {
        let same = await investigate(World(), request(flaky: [Self.gear], redChecks: ["test"]))
        XCTAssertEqual(same.outcome.verdict, .flaky(reason: CITriage.knownFlakyReason([Self.gear])))
        let changed = await investigate(World(), request(flaky: [Self.gear], redChecks: ["test", "lint"]))
        XCTAssertEqual(changed.outcome, CITriageInvestigation.Outcome(), "not read: asked again")
        XCTAssertEqual(changed.calls.asked, ["run"])
    }

    /// One red job the rules can't read keeps the whole run from being
    /// flaky, whatever the others say.
    func testOneJobTheRulesCantReadKeepsTheRunPlain() async {
        var world = World()
        world.runView = Self.runView(jobs: #"{"name":"build","databaseId":1,"conclusion":"failure","steps":[{"name":"Fetch","conclusion":"failure"}]},"#
            + #"{"name":"lint","databaseId":2,"conclusion":"failure","steps":[{"name":"Lint","conclusion":"failure"}]}"#)
        world.log = [
            "build\tFetch\t2026-11-09T23:09:12.1234567Z error: failed downloading 'https://example.com/Kit.zip' which is required by binary target 'kit': x",
            "lint\tLint\t2026-11-09T23:09:13.1234567Z ##[error]3 files need formatting"
        ].joined(separator: "\n")
        let (outcome, calls) = await investigate(world)
        XCTAssertEqual(outcome.verdict, .unsure)
        XCTAssertEqual(calls.inputs, [])

        // The lint job has no line in the log at all: nothing read of it.
        world.log = "build\tFetch\t2026-11-09T23:09:12.1234567Z error: failed downloading 'https://example.com/Kit.zip' which is required by binary target 'kit': x"
        let silent = await investigate(world)
        XCTAssertEqual(silent.outcome.verdict, .unsure)

        // Alone, the build job's download is a flake.
        world.runView = Self.runView(jobs: #"{"name":"build","databaseId":1,"conclusion":"failure","steps":[{"name":"Fetch","conclusion":"failure"}]}"#)
        let alone = await investigate(world)
        XCTAssertEqual(alone.outcome.verdict, .flaky(reason: CITriage.downloadReason))
    }

    func testJobFindingsFollowTheLogsJobColumn() {
        let jobs = [CITriage.Job(name: "test", conclusion: "failure", stepCount: 1, failedSteps: []),
                    CITriage.Job(name: "lint", conclusion: "failure", stepCount: 1, failedSteps: [])]
        var found = CITriage.LogFindings()
        found.otherErrors = ["x"]
        XCTAssertEqual(CITriageInvestigation.jobFindings(of: jobs, in: [("lint", found)]), [CITriage.LogFindings(), found])
        XCTAssertEqual(CITriageInvestigation.jobFindings(of: [jobs[0]], in: [("", found)]), [found], "a raw log is its only job's")
        XCTAssertEqual(CITriageInvestigation.jobFindings(of: jobs, in: [("", found)]), [CITriage.LogFindings(), CITriage.LogFindings()])
    }

    // MARK: - What they leave open

    func testAnOpenFailureGoesToTheModelWithItsSourceAndTheChangedDeclarations() async throws {
        let (outcome, calls) = await investigate(World())
        XCTAssertEqual(outcome, CITriageInvestigation.Outcome(
            verdict: .flaky(reason: "The tests drive gears; the changes edit an axle."), tests: [Self.gear], wasRead: true
        ))
        let input = try XCTUnwrap(calls.inputs.first)
        XCTAssertEqual(calls.inputs.count, 1)
        XCTAssertTrue(input.contains("- GearTests.testStops\n    GearTests.swift:41: XCTAssertEqual failed"), input)
        XCTAssertTrue(input.contains("// Tests/WidgetTests/GearTests.swift\n    func testStops() {\n        stop()\n    }"), input)
        XCTAssertTrue(input.contains("The pull request changes 1 files:\nSources/Widgets/Axle.swift: var speed"), input)
        // Read at the run's commit, in the workspace's repository, the
        // changed files in one batch.
        XCTAssertTrue(calls.git.contains(["cat-file", "-e", "\(Self.commit)^{commit}"]))
        XCTAssertEqual(calls.blobsAsked, [["\(Self.commit):Tests/WidgetTests/GearTests.swift"], ["\(Self.commit):Sources/Widgets/Axle.swift"]])
    }

    /// The run tests the merge with the base branch: a failing test that
    /// isn't at the pull request's commit came with it, and nothing here
    /// says a rerun would pass.
    func testATestTheBaseBranchBroughtGetsNoVerdictForNow() async {
        var world = World()
        world.tree = ["Sources/Widgets/Axle.swift"]
        let (outcome, calls) = await investigate(world)
        XCTAssertEqual(outcome, CITriageInvestigation.Outcome(verdict: .unsure, tests: [Self.gear], wasRead: true, isUnanswered: true),
                       "asked again later")
        XCTAssertEqual(calls.inputs, [])
    }

    /// The test is where its class's file is, or in an extension of the
    /// class elsewhere, or in a superclass.
    func testATestIsFoundInAnExtensionOrASuperclass() async throws {
        var world = World()
        world.tree = ["Sources/Widgets/Axle.swift", "Tests/WidgetTests/GearTests.swift", "Tests/WidgetTests/GearTests+Stops.swift"]
        world.blobs["Tests/WidgetTests/GearTests.swift"] = "final class GearTests {\n    func testTurns() {}\n}\n"
        world.blobs["Tests/WidgetTests/GearTests+Stops.swift"] = "extension GearTests {\n    func testStops() {\n        stop()\n    }\n}\n"
        world.declaring = ["Tests/WidgetTests/GearTests+Stops.swift"]
        let (extended, calls) = await investigate(world)
        XCTAssertNotNil(extended.verdict.flakyReason)
        XCTAssertTrue(try XCTUnwrap(calls.inputs.first).contains("// Tests/WidgetTests/GearTests+Stops.swift\n    func testStops() {"))

        // A mutant subclass runs its superclass's tests.
        world = World()
        world.log = Self.failureLine().replacingOccurrences(of: "GearTests testStops", with: "GearMutantTests testStops")
        world.tree = ["Sources/Widgets/Axle.swift", "Tests/WidgetTests/GearTests.swift", "Tests/WidgetTests/GearMutantTests.swift"]
        world.blobs["Tests/WidgetTests/GearMutantTests.swift"] = "final class GearMutantTests: GearTests {}\n"
        let (inherited, inheritedCalls) = await investigate(world)
        XCTAssertNotNil(inherited.verdict.flakyReason)
        XCTAssertTrue(try XCTUnwrap(inheritedCalls.inputs.first).contains("// Tests/WidgetTests/GearTests.swift\n    func testStops() {"))
    }

    /// Only tests that failed are kept for learning: a test merely left
    /// running when a job stopped (a timeout) teaches nothing.
    func testOnlyFailedTestsAreKept() async {
        var world = World()
        world.log = "test\tRun tests\t2026-11-09T23:09:11.1234567Z Test Case '-[WidgetTests.AxleTests testJams]' started.\n"
            + Self.failureLine()
        let (outcome, _) = await investigate(world)
        XCTAssertEqual(outcome.tests, [Self.gear])
    }

    func testAClassOutsideTheFileOfItsNameIsFoundWhereItIsDeclared() async throws {
        var world = World()
        world.tree = ["Sources/Widgets/Axle.swift", "Tests/WidgetTests/PartsTests.swift"]
        world.declaring = ["Tests/WidgetTests/PartsTests.swift"]
        world.blobs["Tests/WidgetTests/PartsTests.swift"] = "final class GearTests {\n    func testStops() {\n        stop()\n    }\n}\n"
        let (_, calls) = await investigate(world)
        let input = try XCTUnwrap(calls.inputs.first)
        XCTAssertTrue(input.contains("// Tests/WidgetTests/PartsTests.swift\n    func testStops() {"), input)
        let grep = try XCTUnwrap(calls.git.first { $0.first == "grep" })
        XCTAssertTrue(grep.contains("class GearTests"))
        XCTAssertEqual(grep.suffix(3), [Self.commit, "--", "*.swift"])
    }

    func testWithoutTheCommitTheModelReadsNamesOnly() async throws {
        var world = World()
        world.commitIsLocal = false
        let (outcome, calls) = await investigate(world)
        XCTAssertNotNil(outcome.verdict.flakyReason)
        let input = try XCTUnwrap(calls.inputs.first)
        XCTAssertFalse(input.contains("Source of the failing tests"))
        XCTAssertTrue(input.hasSuffix("The pull request changes 1 files:\nSources/Widgets/Axle.swift\n</failure>"), input)
        XCTAssertEqual(calls.git, [["config", "--get", "extensions.partialClone"], ["cat-file", "-e", "\(Self.commit)^{commit}"]],
                       "nothing else is asked of a commit that isn't there")
        XCTAssertEqual(calls.blobsAsked, [])

        // A partial clone would fetch what it lacks: nothing is read.
        world.commitIsLocal = true
        world.isPartialClone = true
        let (_, partial) = await investigate(world)
        XCTAssertEqual(partial.git, [["config", "--get", "extensions.partialClone"]])
        XCTAssertEqual(partial.blobsAsked, [])
        XCTAssertNotNil(partial.inputs.first)

        let (rootless, rootlessCalls) = await investigate(World(), request(root: nil))
        XCTAssertNotNil(rootless.verdict.flakyReason)
        XCTAssertEqual(rootlessCalls.git, [])
    }

    /// A workspace whose agent runs on another account: the rules only.
    /// The run is still read and remembered, which is how Nirux learns;
    /// the answer stays owed.
    func testNoModelForAWorkspaceOnAnotherAccount() async {
        let (outcome, calls) = await investigate(World(), request(isModelAllowed: false))
        XCTAssertEqual(outcome, CITriageInvestigation.Outcome(verdict: .unsure, tests: [Self.gear], wasRead: true, isUnanswered: true))
        XCTAssertEqual(calls.inputs, [])
        XCTAssertEqual(calls.git, [], "nor its source read for nothing")
    }

    /// The option went off while `gh` was read: nothing goes to the model.
    func testTurnedOffOnTheWayNothingGoesToTheModel() async {
        let (outcome, calls) = await investigate(World(), isStillWanted: { false })
        XCTAssertEqual(outcome.verdict, .unsure)
        XCTAssertTrue(outcome.isUnanswered)
        XCTAssertEqual(calls.inputs, [])
    }

    func testAnythingMissingMeansNoVerdict() async {
        var world = World()
        world.answer = nil
        let silent = await investigate(world)
        XCTAssertEqual(silent.outcome.verdict, .unsure, "the model gave no answer")
        XCTAssertTrue(silent.outcome.wasRead)
        XCTAssertTrue(silent.outcome.isUnanswered, "asked again another time")

        world = World()
        world.files = #"{"message":"Bad credentials"}"#
        let noFiles = await investigate(world, request(flaky: [Self.gear]))
        XCTAssertEqual(noFiles.outcome.verdict, .unsure, "nothing says the pull request leaves the test alone")
        XCTAssertEqual(noFiles.calls.inputs, [])

        world = World()
        world.log = nil
        let noLog = await investigate(world)
        XCTAssertEqual(noLog.outcome, CITriageInvestigation.Outcome(), "not read: asked again another time")

        world = World()
        world.runView = nil
        let noRun = await investigate(world)
        XCTAssertEqual(noRun.outcome, CITriageInvestigation.Outcome())
        XCTAssertEqual(noRun.calls.asked, ["run"])

        // The run passes now (a rerun went through meanwhile): nothing red to read.
        world = World()
        world.runView = Self.runView(jobs: #"{"name":"test","databaseId":11,"conclusion":"success","steps":[{"name":"Run tests","conclusion":"success"}]}"#)
        let green = await investigate(world)
        XCTAssertEqual(green.outcome, CITriageInvestigation.Outcome())
        XCTAssertEqual(green.calls.asked, ["run"])
    }

    func testOnlyARepositoryWithItsHostIsAskedForFiles() {
        func arguments(_ repository: String) -> [String]? {
            CITriageInvestigation.changedFilesArguments(CITriageInvestigation.Request(
                run: CIFailure.Run(repository: repository, id: 7), pullRequest: 52, repositoryRoot: nil,
                isModelAllowed: false, knownFlaky: []
            ))
        }
        XCTAssertEqual(arguments("ghe.example.com/acme/widgets")?[2], "ghe.example.com")
        XCTAssertNil(arguments("acme/widgets"))
        XCTAssertNil(arguments("github.com/acme/widgets/extra"))
    }

    /// `git cat-file --batch`'s answers, each in its place.
    func testBatchOutputGivesEachBlobInOrder() {
        var output = Data("aaaa blob 5\nhello\n".utf8)
        output += Data("HEAD:missing.swift missing\n".utf8)
        output += Data("bbbb tree 4\nxxxx\n".utf8)
        output += Data("cccc blob 0\n\n".utf8)
        output += Data("dddd blob 3\nend\n".utf8)
        let blobs = CITriageInvestigation.blobs(count: 6, inBatchOutput: output)
        XCTAssertEqual(blobs, [Data("hello".utf8), nil, nil, Data(), Data("end".utf8), nil])
        XCTAssertEqual(CITriageInvestigation.blobs(count: 2, inBatchOutput: Data("eeee blob 99\nshort\n".utf8)), [nil, nil], "cut short")
    }

    // MARK: - The model's runs

    private let cli = BranchReview.ClaudeCLI(path: "/bin/echo")

    private static func events(_ lines: [String]) -> BoundedProcess.Outcome {
        BoundedProcess.Outcome(standardOutput: Data(lines.joined(separator: "\n").utf8), standardError: Data(), terminationStatus: 0, stop: nil)
    }

    private static func result(_ text: String) -> String {
        #"{"type":"result","is_error":false,"result":"\#(text)"}"#
    }

    private func knowsSetup(_ account: ClaudeOneShotRunner.Account) async throws {
        account.prepare()
        let deadline = Date().addingTimeInterval(10)
        while !account.knowsSetup, Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(account.knowsSetup)
    }

    func testTheModelIsSonnetAloneOnTheTriagesPrompt() {
        let arguments = ClaudeOneShotRunner.arguments(for: CITriageModel.client)
        func value(after flag: String) -> String? {
            arguments.firstIndex(of: flag).flatMap { arguments.indices.contains($0 + 1) ? arguments[$0 + 1] : nil }
        }
        XCTAssertEqual(value(after: "--model"), "claude-sonnet-5-5")
        XCTAssertEqual(value(after: "--tools"), "")
        XCTAssertEqual(value(after: "--system-prompt"), CITriage.systemPrompt)
        XCTAssertTrue(arguments.contains("--restricted"))
        XCTAssertTrue(CITriage.systemPrompt.contains("First line: one short sentence"), "what makes the model commit")
        XCTAssertNotEqual(CITriageModel.client.folderName, HaikuTurnEndClassifier.client.folderName)
    }

    /// One account behind both clients: a run billed per call rests every
    /// client, runs that keep failing only their own.
    func testClientsShareTheBilledRestAndKeepTheirOwnFailures() async throws {
        let account = ClaudeOneShotRunner.Account(checkSetup: { [cli] in .ready(cli) })
        try await knowsSetup(account)
        let billed = LockedFlag()
        let failing = ClaudeOneShotRunner(client: CITriageModel.client, account: account, runProcess: { _, _, _ in nil })
        let other = ClaudeOneShotRunner(client: HaikuTurnEndClassifier.client, account: account, runProcess: { _, _, _ in
            billed.value
                ? Self.events([#"{"type":"rate_limit_event","rate_limit_info":{"isUsingOverage":true}}"#, Self.result("ok")])
                : Self.events([Self.result("ok")])
        })
        for _ in 0..<(CITriageModel.client.failuresBeforeRest + 1) {
            let none = await failing.answer(to: Data(), read: { $0 })
            XCTAssertNil(none)
        }
        let unaffected = await other.answer(to: Data(), read: { $0 })
        XCTAssertEqual(unaffected, "ok", "the other client's runs go on")

        billed.value = true
        let paid = await other.answer(to: Data(), read: { $0 })
        XCTAssertEqual(paid, "ok", "paid already: kept")
        XCTAssertEqual(account.setup(), .unavailable, "and no client runs after it")
    }

    /// A run billed per call rests every client until the plan's limit
    /// resets, a day at most, and a relaunch rests too.
    func testABilledRunRestsUntilTheLimitResetsAcrossRelaunches() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("claude-runs-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let restURL = folder.appendingPathComponent("claude-runs-rest")
        let clock = Clock(1_000)
        let account = ClaudeOneShotRunner.Account(checkSetup: { [cli] in .ready(cli) }, now: { clock.value }, restURL: restURL)
        try await knowsSetup(account)
        let resetsAt = 1_000 + 3 * 60 * 60
        let runner = ClaudeOneShotRunner(client: CITriageModel.client, account: account, runProcess: { _, _, _ in
            Self.events([#"{"type":"rate_limit_event","rate_limit_info":{"overageInUse":true,"resetsAt":\#(resetsAt)}}"#, Self.result("ok")])
        }, now: { clock.value })
        let paid = await runner.answer(to: Data(), read: { $0 })
        XCTAssertEqual(paid, "ok")

        // As after a relaunch: another account, the same file.
        let relaunched = ClaudeOneShotRunner.Account(checkSetup: { [cli] in .ready(cli) }, now: { clock.value }, restURL: restURL)
        try await knowsSetup(relaunched)
        clock.value = TimeInterval(resetsAt - 1)
        XCTAssertEqual(account.setup(), .unavailable)
        XCTAssertEqual(relaunched.setup(), .unavailable)
        clock.value = TimeInterval(resetsAt + 1)
        XCTAssertEqual(relaunched.setup(), .ready(cli))

        // A reset a year away rests a day at most.
        relaunched.restAfterBilledRun(resetsAt: clock.value + 365 * 24 * 60 * 60)
        clock.value += ClaudeOneShotRunner.Account.longestBilledRest - 60
        XCTAssertEqual(relaunched.setup(), .unavailable)
        clock.value += 61
        XCTAssertEqual(relaunched.setup(), .ready(cli))

        // A later, shorter rest doesn't shorten one kept on disk.
        let third = ClaudeOneShotRunner.Account(checkSetup: { [cli] in .ready(cli) }, now: { clock.value }, restURL: restURL)
        try await knowsSetup(third)
        relaunched.restAfterBilledRun(resetsAt: clock.value + 3 * 60 * 60)
        third.restAfterBilledRun()
        clock.value += 2 * 60 * 60
        XCTAssertEqual(third.setup(), .unavailable)
        // One written under another clock, further ahead than any rest can
        // be, would never end: it doesn't count.
        try Data(String(Int(clock.value + 30 * 24 * 60 * 60)).utf8).write(to: restURL)
        let fourth = ClaudeOneShotRunner.Account(checkSetup: { [cli] in .ready(cli) }, now: { clock.value }, restURL: restURL)
        try await knowsSetup(fourth)
        XCTAssertEqual(fourth.setup(), .ready(cli))
        XCTAssertEqual(
            ClaudeOneShotRunner.report(from: Self.events([#"{"type":"rate_limit_event","rate_limit_info":{"isUsingOverage":true,"resetsAt":42}}"#])),
            ClaudeOneShotRunner.RunReport(text: nil, billedPerCall: true, overageResetsAt: 42)
        )
    }

    func testAnAnswerTheClientCantReadCountsAsAFailedRun() async throws {
        let account = ClaudeOneShotRunner.Account(checkSetup: { [cli] in .ready(cli) })
        try await knowsSetup(account)
        let runs = LockedCount()
        var resting = CITriageModel.client
        resting.failuresBeforeRest = 2
        let client = resting
        let runner = ClaudeOneShotRunner(client: client, account: account, runProcess: { _, arguments, _ in
            runs.increment()
            XCTAssertEqual(arguments, ClaudeOneShotRunner.arguments(for: client))
            return Self.events([Self.result("no verdict here")])
        })
        for _ in 0..<3 {
            let verdict = await runner.answer(to: Data(), read: CITriage.verdict(fromAnswer:))
            XCTAssertNil(verdict)
        }
        XCTAssertEqual(runs.value, 2, "resting after two")
    }

    private final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var time: TimeInterval
        init(_ time: TimeInterval) { self.time = time }
        var value: TimeInterval {
            get { lock.withLock { time } }
            set { lock.withLock { time = newValue } }
        }
    }

    private final class LockedFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var flag = false
        var value: Bool {
            get { lock.withLock { flag } }
            set { lock.withLock { flag = newValue } }
        }
    }

    private final class LockedCount: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        func increment() { lock.withLock { count += 1 } }
        var value: Int { lock.withLock { count } }
    }
}
