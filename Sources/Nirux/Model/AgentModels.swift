import Foundation

struct TaskAgentSelection: Codable, Equatable, Sendable {
    let agent: CodingAgent
    var model: String?

    var label: String { agent.productName + (model.map { " (\($0))" } ?? "") }
}

enum AgentModels {
    struct Choice: Equatable, Sendable {
        let slug: String
        let label: String
        var listed = true
    }

    struct Refusal: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }

    static let claudeAliases = ["fable", "opus", "sonnet", "haiku", "best", "opusplan", "fable[1m]", "opus[1m]", "sonnet[1m]"]

    static func validate(
        _ selection: TaskAgentSelection, environment: [String: String], installed: AgentCLIAvailability = AgentCLILocator.locate(),
        catalog: (CodingAgent, String, [String: String]) throws -> [Choice] = choices
    ) throws -> TaskAgentSelection {
        let executable = try executable(for: selection.agent, installed: installed)
        guard let model = selection.model else { return selection }
        if selection.agent == .claude {
            let name = model.lowercased()
            guard claudeAliases.contains(name) || name.wholeMatch(of: /claude-[a-z0-9][a-z0-9.-]*(\[1m\])?/) != nil else {
                throw Refusal("Unknown Claude model “\(model)”. Use \(claudeAliases.joined(separator: ", ")), or a full claude- model ID.")
            }
            return TaskAgentSelection(agent: .claude, model: name)
        }
        let choices = try catalog(selection.agent, executable, environment)
        guard let match = choices.first(where: { $0.slug.caseInsensitiveCompare(model) == .orderedSame }) else {
            throw Refusal("Unknown \(selection.agent.rawValue) model “\(model)”. Choices: "
                + choices.filter(\.listed).map(\.label).joined(separator: ", ") + ".")
        }
        return TaskAgentSelection(agent: selection.agent, model: match.slug)
    }

    private static func executable(for agent: CodingAgent, installed: AgentCLIAvailability) throws -> String {
        let executable = switch agent {
        case .claude: installed.claudePath
        case .codex: installed.codexPath
        case .agy: installed.agyPath
        default: nil as String?
        }
        guard let executable else { throw Refusal("\(agent.rawValue) isn't installed on this Mac.") }
        return executable
    }

    static func listedChoices(for agent: CodingAgent, environment: [String: String]) throws -> [Choice] {
        if agent == .claude { return claudeAliases.map { Choice(slug: $0, label: $0) } }
        let path = try executable(for: agent, installed: AgentCLILocator.locate())
        return try choices(for: agent, executable: path, environment: environment).filter(\.listed)
    }

    static func choices(for agent: CodingAgent, executable: String, environment: [String: String]) throws -> [Choice] {
        let agy = agent == .agy
        let result = BoundedProcess.run(
            executableURL: URL(fileURLWithPath: executable), arguments: agy ? ["models"] : ["debug", "models"],
            currentDirectoryURL: URL(fileURLWithPath: NSHomeDirectory()),
            environment: environment.merging(agy ? ["AGY_CLI_DISABLE_AUTO_UPDATE": "1"] : [:]) { _, flag in flag }, timeout: 20,
            captureStandardError: true, maxStandardOutputBytes: 4 << 20
        )
        let output = result.map { String(decoding: $0.standardOutput, as: UTF8.self) } ?? ""
        let choices = agy ? agyChoices(output) : codexChoices(output)
        guard result?.terminationStatus == 0, !choices.isEmpty else {
            let stderr = result.map { String(decoding: $0.standardError, as: UTF8.self) } ?? ""
            let detail = (stderr.isEmpty ? output : stderr).split(whereSeparator: \.isNewline).last?.prefix(300)
            throw Refusal("Couldn't list \(agent.rawValue) models. \(detail ?? "") Leave model out to use its default.")
        }
        return choices
    }

    static func agyChoices(_ text: String) -> [Choice] {
        text.split(whereSeparator: \.isNewline).compactMap { line in
            let parts = line.split(separator: "\t", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else { return nil }
            return Choice(slug: parts[0], label: "\(parts[0]) (\(parts[1]))")
        }
    }

    static func codexChoices(_ text: String) -> [Choice] {
        struct Catalog: Decodable {
            struct Model: Decodable {
                let slug: String
                let visibility: String?
            }
            let models: [Model]
        }
        guard let catalog = try? JSONDecoder().decode(Catalog.self, from: Data(text.utf8)) else { return [] }
        return catalog.models.map { Choice(slug: $0.slug, label: $0.slug, listed: $0.visibility == "list") }
    }

    static func launchModel(arguments: [String]) -> String? {
        for (index, argument) in arguments.enumerated() {
            if argument == "--" { break }
            let value: String?
            if argument == "--model" || argument == "-m" {
                value = arguments[safe: index + 1]
            } else if argument.hasPrefix("--model=") {
                value = String(argument.dropFirst("--model=".count))
            } else {
                continue
            }
            guard let value, !value.isEmpty, !value.hasPrefix("-"),
                  value.rangeOfCharacter(from: .controlCharacters) == nil else { return nil }
            return value
        }
        return nil
    }
}
