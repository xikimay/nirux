import Foundation

/// A Claude Code release number (`2.1.283`). Read from where the installer
/// put the CLI, never by running it: launch stays fast, and nothing from a
/// login shell's startup files runs.
struct ClaudeCodeVersion: Comparable, CustomStringConvertible {
    let major: Int
    let minor: Int
    let patch: Int
    /// `2.1.90-beta.1`: before 2.1.90 itself.
    let isPrerelease: Bool

    init(major: Int, minor: Int, patch: Int, isPrerelease: Bool = false) {
        self.major = major
        self.minor = minor
        self.patch = patch
        self.isPrerelease = isPrerelease
    }

    /// `2.1.283`, or `2.1.90-beta.1` (a pre-release of 2.1.90).
    init?(_ text: String) {
        let parts = text.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        let numbers = (parts.first ?? "").split(separator: ".", omittingEmptySubsequences: false)
        guard numbers.count == 3,
              numbers.allSatisfy({ !$0.isEmpty && $0.allSatisfy { $0.isASCII && $0.isNumber } }),
              let major = Int(numbers[0]), let minor = Int(numbers[1]), let patch = Int(numbers[2]) else { return nil }
        self.init(major: major, minor: minor, patch: patch, isPrerelease: parts.count > 1)
    }

    static func < (lhs: ClaudeCodeVersion, rhs: ClaudeCodeVersion) -> Bool {
        (lhs.major, lhs.minor, lhs.patch, lhs.isPrerelease ? 0 : 1)
            < (rhs.major, rhs.minor, rhs.patch, rhs.isPrerelease ? 0 : 1)
    }

    var description: String { "\(major).\(minor).\(patch)\(isPrerelease ? "-pre" : "")" }

    /// The oldest `claude` a Nirux terminal could run: every one found on
    /// its PATH and in the usual install places (see `AgentCLILocator`),
    /// every Node version's included. ~/.claude/settings.json is shared by
    /// all of them. Nil when none is found or any one's version can't be
    /// read.
    static func detect(
        path: String = PtySession.effectivePath,
        home: String = NSHomeDirectory()
    ) -> ClaudeCodeVersion? {
        let directories = AgentCLILocator.searchDirectories(path: path, home: home)
        let binaries = directories.compactMap { AgentCLILocator.executable(named: "claude", in: [$0]) }
        guard !binaries.isEmpty else { return nil }
        var oldest: ClaudeCodeVersion?
        for binary in binaries {
            guard let version = installed(at: binary) else { return nil }
            oldest = min(oldest ?? version, version)
        }
        return oldest
    }

    /// The version of the `claude` at `path`, from its install layout:
    /// - the native installer links it to `…/claude/versions/<version>`;
    /// - Homebrew's cask keeps it in `…/Caskroom/claude-code/<version>/`;
    /// - npm, pnpm, yarn and bun link it into the `@anthropic-ai/claude-code`
    ///   package, whose package.json says;
    /// - the older local install is a script in `~/.claude/local`, beside
    ///   that package's `node_modules`.
    ///
    /// Shims (Volta, asdf, mise) and wrappers read as unknown.
    static func installed(at path: String) -> ClaudeCodeVersion? {
        let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath()
        let directory = resolved.deletingLastPathComponent()
        if directory.lastPathComponent == "versions",
           directory.deletingLastPathComponent().lastPathComponent == "claude",
           let version = ClaudeCodeVersion(resolved.lastPathComponent) {
            return version
        }
        if directory.deletingLastPathComponent().lastPathComponent == "claude-code",
           let version = ClaudeCodeVersion(directory.lastPathComponent) {
            return version
        }
        if directory.lastPathComponent == "local", directory.deletingLastPathComponent().lastPathComponent == ".claude" {
            return packageVersion(at: directory.appendingPathComponent("node_modules/@anthropic-ai/claude-code/package.json"))
        }
        // Inside the package (its cli.js, or a binary under it).
        var candidate = directory
        for _ in 0..<3 {
            if candidate.lastPathComponent == "claude-code",
               candidate.deletingLastPathComponent().lastPathComponent == "@anthropic-ai" {
                return packageVersion(at: candidate.appendingPathComponent("package.json"))
            }
            candidate.deleteLastPathComponent()
        }
        return nil
    }

    /// The version in a package.json, if it is Claude Code's.
    private static func packageVersion(at url: URL) -> ClaudeCodeVersion? {
        guard let data = try? Data(contentsOf: url),
              let manifest = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              manifest["name"] as? String == "@anthropic-ai/claude-code",
              let version = manifest["version"] as? String else { return nil }
        return ClaudeCodeVersion(version)
    }
}
