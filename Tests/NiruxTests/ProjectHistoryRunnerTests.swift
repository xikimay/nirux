import XCTest
@testable import Nirux

/// The background `claude -p` calls (docs/project-memory-tree.md, section
/// 3.3), against a fake `claude` that answers each message it reads with
/// the next result a test gives it. The real CLI runs only by hand.
final class ProjectHistoryRunnerTests: XCTestCase {
    private var bin: URL!
    private var runs: URL!

    override func setUpWithError() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("nirux-runner-\(UUID().uuidString)")
        bin = base.appendingPathComponent("bin", isDirectory: true)
        runs = base.appendingPathComponent("runs", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: runs, withIntermediateDirectories: true)
        let script = bin.appendingPathComponent("claude")
        try """
            #!/bin/sh
            dir=$(cd "$(dirname "$0")" && pwd)
            printf '%s\\0' "$@" > "$dir/args"
            env > "$dir/env"
            if [ -f "$dir/stderr" ]; then cat "$dir/stderr" >&2; exit 1; fi
            n=0
            while IFS= read -r line; do
              n=$((n + 1))
              printf '%s\\n' "$line" >> "$dir/stdin"
              cat "$dir/init"
              [ -f "$dir/event$n" ] && cat "$dir/event$n"
              [ -f "$dir/sleep$n" ] && sleep "$(cat "$dir/sleep$n")"
              [ -f "$dir/result$n" ] || exit 0
              cat "$dir/result$n"
            done

            """.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        try event(["type": "system", "subtype": "init", "tools": [], "mcp_servers": [], "apiKeySource": "none"], named: "init")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: bin.deletingLastPathComponent())
    }

    private func event(_ object: [String: Any], named name: String) throws {
        var data = try JSONSerialization.data(withJSONObject: object)
        data.append(0x0A)
        try data.write(to: bin.appendingPathComponent(name))
    }

    private func write(_ text: String, named name: String) throws {
        try text.write(to: bin.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }

    /// A result as `claude -p` writes it: its turn's `usage`; the whole
    /// conversation's `modelUsage` (here with an auxiliary model's call)
    /// and cost so far.
    private func result(
        _ text: String, error: Bool = false, status: Int? = nil, kind: String? = nil, number: Int, modelUsage: Bool = true
    ) throws {
        var object: [String: Any] = [
            "type": "result", "subtype": "success", "is_error": error, "result": text,
            "usage": ["input_tokens": 3, "cache_creation_input_tokens": 1_000, "cache_read_input_tokens": 9_000, "output_tokens": 120],
            "total_cost_usd": 0.01 * Double(number)
        ]
        if modelUsage {
            object["modelUsage"] = [
                "claude-sonnet-5-5": [
                    "inputTokens": 3 * number, "cacheCreationInputTokens": 1_000 * number,
                    "cacheReadInputTokens": 9_000 * number, "outputTokens": 120 * number, "costUSD": 0.01 * Double(number)
                ],
                "claude-haiku-4-5": ["inputTokens": 50, "cacheCreationInputTokens": 0, "cacheReadInputTokens": 500, "outputTokens": 5]
            ]
        }
        if let status { object["api_error_status"] = status }
        if let kind { object["api_error"] = kind }
        try event(object, named: "result\(number)")
    }

    private func recorded(_ name: String) throws -> String {
        try String(contentsOf: bin.appendingPathComponent(name), encoding: .utf8)
    }

    private func runner(_ model: ProjectHistory.RunnerModel = .sonnet) -> ProjectHistory.ClaudeRunner {
        ProjectHistory.ClaudeRunner(
            cli: BranchReview.ClaudeCLI(path: bin.appendingPathComponent("claude").path), model: model, timeout: 20,
            idleTimeout: 10, workingDirectory: runs
        )
    }

    private func converse(_ runner: ProjectHistory.ClaudeRunner? = nil) -> ProjectHistory.ConversationResult {
        (runner ?? self.runner()).converse(system: "the system prompt", message: "the message") { _, _ in nil }
    }

    /// A follow-up goes in the same conversation; the input ends once
    /// `followUp` has nothing more, which ends the run. The flags confine
    /// it; the system prompt goes as given; the usage is the last result's,
    /// which counts the whole conversation.
    func testAFollowUpGoesInTheSameConversation() throws {
        try result("first answer", number: 1)
        try result("second answer", number: 2)
        let asked = Locked<[Int]>([])

        let outcome = runner().converse(system: "the system prompt\non two lines", message: "the message") { answer, count in
            asked.update { $0 + [count] }
            return answer == "first answer" ? "say it shorter" : nil
        }

        XCTAssertEqual(outcome.answers, ["first answer", "second answer"])
        XCTAssertNil(outcome.failure)
        XCTAssertEqual(asked.value, [1, 2])
        XCTAssertEqual(outcome.usage.tries, 2)
        XCTAssertEqual(outcome.usage.cacheReadTokens, 18_500, "the last result's modelUsage counts the conversation")
        XCTAssertEqual(outcome.usage.inputTokens, 56)
        XCTAssertEqual(outcome.usage.costUSD, 0.02, accuracy: 1e-9)
        XCTAssertLessThan(outcome.usage.seconds, 8, "the closed input ended the run before the idle timeout")
        let messages = try recorded("stdin").split(separator: "\n").map { line -> String in
            let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
            let content = try XCTUnwrap((object["message"] as? [String: Any])?["content"] as? [[String: Any]])
            return try XCTUnwrap(content.first?["text"] as? String)
        }
        XCTAssertEqual(messages, ["the message", "say it shorter"])
        let arguments = try recorded("args").split(separator: "\0", omittingEmptySubsequences: false).map(String.init)
        for flags in [
            ["-p"], ["--model", "claude-sonnet-5-5"], ["--effort", "medium"], ["--input-format", "stream-json"],
            ["--output-format", "stream-json"], ["--include-partial-messages"], ["--max-budget-usd", "1.0"],
            ["--tools", ""], ["--restricted"], ["--permission-prompts", "none"], ["--strict-mcp-config"],
            ["--disable-slash-commands"], ["--no-session-persistence"],
            ["--settings", #"{"disableAllHooks":true,"instructionFiles":"managed-only"}"#],
            ["--system-prompt", "the system prompt\non two lines"]
        ] {
            XCTAssertTrue(arguments.indices.contains { Array(arguments.dropFirst($0).prefix(flags.count)) == flags }, "\(flags)")
        }
        XCTAssertTrue(try recorded("env").contains("CLAUDE_CODE_PROMPT_CACHE_TTL=5m"))
    }

    /// No API key, base URL or other provider setting reaches the run.
    func testTheEnvironmentKeepsNoAPIKey() {
        let environment = runner().environment(from: [
            "HOME": "/Users/u", "ANTHROPIC_API_KEY": "sk-ant-api03-x", "ANTHROPIC_BASE_URL": "https://proxy",
            "CLAUDE_CODE_USE_BEDROCK": "1", "PATH": "/usr/bin"
        ])
        XCTAssertEqual(environment["HOME"], "/Users/u")
        XCTAssertEqual(environment["CLAUDE_CODE_PROMPT_CACHE_TTL"], "5m")
        XCTAssertNil(environment["ANTHROPIC_API_KEY"])
        XCTAssertNil(environment["ANTHROPIC_BASE_URL"])
        XCTAssertNil(environment["CLAUDE_CODE_USE_BEDROCK"])
    }

    /// The caller's cancellation stops a run under way.
    func testTheCallersCancellationStopsTheRun() throws {
        try result("an answer", number: 1)
        try write("5", named: "sleep1")
        let cancellation = BoundedProcess.Cancellation()
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) { cancellation.cancel() }
        let outcome = runner().converse(system: "s", message: "m", followUp: { _, _ in nil }, cancellation: cancellation)
        XCTAssertEqual(outcome.answers, [])
        XCTAssertEqual(outcome.failure, .transient("the run stopped (cancelled)"))
        XCTAssertLessThan(outcome.usage.seconds, 4)
    }

    /// Without `modelUsage`, each turn's own usage is summed.
    func testUsageWithoutModelUsageIsSummed() throws {
        try result("first answer", number: 1, modelUsage: false)
        try result("second answer", number: 2, modelUsage: false)
        let outcome = runner().converse(system: "s", message: "m") { _, count in count == 1 ? "again" : nil }
        XCTAssertEqual(outcome.usage.cacheReadTokens, 18_000)
        XCTAssertEqual(outcome.usage.outputTokens, 240)
    }

    /// A conversation stops at `maxAnswers`, whatever `followUp` asks.
    func testFollowUpsStopAtMaxAnswers() throws {
        for number in 1...4 { try result("answer \(number)", number: number) }
        var bounded = runner()
        bounded.maxAnswers = 2
        let outcome = bounded.converse(system: "s", message: "m") { _, _ in "again" }
        XCTAssertEqual(outcome.answers, ["answer 1", "answer 2"])
        XCTAssertNil(outcome.failure)
    }

    /// A follow-up whose answer never comes fails the call: the answer it
    /// asked to fix isn't returned as final. A silent run counts as a
    /// failed try, not as the network's.
    func testAConversationCutShortFails() throws {
        try result("first answer", number: 1)
        let cut = runner().converse(system: "s", message: "m") { _, count in count == 1 ? "fix it" : nil }
        XCTAssertEqual(cut.answers, [])
        guard case .permanent = cut.failure else { return XCTFail("\(String(describing: cut.failure))") }

        try result("API Error: 529 Overloaded", error: true, number: 2)
        let failedFix = runner().converse(system: "s", message: "m") { _, count in count == 1 ? "fix it" : nil }
        XCTAssertEqual(failedFix.answers, [], "the answer it asked to fix isn't kept")
        guard case .transient = failedFix.failure else { return XCTFail("\(String(describing: failedFix.failure))") }
        try FileManager.default.removeItem(at: bin.appendingPathComponent("result2"))

        try write("3", named: "sleep1")
        var impatient = runner()
        impatient.idleTimeout = 1
        let stalled = converse(impatient)
        XCTAssertEqual(stalled.answers, [])
        XCTAssertEqual(stalled.failure, .permanent("the run stalled (idle)"))

        try event(["type": "system", "subtype": "api_retry", "attempt": 1, "error": "server_error"], named: "event1")
        XCTAssertEqual(converse(impatient).failure, .transient("the run stalled retrying (idle)"),
                       "Claude Code was retrying the network: not a failed try")
        try event(["type": "system", "subtype": "api_retry", "attempt": 1, "error": "billing_error"], named: "event1")
        XCTAssertEqual(converse(impatient).failure, .unavailable("the run stalled retrying (billing_error)"))

        // A retry its turn got past doesn't excuse the follow-up's stall.
        try FileManager.default.removeItem(at: bin.appendingPathComponent("sleep1"))
        try event(["type": "system", "subtype": "api_retry", "attempt": 1, "error": "server_error"], named: "event1")
        try write("3", named: "sleep2")
        let hung = impatient.converse(system: "s", message: "m") { _, count in count == 1 ? "fix it" : nil }
        XCTAssertEqual(hung.failure, .permanent("the run stalled (idle)"))
    }

    /// Haiku runs without thinking and without an effort.
    func testHaikuRunsWithoutThinking() throws {
        try result("an answer", number: 1)
        _ = converse(runner(.haiku))
        let arguments = try recorded("args").split(separator: "\0").map(String.init)
        XCTAssertTrue(arguments.contains("claude-haiku-4-5"))
        XCTAssertFalse(arguments.contains("--effort"))
        XCTAssertTrue(try recorded("env").contains("MAX_THINKING_TOKENS=0"))
    }

    /// Near the limit, the answer already paid for is kept and the call
    /// says to pause; extra usage stops the run at once.
    func testUsageNearTheLimitPausesAndOverageStops() throws {
        // As Claude Code 2.1.291 sent it on 2026-10-06: a warning at 32%.
        try event(["type": "rate_limit_event", "rate_limit_info": [
            "status": "allowed_warning", "resetsAt": 1_800_000_000, "rateLimitType": "seven_day", "utilization": 0.32,
            "isUsingOverage": false, "unifiedWindows": [
                "five_hour": ["utilization": 0.09, "resetsAt": 1_799_990_000], "seven_day": ["utilization": 0.32, "resetsAt": 1_800_000_000]
            ]
        ]], named: "event1")
        try result("an answer", number: 1)
        var outcome = converse()
        XCTAssertEqual(outcome.answers, ["an answer"])
        XCTAssertNil(outcome.failure, "a warning at 32% isn't a pause")
        XCTAssertEqual(outcome.usage.sawUsageWindows, true)

        try event(["type": "rate_limit_event", "rate_limit_info": ["status": "allowed", "unifiedWindows": [
            "five_hour": ["utilization": 0.82, "resetsAt": 1_800_000_100], "seven_day": ["utilization": 0.2, "resetsAt": 1_800_500_000]
        ]]], named: "event1")
        outcome = converse()
        XCTAssertEqual(outcome.answers, ["an answer"])
        XCTAssertEqual(outcome.failure, .usageLimit(resetsAt: Date(timeIntervalSince1970: 1_800_000_100)),
                       "a window past 80% pauses until it resets")
        XCTAssertEqual(outcome.usage.sawUsageWindows, true)

        try event(["type": "rate_limit_event", "rate_limit_info": ["status": "allowed", "unifiedWindows": [
            "five_hour": ["utilization": 0.64, "resetsAt": 1_800_000_100]
        ]]], named: "event1")
        XCTAssertNil(converse().failure, "64% goes on")
        var strict = runner()
        strict.pauseAtUtilization = 0.6
        guard case .usageLimit = converse(strict).failure else { return XCTFail("past a lower threshold, it pauses") }

        try event(["type": "rate_limit_event", "rate_limit_info": [
            "status": "allowed", "rateLimitType": "seven_day_sonnet", "utilization": 0.91, "resetsAt": 1_800_200_000
        ]], named: "event1")
        XCTAssertEqual(converse().failure, .usageLimit(resetsAt: Date(timeIntervalSince1970: 1_800_200_000)),
                       "a model's weekly window, reported on its own")

        try write("5", named: "sleep1")
        for info: [String: Any] in [
            ["status": "allowed", "isUsingOverage": true], ["status": "allowed", "overageInUse": true], ["status": "rejected"]
        ] {
            try event(["type": "rate_limit_event", "rate_limit_info": info], named: "event1")
            outcome = converse()
            guard case .usageLimit = outcome.failure else { return XCTFail("\(info) must stop") }
            XCTAssertEqual(outcome.answers, [])
            XCTAssertLessThan(outcome.usage.seconds, 4, "\(info): the run was stopped, not left to finish its turn")
        }
    }

    /// A run whose setup is refused is stopped at once: an API key, tools,
    /// or no init event at all.
    func testARefusedSetupStopsTheRun() throws {
        try result("an answer", number: 1)
        try write("5", named: "sleep1")
        try event(["type": "system", "subtype": "init", "tools": [], "mcp_servers": [], "apiKeySource": "ANTHROPIC_API_KEY"],
                  named: "init")
        let keyed = converse()
        guard case .unavailable(let reason) = keyed.failure else { return XCTFail("an API key is refused") }
        XCTAssertTrue(reason.contains("ANTHROPIC_API_KEY"), reason)
        XCTAssertEqual(keyed.answers, [])
        XCTAssertLessThan(keyed.usage.seconds, 4, "stopped, not left to bill its turn")

        try FileManager.default.removeItem(at: bin.appendingPathComponent("sleep1"))
        try event(["type": "system", "subtype": "init", "tools": ["Bash"], "mcp_servers": [], "apiKeySource": "none"], named: "init")
        guard case .unavailable = converse().failure else { return XCTFail("tools are refused") }
        try write("", named: "init")
        guard case .unavailable = converse().failure else { return XCTFail("a result without a confirmed setup is refused") }
    }

    /// What a failed result means: its HTTP status first, then its text.
    func testFailuresAreClassified() throws {
        try result("API Error: 529 Overloaded", error: true, number: 1)
        guard case .transient = converse().failure else { return XCTFail("overloaded is transient") }
        try result("API Error: 400 prompt is too long: 215290 tokens > 200000 maximum", error: true, number: 1)
        guard case .permanent = converse().failure else { return XCTFail("too long is permanent, whatever its numbers") }
        try result("API Error: 429 rate_limit_error", error: true, status: 429, number: 1)
        guard case .transient = converse().failure else { return XCTFail("a rate limit that isn't the plan's is transient") }
        try result("Unable to connect to API: SSL certificate verification failed. See https://code.claude.com/docs/en/network-config",
                   error: true, number: 1)
        guard case .unavailable = converse().failure else { return XCTFail("a proxy's certificate needs the user") }
        try result("Unable to connect to API. Check your internet connection", error: true, number: 1)
        guard case .transient = converse().failure else { return XCTFail("a lost connection is transient") }
        try result("Connection dropped (ConnectionClosed)", error: true, number: 1)
        guard case .transient = converse().failure else { return XCTFail("a dropped connection is transient") }
        try result("API Error: something", error: true, kind: "tls_untrusted_ca", number: 1)
        guard case .unavailable = converse().failure else { return XCTFail("a typed kind that needs the user stops") }
        try result("API Error: no response", error: true, kind: "no_response", number: 1)
        guard case .transient = converse().failure else { return XCTFail("no response is transient") }
        try result("API Error: 401 authentication_error", error: true, status: 401, number: 1)
        guard case .unavailable = converse().failure else { return XCTFail("a 401 needs the user") }
        try result("Unable to connect to API: SSL error (EPROTO)", error: true, number: 1)
        guard case .unavailable = converse().failure else { return XCTFail("a TLS setting needs the user") }
        try result("Not logged in · Please run /login", error: true, number: 1)
        guard case .unavailable = converse().failure else { return XCTFail("logged out stops") }
        try result("Claude AI usage limit reached", error: true, number: 1)
        guard case .usageLimit = converse().failure else { return XCTFail("limit pauses") }
        try event(["type": "result", "subtype": "error_max_budget_usd", "is_error": true, "errors": ["Reached the budget"]],
                  named: "result1")
        XCTAssertEqual(converse().failure, .permanent("Reached the budget"), "an error result's errors say why")
        try write("error: unknown option '--restricted'\n", named: "stderr")
        guard case .unavailable(let reason) = converse().failure else { return XCTFail("refused options need an update") }
        XCTAssertTrue(reason.contains("unknown option"), reason)
    }

    /// Events split across reads, and a last line without its newline.
    func testEventsSplitAcrossChunks() throws {
        let input = BoundedProcess.StreamingInput()
        let run = ProjectHistory.Conversation(input: input) { _, _ in nil }
        let lines = [
            #"{"type":"system","subtype":"init","tools":[],"mcp_servers":[],"apiKeySource":"none"}"#,
            #"{"type":"result","subtype":"success","is_error":false,"result":"split answer","total_cost_usd":0.5}"#
        ].joined(separator: "\n")
        let data = Data(lines.utf8)
        for start in stride(from: 0, to: data.count, by: 7) {
            run.consume(data[start..<min(start + 7, data.count)])
        }
        let outcome = run.result(stop: nil, status: 0, standardError: "")
        XCTAssertEqual(outcome.answers, ["split answer"])
        XCTAssertEqual(outcome.usage.costUSD, 0.5)

        let whole = ProjectHistory.Conversation(input: BoundedProcess.StreamingInput()) { _, _ in nil }
        whole.consume(data + Data("\n".utf8))
        XCTAssertEqual(whole.result(stop: nil, status: 0, standardError: "").answers, ["split answer"], "two lines in one chunk")
    }

    /// The checked runner says why while `claude` can't run, and runs once
    /// it can, with no restart.
    func testTheCheckedRunnerChecksAgainAfterARefusal() throws {
        try result("an answer", number: 1)
        let ready = Locked(false)
        let cli = BranchReview.ClaudeCLI(path: bin.appendingPathComponent("claude").path)
        let checked = ProjectHistory.CheckedClaudeRunner(model: .sonnet, workingDirectory: runs) {
            ready.value ? .ready(cli) : .refused("claude isn't logged in")
        }
        XCTAssertEqual(checked.converse(system: "s", message: "m") { _, _ in nil }.failure, .unavailable("claude isn't logged in"))
        ready.update { _ in true }
        XCTAssertEqual(checked.converse(system: "s", message: "m") { _, _ in nil }.answers, ["an answer"])

        // A run found unavailable sends the next call back to the check.
        try event(["type": "system", "subtype": "init", "tools": [], "mcp_servers": [], "apiKeySource": "ANTHROPIC_API_KEY"],
                  named: "init")
        guard case .unavailable = checked.converse(system: "s", message: "m", followUp: { _, _ in nil }).failure else {
            return XCTFail("an API key is refused")
        }
        ready.update { _ in false }
        XCTAssertEqual(checked.converse(system: "s", message: "m") { _, _ in nil }.failure, .unavailable("claude isn't logged in"))
    }

    /// A record after a line a crash cut starts a line of its own.
    func testUsageRecordsAfterACutLine() throws {
        let folder = runs.appendingPathComponent("journal", isDirectory: true)
        let journal = try XCTUnwrap(ProjectHistoryJournal.open(folder: folder))
        try Data(#"{"date":"#.utf8).write(to: folder.appendingPathComponent(ProjectHistory.usageFileName))
        let record = ProjectHistory.UsageRecord(
            date: Date(timeIntervalSince1970: 1_800_000_000), task: "decisions 3", model: "claude-sonnet-5-5",
            outcome: "decisions", usage: ProjectHistory.RunUsage(costUSD: 0.02, tries: 1)
        )
        journal.appendUsage(record)
        let lines = try String(contentsOf: folder.appendingPathComponent(ProjectHistory.usageFileName), encoding: .utf8)
            .split(separator: "\n")
        XCTAssertEqual(lines.count, 2)
        XCTAssertEqual(try ProjectHistoryJournal.decoder.decode(ProjectHistory.UsageRecord.self, from: Data(lines[1].utf8)), record)
    }

    /// The status line's pause takes its threshold.
    func testTheStatusLinePauseTakesAThreshold() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let limits = ClaudeUsageLimits(
            fiveHour: .init(usedPercentage: 65, resetsAt: 1_800_003_600, reportedAt: 1_799_999_000)
        )
        XCTAssertNil(ProjectHistory.nearLimitUntil(limits, now: now))
        XCTAssertEqual(ProjectHistory.nearLimitUntil(limits, now: now, percent: 60), Date(timeIntervalSince1970: 1_800_003_600))
    }

    /// A child that answers each line: the input streams while it runs.
    func testStreamingInputIsWrittenAsTheRunGoes() throws {
        let input = BoundedProcess.StreamingInput()
        input.send(Data("first\n".utf8))
        let seen = Locked<String>("")
        let outcome = BoundedProcess.execute(
            executableURL: URL(fileURLWithPath: "/bin/cat"), arguments: [], currentDirectoryURL: runs,
            streamingInput: input, timeout: 10,
            onStandardOutput: { chunk in
                let text = seen.update { $0 + String(decoding: chunk, as: UTF8.self) }
                if text == "first\n" { input.send(Data("second\n".utf8)) }
                if text.hasSuffix("second\n") { input.close() }
            }
        )
        XCTAssertEqual(outcome?.terminationStatus, 0)
        XCTAssertEqual(seen.value, "first\nsecond\n")
    }
}

/// A value shared with an output handler's thread.
private final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value

    init(_ value: Value) {
        stored = value
    }

    var value: Value { lock.withLock { stored } }

    @discardableResult
    func update(_ change: (Value) -> Value) -> Value {
        lock.withLock {
            stored = change(stored)
            return stored
        }
    }
}
