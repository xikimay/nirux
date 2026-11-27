import Foundation

/// What rests on a brick (docs/design/knowledge-bricks.md, "Links"): a
/// brick through its `restsOn`, any other item (a brief rule, a team rule, a
/// memory) by citing the brick's id in its text. When a brick stops being
/// served, everything resting on it is flagged.
public enum KnowledgeLinks {
    static let idPattern = #"b-[0-9a-f]{12}"#

    public static func isBrickID(_ text: String) -> Bool {
        text.range(of: "^\(idPattern)$", options: .regularExpression) != nil
    }

    /// The brick ids `text` cites, in order, once each.
    public static func cited(in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: #"\b"# + idPattern + #"\b"#) else { return [] }
        var seen = Set<String>()
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { match in
            guard let range = Range(match.range, in: text) else { return nil }
            let id = String(text[range])
            return seen.insert(id).inserted ? id : nil
        }
    }
}

extension KnowledgeStore.Loaded {
    /// A brick's status with the bricks it rests on: one of them no longer
    /// served since the brick was last confirmed flags it. Nil for a brick
    /// it doesn't hold.
    public func status(of id: String, now: TimeInterval, macOS: Int) -> BrickStatus? {
        status(of: id, now: now, macOS: macOS, depth: 0)
    }

    func status(of id: String, now: TimeInterval, macOS: Int, depth: Int) -> BrickStatus? {
        guard let brick = bricks[id] else { return nil }
        let own = brick.status(state(of: id), now: now, macOS: macOS)
        guard own == .open, depth < 16 else { return own }
        let confirmed = state(of: id).reconfirmedAt ?? 0
        for base in brick.restsOn ?? [] {
            guard let status = status(of: base, now: now, macOS: macOS, depth: depth + 1) else {
                return .flagged("It rests on \(base), which this space no longer holds.")
            }
            guard status != .open, (turnedAt(base, status: status, now: now) ?? now) > confirmed else { continue }
            return .flagged("It rests on \(base), now \(status.title)" + (status.reason.map { ": \($0)" } ?? "."))
        }
        return own
    }

    /// When a brick that isn't served stopped being: its closing, failure,
    /// suspicion or expiry; for one flagged, nil (its base's time counts).
    func turnedAt(_ id: String, status: BrickStatus, now: TimeInterval) -> TimeInterval? {
        guard let brick = bricks[id] else { return nil }
        let state = state(of: id)
        switch status {
        case .open: return nil
        case .closed: return state.closedAt
        case .failing: return state.failedAt
        case .suspect: return state.suspectAt
        case .expired: return brick.expiry(state)
        case .flagged: return nil
        }
    }

    /// The bricks resting on `id`.
    public func resting(on id: String) -> [String] {
        ordered.filter { $0.brick.restsOn?.contains(id) == true }.map(\.id)
    }
}
