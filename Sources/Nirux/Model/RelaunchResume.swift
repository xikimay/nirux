import Foundation

/// Which restored agents a relaunch starts on its own, after an unclean
/// exit (an update's relaunch, a crash, a forced quit: never the user's
/// Quit), in a space whose "Resume work after a relaunch" is on (Space
/// Settings › Defaults): the Lead's, one last seen working, and one a
/// Mission message waits for.
/// The others wait for their column to show or for Resume, as before: an
/// update relaunching at night left every task paused until morning.
enum RelaunchResume {
    struct Candidate: Equatable, Sendable {
        let agentUUID: String?
        let lastStatus: PersistedAgentStatus?
        let isLead: Bool
    }

    /// Never one last seen waiting on a question or a permission: it waits
    /// for whoever it waited on, a Mission message for it too.
    static func resumes(_ candidate: Candidate, messageWaitsFor waiting: Set<String>) -> Bool {
        guard candidate.lastStatus != .needsAttention else { return false }
        return candidate.isLead || candidate.lastStatus == .working || candidate.agentUUID.map(waiting.contains) == true
    }

    /// One last seen mid-turn, the Lead too, is told once to go on; one that
    /// ended its turn, waited on a question or a permission waits for whoever
    /// it waited on.
    static func continues(_ candidate: Candidate) -> Bool {
        candidate.lastStatus == .working
    }

    static let continueText = "Nirux restarted while you were working. Continue where you left off."

    /// The agents the Mission messages still to type are for: a child for
    /// a `tell` or an answer, the parent for the rest.
    static func waitingAgents(_ pending: [MissionStore.AcceptedEvent]) -> Set<String> {
        Set(pending.compactMap { delivery in
            switch delivery.event.kind {
            case .instruction, .response: delivery.event.childAgentUUID
            default: delivery.event.parentAgentUUID ?? delivery.mission.parentAgentUUID
            }
        })
    }
}
