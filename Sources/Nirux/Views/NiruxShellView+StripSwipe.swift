import AppKit
import GhosttyTerminal
import WebKit

/// Two fingers over the columns, as in a scrolling window manager. Sideways,
/// they slide the strip (`StripSwipe`), when what lies under them can't
/// scroll that way and System Settings' "Swipe between pages" scrolls with
/// two fingers. Double-tapping, they fit a column to the window.
extension NiruxShellView {
    /// The window's scroll events, before the view under the pointer: true
    /// when the strip takes this one.
    func scrolled(_ event: NSEvent) -> Bool {
        guard event.window === window, let superview else {
            // Fingers down over another window: a swipe whose end never came lets go.
            if !event.phase.isDisjoint(with: [.mayBegin, .began]) { letGoOfStrip() }
            return false
        }
        return scrolled(StripSwipe.Scroll(event), over: self.hitTest(superview.convert(event.locationInWindow, from: nil)))
    }

    /// `hit`: the view under the fingers, read when a gesture begins.
    func scrolled(_ scroll: StripSwipe.Scroll, over hit: @autoclosure () -> NSView?) -> Bool {
        if scroll.phase == .mayBegin || scroll.phase == .began {
            letGoOfStrip()
            stripSwipe = scroll.phase == .began ? swipe(at: scroll.time, over: hit()) : nil
        }
        guard var swipe = stripSwipe else { return false }
        guard let workspace = activeWorkspace, workspace.columns.map(\.id) == swipe.columns else {
            // The cards changed under the fingers.
            letGoOfStrip()
            return false
        }
        let step = swipe.scrolled(scroll)
        stripSwipe = swipe.isOver ? nil : swipe
        apply(step, to: workspace)
        return step != .pass
    }

    /// A scroll the views under the pointer left (a web page's, see
    /// `WKWebView.passOnUnhandled`): what lies under the fingers can't
    /// scroll that way.
    func contentLeft(_ scroll: StripSwipe.Scroll) {
        guard var swipe = stripSwipe, let workspace = activeWorkspace, workspace.columns.map(\.id) == swipe.columns else { return }
        let step = swipe.declined(scroll)
        stripSwipe = swipe
        apply(step, to: workspace)
    }

    /// Two fingers double-tapping a column whose content leaves them (a
    /// terminal does, and a page that doesn't zoom): the column takes the
    /// focus and fills the window or, filling it, goes back to its width.
    /// False over anything else (the sidebar, the space plan).
    func fitColumn(over hit: NSView?) -> Bool {
        guard let workspace = activeWorkspace, let hit,
              let index = workspace.columns.firstIndex(where: { !$0.isClosing && hit.isDescendant(of: $0.view) })
        else { return false }
        workspace.columns[index].toggleFit()
        if index == workspace.focusedIndex { relayout(animated: true) } else { focusColumnByIndex(index) }
        redrawTerminalsOnceSettled()
        return true
    }

    /// What the content under the fingers can do sideways, from `view` up
    /// to the workspace. A scroll view can while it isn't at that end, and
    /// a terminal while its program owns the mouse (vim, tmux). A web page
    /// says so itself, but for the history its own swipe goes through.
    static func reach(
        under view: NSView, in workspace: NSView, ownsMouse: @MainActor (TerminalView) -> Bool = { $0.isMouseCaptured }
    ) -> (toStart: StripSwipe.Reach, toEnd: StripSwipe.Reach) {
        var reach = (toStart: StripSwipe.Reach.cannot, toEnd: StripSwipe.Reach.cannot)
        for view in sequence(first: view, next: \.superview).prefix(while: { $0 !== workspace }) {
            if let terminal = view as? TerminalView, ownsMouse(terminal) { return (.can, .can) }
            if let web = view as? WKWebView {
                let history = web.allowsBackForwardNavigationGestures
                return (history && web.canGoBack ? .can : .asks, history && web.canGoForward ? .can : .asks)
            }
            if let scroll = view as? NSScrollView, let document = scroll.documentView {
                let shown = scroll.contentView.bounds
                if shown.minX > document.frame.minX + 0.5 { reach.toStart = .can }
                if shown.maxX < document.frame.maxX - 0.5 { reach.toEnd = .can }
            }
        }
        return reach
    }

    private func swipe(at time: TimeInterval, over hit: NSView?) -> StripSwipe? {
        guard sideEffects.swipesBetweenPages(), let workspace = activeWorkspace, !workspace.columns.isEmpty,
              let hit, hit.isDescendant(of: workspace.containerView) else { return nil }
        let viewport = workspace.containerView.bounds.width
        let widths = workspace.columnFrames.map(\.width)
        return StripSwipe(
            began: time, reach: Self.reach(under: hit, in: workspace.containerView), camera: workspace.shownCameraX,
            stops: widths.indices.map { WorkspaceState.camera(for: widths, focus: $0, viewport: viewport) },
            focus: workspace.focusedIndex, viewport: viewport, columns: workspace.columns.map(\.id)
        )
    }

    private func apply(_ step: StripSwipe.Step, to workspace: WorkspaceState) {
        switch step {
        case .pass, .swallow:
            return
        case .follow(let camera):
            // The lights and the agents in view follow at the settle's layout.
            workspace.holdCamera(at: camera)
        case .settle(let index, let camera, let velocity):
            workspace.heldCamera = nil
            if index == workspace.focusedIndex { relayout(animated: true) } else { focusColumnByIndex(index) }
            // The layout's pass under the rail lasts as long as the glide.
            if let glide = workspace.glideStrip(fromCamera: camera, velocity: velocity, moves: agentLightsMayMove),
               passingUnderRail === workspace {
                passUnderRail(workspace, for: glide)
            }
        }
    }

    /// The workspace whose camera the fingers hold.
    var swipedWorkspace: WorkspaceState? {
        guard let swipe = stripSwipe, swipe.holdsCamera else { return nil }
        return workspaces.first { $0.columns.contains { swipe.columns.contains($0.id) } }
    }

    /// A swipe gone before its end (fingers down again, the cards changed):
    /// the camera goes where the strip wants it.
    private func letGoOfStrip() {
        let held = swipedWorkspace
        stripSwipe = nil
        guard let held else { return }
        held.heldCamera = nil
        relayout(animated: true)
    }
}

extension StripSwipe.Scroll {
    init(_ event: NSEvent) {
        let phase: Phase = if !event.momentumPhase.isDisjoint(with: [.ended, .cancelled]) {
            .momentumEnded
        } else if !event.momentumPhase.isEmpty {
            .momentum
        } else if event.phase.contains(.mayBegin) {
            .mayBegin
        } else if event.phase.contains(.began) {
            .began
        } else if event.phase.contains(.ended) {
            .ended
        } else if event.phase.contains(.cancelled) {
            .cancelled
        } else {
            event.phase.isEmpty ? .none : .changed
        }
        self.init(dx: event.scrollingDeltaX, dy: event.scrollingDeltaY, phase: phase, time: event.timestamp)
    }
}

/// A page in a column leaves the strip a sideways swipe it can't scroll:
/// WebKit reports it unhandled, and the web view passes it up the responder
/// chain, as a scroll view passes one it can't take.
extension WKWebView {
    /// Bounces only at its top and bottom (`_rubberBandingEnabled`,
    /// WKWebViewPrivate.h): a page that can't scroll further sideways then
    /// leaves the scroll unhandled instead of rubber-banding.
    func bouncesOnlyVertically() {
        let setter = NSSelectorFromString("_setRubberBandingEnabled:")
        guard responds(to: setter) else { return }
        typealias SetEdges = @convention(c) (AnyObject, Selector, UInt) -> Void
        unsafeBitCast(method(for: setter), to: SetEdges.self)(self, setter, Self.verticalEdges)
    }

    /// `_WKRectEdge`'s top and bottom.
    static let verticalEdges: UInt = 1 << 1 | 1 << 3

    /// A scroll the page left (`_webView:didNotHandleWheelEvent:`).
    func passOnUnhandled(_ event: NSEvent) {
        nextResponder?.scrollWheel(with: event)
    }
}
