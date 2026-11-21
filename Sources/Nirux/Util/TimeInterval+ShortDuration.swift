import Foundation

extension TimeInterval {
    /// Compact duration for sidebar chips: 42s, 12m, 1h05m.
    var shortDuration: String {
        let total = max(0, Int(self))
        if total < 60 { return "\(total)s" }
        if total < 3600 { return "\(total / 60)m" }
        return "\(total / 3600)h\(String(format: "%02d", (total % 3600) / 60))m"
    }
}
