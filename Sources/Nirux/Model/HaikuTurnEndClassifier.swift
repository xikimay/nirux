import Foundation

/// Classifies a Claude turn's final message with Claude Haiku through a
/// headless `claude -p`, on the account `claude` is logged in with. Chosen
/// after a measurement on 240 real turn ends against reference labels:
/// recall 0.99, precision 0.75, 2.1 s median, about $0.0003 a turn at API
/// prices. A local heuristic, Apple's on-device model and Create ML
/// classifiers all missed more questions.
///
/// It runs only on a Claude subscription (claude.ai, through Anthropic):
/// anywhere else each turn would be billed, so every turn alerts as
/// before. No tools, MCP servers, hooks, settings, instruction files or
/// saved session: the run sees the message and nothing else. Any failure
/// is `.unknown`.
final class HaikuTurnEndClassifier: TurnEndClassifier, @unchecked Sendable {
    static let shared = HaikuTurnEndClassifier()

    /// A full model name, not an alias that would move to the next model.
    static let model = "claude-haiku-5-5"
    /// Measured p90 under load: 3 s. Past it the turn alerts.
    static let timeout: TimeInterval = 12
    /// Runs in a row without a verdict after which the classifier rests
    /// for `missingSetupLifetime` (every turn end alerting at once), rather
    /// than make each one wait for its timeout: an outage, a network, a
    /// model the account can't use.
    static let failuresBeforeRest = 3
    /// Runs at once. A turn end past it alerts at once: several agents
    /// ending their turns in the same seconds is rare.
    static let maxConcurrentRuns = 4
    /// How long a found setup (or its absence) is trusted before being
    /// checked again: `claude` may be logged out, or updated, meanwhile.
    static let readySetupLifetime: TimeInterval = 60 * 60
    static let missingSetupLifetime: TimeInterval = 10 * 60

    /// The prompt measured, word for word: "when unsure, answer ASK" keeps
    /// recall up, which matters more than precision here.
    static let systemPrompt = """
        You read the final message an AI coding agent wrote at the end of its turn, and decide whether the user must \
        answer before the work can go on.

        Answer ASK when the message hands something back to the user: a question to them, a choice between options, \
        a request for confirmation or approval, an action only the user can do (log in, test, run a command, check \
        something), or an offer to do more ("want me to…?", "should I…?", "let me know if…", "si tu veux, je \
        peux…", "dis-moi si…", "je merge ?").
        Answer DONE when the message only reports results or answers a question, and asks nothing. A rhetorical \
        question the message answers itself is DONE. Quoted text, code and headings are not questions to the user.
        When unsure, answer ASK.

        Reply with exactly one word: ASK or DONE.
        """

    /// What a run needs: a `claude` that confines its runs, logged in on a
    /// subscription.
    enum Setup: Equatable, Sendable {
        case ready(BranchReview.ClaudeCLI)
        case unavailable
    }

    /// Guards `runningCount`, `cachedSetup` and `isRefreshingSetup`.
    private let lock = NSLock()
    private var runningCount = 0
    private var cachedSetup: (setup: Setup, checkedAt: TimeInterval)?
    private var isRefreshingSetup = false
    private var failuresInARow = 0
    /// Held while the setup is checked: one check at a time.
    private let setupLock = NSLock()
    private let checkSetup: @Sendable () -> Setup
    private let runProcess: @Sendable (BranchReview.ClaudeCLI, [String], Data) -> BoundedProcess.Outcome?
    private let now: @Sendable () -> TimeInterval

    init(
        checkSetup: @escaping @Sendable () -> Setup = HaikuTurnEndClassifier.defaultSetup,
        runProcess: @escaping @Sendable (BranchReview.ClaudeCLI, [String], Data) -> BoundedProcess.Outcome?
            = HaikuTurnEndClassifier.defaultRun,
        now: @escaping @Sendable () -> TimeInterval = { Date().timeIntervalSince1970 }
    ) {
        self.checkSetup = checkSetup
        self.runProcess = runProcess
        self.now = now
    }

    /// Checks the setup in the background (at launch, or when the option
    /// is turned on): the first turn end needn't wait for it.
    func prepare() {
        DispatchQueue.global(qos: .utility).async { _ = self.checkSetupNow() }
    }

    func classify(_ message: String) async -> TurnEndVerdict {
        guard reserveRun() else { return .unknown }
        // The run blocks its thread for seconds: never the caller's, which
        // may be the main actor's.
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let verdict = self.classifyNow(message)
                self.endRun()
                continuation.resume(returning: verdict)
            }
        }
    }

    /// Blocks: call it off the main thread.
    private func classifyNow(_ message: String) -> TurnEndVerdict {
        guard case .ready(let cli) = setup() else { return .unknown }
        let verdict = Self.verdict(from: runProcess(cli, Self.arguments(), Self.input(for: message)))
        lock.withLock {
            failuresInARow = verdict == .unknown ? failuresInARow + 1 : 0
            if failuresInARow >= Self.failuresBeforeRest {
                failuresInARow = 0
                cachedSetup = (.unavailable, now())
            }
        }
        return verdict
    }

    /// The message between tags it can't close itself.
    static func input(for message: String) -> Data {
        let fenced = message.replacingOccurrences(of: "</message>", with: "</ message>", options: .caseInsensitive)
        return Data("<message>\n\(fenced)\n</message>".utf8)
    }

    private func reserveRun() -> Bool {
        lock.withLock {
            guard runningCount < Self.maxConcurrentRuns else { return false }
            runningCount += 1
            return true
        }
    }

    private func endRun() {
        lock.withLock { runningCount -= 1 }
    }

    /// The setup known, checked again in the background once it is old:
    /// only the very first turn end (before `prepare` is done) waits for a
    /// check, which runs `claude` twice.
    private func setup() -> Setup {
        let time = now()
        let known: Setup? = lock.withLock {
            guard let cached = cachedSetup else { return nil }
            if !isFresh(cached, at: time), !isRefreshingSetup {
                isRefreshingSetup = true
                DispatchQueue.global(qos: .utility).async { _ = self.checkSetupNow() }
            }
            return cached.setup
        }
        return known ?? checkSetupNow()
    }

    private func checkSetupNow() -> Setup {
        setupLock.withLock {
            // Checked by another caller while this one waited (or rested by
            // failures): the refresh asked for is done.
            let fresh: Setup? = lock.withLock {
                guard let cached = cachedSetup, isFresh(cached, at: now()) else { return nil }
                isRefreshingSetup = false
                return cached.setup
            }
            if let fresh { return fresh }
            let setup = checkSetup()
            lock.withLock {
                cachedSetup = (setup, now())
                isRefreshingSetup = false
            }
            return setup
        }
    }

    private func isFresh(_ cached: (setup: Setup, checkedAt: TimeInterval), at time: TimeInterval) -> Bool {
        let lifetime = cached.setup == .unavailable ? Self.missingSetupLifetime : Self.readySetupLifetime
        return time - cached.checkedAt < lifetime
    }

    /// The flags of a run: Haiku alone, confined, no tools, with the prompt
    /// above; the message on standard input, one JSON result out.
    /// `--max-budget-usd` caps a run that would go wrong (a normal one
    /// costs a hundredth of it).
    static func arguments() -> [String] {
        ["-p", "--model", model, "--tools", ""] + BranchReview.ClaudeCLI.confinementArguments
            + ["--max-budget-usd", "0.05", "--output-format", "json", "--system-prompt", systemPrompt]
    }

    /// `ClaudeCLI.environment`'s, without thinking (Claude Code turns it on
    /// for Haiku, which then spends thousands of tokens on one word) and
    /// without updates: a run every turn end mustn't update `claude`.
    static func environment(for cli: BranchReview.ClaudeCLI, from base: [String: String] = ProcessInfo.processInfo.environment)
        -> [String: String] {
        var environment = cli.environment(from: base)
        environment["MAX_THINKING_TOKENS"] = "0"
        environment["DISABLE_AUTOUPDATER"] = "1"
        return environment
    }

    /// The verdict a run's JSON result gives: its `result` starting with
    /// ASK or DONE. A run that failed, was stopped, or reported an error
    /// (`is_error`, an API error reads as a successful result) gives none.
    static func verdict(from outcome: BoundedProcess.Outcome?) -> TurnEndVerdict {
        guard let outcome, outcome.stop == nil, outcome.terminationStatus == 0,
              let object = (try? JSONSerialization.jsonObject(with: outcome.standardOutput)) as? [String: Any],
              object["is_error"] as? Bool == false,
              let result = object["result"] as? String
        else { return .unknown }
        let answer = result.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if answer.hasPrefix("ASK") { return .asks }
        if answer.hasPrefix("DONE") { return .done }
        return .unknown
    }

    /// A confining `claude` logged in on a subscription. Runs `claude
    /// --help` and `claude auth status`: off the main thread.
    @Sendable static func defaultSetup() -> Setup {
        guard case .ready(let cli) = BranchReview.ClaudeCLI.locate(),
              let account = cli.account(), account.isLoggedIn, !account.isBilledPerCall
        else { return .unavailable }
        return .ready(cli)
    }

    /// Runs in an empty folder of Nirux's own (`claude` runs `git` where it
    /// starts), made again each time: macOS empties temporary folders left
    /// untouched for days.
    @Sendable static func defaultRun(
        cli: BranchReview.ClaudeCLI, arguments: [String], input: Data
    ) -> BoundedProcess.Outcome? {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("NiruxTurnEnd", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return BoundedProcess.execute(
            executableURL: URL(fileURLWithPath: cli.path), arguments: arguments,
            currentDirectoryURL: folder, environment: .replaced(environment(for: cli)),
            standardInput: input, timeout: timeout, maxStandardOutputBytes: 1 << 20
        )
    }
}
