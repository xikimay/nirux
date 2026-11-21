import Foundation

/// The text Nirux types into an agent's prompt for a Mission message (see
/// `MissionStore.pendingPromptDeliveries`). Instructions (`tell`) go in raw,
/// so a slash command stays one, except a Lead's to a task that doesn't
/// report to it; everything else starts with `prefix`, so the agent can
/// tell Nirux from the user.
enum MissionPromptText {
    static let prefix = "[Nirux Mission]"

    /// The line above a Lead's tell to a task that doesn't report to it.
    static let oneWayHeader = "\(prefix) From the space's Lead (one-way: your questions and result still go to "
        + "whoever started this task):"

    /// What Nirux types around a long message at most, in scalars: an
    /// answer's prefix and the parent's title, cut at `maxNameScalars`, or
    /// a one-way tell's header. Questions and results are short.
    static let maxNameScalars = 200
    static let headerScalars = max(
        "\(prefix) Answer from \"\": ".unicodeScalars.count + maxNameScalars, oneWayHeader.unicodeScalars.count + 1
    )

    /// Whether `message`, typed as it is, starts with a slash command
    /// (`/clear`), not a path (`/Users/…`).
    static func startsWithSlashCommand(_ message: String) -> Bool {
        message.range(of: #"^/[A-Za-z][A-Za-z0-9_:-]*(\s|$)"#, options: .regularExpression) != nil
    }

    /// `childTitle` and `parentTitle` are the workspaces' titles now; nil
    /// when the workspace is gone.
    static func text(
        for delivery: MissionStore.AcceptedEvent, childTitle: String?, parentTitle: String?
    ) -> String? {
        let event = delivery.event
        let child = childName(title: childTitle, branch: delivery.mission.branch)
        switch event.kind {
        case .instruction:
            return event.leadSender != nil || delivery.mission.oneWay == true ? oneWayHeader + "\n" + event.message : event.message
        case .question where delivery.mission.reportsToLead == true:
            // A space's Lead answers with its tools (see LeadTools).
            return question(event, from: child, accept: toolAccept, trailer: "Answer with the reply tool, question \(event.id); "
                + "if neither the brief, the code nor the user's words settle it, don't guess: hand it to the user with ask_user.")
        case .question where delivery.mission.reportsToTask == true:
            // A task's agent that started it with start_task answers with
            // its tools too (see TaskTools).
            return question(event, from: child, accept: toolAccept, trailer: "Answer with the reply tool, question \(event.id); "
                + "if neither the code nor the user's words settle it, don't guess: hand it to the user with ask_user.")
        case .question:
            return question(event, from: child, accept: cliAccept, trailer: "Reply with: \"$NIRUX_CLI_PATH\" --mission reply "
                + "--event \(event.id) --message \"<answer>\" (if you can't tell, don't guess: ask the user)")
        case .response:
            let from = event.answeredByUser == true ? "the user"
                : parentTitle.map { "\"\(String(String.UnicodeScalarView(quoted($0).unicodeScalars.prefix(maxNameScalars))))\"" }
                ?? "the parent agent"
            let retired = delivery.mission.events.first { $0.id == event.inReplyTo && $0.retiredAt != nil }
            return "\(prefix) Answer from \(from): \(event.message)"
                + (event.acceptedRecommendation == true ? "\n" + acceptedNote : "")
                + (retired.map { "\n" + lateNote(to: $0) } ?? "")
        case .completed:
            return "\(prefix) \(child) completed: \(quoted(event.message))"
                + neverTypedNote(questionsNeverTyped(retiredBy: event, in: delivery.mission))
        case .acknowledged:
            return nil
        }
    }

    /// Under an answer that is the child's own recommendation.
    static let acceptedNote = "It is the answer you recommended."
    /// Under an answer to `question`, which the child moved past
    /// (`MissionEvent.retiredAt`).
    static func lateNote(to question: MissionEvent) -> String {
        "It answers your question “\(AgentText.clean(quoted(question.message), maxLength: lateNoteExcerpt) ?? "")”, asked before your "
            + "last prompt: weigh it against what came since."
    }

    static let lateNoteExcerpt = 120

    /// A question as Nirux types it: who asks, its words, its kind and
    /// recommendation, then how to answer, which names the question and
    /// always fits what Nirux types: a message too long in scalars gives way.
    private static func question(_ event: MissionEvent, from child: String, accept: String, trailer: String) -> String {
        let head = "\(prefix) Question from \(child):\n"
        let tail = "\n" + blockLines(of: event, accept: accept) + trailer
        let room = TypedPromptSanitizer.maxCharacters - head.unicodeScalars.count - tail.unicodeScalars.count
        return head + fitted(quoted(event.message), scalars: room) + tail
    }

    /// `text` within `limit` scalars, ending on "…" when cut.
    static func fitted(_ text: String, scalars limit: Int) -> String {
        guard text.unicodeScalars.count > limit else { return text }
        return String(String.UnicodeScalarView(text.unicodeScalars.prefix(max(0, limit - 1)))) + "…"
    }

    static let toolAccept = "reply's accept: true sends it"
    static let cliAccept = "--accept in place of --message sends it"

    /// What blocks the child and what it recommends (what it needs, for an
    /// access question), on one line; `accept` says how its parent sends the
    /// recommendation as the answer. Nil for a question with neither.
    static func blockLine(of question: MissionEvent, accept: String?) -> String? {
        let kind = question.questionKind.map { "Kind: \(quoted($0.rawValue))." }
        let recommendation = question.recommendation.map { text in
            if question.questionKind == .access { return "Needed: \(quoted(text))" }
            let hint = question.acceptableRecommendation == nil ? nil : accept
            return "Recommended" + (hint.map { " (\($0))" } ?? "") + ": \(quoted(text))"
        }
        let parts = [kind, recommendation].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    private static func blockLines(of question: MissionEvent, accept: String) -> String {
        blockLine(of: question, accept: accept).map { $0 + "\n" } ?? ""
    }

    /// The child's questions its `completed` retired unanswered (see
    /// `MissionStore.process`, which marks them consumed at its time) that
    /// were never typed into the parent's prompt: the user may have answered
    /// them in the child's terminal, and the parent never saw them.
    static func questionsNeverTyped(retiredBy completed: MissionEvent, in mission: Mission) -> [MissionEvent] {
        let answered = Set(mission.events.compactMap { $0.kind == .response ? $0.inReplyTo : nil })
        // And those a prompt retired since its last completion, listed once.
        let since = mission.events.filter { $0.kind == .completed && $0.timestamp < completed.timestamp }.map(\.timestamp).max() ?? 0
        return mission.events.filter {
            $0.kind == .question && $0.parentTypedAt == nil && $0.handedToUserBecause == nil && !answered.contains($0.id)
                && ($0.parentConsumedAt == completed.timestamp || ($0.retiredAt ?? 0) > since)
        }
    }

    static let neverTypedListed = 5
    static let neverTypedExcerpt = 200

    private static func neverTypedNote(_ questions: [MissionEvent]) -> String {
        guard !questions.isEmpty else { return "" }
        let count = questions.count == 1 ? "a question" : "\(questions.count) questions"
        let listed = questions.prefix(neverTypedListed).map { "\n- " + (AgentText.clean(quoted($0.message), maxLength: neverTypedExcerpt) ?? "") }
        let more = questions.count > neverTypedListed ? "\n(and \(questions.count - neverTypedListed) more)" : ""
        return "\nIt asked you \(count) that never reached your prompt; the user may have answered in its terminal. Its words:"
            + listed.joined() + more
    }

    /// A child's text on one line, without the prefix: it can't pass for a
    /// line Nirux wrote (an answer "from the user", another `Reply with`).
    static func quoted(_ text: String) -> String {
        text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .replacingOccurrences(of: prefix, with: "(Nirux Mission)")
    }

    /// `"Date filter API" (branch feat/date-filter)`; the branch alone when
    /// the title is the branch, or the workspace is gone.
    private static func childName(title: String?, branch: String) -> String {
        let branch = fitted(quoted(branch), scalars: maxNameScalars)
        guard let title = title.map({ fitted(quoted($0), scalars: maxNameScalars) }), title != branch else { return "\"\(branch)\"" }
        return "\"\(title)\" (branch \(branch))"
    }
}
