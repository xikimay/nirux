/// Human-readable lifecycle state for a workspace. `WorkspaceState.phase`
/// is an optional manual override; when it is nil Nirux derives a phase from
/// the live agent, blocker, inactive, and pull-request state.
enum WorkspacePhase: String, Codable, CaseIterable {
    case active, waiting, blocked, review, parked, done

    var displayName: String {
        switch self {
        case .active: return "Active"
        case .waiting: return "Waiting"
        case .blocked: return "Blocked"
        case .review: return "Review"
        case .parked: return "Parked"
        case .done: return "Done"
        }
    }

    var symbol: String {
        switch self {
        case .active: return "▶"
        case .waiting: return "◷"
        case .blocked: return "!"
        case .review: return "◇"
        case .parked: return "–"
        case .done: return "✓"
        }
    }

    /// Pure derivation kept separate from the live workspace so phase rules
    /// remain predictable and unit-testable.
    static func derived(
        isInactive: Bool,
        hasBlocker: Bool,
        agentStatuses: [AgentStatus],
        pullRequestState: String?
    ) -> WorkspacePhase {
        if hasBlocker { return .blocked }
        if agentStatuses.contains(.needsAttention) { return .waiting }
        if agentStatuses.contains(.working) { return .active }
        if isInactive { return .parked }
        switch pullRequestState?.uppercased() {
        case "MERGED", "CLOSED": return .done
        case "OPEN": return .review
        default: return .active
        }
    }
}
