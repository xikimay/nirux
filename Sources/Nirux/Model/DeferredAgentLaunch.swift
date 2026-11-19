import Foundation

/// When the agents of a restored layout start (Settings → General): each
/// once its column shows, or all with the window as before.
enum AgentResumeOnLaunch: String, Codable, CaseIterable {
    case lazily
    case allAtOnce

    static let defaultValue: AgentResumeOnLaunch = .lazily

    var displayName: String {
        switch self {
        case .lazily: return "When their column shows"
        case .allAtOnce: return "All at once"
        }
    }
}

/// An agent column's status when Nirux last saved it, kept so a column
/// whose agent hasn't resumed yet can say where it was.
enum PersistedAgentStatus: String, Codable {
    case idle, working, needsAttention

    init(_ status: AgentStatus) {
        switch status {
        case .idle: self = .idle
        case .working: self = .working
        case .needsAttention: self = .needsAttention
        }
    }
}

/// A restored agent column whose agent has not started yet: what its
/// launch runs once the column shows, gets the focus, or the user asks
/// (see NiruxShellView+LazyRestore.swift). The resume target was claimed
/// when the layout was restored, so two columns never resume one session.
struct DeferredAgentLaunch: Equatable {
    let launch: AgentLaunch
    /// The session's title the last time it ran here, if it had one.
    let title: String?
    let lastStatus: PersistedAgentStatus?

    /// Where the agent was the last time it ran here, nil when unknown.
    var lastStatusText: String? {
        switch lastStatus {
        case .working?: return "last seen working"
        case .needsAttention?: return "last seen waiting for you"
        case .idle?: return "last seen idle"
        case nil: return nil
        }
    }

    /// "Fix the login form · last seen working", or what is known of it.
    var summary: String {
        [title ?? "\(launch.agent.rawValue) session", lastStatusText].compactMap { $0 }.joined(separator: " · ")
    }

    /// The session title an agent column's terminal title gives, or nil for
    /// none: no spinner glyph in front, no shell or launch line, no
    /// generic agent name.
    static func sessionTitle(fromTerminalTitle terminalTitle: String?) -> String? {
        guard let cleaned = terminalTitle.flatMap({ AgentText.clean($0, maxLength: maxTitleLength) }) else { return nil }
        var scalars = String.UnicodeScalarView()
        scalars.append(contentsOf: cleaned.unicodeScalars.drop(while: isTitleDecoration))
        let title = String(scalars)
        let lowered = title.lowercased()
        guard !title.isEmpty,
              !Shell.isShell(lowered), !CodingAgent.allCases.contains(where: { $0.genericTitles.contains(lowered) }),
              !launchLinePrefixes.contains(where: { lowered.hasPrefix($0) }) else { return nil }
        return title
    }

    static let maxTitleLength = 80

    /// A shell that titles its window with the running command shows the
    /// launch line until the agent sets its own title.
    private static let launchLinePrefixes = ["command ", "claude -", "codex -", "codex resume"]

    /// Claude Code puts a status glyph before its title (✳ idle, a dingbat
    /// or braille spinner while it works).
    private static func isTitleDecoration(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x2700...0x27BF, 0x2800...0x28FF, 0x00B7, 0x2022, 0x2219, 0x22C5, 0x2A: return true
        default: return scalar.properties.isWhitespace
        }
    }
}
