import Foundation

/// The finding kinds a space's reviews keep recording, given to each
/// reviewer as it starts (docs/design/review-checklist.md). Claude Code runs
/// `/code-review` as a forked subagent, typed or through the Skill tool:
/// only a SubagentStart hook's context reaches the fork (measured on
/// 2.1.332), so that is where the receiver gives it.
enum ReviewChecklist {
    static let maxKinds = 7
    static let maxHandles = 5
    /// The passes it goes to, by their exact command or skill name.
    static let passes: Set<ReviewPass> = [.codeReview, .premortem]

    static let header = "Review checklist from Nirux: this space's reviews recorded these kinds of finding in two tasks or more "
        + "over the last 30 days, the most tasks first. Check the change for each of them too."

    /// The kinds of `entries` seen in two tasks or more in the last 30 days,
    /// each with its tasks, the latest first, and its latest finding; nil
    /// when none is.
    static func text(_ entries: [ReviewFindings.Entry], now: TimeInterval) -> String? {
        let since = now - Double(ReviewFindings.lines.keptDays) * 86_400
        let kinds = ReviewFindings.kinds(entries.filter { $0.time >= since }).filter { $0.taskCount > 1 }.prefix(maxKinds)
        guard !kinds.isEmpty else { return nil }
        let lines = kinds.map { kind in
            // Each task by its latest sighting, the latest first.
            let lastSightings = Dictionary(kind.sightings.map { ($0.identity, $0) }, uniquingKeysWith: { _, last in last }).values
            let handles = lastSightings.sorted { ($0.time, $0.handle) > ($1.time, $1.handle) }.map(\.handle)
            let more = handles.count > maxHandles ? " and \(handles.count - maxHandles) more" : ""
            let latest = kind.sightings.last.map { " · latest: “\($0.text)”" } ?? ""
            return "- \(kind.name) · \(kind.taskCount) tasks (\(handles.prefix(maxHandles).joined(separator: ", "))\(more))\(latest)"
        }
        return ([header] + lines).joined(separator: "\n")
    }

    /// The space's list now, unless its switch is off.
    static func due(spaceID: String, stateDirectory: URL, now: TimeInterval) -> String? {
        guard SpaceDefaultsStore.defaults(forSpace: spaceID, stateDirectory: stateDirectory).reviewChecklistIsOn else { return nil }
        return text(ReviewFindings.lines.load(spaceID: spaceID, stateDirectory: stateDirectory), now: now)
    }

    // MARK: - The hook receiver

    /// What the receiver prints for a SubagentStart: the list as context,
    /// for the fork of a review skill only. Any other subagent costs one
    /// file lookup.
    static func subagentStartOutput(
        _ payload: [String: Any], environment: [String: String], stateDirectory: URL = Persistence.stateDirectory, now: TimeInterval
    ) -> Data? {
        guard let skill = forkedSkill(payload), ReviewPass.command(skill).map(passes.contains) == true,
              let session = payload["session_id"] as? String, !session.isEmpty,
              let space = Persistence.spaceID(environment: environment, stateDirectory: stateDirectory),
              let text = due(spaceID: space, stateDirectory: stateDirectory, now: now)
        else { return nil }
        reaches.append(Reach(time: now, session: session, kind: .given), spaceID: space, stateDirectory: stateDirectory, trims: false)
        return try? JSONSerialization.data(withJSONObject: [
            "hookSpecificOutput": ["hookEventName": "SubagentStart", "additionalContext": text]
        ])
    }

    /// The skill a subagent runs as a fork: Claude Code names it in
    /// `<session>/subagents/agent-<id>.forked-skill.json` beside the
    /// transcript before SubagentStart runs. Undocumented: the daily pass
    /// says when the list stops reaching reviewers.
    static func forkedSkill(_ payload: [String: Any]) -> String? {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        guard let transcript = (payload["transcript_path"] as? String).flatMap(AgentHookEvent.validTranscriptPath),
              let agent = payload["agent_id"] as? String, !agent.isEmpty, agent.unicodeScalars.allSatisfy(allowed.contains)
        else { return nil }
        let url = URL(fileURLWithPath: transcript).deletingPathExtension()
            .appendingPathComponent("subagents").appendingPathComponent("agent-\(agent).forked-skill.json")
        guard case .data(let data) = BoardConfigStore.read(url, maxBytes: 4_096),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return nil }
        return object["skillName"] as? String
    }

    /// A `/code-review` start the hooks say by documented means (a typed
    /// command, a Skill call), noted while a list is due: the daily pass
    /// compares them with the lists given. Only it was measured running as a
    /// fork; `ultra` runs in the cloud. A Skill call that ran otherwise than
    /// as a background fork (a foreground subagent's, inline) had no
    /// forked-skill file on 2.1.321–2.1.332, so gets no list: not counted.
    static func noteReviewStart(
        _ event: AgentHookEvent, payload: [String: Any], environment: [String: String],
        stateDirectory: URL = Persistence.stateDirectory, now: TimeInterval
    ) {
        let arguments = ((payload["tool_input"] as? [String: Any])?["args"] as? String ?? payload["prompt"] as? String ?? "")
            .split(whereSeparator: \.isWhitespace).prefix(2)
        let response = payload["tool_response"] as? [String: Any]
        let ranOtherwise = response?["status"] != nil && !(response?["status"] as? String == "forked" && response?["background"] as? Bool == true)
        guard event.passes.contains(.codeReview), !arguments.contains(where: { $0.lowercased() == "ultra" }), !ranOtherwise,
              let session = event.sessionID, !session.isEmpty,
              let space = Persistence.spaceID(environment: environment, stateDirectory: stateDirectory),
              due(spaceID: space, stateDirectory: stateDirectory, now: now) != nil
        else { return }
        reaches.append(Reach(time: now, session: session, kind: .started), spaceID: space, stateDirectory: stateDirectory, trims: false)
    }

    // MARK: - Reach

    struct Reach: Codable, Equatable, Sendable {
        enum Kind: String, Codable, Sendable { case started, given }

        let time: TimeInterval
        let session: String
        let kind: Kind

        enum CodingKeys: String, CodingKey { case time = "t", session = "s", kind = "k" }
    }

    /// Written by hook receivers, which never trim it (another may append
    /// meanwhile), trimmed by the app at launch, read by the daily pass.
    static let reaches = SpaceLog<Reach>(fileName: "review-checklist.jsonl", keptDays: 8, maxFileBytes: 500_000) { $0.time }

    /// The review starts in `window` a list reached, of those noted: in
    /// each session, one list per start at most, in either order (a fork
    /// may start before its Skill call's PostToolUse).
    static func reached(_ reaches: [Reach], in window: DailyPass.Window) -> (reached: Int, started: Int) {
        let sessions = Dictionary(grouping: reaches.filter { window.contains($0.time) }, by: \.session).values
        return sessions.reduce((0, 0)) { total, events in
            let started = events.filter { $0.kind == .started }.count
            return (total.0 + min(started, events.count - started), total.1 + started)
        }
    }
}
