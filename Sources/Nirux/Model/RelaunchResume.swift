import Foundation

/// Which restored agents a relaunch starts on its own, in a space whose
/// "Resume work after a relaunch" is on (Space Settings › Defaults): the
/// Lead's, one last seen working, and one a Mission message waits for.
/// The others wait for their column to show or for Resume, as before: an
/// update relaunching at night left every task paused until morning.
enum RelaunchResume {
    struct Candidate: Equatable, Sendable {
        let agentUUID: String?
        let lastStatus: PersistedAgentStatus?
        let isLead: Bool
    }

    static func resumes(_ candidate: Candidate, messageWaitsFor waiting: Set<String>) -> Bool {
        candidate.isLead || candidate.lastStatus == .working || candidate.agentUUID.map(waiting.contains) == true
    }

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
