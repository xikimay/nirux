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
    /// Darwin's system aliases can prefix a workspace or state directory.
    /// O_NOFOLLOW_ANY still checks every component of the path under them.
    var expandingSystemAliases: String {
        for alias in ["/tmp", "/var", "/etc"] where self == alias || hasPrefix(alias + "/") {
            return "/private" + self
        }
        return self
    }

    /// The words of a warning, as `NSColor.niruxWarning` draws them:
    /// "⚠︎ Couldn’t read the file."
    var asWarning: String { "⚠︎ " + self }
}
