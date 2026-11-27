import Foundation

/// What changes about a space's bricks, beside the files that never do:
/// each brick's last check, its closing or suspicion, its reconfirmation;
/// the proposals waiting for the user. `<space dir>/knowledge/state.json`.
public struct KnowledgeState: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1
    public var schemaVersion = currentSchemaVersion
    public var bricks: [String: BrickState] = [:]
    public var proposals: [BrickProposal] = []
    /// Per anchor, the base commit its bricks were last checked at.
    public var checkedTips: [String: String] = [:]
    /// The last check that read pages too.
    public var dailyCheckAt: TimeInterval?

    public init() {}
}

public struct BrickState: Codable, Equatable, Sendable {
    public var checkedAt: TimeInterval?
    /// The base commit its proofs held at.
    public var checkedTip: String?
    public var closedAt: TimeInterval?
    public var closedBecause: String?
    public var replacedBy: String?
    public var suspectAt: TimeInterval?
    public var suspectBecause: String?
    public var reconfirmedAt: TimeInterval?
    /// The macOS major version it was last reconfirmed on.
    public var reconfirmedMacOS: Int?

    public init() {}
}

/// A brick as agents may get it now.
public enum BrickStatus: Equatable, Sendable {
    case open
    /// No check can contradict it any more: served again once reconfirmed.
    case expired(String)
    /// Someone may have proven it wrong: served again once reconfirmed.
    case suspect(String)
    /// A proof stopped holding, or the user closed it: for good.
    case closed(String)

    public var isServed: Bool { self == .open }

    public var title: String {
        switch self {
        case .open: return "brick"
        case .expired: return "expired"
        case .suspect: return "suspect"
        case .closed: return "closed"
        }
    }

    public var reason: String? {
        switch self {
        case .open: return nil
        case .expired(let reason), .suspect(let reason), .closed(let reason): return reason
        }
    }
}

extension KnowledgeBrick {
    /// How long a brick no check can contradict is served after its
    /// validation or last reconfirmation.
    public static let lifetime: TimeInterval = 90 * 86_400

    /// When it stops being served unless reconfirmed; nil while a proof is
    /// checked again.
    public func expiry(_ state: BrickState) -> TimeInterval? {
        guard !isRechecked else { return nil }
        return (state.reconfirmedAt ?? validatedAt ?? 0) + Self.lifetime
    }

    public func status(_ state: BrickState, now: TimeInterval, macOS: Int) -> BrickStatus {
        if state.closedAt != nil { return .closed(state.closedBecause ?? "Closed.") }
        if state.suspectAt != nil { return .suspect(state.suspectBecause ?? "Suspect.") }
        if let confirmed = state.reconfirmedMacOS ?? self.macOS, confirmed != macOS {
            return .expired("Confirmed on macOS \(confirmed): confirm it still holds on macOS \(macOS).")
        }
        if let expiry = expiry(state), now >= expiry {
            return .expired("No check can contradict it, and \(Int(Self.lifetime / 86_400)) days went by: confirm it still holds.")
        }
        return .open
    }
}

/// A brick an agent proposed, waiting for the user; then what they decided,
/// kept a while so the same one isn't proposed again.
public struct BrickProposal: Codable, Equatable, Sendable {
    public var brick: KnowledgeBrick
    public var proposedAt: TimeInterval
    /// The Lead that proposed it.
    public var leadWorkspaceID: String?
    public var leadAgentUUID: String?
    public var dismissedAt: TimeInterval?
    public var validatedAt: TimeInterval?

    public init(brick: KnowledgeBrick, proposedAt: TimeInterval, leadWorkspaceID: String? = nil, leadAgentUUID: String? = nil) {
        self.brick = brick
        self.proposedAt = proposedAt
        self.leadWorkspaceID = leadWorkspaceID
        self.leadAgentUUID = leadAgentUUID
    }

    public var id: String { brick.id }
    public var isPending: Bool { dismissedAt == nil && validatedAt == nil }
    public var decidedAt: TimeInterval? { dismissedAt ?? validatedAt }
}
