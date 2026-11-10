import Foundation

/// Whether the user is in front of Nirux: Nirux is the active app, the
/// user's macOS session is in front (not switched to another account), and
/// the screen is awake and unlocked. A user who leaves any of these is away
/// until all of them hold again.
struct AwayTracker {
    enum Condition: Hashable, CaseIterable {
        case appActive, sessionActive, screenAwake, screenUnlocked
    }

    enum Change: Equatable {
        case wentAway
        /// Back after being away since then (epoch seconds).
        case cameBack(since: TimeInterval)
    }

    private var missing: Set<Condition>
    /// Since when the user is away; nil while they are in front.
    private(set) var awaySince: TimeInterval?

    /// `missing`: the conditions that don't hold at `now` (the app may
    /// start in the background, or in a session switched out).
    init(missing: Set<Condition> = [], now: TimeInterval) {
        self.missing = missing
        awaySince = missing.isEmpty ? nil : now
    }

    /// The conditions that don't hold at `now`, read again whole: the
    /// user went away, came back, or neither. Read whole, notifications
    /// that come late or out of order (a locked screen's, to an inactive
    /// app) can't leave one condition behind.
    mutating func update(missing now: Set<Condition>, at time: TimeInterval) -> Change? {
        let wasPresent = missing.isEmpty
        missing = now
        switch (wasPresent, missing.isEmpty) {
        case (true, false):
            awaySince = time
            return .wentAway
        case (false, true):
            defer { awaySince = nil }
            return awaySince.map { .cameBack(since: $0) }
        default:
            return nil
        }
    }
}
