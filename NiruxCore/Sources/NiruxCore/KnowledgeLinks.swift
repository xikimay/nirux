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
    /// A brick's status with the bricks it rests on: one that stopped being
    /// served after the brick was last confirmed (validated or "Still
    /// True") flags it. Nil for a brick it doesn't hold.
    public func status(of id: String, now: TimeInterval, macOS: Int) -> BrickStatus? {
        chain(of: id, now: now, macOS: macOS, depth: 0)?.status
    }

    /// Its status, and when it stopped being served (nil while it is): a
    /// flagged brick takes its base's time, so confirming the brick on top
    /// clears it.
    func chain(of id: String, now: TimeInterval, macOS: Int, depth: Int) -> (status: BrickStatus, turned: TimeInterval?)? {
        guard let brick = bricks[id] else { return nil }
        let state = state(of: id)
        let own = brick.status(state, now: now, macOS: macOS)
        switch own {
        case .closed: return (own, state.closedAt ?? now)
        case .failing: return (own, state.failedAt ?? now)
        case .suspect: return (own, state.suspectAt ?? now)
        case .expired: return (own, state.expiredAt ?? brick.expiry(state) ?? now)
        case .flagged: return (own, now)
        case .open: break
        }
        guard depth < 16 else { return (own, nil) }
        let confirmed = state.reconfirmedAt ?? brick.validatedAt ?? 0
        for base in brick.restsOn ?? [] {
            // A base the space doesn't hold (a file lost) says nothing: the
            // brick's own proofs still decide.
            guard let (status, turned) = chain(of: base, now: now, macOS: macOS, depth: depth + 1) else { continue }
            guard let turned, turned > confirmed else { continue }
            return (.flagged("It rests on \(base), now \(status.title)" + (status.reason.map { ": \($0)" } ?? ".")), turned)
        }
        return (own, nil)
    }

    /// Until when, and on which macOS, the brick `id` may be served with
    /// the bricks it rests on: the soonest expiry, any macOS bound, down
    /// the chain.
    func servedBounds(of id: String, macOS current: Int, depth: Int = 0) -> (until: TimeInterval?, macOS: Int?) {
        guard let brick = bricks[id], depth < 16 else { return (nil, nil) }
        let state = state(of: id)
        var until = brick.expiry(state)
        var system = brick.macOS == nil ? nil : state.reconfirmedMacOS ?? brick.macOS
        for base in brick.restsOn ?? [] {
            let bounds = servedBounds(of: base, macOS: current, depth: depth + 1)
            until = [until, bounds.until].compactMap { $0 }.min()
            system = system ?? bounds.macOS
        }
        return (until, system)
    }

    /// The bricks resting on `id`.
    public func resting(on id: String) -> [String] {
        ordered.filter { $0.brick.restsOn?.contains(id) == true }.map(\.id)
    }
}
