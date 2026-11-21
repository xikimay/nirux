import Foundation

struct TaskAgentChoice: Equatable {
    let agent: CodingAgent
    let model: String?

    enum Problem: LocalizedError {
        case agent, model

        var errorDescription: String? {
            switch self {
            case .agent: "Choose claude, codex or agy."
            case .model: "Enter a provider model ID of at most 128 characters on one line, or leave it blank for the CLI default."
            }
        }
    }

    static func parse(_ arguments: [String: Any]) -> Result<Self, Problem> {
        guard let name = arguments["agent"] as? String, let agent = CodingAgent(launchable: name)
        else { return .failure(.agent) }
        guard let raw = arguments["model"] else { return .success(Self(agent: agent, model: nil)) }
        guard let text = raw as? String, text.rangeOfCharacter(from: .controlCharacters) == nil else { return .failure(.model) }
        let model = text.trimmingCharacters(in: .whitespaces)
        guard model.count <= 128, !model.hasPrefix("-"), model.rangeOfCharacter(from: .newlines) == nil else { return .failure(.model) }
        return .success(Self(agent: agent, model: model.isEmpty ? nil : model))
    }
}
