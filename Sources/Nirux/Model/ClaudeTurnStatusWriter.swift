import Foundation

/// Where a task stands after a turn, in a few words, from the turn's final
/// message: the line its row shows ("fix pushed, CI green").
enum TurnStatus: Equatable, Sendable {
    case line(String)
    /// The turn changed nothing (it only explained or answered): the row
    /// keeps its line.
    case unchanged
}

/// Writes a turn's status line. Its own call, apart from the turn-end
/// classifier's: a line added to the verdict's prompt moved verdicts on
/// borderline turns, both ways.
protocol TurnStatusWriter: Sendable {
    /// Never throws: any failure is nil (no line). May take seconds; the
    /// caller doesn't wait on the main thread.
    func status(of message: String) async -> TurnStatus?
}

/// Writes the line with Claude Sonnet through a headless `claude -p`, on the
/// account `claude` is logged in with (`ClaudeOneShotRunner`: a Claude
/// subscription only, the message and nothing else in front of the model).
/// Measured on 240 real turn ends: a line every time, 2 unfaithful and 2
/// vague of 230 by Opus's reading, 5 words at the median, 2.6 s at the
/// median. Haiku added lines and comments, and mixed languages.
final class ClaudeTurnStatusWriter: TurnStatusWriter, @unchecked Sendable {
    static let shared = ClaudeTurnStatusWriter(account: .shared)

    /// A full model name, not an alias that would move to the next model.
    static let model = "claude-sonnet-5-5"
    /// The longest line kept: the row cuts a long one anyway.
    static let maxLength = 80

    /// The prompt measured, word for word. English, as the rest of the
    /// row; "-" keeps the line a turn didn't change.
    static let systemPrompt = """
        You read the final message an AI coding agent wrote at the end of its turn, and write where the task stands \
        now, for a one-line task list.

        Always in English, even when the message is in another language. At most 4 short words (about 25 \
        characters), no final period. Name the outcome or what the work waits on ("fix pushed, CI green", "waits on \
        merge go-ahead", "tests fail on CI"), not the steps taken. Write "-" only when the turn changed nothing about \
        the work: it only explained or answered a question, and reports no change, fix, result or new state.

        Reply with the status line only.
        """

    /// Its runs: as the classifier's, two at once (a third turn end in the
    /// same seconds gets no line), resting apart from the classifier.
    static let client = ClaudeOneShotRunner.Client(
        model: model, systemPrompt: systemPrompt, timeout: 20, maxBudgetUSD: "0.05",
        maxConcurrentRuns: 2, failuresBeforeRest: 3, folderName: "NiruxTurnStatus"
    )

    private let runner: ClaudeOneShotRunner

    private init(account: ClaudeOneShotRunner.Account) {
        runner = ClaudeOneShotRunner(client: Self.client, account: account)
    }

    /// With a setup check and a run of its own (tests).
    init(
        checkSetup: @escaping @Sendable () -> ClaudeOneShotRunner.Account.Setup,
        runProcess: @escaping @Sendable (BranchReview.ClaudeCLI, [String], Data) -> BoundedProcess.Outcome?
    ) {
        runner = ClaudeOneShotRunner(
            client: Self.client, account: ClaudeOneShotRunner.Account(checkSetup: checkSetup), runProcess: runProcess
        )
    }

    /// Checks the setup in the background (at launch, or when the option
    /// is turned on). Turn ends before it is known get no line.
    func prepare() {
        runner.account.prepare()
    }

    var knowsSetup: Bool { runner.account.knowsSetup }

    func status(of message: String) async -> TurnStatus? {
        await runner.answer(to: ClaudeTurnEndClassifier.input(for: message), read: Self.status(fromAnswer:))
    }

    /// The answer's first line, without a "S:" label, quotation marks or a
    /// final period; "-" when the turn changed nothing. Nil for nothing.
    static func status(fromAnswer text: String) -> TurnStatus? {
        let marks = CharacterSet(charactersIn: "\"“”'`*").union(.whitespaces)
        guard var line = text.split(whereSeparator: \.isNewline).lazy
            .map({ $0.trimmingCharacters(in: marks) }).first(where: { !$0.isEmpty })
        else { return nil }
        if line.hasSuffix("."), !line.hasSuffix("..") { line.removeLast() }
        if ["-", "–", "—"].contains(line) { return .unchanged }
        return AgentText.clean(line, maxLength: maxLength).map(TurnStatus.line)
    }
}
