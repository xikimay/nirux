import AppKit

/// Two fingers scrolling over the columns, from the gesture's `.began` to the
/// end of its momentum. The content under the fingers keeps the gesture when
/// it can scroll the way they go. Otherwise, once they go clearly sideways,
/// the strip follows them, past its ends with a rubber band, and settles on
/// the card their speed carries it to.
struct StripSwipe {
    /// A scroll event as the swipe reads it: `scrollingDelta`, phases, time.
    struct Scroll {
        var dx: CGFloat
        var dy: CGFloat
        var phase: NSEvent.Phase
        var momentum: NSEvent.Phase = []
        var time: TimeInterval

        init(dx: CGFloat, dy: CGFloat = 0, phase: NSEvent.Phase, momentum: NSEvent.Phase = [], time: TimeInterval) {
            (self.dx, self.dy, self.phase, self.momentum, self.time) = (dx, dy, phase, momentum, time)
        }

        init(_ event: NSEvent) {
            self.init(
                dx: event.scrollingDeltaX, dy: event.scrollingDeltaY,
                phase: event.phase, momentum: event.momentumPhase, time: event.timestamp
            )
        }
    }

    /// Whether the content under the fingers can scroll further one way. A
    /// web page `asks`: it says so itself, leaving an event it can't take
    /// (`declined(at:)`).
    enum Reach { case can, cannot, asks }

    /// What the strip does with a scroll event.
    enum Step: Equatable {
        /// Nothing: the content has the event.
        case pass
        /// The strip has it, its camera at `camera`.
        case follow(camera: CGFloat)
        /// The fingers left: the strip glides from `camera`, at `velocity`
        /// camera points a second, to the card at `index`.
        case settle(index: Int, camera: CGFloat, velocity: CGFloat)
        /// The momentum of a swipe the strip had.
        case swallow
    }

    /// How far the fingers go before the swipe knows which way they mean.
    static let intent: CGFloat = 6
    /// How far back the fingers' speed is read.
    static let speedWindow: TimeInterval = 0.08
    /// How far the fingers' speed at release carries the strip: as far as
    /// that speed goes in this time.
    static let carry: TimeInterval = 0.2

    private enum Owner { case undecided, content, strip }
    private var owner = Owner.undecided
    private var settled = false
    private var declined = false
    private var moved = CGVector.zero
    private var latest: TimeInterval
    /// The camera before the rubber band, over the last `speedWindow`.
    private var samples: [(time: TimeInterval, camera: CGFloat)]

    let began: TimeInterval
    /// Toward the strip's start (`dx` > 0: what lies left comes into view)
    /// and toward its end.
    let reach: (toStart: Reach, toEnd: Reach)
    /// The camera where the swipe found it, before the rubber band: a strip
    /// caught on its way back from past an end goes on from where it shows.
    let start: CGFloat
    /// Each card's camera (`WorkspaceState.camera(for:focus:viewport:)`).
    let stops: [CGFloat]
    let focus: Int
    let viewport: CGFloat
    /// The cards the stops are for.
    let columns: [UUID]

    init(
        began: TimeInterval, reach: (toStart: Reach, toEnd: Reach), camera: CGFloat,
        stops: [CGFloat], focus: Int, viewport: CGFloat, columns: [UUID] = []
    ) {
        (self.began, self.latest, self.reach) = (began, began, reach)
        (self.stops, self.focus, self.viewport, self.columns) = (stops, focus, viewport, columns)
        let low = stops.min() ?? camera, high = stops.max() ?? camera
        let held = min(max(camera, low), high)
        start = held + Self.unband(camera - held, viewport: viewport)
        samples = [(began, start)]
    }

    /// Whether the strip has the swipe.
    var isStrips: Bool { owner == .strip }
    /// Whether the fingers hold the strip.
    var holdsCamera: Bool { owner == .strip && !settled }

    /// The strip lets go before the swipe's end: nothing more of it moves it.
    mutating func letGo() {
        settled = true
    }

    mutating func scrolled(_ scroll: Scroll) -> Step {
        // A mouse's wheel has no phase: the content's.
        guard !scroll.phase.isEmpty || !scroll.momentum.isEmpty else { return .pass }
        guard scroll.momentum.isEmpty else { return owner == .strip ? .swallow : .pass }
        latest = max(latest, scroll.time)
        let lifted = !scroll.phase.isDisjoint(with: [.ended, .cancelled])
        switch owner {
        case .content:
            return .pass
        case .undecided:
            moved.dx += scroll.dx
            moved.dy += scroll.dy
            guard !lifted else {
                owner = .content
                return .pass
            }
            decide()
            return owner == .strip ? follow() : .pass
        case .strip:
            guard !settled else { return .swallow }
            moved.dx += scroll.dx
            return lifted ? settle(cancelled: scroll.phase.contains(.cancelled)) : follow()
        }
    }

    /// The content left an event of the swipe (WebKit didn't handle it): it
    /// can't scroll that way, so the strip may take the swipe at once.
    mutating func declined(at time: TimeInterval) -> Step {
        guard time >= began, owner == .undecided else { return .pass }
        declined = true
        decide()
        return owner == .strip ? follow() : .pass
    }

    private mutating func decide() {
        guard max(abs(moved.dx), abs(moved.dy)) >= Self.intent else { return }
        guard abs(moved.dx) >= 2 * abs(moved.dy) else {
            owner = .content
            return
        }
        switch moved.dx > 0 ? reach.toStart : reach.toEnd {
        case .can: owner = .content
        case .cannot: owner = .strip
        case .asks: if declined { owner = .strip }
        }
    }

    private var camera: CGFloat { start - moved.dx }

    private mutating func follow() -> Step {
        samples.append((latest, camera))
        if let old = samples.lastIndex(where: { $0.time <= latest - Self.speedWindow }), old > 0 {
            samples.removeFirst(old)
        }
        return .follow(camera: shown(camera))
    }

    /// Where the fingers leave the strip, their speed carrying it on; a
    /// cancelled swipe goes back to the card it started on.
    private mutating func settle(cancelled: Bool) -> Step {
        _ = follow()
        settled = true
        let first = samples[0], last = samples[samples.count - 1]
        let span = last.time - first.time
        let speed = span > 0 ? (last.camera - first.camera) / span : 0
        let shownSpeed = span > 0 ? (shown(last.camera) - shown(first.camera)) / span : 0
        let index = cancelled ? focus : Self.stop(nearest: camera + speed * Self.carry, in: stops, focus: focus)
        return .settle(index: index, camera: shown(camera), velocity: cancelled ? 0 : shownSpeed)
    }

    /// The card whose camera lies nearest `camera`; of cards sharing it (at
    /// a strip's end), the one nearest `focus`.
    static func stop(nearest camera: CGFloat, in stops: [CGFloat], focus: Int) -> Int {
        let distance = { (index: Int) in abs(stops[index] - camera) }
        guard let nearest = stops.indices.map(distance).min() else { return focus }
        return stops.indices.filter { distance($0) == nearest }.min { abs($0 - focus) < abs($1 - focus) } ?? focus
    }

    /// The camera shown for `camera`: past the stops, a rubber band.
    private func shown(_ camera: CGFloat) -> CGFloat {
        let low = stops.min() ?? start, high = stops.max() ?? start
        let held = min(max(camera, low), high)
        return held + Self.band(camera - held, viewport: viewport)
    }

    /// How far a strip pulled `past` its end shows past it: less and less,
    /// never a viewport.
    static func band(_ past: CGFloat, viewport: CGFloat) -> CGFloat {
        let reach = max(viewport, 1)
        let shown = (1 - 1 / (abs(past) * 0.55 / reach + 1)) * reach
        return past < 0 ? -shown : shown
    }

    /// How far past its end a strip shown `shown` past it was pulled.
    static func unband(_ shown: CGFloat, viewport: CGFloat) -> CGFloat {
        let reach = max(viewport, 1), distance = min(abs(shown), reach - 1)
        let past = distance * reach / ((reach - distance) * 0.55)
        return shown < 0 ? -past : past
    }
}
