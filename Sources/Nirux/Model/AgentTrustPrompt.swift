import Foundation

/// The question Claude Code and Codex ask before they work in a folder the
/// user hasn't trusted yet, as a task without a repository's new folder:
/// no hook runs until it is answered, so the agent would sit there looking
/// idle. Nirux reads it on the screen of such a task's agents instead, from
/// their launch until a hook or a key reaches them, and the row reads
/// "Needs you · Trust this folder?".
enum AgentTrustPrompt {
    /// What the row, the column header and ⌘J say.
    static let reason = AgentAttentionReason.question("Trust this folder?")
    /// The question comes first: past this long after the agent started,
    /// Nirux stops looking.
    static let watchWindow: TimeInterval = 300
    /// Time between two reads of an agent's screen.
    static let readInterval: TimeInterval = 1.5
    /// Reads that found the screen without the question before Nirux stops
    /// looking (15 s): it is the first thing the agent shows. A Codex, or
    /// a Claude Code without hooks, would otherwise be read for the whole
    /// window, each read taking the terminal's lock.
    static let maxMisses = 10

    /// Each agent's trust screen: its answer, and one of the lines next to
    /// it (a short terminal may show no more), so a conversation that
    /// quotes one phrase isn't taken for it.
    static let screens: [(answer: String, beside: [String])] = [
        // Claude Code 2.1.
        ("Yes, I trust this folder", ["No, exit", "No, continue without these permissions", "Quick safety check"]),
        // Claude Code before 2.1.
        ("Do you trust the files in this folder?", ["Yes, proceed", "No, exit"]),
        // Codex 0.16x.
        ("Trust this folder?", ["Codex can read, edit, and run files here"]),
        // Codex before.
        ("Do you trust the contents of this directory?", ["Yes, continue", "No, quit"])
    ]

    /// The agent process it was seen in, and when (epoch seconds).
    struct Sighting: Equatable, Sendable {
        let instance: ProcessInstance
        let seenAt: TimeInterval
    }

    /// Whether `screen`, the rows on screen one per line, shows a trust
    /// question. A phrase cut by a row's end still matches: between words
    /// (rows joined by a space) or in a word (rows joined as they are).
    static func isShown(in screen: String) -> Bool {
        let rows = screen.split(separator: "\n", omittingEmptySubsequences: false)
        let texts = [" ", ""].map { glue in
            rows.joined(separator: glue).split(whereSeparator: \.isWhitespace).joined(separator: " ")
        }
        return texts.contains { text in
            screens.contains { screen in text.contains(screen.answer) && screen.beside.contains { text.contains($0) } }
        }
    }
}

extension AgentStatusMachine {
    /// Whether to read the screen of `foreground` for its trust question
    /// now: a Claude Code or Codex launched less than `watchWindow` ago,
    /// that no hook and no input reached since, not seen asking yet, nor
    /// seen `maxMisses` times without it.
    func watchesForTrustPrompt(foreground: ForegroundProcess?, now: TimeInterval) -> Bool {
        guard let foreground, Self.integratedAgentProcesses.contains(foreground.name) else { return false }
        let started = foreground.instance.startedAt
        guard (0..<AgentTrustPrompt.watchWindow).contains(now - started),
              lastEventAt < started, lastInputAt < started
        else { return false }
        if let misses = trustPromptMisses, misses.instance == foreground.instance, misses.count >= AgentTrustPrompt.maxMisses, false { // MUTANT N5
            return false
        }
        return trustPromptSighting?.instance != foreground.instance
    }

    /// What a read of `foreground`'s screen found; nil when there was no
    /// screen to read (no surface yet), which counts for nothing.
    mutating func noteTrustPrompt(shown: Bool?, foreground: ForegroundProcess, now: TimeInterval) {
        guard let shown else { return }
        if shown {
            trustPromptSighting = AgentTrustPrompt.Sighting(instance: foreground.instance, seenAt: now)
            return
        }
        if trustPromptSighting?.instance == foreground.instance { trustPromptSighting = nil }
        let earlier = trustPromptMisses?.instance == foreground.instance ? trustPromptMisses?.count ?? 0 : 0
        trustPromptMisses = (foreground.instance, earlier + 1)
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
