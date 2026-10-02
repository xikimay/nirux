import AppKit
import Foundation

extension NSColor {
    /// Old name of `Theme.Color.accent`, left for the files in
    /// `ThemeGuardTests.pending`.
    @available(*, deprecated, message: "Use Theme.Color.accent")
    static let niruxAccent = Theme.Color.accent
    /// A usage close to its limit: a Claude column's context ("ctx 92%"),
    /// the plan usage limits in the title bar.
    static let niruxNearLimit = NSColor.systemOrange.withAlphaComponent(0.9)
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
