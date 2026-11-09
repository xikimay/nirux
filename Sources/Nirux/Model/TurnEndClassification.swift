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
    /// The agent's environment (the hook's, which it inherits) sends Claude
    /// Code elsewhere than the login Nirux's own `claude -p` uses: one of
    /// the variables that run drops (`ClaudeCLI.accountVariables`: a cloud
    /// provider, an API key, a gateway, a token). Its messages are not sent
    /// to that login: its turn ends alert as before. The configuration
    /// folder, which the run keeps, is compared instead (`TurnEndMarker`).
    static func usesOtherAccount(_ environment: [String: String]) -> Bool {
        BranchReview.ClaudeCLI.accountVariables.contains { environment[$0].map { !$0.isEmpty && $0 != "0" } ?? false }
    }

    /// Two `CLAUDE_CONFIG_DIR` values name the same folder: unset or empty
    /// is Claude Code's default, `~/.claude`.
    static func sameConfigDirectory(_ first: String?, _ second: String?, home: String) -> Bool {
        func folder(_ value: String?) -> String {
            guard let value, !value.isEmpty else { return (home as NSString).appendingPathComponent(".claude") }
            let expanded = value.hasPrefix("~/") ? (home as NSString).appendingPathComponent(String(value.dropFirst(2))) : value
            return (expanded as NSString).standardizingPath
        }
        return folder(first) == folder(second)
    }

    /// The start and the end of `message`, the part a classifier reads:
    /// the whole message up to `limit` Unicode scalars (at most 4 bytes
    /// each: the hook's event line stays a few kilobytes), else its first
    /// `headLength` and its last scalars around a "[…]" line (a question
    /// usually ends the message; its start says what the turn was about).
    /// Nil for a message without visible text.
    static func excerpt(_ message: String, limit: Int = 3_000, headLength: Int = 600) -> String? {
        let scalars = message.trimmingCharacters(in: .whitespacesAndNewlines).unicodeScalars
        guard !scalars.isEmpty else { return nil }
        guard scalars.count > limit else { return String(scalars) }
        let head = String(String.UnicodeScalarView(scalars.prefix(headLength)))
        let tail = String(String.UnicodeScalarView(scalars.suffix(max(0, limit - headLength))))
        return head + "\n[…]\n" + tail
    }

    /// The message's last line of prose, cleaned for one line of a
    /// notification: what a turn that asks most likely asks. Lines inside
    /// fenced code are skipped, counting fences from the end: an excerpt
    /// may have lost the start of a block, never its end.
    static func lastLine(of message: String, maxLength: Int = 200) -> String? {
        var inFence = false
        for line in message.split(whereSeparator: \.isNewline).reversed() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                inFence.toggle()
                continue
            }
            if !inFence, let cleaned = AgentText.clean(String(line), maxLength: maxLength) { return cleaned }
        }
        return nil
    }
}

/// Tells hook receivers that a running Nirux reads final messages (the
/// option is on), and with which Claude configuration folder its `claude
/// -p` runs. Without a marker naming a Nirux still running, or for an
/// agent with another folder, receivers leave the message out of the event
/// queue: nothing would read it, and Stop lines would grow for nothing.
struct TurnEndMarker: Codable, Equatable {
    let app: ProcessInstance
    /// Nirux's own `CLAUDE_CONFIG_DIR` (nil: the default), which its
    /// `claude -p` keeps (`ClaudeCLI.keptVariables`).
    let claudeConfigDir: String?

    static var url: URL { Persistence.stateDirectory.appendingPathComponent("turn-end-classifier.json") }

    /// The option is on in `app`.
    static func publish(app: ProcessInstance, environment: [String: String], at url: URL = url) {
        let marker = TurnEndMarker(app: app, claudeConfigDir: environment["CLAUDE_CONFIG_DIR"])
        try? JSONEncoder().encode(marker).write(to: url, options: .atomic)
    }

    /// The option is off in `app`, or `app` quits: the marker goes, unless
    /// it names another Nirux still running on this state directory.
    static func withdraw(app: ProcessInstance?, at url: URL = url,
                         running: (pid_t) -> ProcessInstance? = ProcessInstance.running(pid:)) {
        if let marker = read(url), marker.app != app, running(marker.app.pid) == marker.app { return }
        try? FileManager.default.removeItem(at: url)
    }

    /// Whether a receiver keeps the final message of an agent running with
    /// `environment` (the hook's).
    static func allowsMessage(environment: [String: String], at url: URL = url,
                              running: (pid_t) -> ProcessInstance? = ProcessInstance.running(pid:)) -> Bool {
        guard let marker = read(url), running(marker.app.pid) == marker.app else { return false }
        return TurnEndText.sameConfigDirectory(
            environment["CLAUDE_CONFIG_DIR"], marker.claudeConfigDir, home: environment["HOME"] ?? NSHomeDirectory()
        )
    }

    private static func read(_ url: URL) -> TurnEndMarker? {
        (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(TurnEndMarker.self, from: $0) }
    }
}
