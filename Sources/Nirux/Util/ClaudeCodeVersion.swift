import Foundation

/// A Claude Code release number (`2.1.283`). Read from where the installer
/// put the CLI, never by running it: launch stays fast, and nothing from a
/// login shell's startup files runs.
struct ClaudeCodeVersion: Comparable, CustomStringConvertible {
    let major: Int
    let minor: Int
    let patch: Int

    init(major: Int, minor: Int, patch: Int) {
        self.major = major
        self.minor = minor
        self.patch = patch
    }

    /// `2.1.283`; a pre-release suffix (`2.1.90-beta.1`) is ignored.
    init?(_ text: String) {
        let release = text.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false).first ?? ""
        let parts = release.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3,
              parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isASCII) && $0.allSatisfy(\.isNumber) }),
              let major = Int(parts[0]), let minor = Int(parts[1]), let patch = Int(parts[2]) else { return nil }
        self.init(major: major, minor: minor, patch: patch)
    }

    static func < (lhs: ClaudeCodeVersion, rhs: ClaudeCodeVersion) -> Bool {
        (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
    }

    var description: String { "\(major).\(minor).\(patch)" }

    /// The version of the `claude` a Nirux terminal would run (see
    /// `AgentCLILocator`), nil when its install doesn't say.
    static func detect() -> ClaudeCodeVersion? {
        AgentCLILocator.locate().claudePath.flatMap(installed(at:))
    }

    /// The version of the `claude` at `path`, from its install layout:
    /// - the native installer links it to `…/claude/versions/<version>`;
    /// - Homebrew's cask keeps it in `…/Caskroom/claude-code/<version>/`;
    /// - npm, pnpm, yarn and bun link it into the `@anthropic-ai/claude-code`
    ///   package, whose package.json says;
    /// - the older local install is a script beside that package's
    ///   `node_modules`.
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
        var candidate = directory
        for _ in 0..<3 {
            for manifest in ["package.json", "node_modules/@anthropic-ai/claude-code/package.json"] {
                if let version = packageVersion(at: candidate.appendingPathComponent(manifest)) { return version }
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
