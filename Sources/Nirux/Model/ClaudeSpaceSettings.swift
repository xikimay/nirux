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

    /// The common forms of what can't be undone, refused in every
    /// permission mode, bypass included, as Space Settings lists them:
    /// secrets, then git commands that lose work. `//` starts at the
    /// filesystem's root: a path without it is the session folder's.
    /// Claude Code checks each command of a compound line (`cd x && git
    /// reset --hard`); `git *` also takes options before the subcommand
    /// (`git -C x`), and a rule without a final `*` matches the end of the
    /// command: `*.` discards every change, not `.gitignore`'s. git's
    /// shortened options (`--forc`) and grouped flags (`-uf`) get past;
    /// auto mode's own check stays behind them.
    static let denyRuleGroups: [[String]] = [
        ["Read(//**/.env)", "Read(//**/.env.*)", "Edit(//**/.env)", "Edit(//**/.env.*)"],
        ["Read(~/.ssh/**)", "Edit(~/.ssh/**)"],
        ["Bash(git *push --force*)", "Bash(git *push -f*)"],
        ["Bash(git *push * --force*)", "Bash(git *push * -f*)", "Bash(git *push * +*)"],
        ["Bash(git *push --delete*)", "Bash(git *push * --delete*)"],
        ["Bash(git *push -d *)", "Bash(git *push * -d *)"],
        ["Bash(git *push --mirror*)", "Bash(git *push * --mirror*)"],
        ["Bash(git *reset *--hard*)", "Bash(git *clean -*)", "Bash(git *worktree remove*)"],
        ["Bash(git *checkout *.)", "Bash(git *checkout *./)"],
        ["Bash(git *checkout -f*)", "Bash(git *checkout --force*)"],
        ["Bash(git *switch -f*)", "Bash(git *switch --force*)"],
        ["Bash(git *switch --discard-changes*)"],
        ["Bash(git *restore *.)", "Bash(git *restore *./)"],
        ["Bash(git *stash drop*)", "Bash(git *stash clear*)"]
    ]

    static var denyRules: [String] { denyRuleGroups.flatMap { $0 } }

    /// A line the user added from the recap (LoopRecap).
    enum Line: Hashable, Sendable {
        /// `permissions.allow`.
        case allow(String)
        /// `autoMode.environment`.
        case environment(String)

        var text: String {
            switch self {
            case .allow(let rule): return rule
            case .environment(let entry): return entry
            }
        }
    }

    /// A repository of the space, as auto mode hears of it.
    struct Repository: Equatable, Sendable {
        /// The main checkout, else the git dir.
        var path: String
        /// As `host/owner/name`.
        var remotes: [String]
    }

    struct File: Encodable, Equatable {
        struct AutoMode: Encodable, Equatable { var environment: [String] }
        struct Permissions: Encodable, Equatable {
            var allow: [String]?
            var deny: [String]?
        }
        struct Sandbox: Encodable, Equatable { var enabled: Bool }

        var autoMode: AutoMode?
        var permissions: Permissions?
        var sandbox: Sandbox?
    }

    /// What `defaults` turns on, and the lines the user added, or nil for
    /// nothing. The sandbox switched off writes nothing, so the user's own
    /// setting holds. `userEnvironment` is the user's `autoMode.environment`:
    /// Claude Code joins it with ours, then puts its own entries at the
    /// first "$defaults", and a list without one replaces them. Ours brings
    /// one only when the user's has no list of its own.
    static func file(_ defaults: SpaceDefaults, repositories: [Repository], userEnvironment: [String]? = nil) -> File? {
        let keepsBuiltIn = userEnvironment?.isEmpty ?? true ? ["$defaults"] : []
        let trusted = defaults.isOn(.trustRepositories) ? repositories.map(environmentEntry) : []
        let environment = trusted + defaults.claudeEnvironment
        let deny = defaults.isOn(.denyIrreversible) ? denyRules : []
        let file = File(
            autoMode: environment.isEmpty ? nil : File.AutoMode(environment: keepsBuiltIn + environment),
            permissions: deny.isEmpty && defaults.claudeAllow.isEmpty ? nil : File.Permissions(
                allow: defaults.claudeAllow.isEmpty ? nil : defaults.claudeAllow, deny: deny.isEmpty ? nil : deny
            ),
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

    /// The space's repositories, each with where `origin` pushes: another
    /// remote (a fork's upstream) isn't the user's.
    static func repositories(_ anchors: [SpaceAnchor]) -> [Repository] {
        anchors.compactMap { anchor in
            guard case .gitRepository(let commonDir) = anchor.kind else { return nil }
            let config = try? String(contentsOfFile: commonDir + "/config", encoding: .utf8)
            return Repository(path: anchor.folder ?? commonDir, remotes: config.map(originPushTargets(gitConfig:)) ?? [])
        }
    }

    /// Where `origin` pushes, as `host/path`: its `pushurl`s when it has
    /// any, else its `url`s, as git does. Never a URL, which may hold a
    /// token, nor a local path.
    static func originPushTargets(gitConfig: String) -> [String] {
        var inOrigin = false
        var values: [(key: String, value: String)] = []
        for line in gitConfig.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("[") {
                inOrigin = isOriginSection(trimmed)
                continue
            }
            let pair = trimmed.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard inOrigin, pair.count == 2 else { continue }
            // A comment ends the value; quotes hold it.
            let value = pair[1].split(whereSeparator: { $0 == "#" || $0 == ";" }).first.map(String.init) ?? ""
            values.append((pair[0].lowercased(), value.trimmingCharacters(in: CharacterSet(charactersIn: "\" \t"))))
        }
        let pushURLs = values.filter { $0.key == "pushurl" }.map(\.value)
        let urls = pushURLs.isEmpty ? values.filter { $0.key == "url" }.map(\.value) : pushURLs
        var targets: [String] = []
        for target in urls.compactMap(pushTarget(remoteURL:)) where !targets.contains(target) { targets.append(target) }
        return targets
    }

    /// `[remote "origin"]`: git reads the section's name in any case, the
    /// remote's exactly.
    static func isOriginSection(_ line: String) -> Bool {
        guard let close = line.firstIndex(of: "]") else { return false }
        let parts = line[line.index(after: line.startIndex)..<close].split(separator: " ", maxSplits: 1)
        return parts.count == 2 && parts[0].lowercased() == "remote" && parts[1].trimmingCharacters(in: .whitespaces) == "\"origin\""
    }

    /// `https://x:token@gitlab.com/group/sub/app.git` → `gitlab.com/group/sub/app`:
    /// the host (and port), the whole path, no credentials; nil for a local
    /// path.
    static func pushTarget(remoteURL: String) -> String? {
        let host: String
        let path: String
        if let url = URL(string: remoteURL), let scheme = url.scheme?.lowercased(),
           ["https", "http", "ssh", "git", "git+ssh", "ssh+git"].contains(scheme), let name = url.host, !name.isEmpty {
            host = name.lowercased() + (url.port.map { ":\($0)" } ?? "")
            path = url.path
        } else if let colon = remoteURL.firstIndex(of: ":"), !remoteURL[..<colon].contains("/"), !remoteURL.contains("://") {
            // scp-like: `[user@]host:path`.
            host = remoteURL[..<colon].split(separator: "@").last.map { $0.lowercased() } ?? ""
            path = String(remoteURL[remoteURL.index(after: colon)...])
        } else {
            return nil
        }
        var trimmed = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if trimmed.lowercased().hasSuffix(".git") { trimmed.removeLast(4) }
        return host.isEmpty || trimmed.isEmpty ? nil : host + "/" + trimmed
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
    /// earlier launch then holds `{}` rather than going (`empty`). Claude
    /// Code reads it as a session starts: a running session keeps what it
    /// read. Throws when it can't be written.
    static func prepare(
        spaceID: String, defaults: SpaceDefaults, anchors: [SpaceAnchor], userEnvironment: [String]?,
        stateDirectory: URL = Persistence.stateDirectory
    ) throws -> String? {
        guard let url = fileURL(spaceID: spaceID, stateDirectory: stateDirectory) else { return nil }
        guard let content = file(defaults, repositories: repositories(anchors), userEnvironment: userEnvironment) else {
            try empty(spaceID: spaceID, stateDirectory: stateDirectory)
            return nil
        }
        try write(content, to: url)
        return url.path
    }

    /// The space's file, if any, holds `{}`: restarting a column replays its
    /// launch line, which still names it, and Claude refuses to start when
    /// a file it names is missing.
    static func empty(spaceID: String, stateDirectory: URL = Persistence.stateDirectory) throws {
        guard let url = fileURL(spaceID: spaceID, stateDirectory: stateDirectory),
              FileManager.default.fileExists(atPath: url.path) else { return }
        try write(File(), to: url)
    }

    private static func write(_ content: File, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(content)
        guard data != (try? Data(contentsOf: url)) else { return }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }
}
