import Foundation

/// The answers a Mission child's questions got, which stay with the task in
/// the ledger: given back to its `claude` when its conversation doesn't hold
/// them (a session started anew, cleared or compacted), as a SessionStart
/// hook's additional context (`AgentHookCLI`), and listed to its parent
/// (list_tasks).
enum MissionAnswerContext {
    /// The SessionStart sources whose conversation lacks the answers: a
    /// resumed or forked one keeps them.
    static let sources: Set<String> = ["startup", "clear", "compact"]
    static let maxLines = 10
    static let maxQuestionLength = 200
    static let maxAnswerLength = 1_000
    /// The later messages given, and how much of each.
    static let maxLaterMessages = 3
    static let maxLaterLength = 300
    /// Under Claude Code's 10,000 UTF-16 units, past which it files the
    /// context away and shows a preview.
    static let maxContextUTF16 = 8_000

    /// `mission`'s answered questions, oldest first.
    static func answered(in mission: Mission) -> [(question: MissionEvent, answer: MissionEvent)] {
        mission.events.compactMap { answer in
            guard answer.kind == .response,
                  let question = mission.events.first(where: { $0.id == answer.inReplyTo && $0.kind == .question })
            else { return nil }
            return (question, answer)
        }
    }

    /// " (from the user, <owner> recommendation)", or "".
    static func notes(of answer: MissionEvent, owner: String) -> String {
        let notes = [
            answer.answeredByUser == true ? "from the user" : nil,
            answer.acceptedRecommendation == true ? "\(owner) recommendation" : nil
        ].compactMap { $0 }
        return notes.isEmpty ? "" : " (\(notes.joined(separator: ", ")))"
    }

    /// The questions `mission`'s child asked since it last reported, oldest
    /// first: each answer it received (an access one not repeated: what the
    /// user gave stays where the child put it), "answered" when Nirux will
    /// type the answer into its prompt, else "still open"; then the messages
    /// typed into its prompt after the first answer it received, on any
    /// Mission of `missions` to that child (its parent's, a Lead's one-way),
    /// which may change one. The latest `maxLines` within
    /// `maxContextUTF16`, the newest cut if it alone doesn't fit; nil for
    /// none.
    static func text(for mission: Mission, among missions: [Mission]) -> String? {
        let round = mission.events.lastIndex { $0.kind == .completed }.map { mission.events.index(after: $0) } ?? mission.events.startIndex
        var firstReceived: TimeInterval?
        let lines = mission.events[round...].filter { $0.kind == .question }.map { question in
            let kind = question.questionKind.map { "\($0.rawValue): " } ?? ""
            let asked = "- \(kind)“\(clipped(question.message, maxQuestionLength))” → "
            guard let answer = mission.events.first(where: { $0.kind == .response && $0.inReplyTo == question.id }) else {
                return asked + "still open"
            }
            guard let receivedAt = answer.childConsumedAt else {
                return asked + (MissionStore.isPendingDelivery(answer, in: mission, now: 0)
                    ? "answered; Nirux types the answer into your prompt" : "still open")
            }
            firstReceived = min(firstReceived ?? receivedAt, receivedAt)
            guard question.questionKind != .access else {
                return asked + "answered; what it gave isn't repeated here: use it where you put it then"
            }
            return asked + "“\(clipped(answer.message, maxAnswerLength))”" + notes(of: answer, owner: "your")
        }
        let later = firstReceived.map { laterMessages(to: mission, among: missions, since: $0) } ?? []
        let laterSection = later.isEmpty ? "" : "\nMessages you were given after those answers, oldest first; they may change one:\n"
            + later.joined(separator: "\n")
        let header = "\(MissionPromptText.prefix) Your questions in this task since it last reported, oldest first, "
            + "and their answers (your conversation no longer holds them):"
        // The "earlier ones" line, at its longest, counts too.
        var size = header.utf16.count + laterSection.utf16.count + earlierLine(lines.count).utf16.count
        var kept: [String] = []
        for line in lines.reversed() where kept.count < maxLines {
            let room = maxContextUTF16 - size - 1
            guard line.utf16.count <= room || kept.isEmpty else { break }
            let fitting = line.utf16.count <= room ? line : prefix(line, utf16: max(0, room - 1)) + "…"
            kept.insert(fitting, at: 0)
            size += 1 + fitting.utf16.count
        }
        guard !kept.isEmpty else { return nil }
        let earlier = lines.count > kept.count ? earlierLine(lines.count - kept.count) : ""
        return ([header] + kept).joined(separator: "\n") + earlier + laterSection
    }

    /// The messages typed into `mission`'s child's prompt after `since`,
    /// the latest `maxLaterMessages`, oldest first, each a clipped line.
    private static func laterMessages(to mission: Mission, among missions: [Mission], since: TimeInterval) -> [String] {
        let typed: [(at: TimeInterval, message: String)] = missions
            .filter { $0.childWorkspaceID == mission.childWorkspaceID && $0.childAgentUUID == mission.childAgentUUID }
            .flatMap(\.events)
            .compactMap { event in
                guard event.kind == .instruction, let at = event.childConsumedAt, at > since else { return nil }
                return (at, event.message)
            }
        return typed.sorted { $0.at < $1.at }.suffix(maxLaterMessages).map { entry in
            let line: String = prefix(clipped(entry.message, maxLaterLength), utf16: maxLaterLength * 2)
            return "- “" + line + "”"
        }
    }

    private static func earlierLine(_ count: Int) -> String {
        "\n(\(count) earlier ones not shown)"
    }

    /// What the SessionStart hook prints for `source` in a terminal with
    /// `environment`: the answers of the Mission whose agent it is, as
    /// Claude Code's JSON; nil when there are none to give.
    static func hookOutput(
        source: String?, environment: [String: String], missionsURL: URL = MissionStore.defaultFileURL,
        handoffsEnabled: () -> Bool = { Persistence.load().map { PersistedSettings.effective($0.settings).missionHandoffsEnabled } ?? false }
    ) -> Data? {
        guard let source, sources.contains(source),
              let missionID = environment["NIRUX_MISSION_ID"],
              let workspaceID = environment["NIRUX_WORKSPACE_ID"],
              let agentUUID = environment["NIRUX_AGENT_UUID"]
        else { return nil }
        var ledger = MissionLedgerReader(url: missionsURL)
        guard ledger.refresh(),
              let mission = ledger.missions.first(where: {
                  $0.id == missionID && $0.childWorkspaceID == workspaceID && $0.childAgentUUID == agentUUID
              }),
              // Nirux carries nothing for it under the handoffs setting now.
              mission.isAlwaysCarried || handoffsEnabled(),
              let text = text(for: mission, among: ledger.missions)
        else { return nil }
        return try? JSONSerialization.data(withJSONObject: [
            "hookSpecificOutput": ["hookEventName": "SessionStart", "additionalContext": text]
        ])
    }

    /// `text`'s first scalars within `limit` UTF-16 units, as Claude Code
    /// counts.
    static func prefix(_ text: String, utf16 limit: Int) -> String {
        var scalars = String.UnicodeScalarView()
        var count = 0
        for scalar in text.unicodeScalars {
            count += scalar.utf16.count
            guard count <= limit else { break }
            scalars.append(scalar)
        }
        return String(scalars)
    }

    /// On one line, cut at `limit`, then no `[Nirux Mission]` prefix: one
    /// cleaning puts together can't pass.
    static func clipped(_ text: String, _ limit: Int) -> String {
        MissionPromptText.quoted(AgentText.clean(text, maxLength: limit) ?? "")
    }
}
