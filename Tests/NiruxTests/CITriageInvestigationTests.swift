import XCTest
@testable import Nirux

/// docs/ci-failure-triage.md: what reading one failed run asks of `gh`,
/// of the local repository and of the model, and when it asks nothing.
/// `gh`, `git` and the model are doubles; every log is made up.
final class CITriageInvestigationTests: XCTestCase {
    private static let commit = String(repeating: "c", count: 40)
    private static let runnerPath = "/Users/runner/work/widgets/widgets/Tests/WidgetTests"
    private static let failureLine = "test\tRun tests\t2026-11-09T23:09:12.1234567Z \(runnerPath)/GearTests.swift:41: "
        + "error: -[WidgetTests.GearTests testStops] : XCTAssertEqual failed"

    /// What a double answers, by the `gh` subcommand asked.
    private struct World: Sendable {
        var runView: String? = #"{"attempt":1,"headSha":"\#(commit)","jobs":[{"name":"test","conclusion":"failure","steps":[{"name":"Run tests","conclusion":"failure"}]}]}"#
        var log: String? = failureLine
        var files: String? = #"{"filename":"Sources/Widgets/Axle.swift","patch":"@@ -1,2 +1,2 @@\n struct Axle {\n-    var speed = 1\n+    var speed = 2"}"#
        var commitIsLocal = true
        var answer: CITriage.Verdict? = .flaky(reason: "The tests drive gears; the changes edit an axle.")
    }

    private final class Calls: @unchecked Sendable {
        private let lock = NSLock()
        private var ghCalls: [[String]] = []
        private var gitCalls: [[String]] = []
        private var modelInputs: [String] = []

        func gh(_ arguments: [String]) { lock.withLock { ghCalls.append(arguments) } }
        func git(_ arguments: [String]) { lock.withLock { gitCalls.append(arguments) } }
        func model(_ input: String) { lock.withLock { modelInputs.append(input) } }
        var gh: [[String]] { lock.withLock { ghCalls } }
        var git: [[String]] { lock.withLock { gitCalls } }
        var inputs: [String] { lock.withLock { modelInputs } }
        /// "run view --json", "run view --log-failed", "api": what was asked, in order.
        var asked: [String] {
            gh.map { $0.contains("--log-failed") ? "log" : $0.first == "api" ? "files" : "run" }
        }
    }

    private func effects(_ world: World, _ calls: Calls) -> CITriageInvestigation.Effects {
        CITriageInvestigation.Effects(
            gh: { arguments, _, _ in
                calls.gh(arguments)
                let answer = arguments.contains("--log-failed") ? world.log : arguments.first == "api" ? world.files : world.runView
                return answer.map { Data($0.utf8) }
            },
            git: { arguments, _ in
                calls.git(arguments)
                switch arguments.prefix(2) {
                case ["cat-file", "-e"]: return world.commitIsLocal ? Data() : nil
                case ["ls-tree", "-r"]: return Data("Sources/Widgets/Axle.swift\u{0}Tests/WidgetTests/GearTests.swift\u{0}".utf8)
                case ["cat-file", "blob"] where arguments.last == "\(Self.commit):Tests/WidgetTests/GearTests.swift":
                    return Data("final class GearTests {\n    func testStops() {\n        stop()\n    }\n}\n".utf8)
                case ["cat-file", "blob"] where arguments.last == "\(Self.commit):Sources/Widgets/Axle.swift":
                    return Data("struct Axle {\n    var speed = 2\n}\n".utf8)
                default: return nil
                }
            },
            model: { input in
                calls.model(String(decoding: input, as: UTF8.self))
                return world.answer
            }
        )
    }

    private func request(isModelAllowed: Bool = true, previous: Set<String> = [], flaky: Set<String> = [], root: String? = "/repo")
        -> CITriageInvestigation.Request {
        CITriageInvestigation.Request(
            run: CIFailure.Run(repository: "github.com/acme/widgets", id: 7), pullRequest: 52, repositoryRoot: root,
            isModelAllowed: isModelAllowed, previousAttemptTests: previous, knownFlaky: flaky
        )
    }

    private func investigate(_ world: World, _ request: CITriageInvestigation.Request? = nil) async
        -> (outcome: CITriageInvestigation.Outcome, calls: Calls) {
        let calls = Calls()
        return (await CITriageInvestigation.investigate(request ?? self.request(), effects: effects(world, calls)), calls)
    }

    // MARK: - What the rules settle asks no model

    func testAJobThatNeverRanIsSettledByTheRunAlone() async {
        var world = World()
        world.runView = #"{"attempt":1,"headSha":"\#(Self.commit)","jobs":[{"name":"test","conclusion":"cancelled","steps":[]}]}"#
        let (outcome, calls) = await investigate(world)
        XCTAssertEqual(outcome, CITriageInvestigation.Outcome(verdict: .flaky(reason: CITriage.neverRanReason), tests: [], wasRead: true))
        XCTAssertEqual(calls.asked, ["run"], "no log to read")
    }

    func testACompileErrorIsRealWithoutThePullRequestsFiles() async {
        var world = World()
        world.log = "test\tBuild\t2026-11-09T23:09:12.1234567Z /Users/runner/work/widgets/widgets/Sources/Widgets/Axle.swift:3:5: error: nope"
        let (outcome, calls) = await investigate(world)
        XCTAssertEqual(outcome.verdict, .real)
        XCTAssertEqual(calls.asked, ["run", "log"])
        XCTAssertEqual(calls.inputs, [])
    }

    func testAnEditedTestFileIsRealAndARerunCuredTestIsFlaky() async {
        var world = World()
        world.files = #"{"filename":"Tests/WidgetTests/GearTests.swift","patch":null}"#
        let edited = await investigate(world, request(flaky: ["GearTests.testStops"]))
        XCTAssertEqual(edited.outcome.verdict, .real)
        XCTAssertEqual(edited.outcome.tests, ["GearTests.testStops"])
        XCTAssertEqual(edited.calls.asked, ["run", "log", "files"])
        XCTAssertEqual(edited.calls.gh.last, [
            "api", "--hostname", "github.com", "--paginate", "repos/acme/widgets/pulls/52/files?per_page=100",
            "--jq", #".[] | {filename, patch: ((.patch // "") | .[0:20000])}"#
        ])

        let cured = await investigate(World(), request(flaky: ["GearTests.testStops"]))
        XCTAssertEqual(cured.outcome.verdict, .flaky(reason: CITriage.knownFlakyReason(["GearTests.testStops"])))
        let again = await investigate(World(), request(previous: ["GearTests.testStops"], flaky: ["GearTests.testStops"]))
        XCTAssertEqual(again.outcome.verdict, .real, "it failed in the attempt before too")
        XCTAssertEqual(cured.calls.inputs + again.calls.inputs + edited.calls.inputs, [], "the rules settled them")
    }

    // MARK: - What they leave open

    func testAnOpenFailureGoesToTheModelWithItsSourceAndTheChangedDeclarations() async throws {
        let (outcome, calls) = await investigate(World())
        XCTAssertEqual(outcome, CITriageInvestigation.Outcome(
            verdict: .flaky(reason: "The tests drive gears; the changes edit an axle."), tests: ["GearTests.testStops"], wasRead: true
        ))
        let input = try XCTUnwrap(calls.inputs.first)
        XCTAssertEqual(calls.inputs.count, 1)
        XCTAssertTrue(input.contains("- GearTests.testStops\n    GearTests.swift:41: XCTAssertEqual failed"), input)
        XCTAssertTrue(input.contains("// Tests/WidgetTests/GearTests.swift\n    func testStops() {\n        stop()\n    }"), input)
        XCTAssertTrue(input.contains("The pull request changes 1 files:\nSources/Widgets/Axle.swift: var speed"), input)
        // Read at the run's commit, in the workspace's repository.
        XCTAssertEqual(calls.git.first, ["cat-file", "-e", "\(Self.commit)^{commit}"])
        XCTAssertTrue(calls.git.contains(["cat-file", "blob", "\(Self.commit):Tests/WidgetTests/GearTests.swift"]))
    }

    func testWithoutTheCommitTheModelReadsNamesOnly() async throws {
        var world = World()
        world.commitIsLocal = false
        let (outcome, calls) = await investigate(world)
        XCTAssertNotNil(outcome.verdict.flakyReason)
        let input = try XCTUnwrap(calls.inputs.first)
        XCTAssertFalse(input.contains("Source of the failing tests"))
        XCTAssertTrue(input.hasSuffix("The pull request changes 1 files:\nSources/Widgets/Axle.swift\n</failure>"), input)
        XCTAssertEqual(calls.git, [["cat-file", "-e", "\(Self.commit)^{commit}"]], "nothing else is asked of a commit that isn't there")

        let (rootless, rootlessCalls) = await investigate(World(), request(root: nil))
        XCTAssertNotNil(rootless.verdict.flakyReason)
        XCTAssertEqual(rootlessCalls.git, [])
    }

    /// A workspace whose agent runs on another account: the rules only.
    /// The run is still read and remembered, which is how Nirux learns.
    func testNoModelForAWorkspaceOnAnotherAccount() async {
        let (outcome, calls) = await investigate(World(), request(isModelAllowed: false))
        XCTAssertEqual(outcome, CITriageInvestigation.Outcome(verdict: .unsure, tests: ["GearTests.testStops"], wasRead: true))
        XCTAssertEqual(calls.inputs, [])
        XCTAssertEqual(calls.git, [], "nor its source read for nothing")
    }

    func testAnythingMissingMeansNoVerdict() async {
        var world = World()
        world.answer = nil
        let silent = await investigate(world)
        XCTAssertEqual(silent.outcome.verdict, .unsure, "the model gave no answer")
        XCTAssertTrue(silent.outcome.wasRead)

        world = World()
        world.files = #"{"message":"Bad credentials"}"#
        let noFiles = await investigate(world, request(flaky: ["GearTests.testStops"]))
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
        world.runView = #"{"attempt":2,"headSha":"\#(Self.commit)","jobs":[{"name":"test","conclusion":"success","steps":[{"name":"Run tests","conclusion":"success"}]}]}"#
        let green = await investigate(world)
        XCTAssertEqual(green.outcome, CITriageInvestigation.Outcome())
        XCTAssertEqual(green.calls.asked, ["run"])
    }

    func testOnlyARepositoryWithItsHostIsAskedForFiles() {
        func arguments(_ repository: String) -> [String]? {
            CITriageInvestigation.changedFilesArguments(CITriageInvestigation.Request(
                run: CIFailure.Run(repository: repository, id: 7), pullRequest: 52, repositoryRoot: nil,
                isModelAllowed: false, previousAttemptTests: [], knownFlaky: []
            ))
        }
        XCTAssertEqual(arguments("ghe.example.com/acme/widgets")?[2], "ghe.example.com")
        XCTAssertNil(arguments("acme/widgets"))
        XCTAssertNil(arguments("github.com/acme/widgets/extra"))
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
        XCTAssertNotEqual(CITriageModel.client.folderName, ClaudeTurnEndClassifier.client.folderName)
    }

    /// One account behind both clients: a run billed per call rests every
    /// client, runs that keep failing only their own.
    func testClientsShareTheBilledRestAndKeepTheirOwnFailures() async throws {
        let account = ClaudeOneShotRunner.Account(checkSetup: { [cli] in .ready(cli) })
        try await knowsSetup(account)
        let billed = LockedFlag()
        let failing = ClaudeOneShotRunner(client: CITriageModel.client, account: account, runProcess: { _, _, _ in nil })
        let other = ClaudeOneShotRunner(client: ClaudeTurnEndClassifier.client, account: account, runProcess: { _, _, _ in
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
