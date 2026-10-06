import Foundation

// MARK: - Background model calls (docs/project-memory-tree.md, section 3.3)

extension ProjectHistory {
    /// The model a background call runs.
    enum RunnerModel: String, Codable, Sendable, CaseIterable {
        case sonnet, haiku

        var identifier: String { self == .sonnet ? "claude-sonnet-5-5" : "claude-haiku-4-5" }
        /// Sonnet at medium, as measured; Haiku takes no effort.
        var effort: String? { self == .sonnet ? "medium" : nil }
    }

    /// What a call cost, as `claude -p` reports it: a result's
    /// `modelUsage` and `total_cost_usd` count the whole conversation (its
    /// `usage`, only its turn).
    struct RunUsage: Codable, Equatable, Sendable {
        var inputTokens = 0
        var cacheCreationTokens = 0
        var cacheReadTokens = 0
        var outputTokens = 0
        /// At API prices.
        var costUSD = 0.0
        /// The results it got, answers and errors.
        var tries = 0
        var seconds = 0.0
        /// The run reported its usage windows, which the pause at a share
        /// of them needs.
        var sawUsageWindows: Bool?
    }

    enum RunFailure: Equatable, Sendable {
        /// The plan's limit is near or reached: wait until it resets.
        case usageLimit(resetsAt: Date?)
        /// The network, an overloaded API: try again shortly.
        case transient(String)
        /// Anything else, which may fail again: a refusal, an empty answer,
        /// a prompt too long, a run that stalled.
        case permanent(String)
        /// No `claude`, logged out, an account that would be billed, a run
        /// that offers tools, options `claude` refuses: stop until the user
        /// acts.
        case unavailable(String)
    }

    /// A conversation's answers, in order, and why it stopped early if it
    /// did: with answers, a limit reached after them (use them, then
    /// pause); without, the call failed.
    struct ConversationResult: Equatable, Sendable {
        var answers: [String]
        var failure: RunFailure?
        var usage: RunUsage
    }

    /// Runs conversations with a confined `claude -p`: no tools, no MCP, no
    /// hooks, no instruction files, no session saved, the environment
    /// Explain allows, the user's subscription only, five-minute cache
    /// entries. A run whose setup or account is refused is stopped at
    /// once, not just left to end.
    struct ClaudeRunner: ProjectHistoryRunner {
        let cli: BranchReview.ClaudeCLI
        let model: RunnerModel
        /// A conversation that runs past this, or stays silent past
        /// `idleTimeout`, is stopped: a failed try.
        var timeout: TimeInterval = 300
        var idleTimeout: TimeInterval = 120
        /// Where runs start: an empty folder of their own.
        let workingDirectory: URL
        /// The share of a usage window (5-hour, 7-day) past which the call
        /// ends after its answer, to wait until that window resets.
        var pauseAtUtilization = 0.8
        /// What one conversation may cost at API prices, follow-ups
        /// included.
        var maxBudgetUSD = 1.0
        /// Answers a conversation may give, the first included.
        var maxAnswers = 3

        func arguments(system: String) -> [String] {
            var arguments = [
                "-p", "--model", model.identifier,
                "--input-format", "stream-json", "--output-format", "stream-json", "--verbose",
                // Partial messages keep the stream busy while the model
                // thinks, for the idle timeout.
                "--include-partial-messages",
                "--max-budget-usd", String(maxBudgetUSD),
                "--tools", "", "--restricted", "--permission-prompts", "none", "--strict-mcp-config",
                "--disable-slash-commands", "--no-session-persistence",
                "--settings", #"{"disableAllHooks":true,"instructionFiles":"managed-only"}"#,
                "--system-prompt", system
            ]
            if let effort = model.effort { arguments += ["--effort", effort] }
            return arguments
        }

        func environment(from base: [String: String] = ProcessInfo.processInfo.environment) -> [String: String] {
            var environment = cli.environment(from: base)
            environment["CLAUDE_CODE_PROMPT_CACHE_TTL"] = "5m"
            if model == .haiku { environment["MAX_THINKING_TOKENS"] = "0" }
            return environment
        }

        /// One conversation: `message`, then each message `followUp` asks
        /// for after an answer, until it returns nil or `maxAnswers` came.
        /// `cancellation` stops it (the user paused or turned it off).
        func converse(
            system: String, message: String, followUp: @escaping @Sendable (String, Int) -> String?,
            cancellation: BoundedProcess.Cancellation?
        ) -> ConversationResult {
            let input = BoundedProcess.StreamingInput()
            let run = Conversation(
                input: input, pauseAtUtilization: pauseAtUtilization, maxAnswers: maxAnswers, cancellation: cancellation,
                followUp: followUp
            )
            input.send(Conversation.userLine(message))
            let started = Date()
            // A purged temporary folder is made again.
            try? FileManager.default.createDirectory(at: workingDirectory, withIntermediateDirectories: true)
            let outcome = BoundedProcess.execute(
                executableURL: URL(fileURLWithPath: cli.path), arguments: arguments(system: system),
                currentDirectoryURL: workingDirectory, environment: .replaced(environment()),
                streamingInput: input, timeout: timeout, idleTimeout: idleTimeout,
                captureStandardError: true, maxStandardOutputBytes: 64 << 20, maxStandardErrorBytes: 64 * 1024,
                cancellation: run.cancellation, onStandardOutput: { run.consume($0) }, keepsStandardOutput: false
            )
            input.close()
            guard let outcome else {
                return ConversationResult(answers: [], failure: .unavailable("claude didn't start"), usage: run.usage)
            }
            var result = run.result(
                stop: outcome.stop, status: outcome.terminationStatus,
                standardError: String(decoding: outcome.standardError, as: UTF8.self)
            )
            result.usage.seconds = Date().timeIntervalSince(started)
            return result
        }
    }

    /// One call's stream: it reads the events, and answers each result with
    /// a follow-up or the end of the input.
    final class Conversation: @unchecked Sendable {
        private let lock = NSLock()
        private let input: BoundedProcess.StreamingInput
        /// Stops the run itself (a refused setup must not finish its turn),
        /// or the caller's cancellation does.
        let cancellation: BoundedProcess.Cancellation
        private var partial = Data()
        private var answers: [String] = []
        private var failure: RunFailure?
        private var usageSoFar = RunUsage()
        /// The run's init event listed no tool and no MCP server, and the
        /// subscription as its account.
        private var setupConfirmed = false
        /// A follow-up was sent and its answer hasn't come.
        private var awaitingAnswer = true
        /// Claude Code is retrying the current request itself (the network,
        /// an overloaded API), and why: a run that then stalls failed for
        /// that reason.
        private var retrying: String?
        /// Each turn's own tokens, summed: for a result without
        /// `modelUsage`.
        private var turnTokens = RunUsage()
        private let pauseAtUtilization: Double
        private let maxAnswers: Int
        /// After an answer (and how many there are), the next message, or
        /// nil to end the conversation.
        private let followUp: @Sendable (String, Int) -> String?

        init(
            input: BoundedProcess.StreamingInput, pauseAtUtilization: Double = 0.8, maxAnswers: Int = 3,
            cancellation: BoundedProcess.Cancellation? = nil, followUp: @escaping @Sendable (String, Int) -> String?
        ) {
            self.input = input
            self.cancellation = BoundedProcess.Cancellation(parent: cancellation)
            self.pauseAtUtilization = pauseAtUtilization
            self.maxAnswers = maxAnswers
            self.followUp = followUp
        }

        var usage: RunUsage { lock.withLock { usageSoFar } }

        static func userLine(_ text: String) -> Data {
            let object: [String: Any] = ["type": "user", "message": ["role": "user", "content": [["type": "text", "text": text]]]]
            var data = (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
            data.append(0x0A)
            return data
        }

        /// What the stream asks of the input once the lock is released.
        private enum Next {
            case ask(String, Int)
            case close
        }

        func consume(_ chunk: Data) {
            let next: [Next] = lock.withLock {
                // Only the new bytes can hold a line's end.
                var from = partial.endIndex
                partial.append(chunk)
                var next: [Next] = []
                var start = partial.startIndex
                while let newline = partial[from...].firstIndex(of: 0x0A) {
                    let line = partial[start..<newline]
                    start = partial.index(after: newline)
                    from = start
                    if let event = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any], let step = handle(event) {
                        next.append(step)
                    }
                }
                // Once per chunk, and only when a line was taken: partial
                // messages come in many small chunks.
                if start != partial.startIndex { partial = Data(partial[start...]) }
                return next
            }
            // The follow-up, written by the caller, runs outside the lock.
            for step in next {
                switch step {
                case .ask(let answer, let count):
                    if let message = followUp(answer, count), lock.withLock({ failure == nil }) {
                        lock.withLock { awaitingAnswer = true }
                        input.send(Self.userLine(message))
                    } else {
                        input.close()
                    }
                case .close:
                    input.close()
                }
            }
        }

        /// Under `lock`.
        private func handle(_ event: [String: Any]) -> Next? {
            switch event["type"] as? String {
            case "system" where event["subtype"] as? String == "init":
                guard let tools = event["tools"] as? [Any], tools.isEmpty,
                      (event["mcp_servers"] as? [Any] ?? []).isEmpty else {
                    return refuse("the run offered tools or MCP servers, or didn't list them")
                }
                guard let source = event["apiKeySource"] as? String, source == "none" else {
                    let source = (event["apiKeySource"] as? String).map { BranchReview.visible($0) } ?? "an unknown account"
                    // A background call never bills an API key.
                    return refuse("it would use \(source) instead of the Claude subscription")
                }
                setupConfirmed = true
                return nil
            case "rate_limit_event":
                guard let info = event["rate_limit_info"] as? [String: Any] else { return nil }
                let resetsAt = (info["resetsAt"] as? Double).map { Date(timeIntervalSince1970: $0) }
                // Never extra usage: the turn stops now.
                if info["isUsingOverage"] as? Bool == true || info["overageInUse"] as? Bool == true
                    || info["status"] as? String == "rejected" {
                    stop(.usageLimit(resetsAt: resetsAt))
                    cancellation.cancel()
                    return .close
                }
                // `allowed_warning` alone says little: it came at 32% of the
                // 7-day window on 2026-10-06. The windows' shares decide.
                // The windows, and the one this request counts against (a
                // model's weekly limit is reported only there).
                let windows = (info["unifiedWindows"] as? [String: Any] ?? [:]).values.compactMap { $0 as? [String: Any] }
                    + (info["utilization"] != nil ? [info] : [])
                guard !windows.isEmpty else { return nil }
                usageSoFar.sawUsageWindows = true
                let full = windows.filter { ($0["utilization"] as? Double ?? 0) >= pauseAtUtilization }
                guard !full.isEmpty else { return nil }
                // Near the limit: this turn's answer is kept, no more turns.
                let reset = full.compactMap { $0["resetsAt"] as? Double }.max()
                stop(.usageLimit(resetsAt: reset.map { Date(timeIntervalSince1970: $0) }))
                return .close
            case "system" where event["subtype"] as? String == "api_retry":
                retrying = event["error"] as? String ?? "unknown"
                return nil
            case "result":
                add(event)
                retrying = nil
                if case .unavailable = failure { return .close }
                guard setupConfirmed else { return refuse("the run didn't confirm its setup") }
                let text = (event["result"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                if event["is_error"] as? Bool == true || event["subtype"] as? String != "success" || text.isEmpty {
                    let errors = (event["errors"] as? [Any] ?? []).compactMap { $0 as? String }.joined(separator: " ")
                    stop(Self.classify(
                        text.isEmpty ? errors : text, status: event["api_error_status"] as? Int, kind: event["api_error"] as? String
                    ))
                    return .close
                }
                answers.append(text)
                awaitingAnswer = false
                return failure == nil && answers.count < maxAnswers ? .ask(text, answers.count) : .close
            default:
                return nil
            }
        }

        /// Under `lock`: the run is refused and stopped at once.
        private func refuse(_ reason: String) -> Next {
            failure = .unavailable(reason)
            cancellation.cancel()
            return .close
        }

        private func stop(_ reason: RunFailure) {
            if failure == nil { failure = reason }
        }

        /// The conversation's usage so far: the latest result's `modelUsage`
        /// and cost, which count it all; without `modelUsage`, each turn's
        /// `usage` summed.
        private func add(_ result: [String: Any]) {
            let turn = result["usage"] as? [String: Any] ?? [:]
            turnTokens.inputTokens += turn["input_tokens"] as? Int ?? 0
            turnTokens.cacheCreationTokens += turn["cache_creation_input_tokens"] as? Int ?? 0
            turnTokens.cacheReadTokens += turn["cache_read_input_tokens"] as? Int ?? 0
            turnTokens.outputTokens += turn["output_tokens"] as? Int ?? 0
            if let models = result["modelUsage"] as? [String: Any], !models.isEmpty {
                let usages = models.values.compactMap { $0 as? [String: Any] }
                func total(_ key: String) -> Int { usages.reduce(0) { $0 + ($1[key] as? Int ?? 0) } }
                usageSoFar.inputTokens = total("inputTokens")
                usageSoFar.cacheCreationTokens = total("cacheCreationInputTokens")
                usageSoFar.cacheReadTokens = total("cacheReadInputTokens")
                usageSoFar.outputTokens = total("outputTokens")
            } else {
                usageSoFar.inputTokens = turnTokens.inputTokens
                usageSoFar.cacheCreationTokens = turnTokens.cacheCreationTokens
                usageSoFar.cacheReadTokens = turnTokens.cacheReadTokens
                usageSoFar.outputTokens = turnTokens.outputTokens
            }
            usageSoFar.costUSD = result["total_cost_usd"] as? Double ?? usageSoFar.costUSD
            usageSoFar.tries += 1
        }

        /// Why Claude Code retries a request, when only the user can fix it.
        private static let accountRetries: Set<String> = [
            "authentication_failed", "oauth_org_not_allowed", "account_on_hold", "verification_required", "billing_error",
            "cloud_credential_error"
        ]

        /// API errors that need the user (an update, a login, a proxy's
        /// certificate, credits), by the kind `claude -p` gives them.
        private static let unavailableKinds: Set<String> = [
            "claude_code_version_too_old", "tls_untrusted_ca", "gateway_content_type", "provider_credentials",
            "gateway_signin_required", "gateway_session_expired", "api_key_auth_disabled", "org_disabled_credential",
            "invalid_credential_header", "model_requires_usage_credits", "long_context_credits_required",
            "consent_unanswered", "no_allowed_fallback", "model_substitution_disabled", "field_not_granted"
        ]

        /// What a failed result says: its typed kind and HTTP status first,
        /// then its text, read as Explain reads it.
        static func classify(_ text: String, status: Int? = nil, kind: String? = nil) -> RunFailure {
            let message = text.isEmpty ? "it failed without a message" : text
            let lowercased = message.lowercased()
            if BranchReview.isUsageLimit(message) { return .usageLimit(resetsAt: nil) }
            if let kind {
                if unavailableKinds.contains(kind) { return .unavailable(message) }
                if kind == "no_response" { return .transient(message) }
            }
            // A proxy or TLS setting is wrong: it won't fix itself.
            if lowercased.contains("not logged in") || lowercased.contains("/login") || lowercased.contains("invalid api key")
                || lowercased.contains("certificate") || lowercased.contains("ssl") || lowercased.contains("tls")
                || lowercased.contains("proxy") || lowercased.contains("selected model")
                || lowercased.contains("model not found") || lowercased.contains("access to model") {
                return .unavailable(message)
            }
            if let status {
                switch status {
                case 401, 403: return .unavailable(message)
                case 408, 409, 429, 500...599: return .transient(message)
                default: return .permanent(message)
                }
            }
            // Not any 529 in a number: "prompt is too long: 215290 tokens".
            // Claude Code's own wordings of a lost connection, and the codes
            // it names (Bun's and Node's).
            let transient = [
                "overloaded", "high load", "api error: 529", "temporarily limiting requests", "not your usage limit",
                "timed out", "unable to connect", "connection dropped", "connection refused", "can't reach the api server",
                "no internet route", "check your internet connection", "econnreset", "econnrefused", "econnaborted",
                "etimedout", "enotfound", "eai_again", "enetunreach", "ehostunreach", "enetdown", "epipe",
                "connectionclosed", "connectionrefused", "failedtoopensocket", "und_err_socket", "socket hang up", "fetch failed"
            ]
            if transient.contains(where: lowercased.contains)
                || lowercased.range(of: #"api error: (5\d\d|429)\b"#, options: .regularExpression) != nil {
                return .transient(message)
            }
            return .permanent(message)
        }

        /// How the run ended: its answers, unless it stopped while one was
        /// still due (a follow-up asked, or none came), or was refused.
        func result(stop: BoundedProcess.Stop?, status: Int32?, standardError: String) -> ConversationResult {
            lock.withLock {
                // A last line without its newline.
                if !partial.isEmpty, let event = (try? JSONSerialization.jsonObject(with: partial)) as? [String: Any] {
                    partial = Data()
                    _ = handle(event)
                }
                let usage = usageSoFar
                if case .unavailable = failure { return ConversationResult(answers: [], failure: failure, usage: usage) }
                if !answers.isEmpty, !awaitingAnswer { return ConversationResult(answers: answers, failure: failure, usage: usage) }
                if let failure { return ConversationResult(answers: [], failure: failure, usage: usage) }
                let stopped = stop.map { "\($0)" } ?? ""
                let reason: RunFailure = switch stop {
                // Claude Code was retrying: an account that needs the user,
                // else the network or an overloaded API.
                case .timedOut, .idle:
                    if let retrying, Self.accountRetries.contains(retrying) {
                        .unavailable("the run stalled retrying (\(retrying))")
                    } else if retrying != nil {
                        .transient("the run stalled retrying (\(stopped))")
                    } else {
                        .permanent("the run stalled (\(stopped))")
                    }
                case .readFailed, .cancelled: .transient("the run stopped (\(stop.map { "\($0)" } ?? ""))")
                case .outputLimit: .permanent("the run wrote too much")
                case nil: Self.exitFailure(status: status, standardError: standardError)
                }
                return ConversationResult(answers: [], failure: reason, usage: usage)
            }
        }

        /// A run that ended without an answer: options `claude` refuses
        /// mean it changed, and stop the work until it is updated.
        private static func exitFailure(status: Int32?, standardError: String) -> RunFailure {
            let error = standardError.trimmingCharacters(in: .whitespacesAndNewlines)
            let shown = error.isEmpty ? "it ended without an answer (exit \(status ?? -1))" : String(error.suffix(300))
            let lowercased = error.lowercased()
            if lowercased.contains("unknown option") || lowercased.contains("error: option") || lowercased.contains("unknown argument") {
                return .unavailable("claude refused its options: \(shown)")
            }
            return .permanent(shown)
        }
    }

    /// What a check of `claude` found: a binary that confines its runs,
    /// logged in to a Claude subscription; or why not.
    enum ClaudeCheck: Equatable, Sendable {
        case ready(BranchReview.ClaudeCLI)
        case refused(String)
    }

    /// Finds `claude` and checks its account (`claude auth status`): a
    /// background call never bills an API key. Runs processes: call it off
    /// the main thread.
    static func checkClaude() -> ClaudeCheck {
        switch BranchReview.ClaudeCLI.locate() {
        case .ready(let cli):
            guard let account = cli.account() else { return .refused("claude's account couldn't be checked") }
            guard account.isLoggedIn else { return .refused("claude isn't logged in") }
            guard !account.isBilledPerCall else {
                return .refused("claude would use \(BranchReview.visible(account.label)) instead of the Claude subscription")
            }
            return .ready(cli)
        case .tooOld:
            return .refused("claude is too old to run confined (2.1.284 or later)")
        case .unknown:
            return .refused("claude couldn't be checked")
        case .missing:
            return .refused("claude wasn't found")
        }
    }

    /// `claude -p` for `model`, checked at its first call and again after
    /// any call that found it unavailable (the caller waits between them):
    /// no app restart is needed once the user installs, updates or logs in
    /// to `claude`.
    final class CheckedClaudeRunner: ProjectHistoryRunner, @unchecked Sendable {
        private let lock = NSLock()
        private var runner: ClaudeRunner?
        private let model: RunnerModel
        private let workingDirectory: URL
        private let check: @Sendable () -> ClaudeCheck
        private let configure: @Sendable (inout ClaudeRunner) -> Void

        init(
            model: RunnerModel, workingDirectory: URL, check: @escaping @Sendable () -> ClaudeCheck = ProjectHistory.checkClaude,
            configure: @escaping @Sendable (inout ClaudeRunner) -> Void = { _ in }
        ) {
            self.model = model
            self.workingDirectory = workingDirectory
            self.check = check
            self.configure = configure
        }

        func converse(
            system: String, message: String, followUp: @escaping @Sendable (String, Int) -> String?,
            cancellation: BoundedProcess.Cancellation?
        ) -> ConversationResult {
            var ready = lock.withLock { runner }
            if ready == nil {
                switch check() {
                case .ready(let cli):
                    var runner = ClaudeRunner(cli: cli, model: model, workingDirectory: workingDirectory)
                    configure(&runner)
                    lock.withLock { self.runner = runner }
                    ready = runner
                case .refused(let reason):
                    return ConversationResult(answers: [], failure: .unavailable(reason), usage: RunUsage())
                }
            }
            guard let ready else { return ConversationResult(answers: [], failure: .unavailable("claude wasn't checked"), usage: RunUsage()) }
            let result = ready.converse(system: system, message: message, followUp: followUp, cancellation: cancellation)
            // Logged out, or the binary changed: checked again next time.
            if case .unavailable = result.failure { lock.withLock { runner = nil } }
            return result
        }
    }

    // MARK: - Usage (section 3.6) and pauses (section 3.7)

    static let usageFileName = "usage.jsonl"

    /// One line of `usage.jsonl`: a call, what it was for, and its outcome.
    struct UsageRecord: Codable, Equatable, Sendable {
        let date: Date
        let task: String
        let model: String
        let outcome: String
        let usage: RunUsage
    }

    /// When Claude's status line says a window reached `percent`: the
    /// latest reset of those windows.
    static func nearLimitUntil(
        _ limits: ClaudeUsageLimits?, now: Date, percent: Int = ClaudeUsageLimits.nearLimitPercent
    ) -> Date? {
        guard let limits = limits?.current(at: now.timeIntervalSince1970) else { return nil }
        let resets = [limits.fiveHour, limits.sevenDay].compactMap { $0 }
            .filter { $0.displayedPercent >= percent }.map(\.resetsAt)
        return resets.max().map { Date(timeIntervalSince1970: $0) }
    }
}

/// What runs the background model calls: `claude -p`
/// (`ProjectHistory.ClaudeRunner`), or a fake in tests. It blocks: call it
/// off the main thread.
protocol ProjectHistoryRunner: Sendable {
    func converse(
        system: String, message: String, followUp: @escaping @Sendable (String, Int) -> String?,
        cancellation: BoundedProcess.Cancellation?
    ) -> ProjectHistory.ConversationResult
}

extension ProjectHistoryRunner {
    func converse(
        system: String, message: String, followUp: @escaping @Sendable (String, Int) -> String?
    ) -> ProjectHistory.ConversationResult {
        converse(system: system, message: message, followUp: followUp, cancellation: nil)
    }
}

extension ProjectHistoryJournal {
    /// Appends a call's usage to `usage.jsonl`, in one write.
    func appendUsage(_ record: ProjectHistory.UsageRecord) {
        guard let data = try? Self.encoder.encode(record) else { return }
        let url = folder.appendingPathComponent(ProjectHistory.usageFileName)
        // Read and write: the last byte is checked before appending.
        let descriptor = Darwin.open(url.path, O_RDWR | O_APPEND | O_CREAT | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK, 0o600)
        guard descriptor >= 0 else { return }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { return }
        var line = data
        line.append(0x0A)
        // After a line a crash cut, on a line of its own.
        var last: UInt8 = 0x0A
        if info.st_size > 0, pread(descriptor, &last, 1, info.st_size - 1) == 1, last != 0x0A { line.insert(0x0A, at: 0) }
        _ = line.withUnsafeBytes { write(descriptor, $0.baseAddress, $0.count) }
    }
}
