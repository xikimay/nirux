import Foundation

/// What a Claude turn's final message asks of the user. Claude reports
/// only that its turn ended (Stop); agents often end on a question written
/// in prose ("3 PRs ready, shall I merge?"), which looks the same. A
/// classifier reads the message so that only a turn that asks something
/// alerts (notification, Dock bounce and badge); a done turn stays quiet.
enum TurnEndVerdict: Equatable, Sendable {
    /// The message hands something back to the user: a question, a choice,
    /// an action only they can do, an offer waiting for a yes.
    case asks
    /// It reports or answers, and asks nothing.
    case done
    /// No answer (the classifier failed, refused, or can't run here): the
    /// turn alerts as every turn end did before, since a missed question
    /// costs more than an extra notification.
    case unknown
}

/// A Claude turn end waiting for its verdict. `turnEndedAt` (the Stop's
/// timestamp) tells it from a later turn end of the same column.
struct TurnEndRequest: Equatable, Sendable {
    /// `TurnEndText.excerpt` of the final assistant message.
    let message: String
    let turnEndedAt: TimeInterval
}

/// Reads a turn's final message. The seam for other classifiers (Apple's
/// on-device model); see `HaikuTurnEndClassifier` for the one in use.
protocol TurnEndClassifier: Sendable {
    /// Never throws: any failure is `.unknown`. May take seconds; the
    /// caller doesn't wait on the main thread.
    func classify(_ message: String) async -> TurnEndVerdict
}

/// The final message's text as the classifier and the alert use it.
enum TurnEndText {
    /// The start and the end of `message`, the part a classifier reads:
    /// the whole message up to `limit` characters, else its first
    /// `headLength` and its last characters around a "[…]" line (a question
    /// usually ends the message; its start says what the turn was about).
    /// Nil for a message without visible text.
    static func excerpt(_ message: String, limit: Int = 3_000, headLength: Int = 600) -> String? {
        let text = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        guard text.count > limit else { return text }
        return String(text.prefix(headLength)) + "\n[…]\n" + String(text.suffix(max(0, limit - headLength)))
    }

    /// The message's last line of prose, cleaned for one line of a
    /// notification: what a turn that asks most likely asks. Lines inside
    /// fenced code are skipped.
    static func lastLine(of message: String, maxLength: Int = 200) -> String? {
        var inFence = false
        var last: Substring?
        for line in message.split(separator: "\n", omittingEmptySubsequences: true) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                inFence.toggle()
                continue
            }
            if !inFence, !trimmed.isEmpty { last = line }
        }
        return last.flatMap { AgentText.clean(String($0), maxLength: maxLength) }
    }
}
