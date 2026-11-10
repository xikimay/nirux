import Foundation

/// Classifies a Claude turn's final message with Claude Haiku through a
/// headless `claude -p`, on the account `claude` is logged in with. Chosen
/// after a measurement on 240 real turn ends against reference labels:
/// recall 0.99, precision 0.75, 2.1 s median, about $0.0003 a turn at API
/// prices. A local heuristic, Apple's on-device model and Create ML
/// classifiers all missed more questions.
///
/// The runs are `ClaudeOneShotRunner`'s: on a Claude subscription only,
/// the message and nothing else in front of the model. Any failure is
/// `.unknown`.
final class HaikuTurnEndClassifier: TurnEndClassifier, @unchecked Sendable {
    static let shared = HaikuTurnEndClassifier(account: .shared)

    /// A full model name, not an alias that would move to the next model.
    static let model = "claude-haiku-5-5"
    /// Measured p90 under load: 3 s. Past it the turn alerts.
    static let timeout: TimeInterval = 12
    /// Runs in a row without a verdict after which the classifier rests
    /// for `missingSetupLifetime` (every turn end alerting at once), rather
    /// than make each one wait for its timeout.
    static let failuresBeforeRest = 3
    /// Runs at once. A turn end past it alerts at once: several agents
    /// ending their turns in the same seconds is rare.
    static let maxConcurrentRuns = 4
    static let readySetupLifetime = ClaudeOneShotRunner.Account.readySetupLifetime
    static let missingSetupLifetime = ClaudeOneShotRunner.Account.missingSetupLifetime

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

    typealias Setup = ClaudeOneShotRunner.Account.Setup

    static let client = ClaudeOneShotRunner.Client(
        model: model, systemPrompt: systemPrompt, timeout: timeout, maxBudgetUSD: "0.05",
        maxConcurrentRuns: maxConcurrentRuns, failuresBeforeRest: failuresBeforeRest, folderName: "NiruxTurnEnd"
    )

    private let runner: ClaudeOneShotRunner

    /// The classifier in use: on the account every client shares.
    private init(account: ClaudeOneShotRunner.Account) {
        runner = ClaudeOneShotRunner(client: Self.client, account: account)
    }

    /// With a setup check, a run and a clock of its own (tests).
    init(
        checkSetup: @escaping @Sendable () -> Setup = ClaudeOneShotRunner.Account.defaultSetup,
        runProcess: @escaping @Sendable (BranchReview.ClaudeCLI, [String], Data) -> BoundedProcess.Outcome?
            = HaikuTurnEndClassifier.defaultRun,
        now: @escaping @Sendable () -> TimeInterval = { Date().timeIntervalSince1970 }
    ) {
        runner = ClaudeOneShotRunner(
            client: Self.client, account: ClaudeOneShotRunner.Account(checkSetup: checkSetup, now: now),
            runProcess: runProcess, now: now
        )
    }

    /// Checks the setup in the background (at launch, or when the option
    /// is turned on). Turn ends before it is known alert at once.
    func prepare() {
        runner.account.prepare()
    }

    /// The setup is known (checked once at least).
    var knowsSetup: Bool { runner.account.knowsSetup }

    func classify(_ message: String) async -> TurnEndVerdict {
        await runner.answer(to: Self.input(for: message), read: Self.verdict(fromAnswer:)) ?? .unknown
    }

    /// The message between tags it can't close itself.
    static func input(for message: String) -> Data {
        let fenced = message.replacingOccurrences(of: "</message>", with: "</ message>", options: .caseInsensitive)
        return Data("<message>\n\(fenced)\n</message>".utf8)
    }

    /// The flags of a run: Haiku alone, confined, no tools, with the prompt
    /// above; the message on standard input, its events out (the first one
    /// says which account it uses). `--max-budget-usd` caps a run that
    /// would go wrong (a normal one costs a hundredth of it).
    static func arguments() -> [String] {
        ClaudeOneShotRunner.arguments(for: client)
    }

    static func environment(for cli: BranchReview.ClaudeCLI, from base: [String: String] = ProcessInfo.processInfo.environment)
        -> [String: String] {
        ClaudeOneShotRunner.environment(for: cli, from: base)
    }

    /// ASK or DONE at the start of the model's answer; nil for anything
    /// else.
    @Sendable static func verdict(fromAnswer text: String) -> TurnEndVerdict? {
        let answer = text.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if answer.hasPrefix("ASK") { return .asks }
        if answer.hasPrefix("DONE") { return .done }
        return nil
    }

    /// What a run said: its verdict, and whether it would be billed per
    /// call (see `ClaudeOneShotRunner.report`).
    struct RunReport: Equatable {
        var verdict: TurnEndVerdict = .unknown
        var billedPerCall = false
    }

    static func report(from outcome: BoundedProcess.Outcome?) -> RunReport {
        let report = ClaudeOneShotRunner.report(from: outcome)
        return RunReport(verdict: report.text.flatMap(verdict(fromAnswer:)) ?? .unknown, billedPerCall: report.billedPerCall)
    }

    static func refusesAccount(of event: [String: Any]) -> Bool {
        ClaudeOneShotRunner.refusesAccount(of: event)
    }

    @Sendable static func defaultRun(
        cli: BranchReview.ClaudeCLI, arguments: [String], input: Data
    ) -> BoundedProcess.Outcome? {
        ClaudeOneShotRunner.defaultRun(timeout: timeout, folderName: client.folderName)(cli, arguments, input)
    }
}
