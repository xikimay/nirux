import AppKit
import Foundation

extension NSColor {
    /// Old name of `Theme.Color.accent`, kept so branches written before
    /// the tokens still build; ThemeGuardTests then points them to the token.
    @available(*, deprecated, message: "Use Theme.Color.accent")
    static let niruxAccent = Theme.Color.accent
    /// A warning, a usage close to its limit among them: the text's own
    /// colour, its words after "⚠︎ " (`String.asWarning`). Orange would read
    /// as amber, which says something waits for the user's answer
    /// (`Theme.Color.waiting`).
    static let niruxWarning = Theme.Color.textPrimary
}

extension String {
    /// The words of a warning, as `NSColor.niruxWarning` draws them:
    /// "⚠︎ Couldn’t read the file."
    var asWarning: String { "⚠︎ " + self }
}

extension Collection {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

extension String {
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
}
