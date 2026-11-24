import AppKit
import WebKit
import XCTest
@testable import Nirux

/// Two fingers over a real shell's columns: sideways they slide the strip
/// and settle on a card, as System Settings allows; what can scroll keeps
/// them; double-tapping fits a column to the window.
@MainActor
final class StripSwipeShellTests: XCTestCase {
    private func withShell(
        reducesMotion: Bool = false, _ body: (NiruxShellView, WorkspaceState) throws -> Void
    ) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("nirux-swipe-\(UUID().uuidString)").path
        let stateDirectory = root + "/state"
        try FileManager.default.createDirectory(atPath: stateDirectory, withIntermediateDirectories: true)
        let previousStateDirectory = ProcessInfo.processInfo.environment["NIRUX_STATE_DIR"]
        setenv("NIRUX_STATE_DIR", stateDirectory, 1)
        defer {
            if let previousStateDirectory {
                setenv("NIRUX_STATE_DIR", previousStateDirectory, 1)
            } else {
                unsetenv("NIRUX_STATE_DIR")
            }
            try? FileManager.default.removeItem(atPath: root)
        }

        _ = NSApplication.shared
        try autoreleasepool {
            let shell = NiruxShellView(frame: NSRect(x: 0, y: 0, width: 1200, height: 800))
            shell.stopHeartbeat()
            shell.sideEffects.windowShows = { _ in true }
            shell.sideEffects.reducesMotion = { reducesMotion }
            shell.sideEffects.swipesBetweenPages = { true }
            shell.sideEffects.watchScrolls = { _ in nil }
            shell.agentLights.isDisplayAsleep = false
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800),
                styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false
            )
            window.isReleasedWhenClosed = false
            window.contentView = shell
            defer { window.close() }
            // Six cards, each 0.4 of the viewport, the second one focused.
            let workspace = try XCTUnwrap(shell.activeWorkspace)
            for _ in 0..<5 { workspace.addColumn() }
            for column in workspace.columns { column.widthFraction = 0.4 }
            workspace.focusedIndex = 1
            shell.relayout(animated: false)
            try body(shell, workspace)
        }
    }

    private func camera(_ workspace: WorkspaceState, focus: Int) -> CGFloat {
        WorkspaceState.camera(for: workspace.columnFrames.map(\.width), focus: focus, viewport: workspace.containerView.bounds.width)
    }

    private func terminal(_ workspace: WorkspaceState, _ index: Int) throws -> NSView {
        try XCTUnwrap(workspace.columns[index].terminalView)
    }

    private func strip(_ workspace: WorkspaceState) throws -> CALayer {
        try XCTUnwrap(workspace.columns.first?.view.superview?.layer)
    }

    /// The fingers' steps over `hit`, `dx` each, one every 0.01 s from
    /// `start`, the first beginning the gesture when `start` is 0; then the
    /// lift when `lifts`. What the shell took.
    @discardableResult
    private func swipe(
        _ shell: NiruxShellView, over hit: NSView?, _ dx: [CGFloat], from start: TimeInterval = 0, lifts: Bool = true
    ) -> [Bool] {
        var taken = dx.enumerated().map { index, dx in
            let time = start + TimeInterval(index) * 0.01
            return shell.scrolled(.init(dx: dx, phase: index == 0 && start == 0 ? .began : .changed, time: time), over: hit)
        }
        if lifts {
            taken.append(shell.scrolled(.init(dx: 0, phase: .ended, time: start + TimeInterval(dx.count) * 0.01), over: hit))
        }
        return taken
    }

    func testFingersOverATerminalSlideTheStripAndSettleOnACard() throws {
        try withShell { shell, workspace in
            let start = camera(workspace, focus: 1)
            XCTAssertEqual(workspace.lastCameraX, start)
            let hit = try terminal(workspace, 1)
            XCTAssertEqual(swipe(shell, over: hit, [-4, -20], lifts: false), [false, true])
            XCTAssertEqual(workspace.lastCameraX, start + 24, "the strip under the fingers")
            XCTAssertEqual(workspace.heldCamera?.isDrag, true)
            // A layout meanwhile (the metadata refresh's) leaves it there.
            shell.relayout(animated: false)
            XCTAssertEqual(workspace.lastCameraX, start + 24)

            // A flick: the next card, the strip gliding there on a spring.
            XCTAssertTrue(swipe(shell, over: hit, Array(repeating: -10, count: 10), from: 0.02).allSatisfy { $0 })
            XCTAssertEqual(workspace.focusedIndex, 2)
            XCTAssertNil(workspace.heldCamera)
            XCTAssertEqual(workspace.lastCameraX, camera(workspace, focus: 2))
            let glide = try XCTUnwrap(try strip(workspace).animation(forKey: "colSlide") as? CASpringAnimation)
            // From where the fingers left it, still going that way.
            XCTAssertEqual((glide.fromValue as? NSNumber)?.doubleValue, Double(camera(workspace, focus: 2) - (start + 124)))
            XCTAssertGreaterThan(glide.initialVelocity, 0)
            XCTAssertTrue(shell.scrolled(.init(dx: -40, phase: [], momentum: .began, time: 0.2), over: hit), "its momentum")
            XCTAssertEqual(workspace.focusedIndex, 2)
        }
    }

    /// Lifted just short of its card at speed, the strip leaves no faster
    /// than its spring's pace, which would carry it past the card.
    func testTheGlideNeverPassesItsCard() throws {
        try withShell { _, workspace in
            workspace.glideStrip(fromCamera: camera(workspace, focus: 1) - 10, velocity: 1000, moves: true)
            let glide = try XCTUnwrap(try strip(workspace).animation(forKey: "colSlide") as? CASpringAnimation)
            XCTAssertEqual(glide.initialVelocity, 2 * .pi / WorkspaceState.slideDuration, accuracy: 0.000_1)
        }
    }

    func testWithReduceMotionTheStripIsAtItsCardAtOnce() throws {
        try withShell(reducesMotion: true) { shell, workspace in
            swipe(shell, over: try terminal(workspace, 1), Array(repeating: -10, count: 10))
            XCTAssertEqual(workspace.focusedIndex, 2)
            XCTAssertNil(try strip(workspace).animation(forKey: "colSlide"))
        }
    }

    func testTheSwipeFollowsSwipeBetweenPages() throws {
        try withShell { shell, workspace in
            shell.sideEffects.swipesBetweenPages = { false }
            XCTAssertEqual(swipe(shell, over: try terminal(workspace, 1), Array(repeating: -15, count: 10)), Array(repeating: false, count: 11))
            XCTAssertEqual(workspace.focusedIndex, 1)
            XCTAssertNil(workspace.heldCamera)
        }
    }

    func testOnlyFingersOverTheColumnsSwipe() throws {
        try withShell { shell, workspace in
            XCTAssertEqual(swipe(shell, over: shell.sidebar, [-20, -20], lifts: false), [false, false])
            XCTAssertNil(workspace.heldCamera)
        }
    }

    /// A card closed, or fingers down again before the end came: the strip
    /// lets go and the camera goes back where it wants.
    func testASwipeGoneBeforeItsEndLetsGoOfTheStrip() throws {
        try withShell { shell, workspace in
            let hit = try terminal(workspace, 1)
            swipe(shell, over: hit, [-20, -20], lifts: false)
            XCTAssertNotNil(workspace.heldCamera)
            XCTAssertFalse(shell.scrolled(.init(dx: 0, phase: .mayBegin, time: 1), over: hit))
            XCTAssertNil(workspace.heldCamera)
            XCTAssertEqual(workspace.lastCameraX, camera(workspace, focus: 1))

            swipe(shell, over: hit, [-20, -20], from: 0, lifts: false)
            XCTAssertNotNil(workspace.heldCamera)
            workspace.addColumn()
            XCTAssertTrue(shell.scrolled(.init(dx: -20, phase: .changed, time: 0.03), over: hit), "the rest stays the strip's")
            XCTAssertNil(workspace.heldCamera)
            XCTAssertTrue(shell.scrolled(.init(dx: -20, phase: [], momentum: .began, time: 0.04), over: hit))

            // Fingers down over another window.
            swipe(shell, over: try terminal(workspace, 1), [-20, -20], from: 0, lifts: false)
            XCTAssertNotNil(workspace.heldCamera)
            XCTAssertFalse(shell.scrolled(try scrollEvent(phase: 128)))
            XCTAssertNil(workspace.heldCamera)
        }
    }

    /// A program that owns the mouse (vim, tmux) keeps a sideways scroll.
    func testATerminalWhoseProgramOwnsTheMouseKeepsTheSwipe() throws {
        try withShell { _, workspace in
            let terminal = try terminal(workspace, 1)
            let owned = NiruxShellView.reach(under: terminal, in: workspace.containerView) { _ in true }
            XCTAssertEqual(owned.toStart, .can)
            XCTAssertEqual(owned.toEnd, .can)
            let plain = NiruxShellView.reach(under: terminal, in: workspace.containerView)
            XCTAssertEqual(plain.toStart, .cannot)
            XCTAssertEqual(plain.toEnd, .cannot)
        }
    }

    /// A page leaves the scroll it can't take (WebKit's report, passed up
    /// the responder chain): the strip takes the swipe then.
    func testAPageThatLeavesTheScrollGivesTheSwipeToTheStrip() throws {
        try withShell { shell, workspace in
            let page = WKWebView(frame: NSRect(x: 0, y: 0, width: 200, height: 200))
            workspace.columns[1].view.addSubview(page)
            let reach = NiruxShellView.reach(under: page, in: workspace.containerView)
            XCTAssertEqual(reach.toStart, .asks)
            XCTAssertEqual(reach.toEnd, .asks)
            let start = camera(workspace, focus: 1)
            XCTAssertEqual(swipe(shell, over: page, [-20, -20], lifts: false), [false, false])
            XCTAssertNil(workspace.heldCamera)

            page.passOnUnhandled(try scrollEvent(phase: 2))
            XCTAssertEqual(workspace.lastCameraX, start + 40, "caught up with the fingers")
            XCTAssertTrue(shell.scrolled(.init(dx: -10, phase: .changed, time: 0.03), over: page))
            XCTAssertEqual(workspace.lastCameraX, start + 50)
        }
    }

    func testEveryPageInAColumnLeavesWhatItCantScroll() throws {
        let browser = WebViewColumn(url: "file:///dev/null", dataStore: .nonPersistent(), isolatedWorkspaceID: UUID().uuidString)
        let editor = EditorColumn(workspaceCwd: NSTemporaryDirectory())
        for view in [browser, editor] as [NSView] {
            let page = try XCTUnwrap(Self.page(in: view), "\(type(of: view))")
            XCTAssertEqual((page.value(forKey: "_rubberBandingEnabled") as? NSNumber)?.uintValue, WKWebView.verticalEdges, "\(type(of: view))")
            let delegate = try XCTUnwrap(page.uiDelegate as? NSObject, "\(type(of: view))")
            XCTAssertTrue(delegate.responds(to: NSSelectorFromString("_webView:didNotHandleWheelEvent:")), "\(type(of: view))")
        }
        XCTAssertTrue(BranchReviewView.instancesRespond(to: NSSelectorFromString("_webView:didNotHandleWheelEvent:")))
    }

    func testAScrollViewKeepsWhatItCanScroll() {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        let scroll = NSScrollView(frame: container.bounds)
        let document = NSView(frame: NSRect(x: 0, y: 0, width: 1200, height: 300))
        scroll.documentView = document
        container.addSubview(scroll)
        var reach = NiruxShellView.reach(under: document, in: container)
        XCTAssertEqual(reach.toStart, .cannot)
        XCTAssertEqual(reach.toEnd, .can)
        scroll.contentView.scroll(to: NSPoint(x: 800, y: 0))
        reach = NiruxShellView.reach(under: document, in: container)
        XCTAssertEqual(reach.toStart, .can)
        XCTAssertEqual(reach.toEnd, .cannot)
    }

    func testTwoFingersDoubleTappingFitAColumnToTheWindowAndBack() throws {
        try withShell { shell, workspace in
            XCTAssertTrue(shell.fitColumn(over: try terminal(workspace, 1)))
            XCTAssertEqual(workspace.columns[1].widthFraction, 1)
            XCTAssertTrue(shell.fitColumn(over: workspace.columns[1].header))
            XCTAssertEqual(workspace.columns[1].widthFraction, 0.4)

            // Another card takes the focus too.
            XCTAssertTrue(shell.fitColumn(over: try terminal(workspace, 2)))
            XCTAssertEqual(workspace.focusedIndex, 2)
            XCTAssertEqual(workspace.columns[2].widthFraction, 1)
            // Left at full width some other way, it forgets the width it had.
            workspace.columns[2].widthFraction = 2.0 / 3
            workspace.columns[2].widthFraction = 1
            XCTAssertTrue(shell.fitColumn(over: try terminal(workspace, 2)))
            XCTAssertEqual(workspace.columns[2].widthFraction, 0.5)

            // Over what lies on the work (the space plan) or beside it.
            let middle = NSPoint(x: shell.viewport.bounds.midX, y: shell.viewport.bounds.midY)
            let overlay = NSView(frame: NSRect(x: middle.x - 50, y: middle.y - 50, width: 100, height: 100))
            shell.viewport.addSubview(overlay)
            for view in [overlay, shell.sidebar] {
                XCTAssertFalse(shell.fitColumn(over: view))
            }
            XCTAssertEqual(workspace.columns.map(\.widthFraction), [0.4, 0.4, 0.5, 0.4, 0.4, 0.4])
        }
    }

    /// Holds let go once a click is over; fingers swiping meanwhile keep
    /// theirs.
    func testAClicksReleaseLeavesTheFingersHold() throws {
        try withShell { shell, workspace in
            shell.addWorkspace(title: "other", cwd: NSTemporaryDirectory())
            let other = try XCTUnwrap(shell.activeWorkspace)
            shell.switchToWorkspace(try XCTUnwrap(shell.workspaces.firstIndex { $0 === workspace }))
            shell.relayout(animated: false)
            shell.sideEffects.secondsSinceMouseUp = { .infinity }
            // A dragged edge's hold that missed its end goes with the click's.
            other.heldCamera = WorkspaceState.CameraHold(x: 0, column: other.columns[0].id, isDrag: true)
            shell.clickBegan(onColumn: nil)
            swipe(shell, over: try terminal(workspace, 1), [-20, -20], lifts: false)
            waitUntil("the other hold let go", timeout: NSEvent.doubleClickInterval + 3) { other.heldCamera == nil }
            XCTAssertEqual(workspace.heldCamera?.isDrag, true)
        }
    }

    private static func page(in view: NSView) -> WKWebView? {
        (view as? WKWebView) ?? view.subviews.lazy.compactMap(page(in:)).first
    }

    /// A scroll event of no window, its phase as `CGScrollPhase` gives it.
    private func scrollEvent(phase: Int64) throws -> NSEvent {
        let event = try XCTUnwrap(CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: 0, wheel2: -10, wheel3: 0))
        event.setIntegerValueField(.scrollWheelEventScrollPhase, value: phase)
        return try XCTUnwrap(NSEvent(cgEvent: event))
    }
}
