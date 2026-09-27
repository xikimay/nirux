import Foundation

/// Tells whether `claude` and `codex` are installed where a Nirux terminal
/// would find them, for the first-launch checklist.
///
/// Terminals start the login shell with `PtySession.effectivePath`; its
/// startup files then add per-user install locations (npm prefixes, Node
/// version managers, shims). Running those startup files from the app
/// could have side effects, so the lookup only reads the file system: that
/// PATH, then the usual per-user install locations. A binary installed
/// somewhere else reads as missing; the checklist can still be closed.
enum AgentCLILocator {
    static func locate(
        path: String = PtySession.effectivePath,
        home: String = NSHomeDirectory(),
        systemDirectories: [String] = systemInstallDirectories
    ) -> AgentCLIAvailability {
        let directories = searchDirectories(path: path, home: home, systemDirectories: systemDirectories)
        return AgentCLIAvailability(
            claudePath: executable(named: "claude", in: directories),
            codexPath: executable(named: "codex", in: directories)
        )
    }

    /// PATH entries first, in order, then the per-user locations; each
    /// directory once.
    static func searchDirectories(
        path: String, home: String, systemDirectories: [String] = systemInstallDirectories
    ) -> [String] {
        var seen = Set<String>()
        let directories = path.split(separator: ":").map(String.init)
            + userInstallDirectories(home: home) + systemDirectories
        return directories.filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    /// Nix profiles outside the home directory (nix-darwin, home-manager,
    /// the default profile).
    static let systemInstallDirectories = [
        "/etc/profiles/per-user/\(NSUserName())/bin",
        "/run/current-system/sw/bin",
        "/nix/var/nix/profiles/default/bin"
    ]

    /// Where the documented installers put the CLIs when that location is
    /// only on PATH through shell startup files.
    static func userInstallDirectories(home: String) -> [String] {
        var directories = [
            "\(home)/.local/bin",  // Claude Code's native installer
            "\(home)/.claude/local",  // Claude Code's older local install (a shell alias)
            "\(home)/.npm-global/bin",
            "\(home)/.volta/bin",
            "\(home)/.bun/bin",
            "\(home)/.yarn/bin",
            "\(home)/Library/pnpm",
            "\(home)/.asdf/shims",
            "\(home)/.local/share/mise/shims",
            "\(home)/.nix-profile/bin",
            "\(home)/bin"
        ]
        if let prefix = npmPrefix(home: home) { directories.append(prefix + "/bin") }
        // nvm, fnm and mise keep one bin directory per installed Node version.
        directories += versionDirectories(in: "\(home)/.nvm/versions/node", binPath: "bin")
        directories += versionDirectories(
            in: "\(home)/Library/Application Support/fnm/node-versions", binPath: "installation/bin"
        )
        directories += versionDirectories(in: "\(home)/.local/share/fnm/node-versions", binPath: "installation/bin")
        directories += versionDirectories(in: "\(home)/.local/share/mise/installs/node", binPath: "bin")
        return directories
    }

    /// The global install prefix set in ~/.npmrc (`prefix=~/.npm-packages`),
    /// where `npm i -g` puts binaries under `bin`. The last setting wins,
    /// as in npm.
    static func npmPrefix(home: String) -> String? {
        guard let text = try? String(contentsOfFile: home + "/.npmrc", encoding: .utf8) else { return nil }
        var prefix: String?
        for line in text.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2, parts[0] == "prefix" else { continue }
            prefix = parts[1].trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        }
        guard var value = prefix else { return nil }
        // Only a whole home reference: `$HOMEBREW_PREFIX` or `~user` is not one.
        for homeReference in ["${HOME}", "$HOME", "~"]
        where value == homeReference || value.hasPrefix(homeReference + "/") {
            value = home + value.dropFirst(homeReference.count)
            break
        }
        return value.hasPrefix("/") ? value : nil
    }

    /// `<root>/<version>/<binPath>` for every version, newest name first so
    /// the default (usually the latest) is reported when several have it.
    private static func versionDirectories(in root: String, binPath: String) -> [String] {
        guard let versions = try? FileManager.default.contentsOfDirectory(atPath: root) else { return [] }
        return versions
            .filter { !$0.hasPrefix(".") }
            .sorted { $0.compare($1, options: .numeric) == .orderedDescending }
            .map { "\(root)/\($0)/\(binPath)" }
    }

    /// First executable regular file (or symlink to one) named `name`.
    static func executable(named name: String, in directories: [String]) -> String? {
        let fileManager = FileManager.default
        for directory in directories {
            let candidate = (directory as NSString).appendingPathComponent(name)
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: candidate, isDirectory: &isDirectory),
                  !isDirectory.boolValue,
                  fileManager.isExecutableFile(atPath: candidate) else { continue }
            return candidate
        }
        return nil
    }
}
