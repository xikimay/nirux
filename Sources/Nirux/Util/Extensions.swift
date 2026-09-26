import AppKit
import Foundation

extension NSColor {
    static let niruxAccent = NSColor(red: 0.47, green: 0.64, blue: 0.97, alpha: 1)
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
    var realPath: String? {
        guard let resolved = Darwin.realpath(self, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }
}
