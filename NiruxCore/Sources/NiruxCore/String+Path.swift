import Foundation

public extension String {
    /// Abbreviate a file path: replace $HOME with ~, keep last N components.
    func abbreviatedPath(maxComponents: Int = 3) -> String {
        var path = self
        let home = NSHomeDirectory()
        if path.hasPrefix(home) {
            path = "~" + path.dropFirst(home.count)
        }
        let components = path.split(separator: "/", omittingEmptySubsequences: true)
        if components.count > maxComponents {
            let kept = components.suffix(maxComponents)
            return (path.hasPrefix("~") ? "~/" : "/") + ".../" + kept.joined(separator: "/")
        }
        return path
    }

    /// realpath(3): the absolute path with every symlink resolved, or nil
    /// if it doesn't exist. Unlike `resolvingSymlinksInPath`, keeps the
    /// `/private` prefix, so /tmp/x and /private/tmp/x compare equal.
    /// Absolute paths only: a relative one would silently resolve against
    /// the app's working directory.
    var realPath: String? {
        guard hasPrefix("/"), let resolved = Darwin.realpath(self, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    /// Darwin's system aliases can prefix a workspace or state directory.
    /// O_NOFOLLOW_ANY still checks every component of the path under them.
    var expandingSystemAliases: String {
        for alias in ["/tmp", "/var", "/etc"] where self == alias || hasPrefix(alias + "/") {
            return "/private" + self
        }
        return self
    }

    var comparablePath: String {
        realPath ?? URL(fileURLWithPath: self).standardizedFileURL.path
    }
}
