import Foundation

/// Nirux's own small reads through a headless `claude -p`: one input, one
/// answer, on the account `claude` is logged in with. Its clients are the
/// turn-end classifier (`HaikuTurnEndClassifier`) and the CI failure
/// triage (`CITriageModel`).
///
/// A run sees its input and nothing else: no tools, MCP servers, hooks,
/// settings, instruction files or saved session. It runs only on a Claude
/// subscription (claude.ai, through Anthropic): anywhere else each run
/// would be billed. `claude auth status` says so ahead of runs; each run's
/// events say so again (an API key stops it, extra usage rests every
/// client). Any failure is no answer.
///
/// Shared by the clients, since they use one account: the setup check and
/// the rest after a run billed per call (`Account`). Each client's own:
/// its model, prompt and limits, how many of its runs go at once (a long
/// run of one must not take the slots of another), and its rest after
/// runs that keep failing.
final class ClaudeOneShotRunner: @unchecked Sendable {
    struct Client: Sendable {
        /// A full model name, not an alias that would move to the next
        /// model.
        var model: String
        var systemPrompt: String
        /// Past it there is no answer.
        var timeout: TimeInterval
        /// `--max-budget-usd`: caps a run that would go wrong.
        var maxBudgetUSD: String
        /// Flags of its own, before the output ones.
        var extraArguments: [String] = []
        /// Runs at once. One past it gets no answer, at once.
        var maxConcurrentRuns: Int
        /// Runs in a row without an answer after which the client rests
        /// for `Account.missingSetupLifetime` (no run, no answer, at once)
        /// rather than make each caller wait for its timeout: an outage, a
        /// network, a model the account can't use.
        var failuresBeforeRest = 3
        /// Its empty folder under the temporary directory, where its runs
        /// start.
        var folderName: String
    }

    /// The account the runs use: what a run needs of it (`Setup`), checked
    /// in the background and kept for a while, and the rest after a run
    /// that would be billed per call.
    final class Account: @unchecked Sendable {
        /// How long a found setup (or its absence) is trusted before being
        /// checked again: `claude` may be logged out, or updated,
        /// meanwhile. A billed run rests the clients for the first.
        static let readySetupLifetime: TimeInterval = 60 * 60
        static let missingSetupLifetime: TimeInterval = 10 * 60

        /// What a run needs: a `claude` that confines its runs, logged in
        /// on a subscription.
        enum Setup: Equatable, Sendable {
            case ready(BranchReview.ClaudeCLI)
            case unavailable
        }

        /// The account every client of the app uses. Its rest after a
        /// billed run is kept in the state directory: a relaunch, or a
        /// second Nirux on that directory, rests too.
        static let shared = Account(restURL: Persistence.stateDirectory.appendingPathComponent("claude-runs-rest"))

        /// The longest a billed run rests the clients, whatever it says of
        /// when the plan's limit resets.
        static let longestBilledRest: TimeInterval = 7 * 24 * 60 * 60

        /// Guards everything below but `setupLock`.
        private let lock = NSLock()
        private var cachedSetup: (setup: Setup, checkedAt: TimeInterval)?
        private var isRefreshingSetup = false
        /// No run before then: one was billed per call.
        private var billedRestUntil: TimeInterval = 0
        /// Where `billedRestUntil` is kept (epoch seconds); nil: in memory
        /// only.
        private let restURL: URL?
        /// Held while the setup is checked: one check at a time.
        private let setupLock = NSLock()
        private let checkSetup: @Sendable () -> Setup
        private let now: @Sendable () -> TimeInterval

        init(
            checkSetup: @escaping @Sendable () -> Setup = Account.defaultSetup,
            now: @escaping @Sendable () -> TimeInterval = { Date().timeIntervalSince1970 },
            restURL: URL? = nil
        ) {
            self.checkSetup = checkSetup
            self.now = now
            self.restURL = restURL
        }

        /// Checks the setup in the background (at launch, or when an
        /// option that needs it is turned on). Runs asked before it is
        /// known get no answer.
        func prepare() {
            lock.withLock { refreshSetupLocked() }
        }

        /// The setup is known (checked once at least).
        var knowsSetup: Bool { lock.withLock { cachedSetup != nil } }

        /// The setup known, checked again in the background once it is
        /// old. Never waited for: unknown yet (just launched) or resting,
        /// there is none.
        func setup() -> Setup {
            let time = now()
            // A rest another Nirux, or this one before a relaunch, began.
            let kept = restURL.flatMap { try? String(contentsOf: $0, encoding: .utf8) }
                .flatMap { TimeInterval($0.trimmingCharacters(in: .whitespacesAndNewlines)) } ?? 0
            return lock.withLock {
                if time < max(billedRestUntil, min(kept, time + Self.longestBilledRest)) { return .unavailable }
                guard let cached = cachedSetup else {
                    refreshSetupLocked()
                    return .unavailable
                }
                if !isFresh(cached, at: time) { refreshSetupLocked() }
                return cached.setup
            }
        }

        /// A run was billed per call (an API key, or extra usage): a
        /// subscription's runs only, for every client. The rest lasts until
        /// the plan's limit resets when the run said when (`resetsAt`,
        /// epoch seconds), an hour at least, a week at most.
        func restAfterBilledRun(resetsAt: TimeInterval? = nil) {
            let time = now()
            let until = min(max(resetsAt ?? 0, time + Self.readySetupLifetime), time + Self.longestBilledRest)
            lock.withLock { billedRestUntil = max(billedRestUntil, until) }
            guard let restURL else { return }
            try? FileManager.default.createDirectory(at: restURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? Data(String(Int(until)).utf8).write(to: restURL, options: .atomic)
        }

        /// Under `lock`: one background check at a time.
        private func refreshSetupLocked() {
            guard !isRefreshingSetup else { return }
            isRefreshingSetup = true
            DispatchQueue.global(qos: .utility).async { self.checkSetupNow() }
        }

        /// Runs `claude --help` and `claude auth status`.
        private func checkSetupNow() {
            setupLock.withLock {
                let setup = checkSetup()
                let time = now()
                lock.withLock {
                    cachedSetup = (setup, time)
                    isRefreshingSetup = false
                }
            }
        }

        private func isFresh(_ cached: (setup: Setup, checkedAt: TimeInterval), at time: TimeInterval) -> Bool {
            let lifetime = cached.setup == .unavailable ? Self.missingSetupLifetime : Self.readySetupLifetime
            return time - cached.checkedAt < lifetime
        }

        /// A confining `claude` logged in on a subscription. Runs `claude
        /// --help` and `claude auth status`: off the main thread.
        @Sendable static func defaultSetup() -> Setup {
            guard case .ready(let cli) = BranchReview.ClaudeCLI.locate(),
                  let account = cli.account(), account.isLoggedIn, !account.isBilledPerCall
            else { return .unavailable }
            return .ready(cli)
        }
    }

    let client: Client
    let account: Account
    private let lock = NSLock()
    private var runningCount = 0
    private var failuresInARow = 0
    /// No run before then: this client's runs kept failing.
    private var failureRestUntil: TimeInterval = 0
    private let runProcess: @Sendable (BranchReview.ClaudeCLI, [String], Data) -> BoundedProcess.Outcome?
    private let now: @Sendable () -> TimeInterval

    init(
        client: Client,
        account: Account = .shared,
        runProcess: (@Sendable (BranchReview.ClaudeCLI, [String], Data) -> BoundedProcess.Outcome?)? = nil,
        now: @escaping @Sendable () -> TimeInterval = { Date().timeIntervalSince1970 }
    ) {
        self.client = client
        self.account = account
        self.runProcess = runProcess ?? Self.defaultRun(timeout: client.timeout, folderName: client.folderName)
        self.now = now
    }

    /// The model's answer to `input`, as `read` takes it (nil: not an
    /// answer, which counts as a failed run). Nil too when no run could go:
    /// no setup yet, a rest, too many at once. Never on the caller's
    /// thread, which may be the main actor's: a run blocks for seconds.
    func answer<Answer: Sendable>(to input: Data, read: @escaping @Sendable (String) -> Answer?) async -> Answer? {
        guard reserveRun() else { return nil }
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let answer = self.answerNow(to: input, read: read)
                self.endRun()
                continuation.resume(returning: answer)
            }
        }
    }

    /// Blocks for the run (never for the setup): off the main thread.
    private func answerNow<Answer>(to input: Data, read: (String) -> Answer?) -> Answer? {
        guard lock.withLock({ now() >= failureRestUntil }), case .ready(let cli) = account.setup() else { return nil }
        let report = Self.report(from: runProcess(cli, Self.arguments(for: client), input))
        let answer = report.text.flatMap(read)
        // Paid already: the answer of a billed run is kept.
        if report.billedPerCall { account.restAfterBilledRun(resetsAt: report.overageResetsAt) }
        lock.withLock {
            if report.billedPerCall || answer != nil {
                failuresInARow = 0
            } else {
                failuresInARow += 1
                if failuresInARow >= client.failuresBeforeRest {
                    failureRestUntil = now() + Account.missingSetupLifetime
                    failuresInARow = 0
                }
            }
        }
        return answer
    }

    private func reserveRun() -> Bool {
        lock.withLock {
            guard runningCount < client.maxConcurrentRuns else { return false }
            runningCount += 1
            return true
        }
    }

    private func endRun() {
        lock.withLock { runningCount -= 1 }
    }

    /// The flags of a run: the client's model alone, confined, no tools,
    /// with its prompt; the input on standard input, its events out (the
    /// first one says which account it uses).
    static func arguments(for client: Client) -> [String] {
        ["-p", "--model", client.model, "--tools", ""] + BranchReview.ClaudeCLI.confinementArguments + client.extraArguments
            + ["--max-budget-usd", client.maxBudgetUSD, "--output-format", "stream-json", "--verbose",
               "--system-prompt", client.systemPrompt]
    }

    /// `ClaudeCLI.environment`'s, without thinking (Claude Code turns it on
    /// for Haiku, which then spends thousands of tokens on one word) and
    /// without updates: a run of Nirux's own mustn't update `claude`.
    static func environment(for cli: BranchReview.ClaudeCLI, from base: [String: String] = ProcessInfo.processInfo.environment)
        -> [String: String] {
        var environment = cli.environment(from: base)
        environment["MAX_THINKING_TOKENS"] = "0"
        environment["DISABLE_AUTOUPDATER"] = "1"
        return environment
    }

    /// What a run said (not `ExplainStream`'s reading, which takes extra
    /// usage as a run that goes on: here it is a run billed per call). Its
    /// answer (the text of its result; none from a run that failed, was
    /// stopped or reported an error, an API error reading as a successful
    /// result), and whether it would be billed per call: an API key behind
    /// it, or the plan's extra usage.
    struct RunReport: Equatable {
        var text: String?
        var billedPerCall = false
        /// When the limit that put the run on extra usage resets (epoch
        /// seconds), when the run said.
        var overageResetsAt: TimeInterval?
    }

    static func report(from outcome: BoundedProcess.Outcome?) -> RunReport {
        var report = RunReport()
        guard let outcome else { return report }
        var result: [String: Any]?
        for line in outcome.standardOutput.split(separator: 0x0A) {
            guard let event = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any] else { continue }
            switch event["type"] as? String {
            case "system":
                if refusesAccount(of: event) { report.billedPerCall = true }
            case "rate_limit_event":
                let info = event["rate_limit_info"] as? [String: Any]
                if info?["isUsingOverage"] as? Bool == true || info?["overageInUse"] as? Bool == true {
                    report.billedPerCall = true
                    if let resetsAt = (info?["resetsAt"] as? NSNumber)?.doubleValue { report.overageResetsAt = resetsAt }
                }
            case "result":
                result = event
            default:
                break
            }
        }
        guard outcome.stop == nil, outcome.terminationStatus == 0, let result,
              result["is_error"] as? Bool == false, let text = result["result"] as? String
        else { return report }
        report.text = text
        return report
    }

    /// A run's first event (`system`/`init`) names an API key behind it
    /// rather than the subscription's login ("none").
    static func refusesAccount(of event: [String: Any]) -> Bool {
        guard event["subtype"] as? String == "init", let source = event["apiKeySource"] as? String else { return false }
        return source != "none"
    }

    /// Runs in an empty folder of Nirux's own (`claude` runs `git` where it
    /// starts), made again each time: macOS empties temporary folders left
    /// untouched for days. A run whose first event names an API key stops
    /// there, before it calls the model.
    static func defaultRun(timeout: TimeInterval, folderName: String)
        -> @Sendable (BranchReview.ClaudeCLI, [String], Data) -> BoundedProcess.Outcome? {
        { cli, arguments, input in
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent(folderName, isDirectory: true)
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let cancellation = BoundedProcess.Cancellation()
            let watch = FirstEventWatch(cancellation: cancellation)
            return BoundedProcess.execute(
                executableURL: URL(fileURLWithPath: cli.path), arguments: arguments,
                currentDirectoryURL: folder, environment: .replaced(environment(for: cli)),
                standardInput: input, timeout: timeout, maxStandardOutputBytes: 1 << 20,
                cancellation: cancellation, onStandardOutput: { watch.read($0) }
            )
        }
    }

    /// Reads a run's output until its first event, and stops the run when
    /// that event refuses its account.
    private final class FirstEventWatch: @unchecked Sendable {
        private let lock = NSLock()
        private var buffer = Data()
        private var done = false
        private let cancellation: BoundedProcess.Cancellation

        init(cancellation: BoundedProcess.Cancellation) {
            self.cancellation = cancellation
        }

        func read(_ chunk: Data) {
            lock.withLock {
                guard !done else { return }
                buffer.append(chunk)
                while let newline = buffer.firstIndex(of: 0x0A) {
                    let line = buffer[buffer.startIndex..<newline]
                    buffer = Data(buffer[buffer.index(after: newline)...])
                    guard let event = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any],
                          event["type"] as? String == "system", event["subtype"] as? String == "init"
                    else { continue }
                    done = true
                    if ClaudeOneShotRunner.refusesAccount(of: event) { cancellation.cancel() }
                    return
                }
            }
        }
    }
}
