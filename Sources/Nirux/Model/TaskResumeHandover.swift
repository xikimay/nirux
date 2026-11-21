import Foundation

enum TaskResumeHandover {
    static func localContext(workspaceID: String, spaceID: String, previous: AgentSessionRecord?) -> [String] {
        var lines = threadContext(workspaceID: workspaceID, spaceID: spaceID)
        if previous?.agent == .claude, let path = previous?.transcriptPath,
           (try? FileManager.default.attributesOfItem(atPath: path)[.type]) as? FileAttributeType == .typeRegular,
           let reading = TranscriptLastMessage.read(path: path) {
            switch reading {
            case .message(let message), .unanswered(let message):
                let text = TranscriptLastMessage.withholdingSecrets(message.text).text
                if let excerpt = AgentText.clean(text, maxLength: 900) { lines.append("Last conversation entry: " + excerpt) }
            case .noText: break
            }
        }
        return lines
    }

    /// Task thread's append-only request and status records. Older tasks have only the card and Mission.
    private static func threadContext(workspaceID: String, spaceID: String) -> [String] {
        guard UUID(uuidString: workspaceID) != nil,
              let space = SpaceBrief.directory(spaceID: spaceID, stateDirectory: Persistence.stateDirectory) else { return [] }
        let file = space.appendingPathComponent("threads/\(workspaceID).jsonl")
        guard let data = BoardConfigStore.read(file, maxBytes: 2_065_536).contents else { return [] }
        struct Entry: Decodable {
            let kind: String
            let text: String?
        }
        var request: String?
        var statuses: [String] = []
        let decoder = JSONDecoder()
        for line in data.split(separator: 10) {
            guard let entry = try? decoder.decode(Entry.self, from: line), let text = entry.text else { continue }
            switch entry.kind {
            case "request": request = AgentText.clean(text, maxLength: 1_500)
            case "status":
                if let line = AgentText.clean(text, maxLength: 240), statuses.last != line { statuses.append(line) }
            default: break
            }
        }
        return [request.map { "Original request: \($0)" }].compactMap { $0 } + statuses.suffix(3).map { "Progress: \($0)" }
    }

    @MainActor static func prompt(
        task: WorkspaceState, previous: AgentSessionRecord?, agent: CodingAgent, missions: [Mission], thread: [String]
    ) -> String {
        var lines = ["Continue the existing Nirux task “\(MissionAnswerContext.clipped(task.title, 160))” in this checkout. Preserve work in progress."]
        lines += thread
        for (label, value) in [("Goal", task.purpose), ("Last update", task.lastSummary), ("Next step", task.nextStep), ("Blocker", task.blocker)] {
            if let value, let text = AgentText.clean(value, maxLength: 600) { lines.append("\(label): \(text)") }
        }
        if let pr = task.prInfo { lines.append("Pull request #\(pr.number)") }
        if let previous { lines.append("Previous conversation in Session History: \(previous.agent.rawValue) \(previous.sessionID).") }
        if let mission = missions.first(where: { $0.id == task.missionID }) {
            if let answers = MissionAnswerContext.text(for: mission, among: missions) { lines.append(answers) }
            for event in mission.events.filter({ ($0.kind == .instruction && $0.childConsumedAt != nil) || $0.kind == .completed }).suffix(3) {
                lines.append("\(event.kind == .completed ? "Last result" : "Parent instruction"): \(MissionAnswerContext.clipped(event.message, 400))")
            }
            lines.append(agent == .claude ? NiruxShellView.typedAnswerMission : NiruxShellView.waitingMission)
        }
        if task.nextStep == nil {
            lines.append("Check the current changes and the latest instructions before continuing. Ask about any missing decision.")
        }
        return lines.joined(separator: "\n")
    }
}
