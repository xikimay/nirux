import Foundation

extension String {
    /// The words of a warning, as `NSColor.niruxWarning` draws them:
    /// "⚠︎ Couldn’t read the file."
    var asWarning: String { "⚠︎ " + self }
}
