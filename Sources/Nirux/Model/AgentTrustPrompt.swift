import Foundation

/// The question Claude Code and Codex ask before they work in a folder the
/// user hasn't trusted yet, as a task without a repository's new folder:
/// no hook runs until it is answered, so the agent would sit there looking
/// idle. Nirux reads it on the agent's screen instead, from its launch until
/// a hook or a key reaches it, and its row reads "Needs you · Trust this
/// folder?".
enum AgentTrustPrompt {
    /// What the row, the column header and ⌘J say.
    static let reason = AgentAttentionReason.question("Trust this folder?")
    /// The question comes first: past this long after the agent started,
    /// Nirux stops looking.
    static let watchWindow: TimeInterval = 300
    /// Time between two reads of an agent's screen.
    static let readInterval: TimeInterval = 1.5

    /// Each agent's trust screen, by two phrases it shows together, so a
    /// conversation that quotes one isn't taken for it.
    static let screens: [[String]] = [
        // Claude Code 2.1.
        ["Yes, I trust this folder", "Quick safety check"],
        // Claude Code before 2.1.
        ["Do you trust the files in this folder?", "Yes, proceed"],
        // Codex 0.16x.
        ["Trust this folder?", "Codex can read, edit, and run files here"],
        // Codex before.
        ["Do you trust the contents of this directory?", "Yes, continue"]
    ]

    /// The agent process it was seen in, and when (epoch seconds).
    struct Sighting: Equatable, Sendable {
        let instance: ProcessInstance
        let seenAt: TimeInterval
    }

    /// Whether `screen`, the rows on screen, shows a trust question. A row
    /// soft-wrapped mid-phrase still matches: whitespace runs count as one
    /// space.
    static func isShown(in screen: String) -> Bool {
        let text = screen.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return screens.contains { phrases in phrases.allSatisfy { text.contains($0) } }
    }
}

extension AgentStatusMachine {
    /// Whether to read the screen of `foreground` for its trust question
    /// now: a Claude Code or Codex launched less than `watchWindow` ago,
    /// that no hook and no input reached since, not seen asking yet.
    func watchesForTrustPrompt(foreground: ForegroundProcess?, now: TimeInterval) -> Bool {
        guard let foreground, Self.integratedAgentProcesses.contains(foreground.name) else { return false }
        let started = foreground.instance.startedAt
        guard (0..<AgentTrustPrompt.watchWindow).contains(now - started),
              lastEventAt < started, lastInputAt < started
        else { return false }
        return trustPromptSighting?.instance != foreground.instance
    }

    /// What a read of `foreground`'s screen found.
    mutating func noteTrustPrompt(shown: Bool, foreground: ForegroundProcess, now: TimeInterval) {
        if shown {
            trustPromptSighting = AgentTrustPrompt.Sighting(instance: foreground.instance, seenAt: now)
        } else if trustPromptSighting?.instance == foreground.instance {
            trustPromptSighting = nil
        }
    }

    /// The trust question `foreground` asks: seen on its screen, and no
    /// hook (the agent went on) nor input (the user answered) since it
    /// started.
    func visibleTrustPrompt(foreground: ForegroundProcess?) -> AgentTrustPrompt.Sighting? {
        guard let foreground, let sighting = trustPromptSighting, sighting.instance == foreground.instance,
              lastEventAt < foreground.instance.startedAt, lastInputAt < foreground.instance.startedAt
        else { return nil }
        return sighting
    }
}
