import Foundation

/// The Claude Code settings a space hands its sessions (Space Settings ›
/// Safety), each part on its own switch. Claude Code merges a `--settings`
/// file over the user's own settings, which Nirux never writes; Nirux
/// rewrites `<state dir>/projects/<space id>/claude-settings.json` before
/// each launch in the space.
enum ClaudeSpaceSettings {
    static let fileName = "claude-settings.json"

    enum Part: CaseIterable, Sendable {
        /// `autoMode.environment`: the space's repositories are the user's.
        case trustRepositories
        /// `permissions.deny`: `denyRules`.
        case denyIrreversible
        /// `sandbox.enabled`.
        case sandbox

        var isOnByDefault: Bool { self != .sandbox }

        /// Its switch in defaults.json; nil holds the default.
        var key: WritableKeyPath<SpaceDefaults, Bool?> {
            switch self {
            case .trustRepositories: return \.claudeTrustsRepositories
            case .denyIrreversible: return \.claudeDeniesIrreversible
            case .sandbox: return \.claudeSandbox
            }
        }
    }

    /// Refused in every permission mode, bypass included, as Space Settings
    /// lists them: secrets, then git commands that can't be undone. Claude Code
    /// checks each command of a compound line (`cd x && git reset --hard`).
    static let denyRuleGroups: [[String]] = [
        ["Read(**/.env)", "Read(**/.env.*)", "Edit(**/.env)", "Edit(**/.env.*)"],
        ["Read(~/.ssh/**)", "Edit(~/.ssh/**)"],
        ["Bash(git push --force*)", "Bash(git push -f*)"],
        ["Bash(git push * --force*)", "Bash(git push * -f*)"],
        ["Bash(git reset --hard*)", "Bash(git reset * --hard*)"],
        ["Bash(git checkout -- .*)", "Bash(git restore .*)"],
        ["Bash(git clean -f*)", "Bash(git clean -d*)"],
        ["Bash(git clean -x*)", "Bash(git clean --force*)"],
        ["Bash(git worktree remove*)"]
    ]

    static var denyRules: [String] { denyRuleGroups.flatMap { $0 } }

    /// A repository of the space, as auto mode hears of it.
    struct Repository: Equatable, Sendable {
        /// The main checkout, else the git dir.
        var path: String
        /// As `host/owner/name`.
        var remotes: [String]
    }

    struct File: Encodable, Equatable {
        struct AutoMode: Encodable, Equatable { var environment: [String] }
        struct Permissions: Encodable, Equatable { var deny: [String] }
        struct Sandbox: Encodable, Equatable { var enabled: Bool }

        var autoMode: AutoMode?
        var permissions: Permissions?
        var sandbox: Sandbox?
    }

    /// What `defaults` turns on, or nil for nothing. The sandbox switched
    /// off writes nothing, so the user's own setting holds.
    static func file(_ defaults: SpaceDefaults, repositories: [Repository]) -> File? {
        let file = File(
            autoMode: defaults.isOn(.trustRepositories) && !repositories.isEmpty
                ? File.AutoMode(environment: ["$defaults"] + repositories.map(environmentEntry)) : nil,
            permissions: defaults.isOn(.denyIrreversible) ? File.Permissions(deny: denyRules) : nil,
            sandbox: defaults.isOn(.sandbox) ? File.Sandbox(enabled: true) : nil
        )
        return file == File() ? nil : file
    }

    /// A bullet in the words of Claude Code's `/auto-mode-setup`. The
    /// "$defaults" before them keeps Claude Code's own entries.
    static func environmentEntry(_ repository: Repository) -> String {
        let place = repository.remotes.isEmpty
            ? "the local repository at \(repository.path)"
            : "\(repository.remotes.joined(separator: ", ")), checked out at \(repository.path)"
        return "**Trusted repo**: \(place), and its worktrees"
    }

    /// The space's repositories, with the remotes their git config names.
    static func repositories(_ anchors: [SpaceAnchor]) -> [Repository] {
        anchors.compactMap { anchor in
            guard case .gitRepository(let commonDir) = anchor.kind else { return nil }
            let config = try? String(contentsOfFile: commonDir + "/config", encoding: .utf8)
            return Repository(path: anchor.folder ?? commonDir, remotes: config.map(remotes(gitConfig:)) ?? [])
        }
    }

    /// Each remote's `host/owner/name`, never its URL, which may hold a
    /// token.
    static func remotes(gitConfig: String) -> [String] {
        var inRemote = false
        var found: [String] = []
        for line in gitConfig.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("[") {
                inRemote = trimmed.hasPrefix("[remote ")
                continue
            }
            let pair = trimmed.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard inRemote, pair.count == 2, pair[0].lowercased() == "url",
                  let repository = GitHubRepository(remoteURL: pair[1].trimmingCharacters(in: CharacterSet(charactersIn: "\"")))
            else { continue }
            let name = "\(repository.host)/\(repository.owner)/\(repository.name)"
            if !found.contains(name) { found.append(name) }
        }
        return found
    }

    /// Writes the file a launch in the space passes and returns its path;
    /// nil when the space hands nothing. A file left by an earlier launch
    /// then holds `{}` rather than going: restarting a column replays its
    /// command, which still names it.
    static func prepare(
        spaceID: String, defaults: SpaceDefaults, anchors: [SpaceAnchor], stateDirectory: URL = Persistence.stateDirectory
    ) -> String? {
        guard let url = SpaceBrief.directory(spaceID: spaceID, stateDirectory: stateDirectory)?
            .appendingPathComponent(fileName) else { return nil }
        let content = file(defaults, repositories: repositories(anchors))
        guard content != nil || FileManager.default.fileExists(atPath: url.path) else { return nil }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try encoder.encode(content ?? File()).write(to: url, options: .atomic)
        } catch {
            NiruxDebugLog.log("ClaudeSpaceSettings: could not write \(url.path): \(error)")
            return nil
        }
        return content == nil ? nil : url.path
    }
}
