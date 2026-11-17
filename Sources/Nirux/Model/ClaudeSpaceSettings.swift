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
    /// lists them: secrets, then git commands that lose work. Claude Code
    /// checks each command of a compound line (`cd x && git reset --hard`);
    /// `git *` also takes options before the subcommand (`git -C x`).
    static let denyRuleGroups: [[String]] = [
        ["Read(**/.env)", "Read(**/.env.*)", "Edit(**/.env)", "Edit(**/.env.*)"],
        ["Read(~/.ssh/**)", "Edit(~/.ssh/**)"],
        ["Bash(git *push --force*)", "Bash(git *push -f*)"],
        ["Bash(git *push * --force*)", "Bash(git *push * -f*)", "Bash(git *push * +*)"],
        ["Bash(git *reset *--hard*)", "Bash(git *clean -*)", "Bash(git *worktree remove*)"],
        ["Bash(git *checkout -- .)", "Bash(git *checkout .)", "Bash(git *restore .)"]
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
    /// off writes nothing, so the user's own setting holds. `userEnvironment`
    /// is the user's `autoMode.environment`: Claude Code joins it with ours,
    /// then puts its own entries at the first "$defaults", and a list
    /// without one replaces them. Ours brings one only when the user's has
    /// no list of its own.
    static func file(_ defaults: SpaceDefaults, repositories: [Repository], userEnvironment: [String]? = nil) -> File? {
        let keepsBuiltIn = userEnvironment?.isEmpty ?? true ? ["$defaults"] : []
        let file = File(
            autoMode: defaults.isOn(.trustRepositories) && !repositories.isEmpty
                ? File.AutoMode(environment: keepsBuiltIn + repositories.map(environmentEntry)) : nil,
            permissions: defaults.isOn(.denyIrreversible) ? File.Permissions(deny: denyRules) : nil,
            sandbox: defaults.isOn(.sandbox) ? File.Sandbox(enabled: true) : nil
        )
        return file == File() ? nil : file
    }

    /// A bullet in the words of Claude Code's `/auto-mode-setup`.
    static func environmentEntry(_ repository: Repository) -> String {
        let place = repository.remotes.isEmpty
            ? "the local repository at \(repository.path)"
            : "\(repository.remotes.joined(separator: ", ")), checked out at \(repository.path)"
        return "**Trusted repo**: \(place), and its worktrees"
    }

    /// The space's repositories, each with its `origin`: another remote
    /// (a fork's upstream) isn't the user's.
    static func repositories(_ anchors: [SpaceAnchor]) -> [Repository] {
        anchors.compactMap { anchor in
            guard case .gitRepository(let commonDir) = anchor.kind else { return nil }
            let config = try? String(contentsOfFile: commonDir + "/config", encoding: .utf8)
            return Repository(path: anchor.folder ?? commonDir, remotes: config.flatMap(origin(gitConfig:)).map { [$0] } ?? [])
        }
    }

    /// `origin`'s `host/owner/name`, never its URL, which may hold a token.
    static func origin(gitConfig: String) -> String? {
        var inOrigin = false
        for line in gitConfig.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("[") {
                inOrigin = trimmed.replacingOccurrences(of: " ", with: "").lowercased() == "[remote\"origin\"]"
                continue
            }
            let pair = trimmed.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard inOrigin, pair.count == 2, pair[0].lowercased() == "url" else { continue }
            // A comment ends the value; quotes hold it.
            let url = pair[1].split(whereSeparator: { $0 == "#" || $0 == ";" }).first.map(String.init) ?? ""
            let unquoted = url.trimmingCharacters(in: CharacterSet(charactersIn: "\" \t"))
            guard !unquoted.lowercased().hasPrefix("file:"), let repository = GitHubRepository(remoteURL: unquoted) else { return nil }
            return "\(repository.host)/\(repository.owner)/\(repository.name)"
        }
        return nil
    }

    /// The space's switches as a launch reads them: a defaults.json Nirux
    /// can't read trusts nothing.
    static func switches(_ loaded: SpaceDefaultsStore.Loaded?) -> SpaceDefaults {
        var defaults = loaded?.defaults ?? SpaceDefaults()
        if loaded?.isUnread == true { defaults.set(.trustRepositories, on: false) }
        return defaults
    }

    /// `autoMode.environment` of the user's Claude Code settings.
    static func userEnvironment(_ settings: [String: Any]) -> [String]? {
        (settings["autoMode"] as? [String: Any])?["environment"] as? [String]
    }

    static func fileURL(spaceID: String, stateDirectory: URL = Persistence.stateDirectory) -> URL? {
        SpaceBrief.directory(spaceID: spaceID, stateDirectory: stateDirectory)?.appendingPathComponent(fileName)
    }

    /// Writes the file a launch in the space passes, when it changed, and
    /// returns its path; nil when the space hands nothing. A file left by an
    /// earlier launch then holds `{}` rather than going: restarting a column
    /// replays its command, which still names it.
    static func prepare(
        spaceID: String, defaults: SpaceDefaults, anchors: [SpaceAnchor], userEnvironment: [String]?,
        stateDirectory: URL = Persistence.stateDirectory
    ) -> String? {
        guard let url = fileURL(spaceID: spaceID, stateDirectory: stateDirectory) else { return nil }
        let content = file(defaults, repositories: repositories(anchors), userEnvironment: userEnvironment)
        let existing = try? Data(contentsOf: url)
        guard content != nil || existing != nil else { return nil }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        do {
            let data = try encoder.encode(content ?? File())
            if data != existing {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: url, options: .atomic)
            }
        } catch {
            NiruxDebugLog.log("ClaudeSpaceSettings: could not write \(url.path): \(error)")
            return nil
        }
        return content == nil ? nil : url.path
    }
}
