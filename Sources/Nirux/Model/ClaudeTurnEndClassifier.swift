import Foundation

/// Classifies a Claude turn's final message with Claude Sonnet through a
/// headless `claude -p`, on the account `claude` is logged in with. Turns
/// that end on a question never get here (`TurnEndText.endsOnQuestion`).
/// Chosen over Haiku after repeated runs on 240 real turn ends and a
/// hand-labeled set (worst run of each): Haiku missed some real questions
/// in some runs whatever the prompt or effort, Sonnet with the question
/// floor missed none. About $0.002 a classified turn at API prices, 2.5 s
/// at the median. A local heuristic, Apple's on-device model and Create ML
/// classifiers all missed more questions.
///
/// The runs are `ClaudeOneShotRunner`'s: on a Claude subscription only,
/// the message and nothing else in front of the model. Any failure is
/// `.unknown`.
final class ClaudeTurnEndClassifier: TurnEndClassifier, @unchecked Sendable {
    static let shared = ClaudeTurnEndClassifier(account: .shared)

    /// A full model name, not an alias that would move to the next model.
    static let model = "claude-sonnet-5-5"
    /// Measured under load, one run after another: p90 8 s, slowest 11 s.
    /// Past it the turn alerts.
    static let timeout: TimeInterval = 20
    /// Runs in a row without a verdict after which the classifier rests
    /// for `missingSetupLifetime` (every turn end alerting at once), rather
    /// than make each one wait for its timeout.
    static let failuresBeforeRest = 3
    /// Runs at once. A turn end past it alerts at once: several agents
    /// ending their turns in the same seconds is rare.
    static let maxConcurrentRuns = 4

    /// The prompt measured, word for word: "when unsure, answer ASK" keeps
    /// recall up, which matters more than precision here. After ASK, the
    /// sentence that asks, quoted (found in the message 170 times in 171),
    /// and whether a yes or no answers it.
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

        Reply with one word on the first line: ASK or DONE.
        After ASK only, add two lines:
        Q: the sentence of the message that asks the user, copied exactly as written (no rewording, no translation).
        A: YESNO when the agent asks for a yes or no it will act on (a permission, a go-ahead, a yes/no decision); \
        OPEN for a choice between options, a question needing details, or something the user must do or check first.
        """

    typealias Setup = ClaudeOneShotRunner.Account.Setup

    /// Its runs: the model alone, confined, no tools, with the prompt
    /// above; the message on standard input, its events out (the first one
    /// says which account it uses). `--max-budget-usd` caps a run that
    /// would go wrong (a normal one costs a twenty-fifth of it, an eighth
    /// when the prompt's cache is cold).
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
        runProcess: (@Sendable (BranchReview.ClaudeCLI, [String], Data) -> BoundedProcess.Outcome?)? = nil,
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
        await runner.answer(to: Self.input(for: message), read: { Self.verdict(fromAnswer: $0, message: message) })
            ?? .unknown
    }

    /// The message between tags it can't close itself.
    static func input(for message: String) -> Data {
        let fenced = message.replacingOccurrences(of: "</message>", with: "</ message>", options: .caseInsensitive)
        return Data("<message>\n\(fenced)\n</message>".utf8)
    }

    /// ASK or DONE on the first line of the model's answer; nil for
    /// anything else. After ASK, the "Q:" line is the question only when
    /// `message` holds it word for word (a reworded one could put a Yes
    /// next to words the agent never wrote), and "A: YESNO" says a plain
    /// yes or no answers it.
    static func verdict(fromAnswer text: String, message: String) -> TurnEndVerdict? {
        let lines = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
        guard let first = lines.first(where: { !$0.isEmpty })?.uppercased() else { return nil }
        if first.hasPrefix("DONE") { return .done }
        guard first.hasPrefix("ASK") else { return nil }
        func value(_ key: String) -> String? {
            lines.first { $0.hasPrefix(key) }.map { $0.dropFirst(key.count).trimmingCharacters(in: .whitespaces) }
        }
        let quote = value("Q:")
        guard let quote, TurnEndText.quotes(quote, in: message) else { return .asks(nil) }
        return .asks(TurnEndQuestion(text: quote, isYesNo: value("A:")?.uppercased() == "YESNO"))
    }
}
