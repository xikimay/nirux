import XCTest
@testable import Nirux

/// Explain's run (docs/branch-review.md, section 4.3), against a fake
/// `claude`: a script that records its arguments, environment, folder and
/// input, then writes the stream-json events a test gives it. The real CLI
/// runs only by hand.
final class BranchReviewExplainRunTests: XCTestCase {
    private var fake: URL!
    private var folder: URL!
    private var cli: BranchReview.ClaudeCLI!

    override func setUpWithError() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("nirux-explain-run-\(UUID().uuidString)")
        fake = base.appendingPathComponent("bin", isDirectory: true)
        folder = base.appendingPathComponent("copy", isDirectory: true)
        try FileManager.default.createDirectory(at: fake, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let script = fake.appendingPathComponent("claude")
        try """
            #!/bin/sh
            dir=$(cd "$(dirname "$0")" && pwd)
            case "$1" in
              --help) cat "$dir/help"; exit 0 ;;
              auth) cat "$dir/auth"; exit 0 ;;
            esac
            printf '%s\\0' "$@" > "$dir/args"
            env > "$dir/env"
            pwd -P > "$dir/cwd"
            cat > "$dir/stdin"
            [ -f "$dir/stderr" ] && cat "$dir/stderr" >&2
            [ -f "$dir/events" ] && cat "$dir/events"
            [ -f "$dir/sleep" ] && exec sleep "$(cat "$dir/sleep")"
            exit "$(cat "$dir/status" 2>/dev/null || echo 0)"

            """.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        cli = BranchReview.ClaudeCLI(path: script.path)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: fake.deletingLastPathComponent())
    }

    /// The run is confined as section 4.3 says, in the copy, with the input
    /// on standard input and none of Nirux's environment beyond the
    /// allowlist; its answer comes back checked against the input.
    func testARunIsConfinedAndItsAnswerChecked() throws {
        try events([
            Self.initEvent(),
            Self.assistant(id: "m1", usage: (10, 0, 0, 5), tools: ["t1"]),
            Self.result(Self.answer)
        ])
        let input = try Self.input()
        let base = [
            "HOME": NSHomeDirectory(), "PATH": "bin:/usr/bin", "NIRUX_AGENT_UUID": "agent", "ANTHROPIC_API_KEY": "billed",
            "CLAUDE_CODE_ENTRYPOINT": "cli", "DISABLE_TELEMETRY": "1"
        ]

        let run = BranchReview.runExplain(input, in: folder, cli: cli, language: "French", environment: base)

        guard case .explained(let output) = run.outcome else { return XCTFail("\(run.outcome)") }
        XCTAssertEqual(output.overview, "Keeps the Mac awake.")
        XCTAssertEqual(output.notes.first?.hunk, .init(path: "Sources/KeepAwake.swift", index: 0))
        XCTAssertEqual(run.setup?.version, "2.1.289")
        XCTAssertEqual(try String(contentsOf: fake.appendingPathComponent("stdin"), encoding: .utf8), input.text)
        XCTAssertEqual(try recorded("cwd"), try XCTUnwrap(folder.path.realPath) + "\n")
        let arguments = try recorded("args").split(separator: "\0", omittingEmptySubsequences: false).map(String.init)
        for flags in [
            ["-p"], ["--model", "claude-opus-5-5"], ["--effort", "medium"], ["--output-format", "stream-json"],
            ["--include-partial-messages"], ["--max-budget-usd", "5.0"], ["--tools", "Read,Grep,Glob"], ["--restricted"],
            ["--permission-prompts", "none"], ["--strict-mcp-config"], ["--disable-slash-commands"],
            ["--no-session-persistence"], ["--settings", #"{"disableAllHooks":true,"instructionFiles":"managed-only"}"#]
        ] {
            XCTAssertTrue(arguments.indices.contains { Array(arguments.dropFirst($0).prefix(flags.count)) == flags }, "\(flags)")
        }
        let prompt = try XCTUnwrap(arguments.firstIndex(of: "--system-prompt").map { arguments[$0 + 1] })
        XCTAssertTrue(prompt.contains("Write in French."))
        let environment = Dictionary(uniqueKeysWithValues: try recorded("env").split(separator: "\n").compactMap { line -> (String, String)? in
            let parts = line.split(separator: "=", maxSplits: 1).map(String.init)
            return parts.count == 2 ? (parts[0], parts[1]) : nil
        })
        // The shell adds PWD, SHLVL and _ itself.
        XCTAssertEqual(Set(environment.keys).subtracting(["PWD", "SHLVL", "_", "OLDPWD"]), ["HOME", "PATH", "DISABLE_TELEMETRY"])
        // The binary's folder first; a relative entry would resolve in the copy.
        XCTAssertEqual(environment["PATH"]?.split(separator: ":").first.map(String.init), fake.path)
        XCTAssertEqual(cli.environment(from: [:], path: "bin:/usr/bin:./node_modules/.bin")["PATH"], fake.path + ":/usr/bin")
    }

    /// The run's first event says how it started: on an API key instead of
    /// the subscription checked, with other tools, or with an MCP server,
    /// it is stopped before its first request.
    func testARunThatStartsOtherwiseIsStopped() throws {
        let input = try Self.input()
        for (event, why) in [
            (Self.initEvent(apiKeySource: "ANTHROPIC_API_KEY"), "it would use an API key (ANTHROPIC_API_KEY) instead of your Claude subscription."),
            (Self.initEvent(tools: ["Read", "Bash", "StructuredOutput"]), "it started with other tools: Bash."),
            (Self.initEvent(mcp: ["github"]), "it started MCP servers.")
        ] {
            try events([event])
            try "30".write(to: fake.appendingPathComponent("sleep"), atomically: true, encoding: .utf8)
            let startedAt = Date()
            XCTAssertEqual(BranchReview.runExplain(input, in: folder, cli: cli).outcome, .failed(.unexpectedSetup(why)))
            XCTAssertLessThan(Date().timeIntervalSince(startedAt), 10)
        }

        // An API key the user accepted after the notice asked.
        try events([Self.initEvent(apiKeySource: "ANTHROPIC_API_KEY"), Self.result(Self.answer)])
        guard case .explained = BranchReview.runExplain(input, in: folder, cli: cli, requiresSubscription: false).outcome else {
            return XCTFail("refused")
        }
    }

    /// The usage of a run that ends is its result's; a run cancelled once
    /// it started reading keeps what its messages reported, each message
    /// counted once at its largest. Only reads count as tool uses.
    func testUsageIsKeptWhenARunEndsOrStops() throws {
        try events([
            Self.assistant(id: "m1", usage: (100, 1_000, 50, 20), tools: []),
            Self.assistant(id: "m1", usage: (100, 1_000, 50, 20), tools: ["t1"]),
            Self.assistant(id: "m2", usage: (5, 2_000, 0, 30), tools: ["t2"]),
            Self.result(Self.answer, usage: (200, 3_000, 50, 60), cost: 0.59, turns: 3)
        ])
        let ended = BranchReview.runExplain(try Self.input(), in: folder, cli: cli)
        XCTAssertEqual(ended.usage.tokensRead, 3_250)
        XCTAssertEqual(ended.usage.outputTokens, 60)
        XCTAssertEqual(ended.usage.costUSD, 0.59)
        XCTAssertEqual(ended.usage.turns, 3)
        XCTAssertTrue(ended.usage.isComplete)
        XCTAssertEqual(ended.models, ["claude-opus-5-5"])

        try events([
            Self.assistant(id: "m1", usage: (100, 1_000, 50, 20), tools: ["t1"]),
            Self.assistant(id: "m1", usage: (100, 1_000, 50, 2), tools: []),
            Self.assistant(id: "m2", usage: (5, 2_000, 0, 30), tools: ["t2"]),
            Self.assistant(id: "m3", usage: (0, 0, 0, 1), tools: ["answer"], tool: "StructuredOutput")
        ])
        try "30".write(to: fake.appendingPathComponent("sleep"), atomically: true, encoding: .utf8)
        let cancellation = BoundedProcess.Cancellation()
        let reads = Counter()
        let startedAt = Date()
        let stopped = BranchReview.runExplain(try Self.input(), in: folder, cli: cli, cancellation: cancellation) { progress in
            reads.value = progress.toolUses
            if progress.toolUses == 2 { cancellation.cancel() }
        }
        XCTAssertEqual(stopped.outcome, .cancelled)
        XCTAssertEqual(reads.value, 2)
        XCTAssertEqual(stopped.usage.tokensRead, 3_155)
        XCTAssertEqual(stopped.usage.outputTokens, 51)
        XCTAssertNil(stopped.usage.costUSD)
        XCTAssertFalse(stopped.usage.isComplete)
        XCTAssertLessThan(Date().timeIntervalSince(startedAt), 10)
    }

    /// A run that ends on the plan's usage limit says so, however claude
    /// reports it; not a run that goes on billed on extra usage, nor a
    /// limit lifted since, nor another kind of limit.
    func testAUsageLimitIsSaidAsSuch() throws {
        let input = try Self.input()
        try events([
            Self.rateLimit(status: "rejected"),
            #"{"type":"result","subtype":"success","is_error":true,"result":"Claude AI usage limit reached|1800000000"}"#
        ])
        XCTAssertEqual(
            BranchReview.runExplain(input, in: folder, cli: cli).outcome, .usageLimit(resetsAt: Date(timeIntervalSince1970: 1_800_000_000))
        )

        for wording in [
            "You've hit your limit", "You've hit your session limit · resets 3pm", "You've hit your weekly limit",
            "You've hit your Opus limit", "Claude AI usage limit reached"
        ] {
            try events([#"{"type":"result","subtype":"error_during_execution","is_error":true,"errors":["\#(wording)"]}"#])
            XCTAssertEqual(BranchReview.runExplain(input, in: folder, cli: cli).outcome, .usageLimit(resetsAt: nil), wording)
        }
        // The servers throttling, not the plan: try again soon.
        try events([#"{"type":"result","subtype":"error_during_execution","is_error":true,"errors":["API Error: Server is temporarily limiting requests (not your usage limit)"]}"#])
        XCTAssertEqual(BranchReview.runExplain(input, in: folder, cli: cli).outcome, .failed(.overloaded))

        try events([])
        try "Claude AI usage limit reached\n".write(to: fake.appendingPathComponent("stderr"), atomically: true, encoding: .utf8)
        try "1".write(to: fake.appendingPathComponent("status"), atomically: true, encoding: .utf8)
        XCTAssertEqual(BranchReview.runExplain(input, in: folder, cli: cli).outcome, .usageLimit(resetsAt: nil))
        try FileManager.default.removeItem(at: fake.appendingPathComponent("stderr"))
        try FileManager.default.removeItem(at: fake.appendingPathComponent("status"))

        // Stalled behind the limit, it says so rather than "timed out".
        try events([Self.rateLimit(status: "rejected")])
        try "30".write(to: fake.appendingPathComponent("sleep"), atomically: true, encoding: .utf8)
        var settings = BranchReview.ExplainSettings()
        settings.idleTimeout = 1
        XCTAssertEqual(
            BranchReview.runExplain(input, in: folder, cli: cli, settings: settings).outcome,
            .usageLimit(resetsAt: Date(timeIntervalSince1970: 1_800_000_000))
        )

        // A limit on one model, then an answer from another: the answer
        // counts.
        try events([Self.rateLimit(status: "rejected"), Self.result(Self.answer)])
        guard case .explained = BranchReview.runExplain(input, in: folder, cli: cli).outcome else { return XCTFail("thrown away") }

        // Extra usage pays for the overflow: the answer counts, and a
        // failure is the failure's.
        try events([Self.rateLimit(status: "rejected", overage: true), Self.result(Self.answer)])
        guard case .explained = BranchReview.runExplain(input, in: folder, cli: cli).outcome else { return XCTFail("thrown away") }
        try events([Self.rateLimit(status: "rejected", overage: true), #"{"type":"result","subtype":"error_during_execution","is_error":true,"errors":["Context limit reached"]}"#])
        XCTAssertEqual(BranchReview.runExplain(input, in: folder, cli: cli).outcome, .failed(.claude("Context limit reached")))
        try events([Self.rateLimit(status: "rejected"), Self.rateLimit(status: "allowed"), #"{"type":"result","subtype":"error_during_execution","is_error":true,"errors":["Context limit reached"]}"#])
        XCTAssertEqual(BranchReview.runExplain(input, in: folder, cli: cli).outcome, .failed(.claude("Context limit reached")))
    }

    /// A run that fails says why, in terms the page can act on.
    func testFailuresSayWhy() throws {
        let input = try Self.input()
        for (line, failure) in [
            ("Error: not logged in · Please run /login", BranchReview.ExplainFailure.notLoggedIn),
            ("There's an issue with the selected model (claude-opus-5-5). Run /model", .modelUnavailable("claude-opus-5-5")),
            ("API Error: 529 {\"type\":\"overloaded_error\"}", .overloaded),
            ("API Error: 529 Service Unavailable", .overloaded),
            ("Opus is experiencing high load, please use /model to switch to Sonnet", .overloaded),
            ("Prompt is too long: 215290 tokens > 200000 maximum", .claude("Prompt is too long: 215290 tokens > 200000 maximum")),
            ("Something \u{202E}else", .claude("Something ⟨U+202E⟩else"))
        ] {
            try events([])
            try (line + "\n").write(to: fake.appendingPathComponent("stderr"), atomically: true, encoding: .utf8)
            try "1".write(to: fake.appendingPathComponent("status"), atomically: true, encoding: .utf8)
            XCTAssertEqual(BranchReview.runExplain(input, in: folder, cli: cli).outcome, .failed(failure), line)
        }
        try FileManager.default.removeItem(at: fake.appendingPathComponent("stderr"))
        try FileManager.default.removeItem(at: fake.appendingPathComponent("status"))

        // The CLI's `error_*` results: `errors`, no `result`.
        try events([#"{"type":"result","subtype":"error_max_turns","is_error":true,"errors":[]}"#])
        XCTAssertEqual(BranchReview.runExplain(input, in: folder, cli: cli).outcome, .failed(.claude("it ended with error_max_turns.")))
        try events([#"{"type":"result","subtype":"error_during_execution","is_error":true,"errors":["Tool use failed", "twice"]}"#])
        XCTAssertEqual(BranchReview.runExplain(input, in: folder, cli: cli).outcome, .failed(.claude("Tool use failed twice")))
        try events([#"{"type":"result","subtype":"error_max_budget_usd","is_error":true,"errors":[]}"#])
        XCTAssertEqual(BranchReview.runExplain(input, in: folder, cli: cli).outcome, .failed(.overBudget))
        try events([#"{"type":"result","subtype":"error_max_structured_output_retries","is_error":true,"errors":[]}"#])
        XCTAssertEqual(BranchReview.runExplain(input, in: folder, cli: cli).outcome, .failed(.unreadableAnswer))

        try events([Self.result(.object(["groups": .array([])]))])
        XCTAssertEqual(BranchReview.runExplain(input, in: folder, cli: cli).outcome, .failed(.unreadableAnswer))

        // The last line, without its newline.
        try events([Self.result(Self.answer)], newline: false)
        guard case .explained = BranchReview.runExplain(input, in: folder, cli: cli).outcome else { return XCTFail("last line lost") }

        try events([Self.assistant(id: "m1", usage: (1, 0, 0, 1), tools: [])])
        try "30".write(to: fake.appendingPathComponent("sleep"), atomically: true, encoding: .utf8)
        var settings = BranchReview.ExplainSettings()
        settings.timeout = 1
        XCTAssertEqual(BranchReview.runExplain(input, in: folder, cli: cli, settings: settings).outcome, .timedOut)

        let missing = BranchReview.ClaudeCLI(path: fake.appendingPathComponent("gone").path)
        XCTAssertEqual(BranchReview.runExplain(input, in: folder, cli: missing).outcome, .failed(.couldNotStart(missing.path)))
    }

    /// Explain runs the first claude found that confines its runs: an old
    /// one earlier in `PATH` doesn't hide it, nor does a relative entry
    /// count. Then it names the account the run will use.
    func testTheClaudeThatConfinesItsRunsIsFound() throws {
        let old = fake.deletingLastPathComponent().appendingPathComponent("old", isDirectory: true)
        try FileManager.default.createDirectory(at: old, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: fake.appendingPathComponent("claude"), to: old.appendingPathComponent("claude"))
        // Confined, but without a spending limit.
        try "  --restricted\n  --permission-prompts <target>\n".write(to: old.appendingPathComponent("help"), atomically: true, encoding: .utf8)
        try "  --restricted  Restricted mode\n  --permission-prompts <target>\n  --max-budget-usd <amount>\n".write(
            to: fake.appendingPathComponent("help"), atomically: true, encoding: .utf8
        )
        XCTAssertEqual(BranchReview.ClaudeCLI.locate(directories: ["relative", old.path, fake.path]), .ready(cli))
        XCTAssertEqual(BranchReview.ClaudeCLI.locate(directories: [old.path]), .tooOld([old.appendingPathComponent("claude").path]))
        XCTAssertEqual(BranchReview.ClaudeCLI.locate(directories: [old.appendingPathComponent("none").path]), .missing)

        try #"{"loggedIn":true,"authMethod":"claude.ai","subscriptionType":"max","email":"a@example.test","apiProvider":"firstParty"}"#.write(
            to: fake.appendingPathComponent("auth"), atomically: true, encoding: .utf8
        )
        let account = try XCTUnwrap(cli.account())
        XCTAssertEqual(account.label, "claude.ai, Max")
        XCTAssertFalse(account.isBilledPerCall)
        for json in [
            #"{"loggedIn":true,"authMethod":"api_key"}"#, #"{"loggedIn":true,"authMethod":"api_key_helper"}"#,
            #"{"loggedIn":true,"authMethod":"oauth_token"}"#, #"{"loggedIn":true,"authMethod":"third_party","apiProvider":"bedrock"}"#
        ] {
            try json.write(to: fake.appendingPathComponent("auth"), atomically: true, encoding: .utf8)
            XCTAssertEqual(cli.account()?.isBilledPerCall, true, json)
        }
        try "not json".write(to: fake.appendingPathComponent("auth"), atomically: true, encoding: .utf8)
        XCTAssertNil(cli.account())
    }

    func testTheAnswerIsInTheMacsLanguage() {
        XCTAssertEqual(BranchReview.explainLanguage(preferred: ["fr-FR", "en"]), "French")
        XCTAssertEqual(BranchReview.explainLanguage(preferred: ["zh-Hant-TW"]), "Chinese, Traditional")
        XCTAssertEqual(BranchReview.explainLanguage(preferred: []), "English")
    }

    // MARK: - Helpers

    private func events(_ lines: [String], newline: Bool = true) throws {
        try (lines.joined(separator: "\n") + (lines.isEmpty || !newline ? "" : "\n"))
            .write(to: fake.appendingPathComponent("events"), atomically: true, encoding: .utf8)
        try? FileManager.default.removeItem(at: fake.appendingPathComponent("sleep"))
    }

    private func recorded(_ name: String) throws -> String {
        try String(contentsOf: fake.appendingPathComponent(name), encoding: .utf8)
    }

    static func input() throws -> BranchReview.ExplainInput {
        try XCTUnwrap(BranchReview.explainInputs(for: BranchReviewPageTests.snapshot(), handover: nil) { _ in nil }.first)
    }

    static let answer: JSONValue = .object([
        "overview": .string("Keeps the Mac awake."),
        "groups": .array([.object(["intent": .string("feature"), "title": .string("Keep awake"), "files": .array([.string("f0")])])]),
        "files": .array([.object(["file": .string("f0"), "summary": .string("Adds the controller."), "importance": .int(3)])]),
        "notes": .array([.object(["hunk": .string("f0h0"), "text": .string("Changes a."), "check": .string("Is a used?")])]),
        "claims": .array([]),
        "questions": .array([.string("Why?")])
    ])

    typealias Usage = (input: Int, cacheRead: Int, cacheCreation: Int, output: Int)

    static func initEvent(apiKeySource: String = "none", tools: [String] = ["Glob", "Grep", "Read", "StructuredOutput"], mcp: [String] = []) -> String {
        let names = tools.map { #""\#($0)""# }.joined(separator: ",")
        let servers = mcp.map { #"{"name":"\#($0)","status":"connected"}"# }.joined(separator: ",")
        return #"{"type":"system","subtype":"init","claude_code_version":"2.1.289","model":"claude-opus-5-5","apiKeySource":"\#(apiKeySource)","tools":[\#(names)],"mcp_servers":[\#(servers)]}"#
    }

    static func rateLimit(status: String, overage: Bool = false) -> String {
        #"{"type":"rate_limit_event","rate_limit_info":{"status":"\#(status)","resetsAt":1800000000,"rateLimitType":"five_hour","isUsingOverage":\#(overage)}}"#
    }

    static func assistant(id: String, usage: Usage, tools: [String], tool: String = "Read") -> String {
        let content = tools.map { #"{"type":"tool_use","id":"\#($0)","name":"\#(tool)","input":{}}"# }.joined(separator: ",")
        return #"{"type":"assistant","message":{"id":"\#(id)","content":[\#(content)],"usage":\#(usageJSON(usage))}}"#
    }

    static func result(_ answer: JSONValue, usage: Usage = (1, 0, 0, 1), cost: Double = 0.01, turns: Int = 1) -> String {
        let structured = String(decoding: try! JSONEncoder().encode(answer), as: UTF8.self)
        return #"{"type":"result","subtype":"success","is_error":false,"num_turns":\#(turns),"total_cost_usd":\#(cost),"usage":\#(usageJSON(usage)),"modelUsage":{"claude-opus-5-5":{}},"result":"","structured_output":\#(structured)}"#
    }

    private static func usageJSON(_ usage: Usage) -> String {
        #"{"input_tokens":\#(usage.input),"cache_read_input_tokens":\#(usage.cacheRead),"cache_creation_input_tokens":\#(usage.cacheCreation),"output_tokens":\#(usage.output)}"#
    }
}

/// Set from the run's waiting thread.
private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = 0

    var value: Int {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}
