import Foundation

/// A project's history (docs/project-memory-tree.md): every turn of its
/// agent sessions, the messages that started it and the final reply, kept
/// word for word in an append-only journal. A later pass summarizes it into
/// a tree that new sessions see.
enum ProjectHistory {
    /// What a message is. Raw values are the journal's and the summaries'
    /// tags, so they never change.
    enum Kind: String, Codable, Sendable, CaseIterable {
        /// What the user typed.
        case user
        /// A message another session sent, or the prompt Nirux typed to
        /// launch the session: not the user's text.
        case peer
        /// A turn's final reply.
        case talk
        /// A memory written down before the history began.
        case note
    }

    /// A message read from a transcript, before the journal gives it an id.
    struct NewMessage: Equatable, Sendable {
        let kind: Kind
        let branch: String?
        var from: String?
        let text: String
        let date: Date
        let session: String?
        /// The transcript line's `uuid`.
        var uuid: String?

        func withText(_ text: String) -> NewMessage {
            NewMessage(kind: kind, branch: branch, from: from, text: text, date: date, session: session, uuid: uuid)
        }
    }

    /// Who sent Nirux's launch prompts and handovers.
    static let niruxSender = "Nirux"

    /// The prompts Nirux types to launch an agent (`agentStartupPrompt`):
    /// written by Nirux for another session, so `peer`, not `user`.
    static func isLaunchPrompt(_ text: String) -> Bool {
        launchPrompts.contains(text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private static let launchPrompts: Set<String> = {
        var prompts = Set<String>()
        for agent in [NiruxApp.WorkspaceAgent.claude, .codex] {
            for (handover, mission) in [(true, false), (true, true), (false, true)] {
                if let prompt = NiruxShellView.agentStartupPrompt(
                    agent: agent, deliveredHandover: handover, isMission: mission
                ) {
                    prompts.insert(prompt)
                }
            }
        }
        return prompts
    }()
}
