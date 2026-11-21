import Foundation

/// Reads the final message through a headless Claude on the user's subscription.
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

    static let systemPrompt = """
        Read the final message of a coding agent. Answer ASK only if the requested work needs a response from the user: \
        a required decision, missing information, access or action only they can provide, or approval before a \
        consequential step. "Which migration strategy should I implement: A or B?", "Ready to merge PR #42?" and \
        "Please log in to gh and tell me when done." are ASK. A required action can be phrased politely.

        Answer DONE for completed work, a report, or an answer, including a rhetorical question answered in the message. \
        Optional offers of further work after completion ("Want me to look at anything else?", "Let me know if you'd \
        like changes", "Si tu veux, je peux aussi…", "Dis-moi si tu as besoin d'autre chose") are DONE. Read the whole \
        message: a courtesy at the end does not cancel a required action earlier. Quoted text, code, headings and \
        punctuation alone do not require a reply. If no required user action is evident, answer DONE.

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
    /// anything else. After ASK, the question is the sentence of `message`
    /// the "Q:" line quotes, as the message writes it (a reworded one could
    /// put a Yes next to words the agent never wrote), and "A: YESNO" says
    /// a plain yes or no answers it.
    static func verdict(fromAnswer text: String, message: String) -> TurnEndVerdict? {
        let lines = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
        guard let first = lines.first(where: { !$0.isEmpty })?.uppercased() else { return nil }
        if first.hasPrefix("DONE") { return .done }
        guard first.hasPrefix("ASK") else { return nil }
        func value(_ key: String) -> String? {
            lines.first { $0.uppercased().hasPrefix(key) }.map { $0.dropFirst(key.count).trimmingCharacters(in: .whitespaces) }
        }
        guard let quote = value("Q:"), let sentence = TurnEndText.quotedSentence(quote, in: message) else { return .asks(nil) }
        return .asks(TurnEndQuestion(text: sentence, isYesNo: value("A:")?.uppercased() == "YESNO"))
    }
}
