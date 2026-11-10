import Foundation

/// A live agent Nirux may type a prompt into for the user (PR Feedback's
/// Address, "Ask Agent Why CI Failed"): see
/// `NiruxShellView.typedPromptTargets`.
struct TypedPromptTarget: Equatable, Sendable {
    let id: String
    let workspaceID: String
    let columnIndex: Int
    let cwd: String
    let status: AgentStatus
    /// A dialog the agent may be showing (see `PtySession.pendingAgentDialog`).
    var pendingDialog: AgentAttentionReason?
}

enum TypedPromptResult: Equatable, Sendable {
    case sent(TypedPromptTarget)
    /// Not typed: the agent may be showing a dialog, where the prompt's
    /// text and Enter would answer it (approve a command, pick an option).
    case blockedByDialog(TypedPromptTarget)
    case sessionUnavailable
    case emptyPrompt
}

enum TypedPromptSanitizer {
    static let maxCharacters = 8_000

    /// Text Nirux types into a terminal is untrusted terminal input (a PR's
    /// URLs, review comments, Mission messages). Keep ordinary Unicode,
    /// newlines and tabs, but discard control characters (especially ESC)
    /// before wrapping the prompt in terminal bracketed-paste markers.
    static func sanitize(_ text: String) -> String? {
        let sanitized = filtered(String(String.UnicodeScalarView(text.unicodeScalars.prefix(maxCharacters))))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return sanitized.isEmpty ? nil : sanitized
    }

    /// `text` with what a terminal would read as a key left out: tabs and
    /// line feeds kept, a carriage return (alone or before a line feed)
    /// made a line feed, every other C0 control, DEL and C1 control
    /// dropped. Nothing in it can end a bracketed paste.
    static func filtered(_ text: String) -> String {
        var result = String.UnicodeScalarView()
        var previousWasCarriageReturn = false
        for scalar in text.unicodeScalars {
            if previousWasCarriageReturn {
                previousWasCarriageReturn = false
                if scalar.value == 0x0A { continue }
            }
            switch scalar.value {
            case 0x09, 0x0A:
                result.append(scalar)
            case 0x0D:
                result.append("\n")
                previousWasCarriageReturn = true
            case 0x20...0x7E, 0xA0...0x10FFFF:
                result.append(scalar)
            default:
                continue
            }
        }
        return String(result)
    }

    static func terminalInput(for text: String) -> String? {
        guard let sanitized = sanitize(text) else { return nil }
        return "\u{1B}[200~\(sanitized)\u{1B}[201~\r"
    }
}
