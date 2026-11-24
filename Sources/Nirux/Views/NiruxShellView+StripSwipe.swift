import AppKit
import WebKit

/// Two fingers over the columns, as in a scrolling window manager. Sideways,
/// they slide the strip (`StripSwipe`), when what lies under them can't
/// scroll that way and System Settings' "Swipe between pages" scrolls with
/// two fingers. Double-tapping, they fit a column to the window.
extension NiruxShellView {
    /// The window's scroll events, before the view under the pointer: true
    /// when the strip takes this one.
    func scrolled(_ event: NSEvent) -> Bool {
        guard event.window === window, let superview else { return false }
        return scrolled(StripSwipe.Scroll(event), over: self.hitTest(superview.convert(event.locationInWindow, from: nil)))
    }

    /// `hit`: the view under the fingers, read when a gesture begins.
    func scrolled(_ scroll: StripSwipe.Scroll, over hit: @autoclosure () -> NSView?) -> Bool {
        if !scroll.phase.isDisjoint(with: [.mayBegin, .began]) {
            letGoOfStrip()
            stripSwipe = scroll.phase.contains(.began) ? swipe(at: scroll.time, over: hit()) : nil
        }
        guard var swipe = stripSwipe else { return false }
        guard let workspace = activeWorkspace, workspace.columns.map(\.id) == swipe.columns else {
            letGoOfStrip()
            return false
        }
        let step = swipe.scrolled(scroll)
        stripSwipe = swipe
        apply(step, to: workspace)
        return step != .pass
    }

    /// A scroll the views under the pointer left (a web page's, see
    /// `WKWebView.passOnUnhandled`): what lies under the fingers can't
    /// scroll that way.
    func contentLeft(at time: TimeInterval) {
        guard var swipe = stripSwipe, let workspace = activeWorkspace, workspace.columns.map(\.id) == swipe.columns else { return }
        let step = swipe.declined(at: time)
        stripSwipe = swipe
        apply(step, to: workspace)
    }

    /// Two fingers double-tapping a column whose content leaves them (a
    /// terminal does, and a page that doesn't zoom): the column takes the
    /// focus and fills the window or, filling it, goes back to its width.
    /// False away from the columns.
    func fitColumn(at point: NSPoint) -> Bool {
        guard let workspace = activeWorkspace, viewport.frame.contains(convert(point, from: nil)),
              let index = workspace.columns.firstIndex(where: { !$0.isClosing && $0.view.bounds.contains($0.view.convert(point, from: nil)) })
        else { return false }
        workspace.columns[index].toggleFit()
        if index == workspace.focusedIndex { relayout(animated: true) } else { focusColumnByIndex(index) }
        redrawTerminalsOnceSettled()
        return true
    }

    /// What the content under the fingers can do sideways, from `view` up
    /// to the workspace. A scroll view can while it isn't at that end. A web
    /// page says so itself, but for the history its own swipe goes through.
    static func reach(under view: NSView, in workspace: NSView) -> (toStart: StripSwipe.Reach, toEnd: StripSwipe.Reach) {
        var reach = (toStart: StripSwipe.Reach.cannot, toEnd: StripSwipe.Reach.cannot)
        for view in sequence(first: view, next: \.superview).prefix(while: { $0 !== workspace }) {
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
            glideStrip(of: workspace, fromCamera: camera, velocity: velocity)
        }
    }

    /// The fingers' glide off the strip, while the interface may move; else
    /// the strip is at its place at once.
    private func glideStrip(of workspace: WorkspaceState, fromCamera x: CGFloat, velocity: CGFloat) {
        guard agentLightsMayMove else { return workspace.endSlide() }
        workspace.glideStrip(fromCamera: x, velocity: velocity)
    }

    /// A swipe gone before its end (another workspace on screen, a card
    /// added or closed, fingers down again): the camera goes where the strip
    /// wants it.
    private func letGoOfStrip() {
        guard let swipe = stripSwipe else { return }
        stripSwipe = nil
        let held = workspaces.filter { $0.columns.contains { swipe.columns.contains($0.id) } && $0.heldCamera?.isDrag == true }
        guard swipe.holdsCamera, !held.isEmpty else { return }
        for workspace in held { workspace.heldCamera = nil }
        relayout(animated: true)
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
