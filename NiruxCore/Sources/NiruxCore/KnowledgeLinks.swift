import Foundation

/// What rests on a brick (docs/design/knowledge-bricks.md, "Links"): a
/// brick through its `restsOn`, any other item (a brief rule, a team rule, a
/// memory) by citing the brick's id in its text. When a brick stops being
/// served, everything resting on it is flagged.
public enum KnowledgeLinks {
    static let idPattern = #"b-[0-9a-f]{12}"#

    public static func isBrickID(_ text: String) -> Bool {
        text.range(of: "^\(idPattern)\\z", options: .regularExpression) != nil
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
    /// served before the brick was last confirmed (validated or "Still
    /// True") no longer counts; one that stopped since flags it. Nil for a
    /// brick it doesn't hold.
    public func status(of id: String, now: TimeInterval, macOS: Int) -> BrickStatus? {
        var chains: [String: Chain] = [:]
        return chain(of: id, now: now, macOS: macOS, cache: &chains)?.status
    }

    /// When a brick stopped being served, as what rests on it compares: a
    /// moment, or the macOS version its bound gave out on.
    enum Stop: Equatable {
        case at(TimeInterval)
        case onMacOS(Int)
    }

    struct Chain {
        let status: BrickStatus
        /// Nil while it is served.
        let stop: Stop?
    }

    /// One result per brick within a call (`cache`): the chain is walked once.
    func chain(of id: String, now: TimeInterval, macOS: Int, cache: inout [String: Chain], depth: Int = 0) -> Chain? {
        if let known = cache[id] { return known }
        guard let brick = bricks[id] else { return nil }
        let state = state(of: id)
        let own = brick.status(state, now: now, macOS: macOS)
        let result: Chain
        switch own {
        case .closed: result = Chain(status: own, stop: .at(state.closedAt ?? 0))
        case .failing: result = Chain(status: own, stop: .at(state.failedAt ?? 0))
        case .suspect: result = Chain(status: own, stop: .at(state.suspectAt ?? 0))
        case .expired:
            let onMacOS = brick.macOS.map { (state.reconfirmedMacOS ?? $0) != macOS } ?? false
            result = Chain(status: own, stop: onMacOS ? .onMacOS(macOS) : .at(brick.expiry(state) ?? 0))
        case .open, .flagged:
            result = depth < 16 ? resting(brick, state: state, now: now, macOS: macOS, cache: &cache, depth: depth) : Chain(status: own, stop: nil)
        }
        cache[id] = result
        return result
    }

    /// An open brick with its bases: flagged by the first that stopped since
    /// it was last confirmed, taking that base's stop.
    private func resting(
        _ brick: KnowledgeBrick, state: BrickState, now: TimeInterval, macOS: Int, cache: inout [String: Chain], depth: Int
    ) -> Chain {
        let confirmedAt = state.reconfirmedAt ?? brick.validatedAt ?? 0
        for base in brick.restsOn ?? [] {
            // A base the space doesn't hold (a file lost) says nothing: the
            // brick's own proofs still decide.
            guard let chain = chain(of: base, now: now, macOS: macOS, cache: &cache, depth: depth + 1), let stop = chain.stop else { continue }
            switch stop {
            case .at(let time) where time <= confirmedAt: continue
            case .onMacOS(let version) where state.reconfirmedMacOS == version: continue
            default:
                return Chain(status: .flagged("It rests on \(base), now \(chain.status.title)" + (chain.status.reason.map { ": \($0)" } ?? ".")), stop: stop)
            }
        }
        return Chain(status: .open, stop: nil)
    }

    /// Until when, and on which macOS, the brick `id` may be served: its own
    /// bounds, and those of the bases still served (one it was confirmed
    /// past no longer bounds it), down the chain.
    func servedBounds(
        of id: String, now: TimeInterval, macOS: Int, chains: inout [String: Chain],
        memo: inout [String: (until: TimeInterval?, macOS: Int?)], depth: Int = 0
    ) -> (until: TimeInterval?, macOS: Int?) {
        if let known = memo[id] { return known }
        guard let brick = bricks[id], depth < 16 else { return (nil, nil) }
        let state = state(of: id)
        var until = brick.expiry(state)
        var system = brick.macOS == nil ? nil : state.reconfirmedMacOS ?? brick.macOS
        for base in brick.restsOn ?? [] where chain(of: base, now: now, macOS: macOS, cache: &chains)?.status == .open {
            let bounds = servedBounds(of: base, now: now, macOS: macOS, chains: &chains, memo: &memo, depth: depth + 1)
            until = [until, bounds.until].compactMap { $0 }.min()
            system = system ?? bounds.macOS
        }
        memo[id] = (until, system)
        return (until, system)
    }

    /// The bricks resting on `id`.
    public func resting(on id: String) -> [String] {
        ordered.filter { $0.brick.restsOn?.contains(id) == true }.map(\.id)
    }
}
