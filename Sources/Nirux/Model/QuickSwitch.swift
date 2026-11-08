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
    /// On screen now.
    let isCurrent: Bool
    /// Not in the active space: ⌘P lists it under Other Spaces, the row
    /// names its space, and the search matches it. The active space's rows
    /// sit under its name, which would match every one of them.
    let isInOtherSpace: Bool
    let agent: QuickSwitchAgentState?

    /// What ⌘P searches: the title, then the branch, the space and the
    /// folder's name. Inactive workspaces list below the active ones that
    /// match as well.
    var candidate: PaletteRanking.Candidate {
        PaletteRanking.Candidate(
            title: title,
            keys: [branch, isInOtherSpace ? spaceName : nil, (folder as NSString).lastPathComponent].compactMap { $0 },
            sinks: isInactive
        )
    }

    /// "Current · branch · space · folder": the branch unless the title
    /// says it already, the space when it isn't the active one.
    func subtitle(folderDisplay: String) -> String {
        let state = isCurrent ? "Current" : isInactive ? "Archived" : nil
        let branch = self.branch.flatMap { $0 == title ? nil : $0 }
        return [state, branch, isInOtherSpace ? spaceName : nil, folderDisplay].compactMap { $0 }.joined(separator: " · ")
    }

    /// What ⌘P's folded Other Spaces row says for the workspaces it hides.
    struct Folded: Equatable {
        /// "Show 3 Workspaces".
        let title: String
        /// Their spaces, in the order given.
        let subtitle: String
        /// "2 need you": how many have an agent waiting on the user or
        /// failed; nil for none. Folding mustn't hide them.
        let attention: String?
        let hasFailure: Bool
    }

    static func folded(_ workspaces: [QuickSwitchWorkspace]) -> Folded {
        var spaces: [String] = []
        for workspace in workspaces where !spaces.contains(workspace.spaceName) { spaces.append(workspace.spaceName) }
        let needingYou = workspaces.compactMap(\.agent).filter(\.needsUser)
        return Folded(
            title: workspaces.count == 1 ? "Show 1 Workspace" : "Show \(workspaces.count) Workspaces",
            subtitle: spaces.joined(separator: " · "),
            attention: needingYou.isEmpty ? nil : needingYou.count == 1 ? "1 needs you" : "\(needingYou.count) need you",
            hasFailure: needingYou.contains(where: \.isFailure)
        )
    }
}

/// The most pressing agent state among a workspace's columns.
enum QuickSwitchAgentState: Equatable {
    case working
    /// An agent waits on a dialog, since this epoch time (the longest).
    case waiting(since: TimeInterval)
    /// An agent's turn failed, or it exited mid-turn.
    case failed(AgentAttentionReason)

    /// A failure first (red, as on the sidebar), else the longest wait,
    /// else work going on.
    static func summary(waits: [AgentWait], isWorking: Bool) -> QuickSwitchAgentState? {
        if let failure = waits.filter(\.reason.isFailure).min(by: { $0.since < $1.since }) {
            return .failed(failure.reason)
        }
        if let wait = waits.min(by: { $0.since < $1.since }) { return .waiting(since: wait.since) }
        return isWorking ? .working : nil
    }

    /// An agent waits on the user, or failed: not one at work.
    var needsUser: Bool {
        if case .working = self { return false }
        return true
    }

    var isFailure: Bool {
        if case .failed = self { return true }
        return false
    }

    /// "working", "waiting 12m", "API error".
    func label(now: TimeInterval) -> String {
        switch self {
        case .working: return "working"
        case .waiting(let since): return "waiting \(SidebarRenderer.shortDuration(now - since))"
        case .failed(let reason): return reason.shortLabel
        }
    }
}
