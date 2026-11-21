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

}
