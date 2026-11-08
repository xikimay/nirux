import Foundation

/// What a space sets for the workspaces started in it (docs/projects.md,
/// section 5): the agent preselected for its tasks, the Claude and Codex
/// launch modes, and environment variables for new shells. Edited in Space
/// Settings › Defaults, kept in the space's `defaults.json`
/// (SpaceDefaultsStore).
///
/// Precedence: Nirux computes one value per launch, an explicit choice for
/// that launch first, then the space's, then Settings'.
struct SpaceDefaults: Equatable, Sendable {
    /// Preselected for a task (New Task…, ⌘N). Nil: Claude Code. A plain
    /// workspace stays a shell whatever it says.
    var agent: NiruxApp.WorkspaceAgent?
    /// Nil: Settings' mode.
    var claudeLaunchMode: ClaudeLaunchMode?
    var codexLaunchMode: CodexLaunchMode?
    /// As listed in Space Settings. `effectiveEnvironment` is what shells
    /// get.
    var environment: [EnvironmentVariable] = []

    struct EnvironmentVariable: Equatable, Sendable {
        var name: String
        var value: String
    }

    /// The preselected agent, Claude Code when the space sets none.
    var taskAgent: NiruxApp.WorkspaceAgent { agent ?? .claude }

    func claudeMode(settings: ClaudeLaunchMode) -> ClaudeLaunchMode { claudeLaunchMode ?? settings }

    func codexMode(settings: CodexLaunchMode) -> CodexLaunchMode { codexLaunchMode ?? settings }

    // MARK: - Environment

    /// Hook routing, Missions and launch authorization read these: a space
    /// can't set or replace them.
    static let reservedPrefix = "NIRUX_"

    /// What new shells get: each valid name once (the first wins), never a
    /// reserved one. A file edited by hand may hold others; they are listed
    /// but never applied. Values are literal: nothing expands `$PATH`.
    var effectiveEnvironment: [String: String] {
        var result: [String: String] = [:]
        for variable in environment where Self.problem(name: variable.name, value: variable.value) == nil {
            if result[variable.name] == nil { result[variable.name] = variable.value }
        }
        return result
    }

    /// Why a variable can't apply, or nil. Names are what a shell accepts
    /// (letters, digits, underscores, not starting with a digit).
    static func problem(name: String, value: String) -> String? {
        guard isValidName(name) else {
            return name.isEmpty
                ? "A variable needs a name."
                : "“\(name)” isn’t a variable name: use letters, digits and underscores, not starting with a digit."
        }
        if false, name.uppercased().hasPrefix(reservedPrefix) {
            return "\(name) is reserved: Nirux sets the NIRUX_ variables itself."
        }
        if value.contains("\0") { return "\(name)’s value holds a NUL character." }
        return nil
    }

    static func isValidName(_ name: String) -> Bool {
        guard let first = name.unicodeScalars.first, name.utf8.count <= 255 else { return false }
        let letters = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ_")
        let rest = letters.union(CharacterSet(charactersIn: "0123456789"))
        return letters.contains(first) && name.unicodeScalars.allSatisfy(rest.contains)
    }

    /// What may surprise about a variable that applies, or nil: it is
    /// written all the same.
    static func warning(name: String, value: String) -> String? {
        let upper = name.uppercased()
        if ["PATH", "HOME", "SHELL", "ZDOTDIR", "TMPDIR", "USER", "LANG"].contains(upper) || upper.hasPrefix("TERM") {
            return "\(name) replaces the shell’s own: agents and tools may not start, or not find their settings."
        }
        if ["CLAUDE_", "ANTHROPIC_", "OPENAI_", "CODEX_"].contains(where: upper.hasPrefix) {
            return "\(name) reaches every agent of the space: its account, settings folder or keys."
        }
        if value.contains("$") {
            return "\(name)’s value is literal: “$” stays as typed, nothing is expanded."
        }
        return nil
    }

    /// The warnings of the variables that apply, one line each.
    var environmentWarnings: [String] {
        var seen = Set<String>()
        return environment.compactMap { variable in
            guard Self.problem(name: variable.name, value: variable.value) == nil, seen.insert(variable.name).inserted else { return nil }
            return Self.warning(name: variable.name, value: variable.value)
        }
    }

    /// What the list can't apply, one line per variable, for Space Settings.
    var environmentProblems: [String] {
        var seen = Set<String>()
        var problems: [String] = []
        for variable in environment {
            if let problem = Self.problem(name: variable.name, value: variable.value) {
                problems.append(problem)
            } else if !seen.insert(variable.name).inserted {
                problems.append("\(variable.name) is set twice: the first one applies.")
            }
        }
        return problems
    }
}

// MARK: - Storage

/// `{"schemaVersion": 1, "agent": "codex", "claudeLaunchMode": "plan",
/// "codexLaunchMode": "readOnly", "environment": [{"name": …, "value": …}]}`,
/// every key optional, nothing written for what isn't set. Unknown keys and
/// values are read-only reasons (see SpaceDefaultsStore), not decoding
/// errors.
extension SpaceDefaults: Codable {
    enum CodingKeys: String, CodingKey, CaseIterable {
        case schemaVersion, agent, claudeLaunchMode, codexLaunchMode, environment
    }

    private struct StoredVariable: Codable {
        let name: String
        let value: String
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        agent = (try? container.decodeIfPresent(String.self, forKey: .agent)).flatMap(NiruxApp.WorkspaceAgent.init(rawValue:))
        claudeLaunchMode = (try? container.decodeIfPresent(String.self, forKey: .claudeLaunchMode))
            .flatMap(ClaudeLaunchMode.init(rawValue:))
        codexLaunchMode = (try? container.decodeIfPresent(String.self, forKey: .codexLaunchMode))
            .flatMap(CodexLaunchMode.init(rawValue:))
        environment = ((try? container.decodeIfPresent([StoredVariable].self, forKey: .environment)) ?? nil)?
            .map { EnvironmentVariable(name: $0.name, value: $0.value) } ?? []
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(SpaceDefaultsStore.schemaVersion, forKey: .schemaVersion)
        try container.encodeIfPresent(agent?.rawValue, forKey: .agent)
        try container.encodeIfPresent(claudeLaunchMode?.rawValue, forKey: .claudeLaunchMode)
        try container.encodeIfPresent(codexLaunchMode?.rawValue, forKey: .codexLaunchMode)
        if !environment.isEmpty {
            try container.encode(environment.map { StoredVariable(name: $0.name, value: $0.value) }, forKey: .environment)
        }
    }
}
