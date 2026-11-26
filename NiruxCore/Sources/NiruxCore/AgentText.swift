import Foundation

/// Display-safe text from agent payloads (notification messages, tool
/// inputs): no control or invisible formatting characters (terminal
/// escapes, bidi overrides), whitespace runs folded to one space, bounded.
public enum AgentText {
    /// The agent's words without the marks around them: "**Rebase** on
    /// `main`" reads "Rebase on main" where no Markdown is drawn. Only
    /// the marks that are never words ("_" and "*" may be).
    public static func withoutMarks(_ text: String) -> String {
        text.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "`", with: "")
    }

    public static func clean(_ text: String, maxLength: Int) -> String? {
        guard maxLength > 0 else { return nil }
        var scalars = String.UnicodeScalarView()
        var kept = 0 // UnicodeScalarView.count is O(n)
        var pendingSpace = false
        var truncated = false
        // Bounds the scan on huge inputs (a Write's content, a heredoc).
        let scalarBudget = maxLength * 4 + 4
        for scalar in text.unicodeScalars {
            if kept >= scalarBudget {
                truncated = true
                break
            }
            if scalar.properties.isWhitespace {
                pendingSpace = true
                continue
            }
            switch scalar.properties.generalCategory {
            case .control, .surrogate:
                continue
            case .format where scalar.value != 0x200D: // keep ZWJ (emoji sequences)
                continue
            default:
                break
            }
            if pendingSpace, kept > 0 {
                scalars.append(" ")
                kept += 1
            }
            pendingSpace = false
            scalars.append(scalar)
            kept += 1
        }
        let result = String(scalars)
        guard !result.isEmpty else { return nil }
        guard truncated || result.count > maxLength else { return result }
        return String(result.prefix(maxLength - 1)).trimmingCharacters(in: .whitespaces) + "…"
    }
}
