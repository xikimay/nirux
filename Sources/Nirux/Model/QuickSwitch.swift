import Foundation

/// A workspace as the quick switcher (⌘P) lists it.
struct QuickSwitchWorkspace: Equatable {
    let id: String
    let title: String
    let branch: String?
    let spaceName: String
    let spaceColorHex: String
    /// The workspace's folder.
    let folder: String
    let isInactive: Bool
    let agent: QuickSwitchAgentState?

    /// What ⌘P searches: the title, then the branch, the space and the
    /// folder's name. Inactive workspaces list after the active ones.
    var candidate: PaletteRanking.Candidate {
        PaletteRanking.Candidate(
            title: title,
            keys: [branch, spaceName, (folder as NSString).lastPathComponent].compactMap { $0 },
            sinks: isInactive
        )
    }

    /// "branch · space · folder": the branch unless the title says it
    /// already, the space when there are several.
    func subtitle(folderDisplay: String, showsSpace: Bool) -> String {
        let branch = self.branch.flatMap { $0 == title ? nil : $0 }
        return [branch, showsSpace ? spaceName : nil, folderDisplay].compactMap { $0 }.joined(separator: " · ")
    }
}

/// The most pressing agent state among a workspace's columns.
enum QuickSwitchAgentState: Equatable {
    case working
    /// An agent waits on a dialog, since this epoch time (the longest).
    case waiting(since: TimeInterval)
    /// An agent's turn failed, or it exited mid-turn.
    case failed(AgentAttentionReason)

    /// A failure first, else the longest wait, else work going on.
    static func summary(waits: [AgentWait], isWorking: Bool) -> QuickSwitchAgentState? {
        if let failure = waits.filter(\.reason.isFailure).min(by: { $0.since < $1.since }) {
            return .failed(failure.reason)
        }
        if let wait = waits.min(by: { $0.since < $1.since }) { return .waiting(since: wait.since) }
        return isWorking ? .working : nil
    }

    /// "working", "waiting 12m", "API error".
    func label(now: TimeInterval) -> String {
        switch self {
        case .working: return "working"
        case .waiting(let since): return "waiting \(PilotSidebarRenderer.shortDuration(now - since))"
        case .failed(let reason): return reason.shortLabel
        }
    }
}
