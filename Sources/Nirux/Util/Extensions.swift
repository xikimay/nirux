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

