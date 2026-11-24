import Foundation

/// What Nirux offers a Claude session at rest whose context costs to go
/// on with: a compaction, or a fresh start with a handover. Heavy from
/// `UsageSummary.heavyContextTokens`; cold once idle past Claude Code's
/// hour-long cache, from `coldContextTokens`: its next message writes the
/// whole context again.
public struct ContextOffer: Hashable, Sendable {
    public enum Reason: Hashable, Sendable { case heavy, cold }
    public enum Choice: String, Hashable, Sendable { case compact, freshStart }

    public var reason: Reason
    public var contextTokens: Int
    /// Its latest response: a later one offers again.
    public var lastResponseAt: TimeInterval

    public static let coldContextTokens = 150_000

    public init(reason: Reason, contextTokens: Int, lastResponseAt: TimeInterval) {
        self.reason = reason
        self.contextTokens = contextTokens
        self.lastResponseAt = lastResponseAt
    }

    /// Nil under both thresholds, and for another agent's session.
    public init?(_ session: UsageReport.LatestSession, now: TimeInterval) {
        guard session.key.agent == .claude, let context = session.contextTokens else { return nil }
        let reason: Reason
        if now - session.lastResponseAt >= UsageSummary.hourCacheLifetime, context >= Self.coldContextTokens {
            reason = .cold
        } else if context >= UsageSummary.heavyContextTokens {
            reason = .heavy
        } else {
            return nil
        }
        self.init(reason: reason, contextTokens: context, lastResponseAt: session.lastResponseAt)
    }
}
