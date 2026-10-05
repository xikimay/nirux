import Foundation

// MARK: - Where Claude Code keeps a repository's memory

/// Claude Code's rules (version 2.1.289), read from its code since its
/// documentation doesn't give them:
/// - the folder is `<config>/projects/<encoded root>/memory/`, where
///   `<config>` is `CLAUDE_CONFIG_DIR`, else `~/.claude`, and the root is
///   the repository's main checkout, found from the launch folder's `.git`
///   without running git: every worktree of a repository shares its
///   memory (its transcripts, not);
/// - `autoMemoryDirectory`, in the first settings file that sets it, moves
///   the folder there for every repository;
/// - `CLAUDE_CODE_DISABLE_AUTO_MEMORY` turns it off, or on whatever the
///   settings say; `autoMemoryEnabled: false` turns it off.
///
/// Nirux reads its own environment, not the one a terminal's shell builds
/// from the user's startup files.
extension ProjectMemory {
    /// The memory folder of a repository, and whether Claude Code uses it.
    struct Location: Equatable, Sendable {
        /// The folder Claude Code files the memory under: the repository's
        /// main checkout, or the launch folder outside a repository.
        let projectRoot: String
        let directory: URL
        /// What turns auto-memory off; nil when it is on.
        let disabledBy: String?
        /// The setting that moved the folder, when one did.
        let movedBy: String?

        /// What the panel says above the list, if anything.
        var notice: String? {
            if let disabledBy {
                return "Auto-memory is off (\(disabledBy)): Claude Code neither reads nor notes what is “When relevant”."
            }
            if let movedBy { return "\(movedBy) puts every repository’s Claude Code memory in one folder." }
            return nil
        }
    }

    /// A settings scope Claude Code reads, in the order they win: its files
    /// merged, the later over the earlier. The flag settings (`claude
    /// --settings`) are the launch's own: Nirux doesn't see them.
    struct SettingsSource: Equatable, Sendable {
        /// "managed settings", ".claude/settings.json"…, as the notice
        /// names it.
        let label: String
        let files: [URL]
    }

    /// Where the managed settings live: MDM preferences replace the files.
    struct ManagedFolders: Equatable, Sendable {
        let preferences: URL
        let settings: URL

        static let system = ManagedFolders(
            preferences: URL(fileURLWithPath: "/Library/Managed Preferences", isDirectory: true),
            settings: URL(fileURLWithPath: "/Library/Application Support/ClaudeCode", isDirectory: true)
        )
    }

    static func settingsSources(
        launchFolder: String, projectRoot: String, configDirectory: String, home: String, managed: ManagedFolders
    ) -> [SettingsSource] {
        let manager = FileManager.default
        let plist = "com.anthropic.claudecode.plist"
        let preferences = [
            managed.preferences.appendingPathComponent(NSUserName()).appendingPathComponent(plist),
            managed.preferences.appendingPathComponent(plist)
        ].filter { manager.fileExists(atPath: $0.path) }
        let dropIns = managed.settings.appendingPathComponent("managed-settings.d", isDirectory: true)
        let files = [managed.settings.appendingPathComponent("managed-settings.json")]
            + ((try? manager.contentsOfDirectory(atPath: dropIns.path)) ?? [])
                .filter { $0.hasSuffix(".json") && !$0.hasPrefix(".") }.sorted()
                .map { dropIns.appendingPathComponent($0) }
        let policy = preferences.first.map { [$0] } ?? files
        let launch = URL(fileURLWithPath: launchFolder)
        // The local file of the main checkout, over the launch folder's;
        // not when that checkout is the home folder or someone else's.
        let mainCheckout = projectRoot == (home.realPath ?? home) || !isOwnedByUser(projectRoot) ? launchFolder : projectRoot
        let local = [launch, URL(fileURLWithPath: mainCheckout)].map { $0.appendingPathComponent(".claude/settings.local.json") }
        let user = (configDirectory as NSString).appendingPathComponent("settings.json")
        return [
            SettingsSource(label: "managed settings", files: policy),
            SettingsSource(label: ".claude/settings.local.json", files: local[0] == local[1] ? [local[0]] : local),
            SettingsSource(label: ".claude/settings.json", files: [launch.appendingPathComponent(".claude/settings.json")]),
            SettingsSource(
                label: user.hasPrefix(home + "/") ? "~" + user.dropFirst(home.count) : user,
                files: [URL(fileURLWithPath: user)]
            )
        ]
    }

    /// The folder, its `.git` and its `.claude` (when there is one) belong
    /// to the user running Nirux.
    private static func isOwnedByUser(_ folder: String) -> Bool {
        [folder, folder + "/.git", folder + "/.claude"].allSatisfy { path in
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: path) else {
                return path.hasSuffix("/.claude")
            }
            return (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == geteuid()
        }
    }

    /// Where Claude Code, launched in `folder`, keeps its memory. Reads a
    /// few small files: call it off the main thread.
    static func locate(
        folder: String, home: String, environment: [String: String], managed: ManagedFolders = .system
    ) -> Location {
        let launchFolder = (folder.realPath ?? normalized(folder)).precomposedStringWithCanonicalMapping
        let projectRoot = canonicalRoot(of: launchFolder) ?? launchFolder
        let configDirectory = configDirectory(home: home, environment: environment)
        let settings = settingsSources(
            launchFolder: launchFolder, projectRoot: projectRoot, configDirectory: configDirectory, home: home, managed: managed
        ).map { source in
            (source, source.files.reduce(into: [String: Any]()) { merged, file in
                merged.merge(readSettings(file)) { $1 }
            })
        }

        var directory = defaultDirectory(projectRoot: projectRoot, configDirectory: configDirectory, environment: environment)
        var movedBy: String?
        // The first scope that sets it; a folder Claude Code refuses there
        // doesn't fall through to the next scope: the default applies.
        let setting = settings.lazy.compactMap { source, values in
            values["autoMemoryDirectory"].flatMap { $0 is NSNull ? nil : (source, $0) }
        }.first
        if let (source, value) = setting, let path = value as? String,
           let moved = memoryDirectory(setting: path, home: home) {
            directory = URL(fileURLWithPath: moved, isDirectory: true)
            movedBy = "autoMemoryDirectory in \(source.label)"
        }
        return Location(
            projectRoot: projectRoot,
            directory: directory,
            disabledBy: disabledBy(environment: environment, settings: settings),
            movedBy: movedBy
        )
    }

    /// `CLAUDE_CONFIG_DIR` as written (no `~`), else `~/.claude`.
    static func configDirectory(home: String, environment: [String: String]) -> String {
        let configured = environment["CLAUDE_CONFIG_DIR"].flatMap { $0.isEmpty ? nil : $0 }
        return (configured ?? (home as NSString).appendingPathComponent(".claude")).precomposedStringWithCanonicalMapping
    }

    static func defaultDirectory(projectRoot: String, configDirectory: String, environment: [String: String]) -> URL {
        // Its own name for the project's folder, only with its own config
        // folder.
        let named = environment["CLAUDE_CONFIG_DIR"].flatMap { $0.isEmpty ? nil : $0 } == nil ? nil
            : environment["CLAUDE_CODE_PROJECT_DIR_NAME"].flatMap { isValidProjectDirectoryName($0) ? $0 : nil }
        return URL(fileURLWithPath: configDirectory)
            .appendingPathComponent("projects", isDirectory: true)
            .appendingPathComponent(named ?? encodedProjectName(projectRoot), isDirectory: true)
            .appendingPathComponent("memory", isDirectory: true)
    }

    /// Every UTF-16 unit but an ASCII letter or digit becomes `-`; past 200
    /// characters, the first 200 and a hash of the whole path.
    static func encodedProjectName(_ path: String) -> String {
        let encoded = String(path.utf16.map { unit -> Character in
            switch unit {
            case 0x30...0x39, 0x41...0x5A, 0x61...0x7A: return Character(Unicode.Scalar(UInt8(unit)))
            default: return "-"
            }
        })
        guard encoded.count > 200 else { return encoded }
        var hash: Int32 = 0
        for unit in path.utf16 { hash = (hash &<< 5) &- hash &+ Int32(unit) }
        return encoded.prefix(200) + "-" + String(abs(Int64(hash)), radix: 36)
    }

    private static func isValidProjectDirectoryName(_ name: String) -> Bool {
        let reserved = Set(["CON", "PRN", "AUX", "NUL"] + (0...9).flatMap { ["COM\($0)", "LPT\($0)"] })
        return (1...64).contains(name.count)
            && name.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") }
            && !reserved.contains(name.uppercased())
    }

    /// `autoMemoryDirectory` as Claude Code takes it: `~/` for the home
    /// folder, then an absolute path; nil for one it refuses.
    static func memoryDirectory(setting: String, home: String) -> String? {
        guard !setting.contains("\0") else { return nil }
        var path = setting
        if path.hasPrefix("~/") {
            // The home folder itself (`~/`, `~/.`, `~/a/..`) or above it
            // (`~/../x`) is refused.
            let rest = normalized("/" + path.dropFirst(2))
            guard rest != "/" else { return nil }
            var depth = 0
            for part in path.dropFirst(2).split(separator: "/") {
                depth += part == ".." ? -1 : (part == "." ? 0 : 1)
                guard depth >= 0 else { return nil }
            }
            path = home + rest
        }
        guard path.hasPrefix("/") else { return nil }
        let result = normalized(path)
        // Network volumes and the system's special folders are refused.
        let special = ["/Network", "/net", "/.vol", "/.file", "/.nofollow", "/.resolve"]
        guard result.count >= 3, !special.contains(where: { result == $0 || result.hasPrefix($0 + "/") }) else { return nil }
        return result
    }

    private static func disabledBy(environment: [String: String], settings: [(SettingsSource, [String: Any])]) -> String? {
        if isTruthy(environment["CLAUDE_CODE_SAFE_MODE"]) { return "CLAUDE_CODE_SAFE_MODE is set" }
        switch environment["CLAUDE_CODE_DISABLE_AUTO_MEMORY"].flatMap(truth) {
        case true?: return "CLAUDE_CODE_DISABLE_AUTO_MEMORY is set"
        // Turned on whatever follows.
        case false?: return nil
        case nil: break
        }
        if isTruthy(environment["CLAUDE_CODE_SIMPLE"]) { return "CLAUDE_CODE_SIMPLE is set" }
        if let (file, enabled) = settings.lazy.compactMap({ file, values in
            (values["autoMemoryEnabled"] as? Bool).map { (file, $0) }
        }).first, !enabled {
            return "autoMemoryEnabled is false in \(file.label)"
        }
        return nil
    }

    /// `1`, `true`, `yes`, `on`: true; `0`, `false`, `no`, `off`: false;
    /// anything else: neither.
    private static func truth(_ value: String) -> Bool? {
        switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "1", "true", "yes", "on": return true
        case "0", "false", "no", "off": return false
        default: return nil
        }
    }

    private static func isTruthy(_ value: String?) -> Bool { value.flatMap(truth) == true }

    /// A settings file's keys: JSON, or a property list for MDM.
    private static func readSettings(_ url: URL) -> [String: Any] {
        guard let data = ProjectMemory.readData(url.path, limit: 4_000_000) else { return [:] }
        let object = url.pathExtension == "plist"
            ? try? PropertyListSerialization.propertyList(from: data, format: nil)
            : try? JSONSerialization.jsonObject(with: data)
        return object as? [String: Any] ?? [:]
    }

    // MARK: - The main checkout

    /// The main checkout of the repository holding `folder`, as Claude Code
    /// reads it: the nearest folder with a `.git`; for a linked worktree,
    /// the checkout its `commondir` belongs to, once the worktree's git
    /// folder points back at it. Nil outside a repository.
    static func canonicalRoot(of folder: String) -> String? {
        let manager = FileManager.default
        var root = folder
        while !manager.fileExists(atPath: (root as NSString).appendingPathComponent(".git")) {
            let parent = (root as NSString).deletingLastPathComponent
            guard parent != root, !parent.isEmpty else { return nil }
            root = parent
        }
        return (mainCheckout(ofWorktree: root) ?? root).precomposedStringWithCanonicalMapping
    }

    private static func mainCheckout(ofWorktree root: String) -> String? {
        let dotGit = (root as NSString).appendingPathComponent(".git")
        guard let text = ProjectMemory.readText(dotGit, limit: 64 * 1024),
              let line = text.split(whereSeparator: \.isNewline).first(where: { $0.hasPrefix("gitdir:") })
        else { return nil }
        let gitDirectory = resolve(line.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespaces), from: root)
        guard let common = ProjectMemory.readText((gitDirectory as NSString).appendingPathComponent("commondir"), limit: 64 * 1024)
                .map({ resolve($0.trimmingCharacters(in: .whitespacesAndNewlines), from: gitDirectory) }),
              (gitDirectory as NSString).deletingLastPathComponent == (common as NSString).appendingPathComponent("worktrees"),
              let back = ProjectMemory.readText((gitDirectory as NSString).appendingPathComponent("gitdir"), limit: 64 * 1024)
        else { return nil }
        // Compared resolved, as Claude Code does: git writes the path as it
        // was typed, in any case.
        let pointer = resolve(back.trimmingCharacters(in: .whitespacesAndNewlines), from: gitDirectory)
        guard (pointer.realPath ?? pointer) == (root.realPath ?? root) + "/.git" else { return nil }
        guard (common as NSString).lastPathComponent == ".git" else {
            return FileManager.default.fileExists(atPath: (common as NSString).appendingPathComponent(".git")) ? root : common
        }
        return (common as NSString).deletingLastPathComponent
    }

    /// `path` from `base` when relative, `.` and `..` worked out, without
    /// resolving links.
    static func resolve(_ path: String, from base: String) -> String {
        normalized(path.hasPrefix("/") ? path : (base as NSString).appendingPathComponent(path))
    }

    static func normalized(_ path: String) -> String {
        var parts: [Substring] = []
        for part in path.split(separator: "/") {
            switch part {
            case ".": continue
            case "..": if !parts.isEmpty { parts.removeLast() }
            default: parts.append(part)
            }
        }
        return "/" + parts.joined(separator: "/")
    }
}
