import AppKit
import XCTest
@testable import Nirux

/// A press on a task's row is tracked until its mouse-up, and the sidebar
/// puts its updates and rebuilds aside meanwhile: the gesture has to end,
/// in the order its events came, and what was put aside has to come back.
@MainActor
final class SidebarRowDragTests: XCTestCase {
    private func row(_ id: String, index: Int, pr: PRInfo? = nil, active: Bool = false) -> WorkspaceInfo {
        WorkspaceInfo(
            id: id, index: index, title: id, profileID: WorkspaceProfile.defaultID, isInactive: false, columnCount: 0,
            focusedColumn: 0, gitBranch: "feat/\(id)", notification: nil, isActive: active, columns: [], prInfo: pr,
            diffStats: nil, purpose: nil, nextStep: nil, blocker: nil, phase: .active, lastSummary: nil, lastActivityAt: nil
        )
    }

    /// An expanded sidebar in a window that is never shown.
    private func sidebar(_ rows: [WorkspaceInfo]) -> (SidebarView, NSWindow) {
        // What an earlier test left in the queue isn't this one's.
        NSApplication.shared.discardEvents(matching: .any, before: nil)
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 660))
        let sidebar = SidebarView(frame: NSRect(x: 0, y: 0, width: 260, height: 660))
        host.addSubview(sidebar)
        let window = NSWindow(contentRect: host.bounds, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        sidebar.isExpanded = true
        sidebar.update(profiles: [], workspaces: rows)
        host.layoutSubtreeIfNeeded()
        return (sidebar, window)
    }

    /// The tasks whose rows are drawn, top to bottom.
    private func rowsDrawn(_ sidebar: SidebarView) -> [String] {
        sidebar.hitAreas.compactMap { area -> (id: String, top: CGFloat)? in
            guard case .workspace(let index) = area.region, let info = sidebar.lastInfos.first(where: { $0.index == index })
            else { return nil }
            return (info.id, area.frame.maxY)
        }.sorted { $0.top > $1.top }.map(\.id)
    }

    private func frame(ofRow index: Int, in sidebar: SidebarView) throws -> NSRect {
        try XCTUnwrap(sidebar.hitAreas.first { if case .workspace(index) = $0.region { true } else { false } }?.frame)
    }

    private func mouse(_ type: NSEvent.EventType, at point: NSPoint, in sidebar: SidebarView, window: NSWindow) throws -> NSEvent {
        try XCTUnwrap(NSEvent.mouseEvent(
            with: type, location: sidebar.contentDocumentView.convert(point, to: nil), modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
            eventNumber: 0, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1
        ))
    }

    private func post(_ type: NSEvent.EventType, at point: NSPoint, in sidebar: SidebarView, window: NSWindow) {
        guard let event = try? mouse(type, at: point, in: sidebar, window: window) else { return XCTFail("no mouse event") }
        NSApp.postEvent(event, atStart: false)
    }

    /// A tick of the drag's own, queued where it is posted.
    private func postTick() {
        guard let tick = NSEvent.otherEvent(
            with: .periodic, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: 0, context: nil, subtype: 0, data1: 0, data2: 0
        ) else { return XCTFail("no periodic event") }
        NSApp.postEvent(tick, atStart: false)
    }

    /// The button is held for `delay` (the drag's ticks are running by
    /// then), then reads up. Each time the gesture then finds it up, the
    /// next of `found` runs first.
    private func releaseButton(of sidebar: SidebarView, after delay: TimeInterval, found: [@MainActor () -> Void] = []) {
        let press = Press(until: Date().addingTimeInterval(delay), found: found)
        sidebar.rowPressHolds = { _ in press.holds() }
    }

    /// What ended a stuck drag before: the next click's mouse-up, long
    /// after, here at `point`. What it returns says whether that was needed.
    private func laterMouseUp(at point: NSPoint, in sidebar: SidebarView, window: NSWindow) -> LaterMouseUp {
        let later = LaterMouseUp()
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self, weak sidebar, weak window] in
            guard let self, let sidebar, let window, sidebar.workspaceDrag != nil else { return }
            later.wasNeeded = true
            self.post(.leftMouseUp, at: point, in: sidebar, window: window)
        }
        return later
    }

    /// A row dragged past the click threshold whose mouse-up never comes
    /// (a modal or another app took it) ends by itself once the button is
    /// up: the list that changed meanwhile shows, and nothing is clicked
    /// or moved.
    func testADragThatLosesItsMouseUpEndsByItself() throws {
        let (sidebar, window) = sidebar([row("a", index: 0, active: true), row("b", index: 1), row("c", index: 2)])
        defer { window.close() }
        var clicked: [Int] = []
        var moved: [[Int]] = []
        sidebar.onWorkspaceClicked = { clicked.append($0) }
        sidebar.onWorkspaceReordered = { moved.append([$0, $1]) }
        releaseButton(of: sidebar, after: 0.6)

        let start = try frame(ofRow: 1, in: sidebar).center
        post(.leftMouseDragged, at: NSPoint(x: start.x, y: start.y - 10), in: sidebar, window: window)
        // A task leaves while the row is held.
        DispatchQueue.main.async { sidebar.update(profiles: [], workspaces: Array(sidebar.lastInfos.dropLast())) }
        let later = laterMouseUp(at: start, in: sidebar, window: window)
        sidebar.mouseDown(with: try mouse(.leftMouseDown, at: start, in: sidebar, window: window))

        XCTAssertFalse(later.wasNeeded, "the drag held the sidebar until another mouse-up")
        XCTAssertNil(sidebar.workspaceDrag)
        XCTAssertNil(sidebar.dragGhostView, "its ghost goes with it")
        XCTAssertEqual(sidebar.lastInfos.map(\.id), ["a", "b"], "the update put aside is applied")
        XCTAssertEqual(rowsDrawn(sidebar), ["a", "b"])
        XCTAssertEqual(clicked, [], "a gesture that was lost clicks nothing")
        XCTAssertEqual(moved, [], "and moves nothing")
    }

    /// The button can read up before its mouse-up is handed over, and the
    /// app can be busy meanwhile: the mouse-up still comes in its turn,
    /// after the drags queued before it, and drops the row where the last
    /// of them left it.
    func testAMouseUpBehindWhatIsQueuedDropsTheRowWhereItWasDragged() throws {
        let (sidebar, window) = sidebar([row("a", index: 0, active: true), row("b", index: 1), row("c", index: 2)])
        defer { window.close() }
        var moved: [[Int]] = []
        sidebar.onWorkspaceReordered = { moved.append([$0, $1]) }

        let start = try frame(ofRow: 0, in: sidebar).center
        let underAll = NSPoint(x: start.x, y: try frame(ofRow: 2, in: sidebar).minY + 2)
        let underTheSecond = NSPoint(x: start.x, y: try frame(ofRow: 1, in: sidebar).minY + 2)
        releaseButton(of: sidebar, after: 0.6, found: [
            // Up: a tick, a last drag back up a row and the mouse-up are queued…
            { [weak self, weak sidebar, weak window] in
                guard let self, let sidebar, let window else { return }
                self.postTick()
                self.post(.leftMouseDragged, at: underTheSecond, in: sidebar, window: window)
                self.post(.leftMouseUp, at: underTheSecond, in: sidebar, window: window)
            },
            // …and the app is busy for longer than a mouse-up is waited for.
            { Thread.sleep(forTimeInterval: 0.3) }
        ])
        post(.leftMouseDragged, at: NSPoint(x: start.x, y: start.y - 10), in: sidebar, window: window)
        post(.leftMouseDragged, at: underAll, in: sidebar, window: window)
        let later = laterMouseUp(at: underAll, in: sidebar, window: window)
        sidebar.mouseDown(with: try mouse(.leftMouseDown, at: start, in: sidebar, window: window))

        XCTAssertFalse(later.wasNeeded, "the gesture never saw the button up")
        XCTAssertNil(sidebar.workspaceDrag)
        XCTAssertEqual(moved, [[0, 1]], "under the second row, where the last drag left it")
    }

    /// Events posted to the app move no button: a drag whose button reads
    /// up all along isn't taken for lost while it keeps moving.
    func testADragThatKeepsMovingIsNotLost() throws {
        let (sidebar, window) = sidebar([row("a", index: 0, active: true), row("b", index: 1), row("c", index: 2)])
        defer { window.close() }
        var moved: [[Int]] = []
        sidebar.onWorkspaceReordered = { moved.append([$0, $1]) }

        let start = try frame(ofRow: 0, in: sidebar).center
        let underAll = NSPoint(x: start.x, y: try frame(ofRow: 2, in: sidebar).minY + 2)
        releaseButton(of: sidebar, after: 0, found: [
            // It moves on…
            { [weak self, weak sidebar, weak window] in
                guard let self, let sidebar, let window else { return }
                self.post(.leftMouseDragged, at: NSPoint(x: start.x, y: start.y - 20), in: sidebar, window: window)
            },
            // …and longer than a mouse-up is waited for after the first tick…
            { Thread.sleep(forTimeInterval: 0.3) },
            // …it is dropped.
            { [weak self, weak sidebar, weak window] in
                guard let self, let sidebar, let window else { return }
                self.post(.leftMouseDragged, at: underAll, in: sidebar, window: window)
                self.post(.leftMouseUp, at: underAll, in: sidebar, window: window)
            }
        ])
        post(.leftMouseDragged, at: NSPoint(x: start.x, y: start.y - 10), in: sidebar, window: window)
        let later = laterMouseUp(at: underAll, in: sidebar, window: window)
        sidebar.mouseDown(with: try mouse(.leftMouseDown, at: start, in: sidebar, window: window))

        XCTAssertFalse(later.wasNeeded)
        XCTAssertNil(sidebar.workspaceDrag)
        XCTAssertEqual(moved, [[0, 2]])
    }

    /// Rows that may no longer move mid-drag (the window got covered) are
    /// rebuilt still when the drag ends, even when the refresh put aside
    /// meanwhile brings the same rows; and nothing stays owed.
    func testARebuildSkippedDuringADragIsMadeAtItsEnd() throws {
        let checksRunning = PRInfo(
            number: 39, state: "OPEN", isDraft: false, ciStatus: "PENDING", checks: [], reviewDecision: nil, mergeable: nil,
            url: "https://example.test/pull/39", additions: nil, deletions: nil, changedFiles: nil
        )
        let (sidebar, window) = sidebar([row("a", index: 0, active: true), row("pr", index: 1, pr: checksRunning)])
        defer { window.close() }
        sidebar.rowPressHolds = { _ in true }
        let ring = { () -> CAShapeLayer? in
            sidebar.expandedViews.first { $0.identifier == SidebarWorkspaceCardRenderer.checksRingID }?
                .layer?.sublayers?.first as? CAShapeLayer
        }
        XCTAssertNotNil(try XCTUnwrap(ring()).animation(forKey: SidebarWorkspaceCardRenderer.checksRingKey), "the ring turns")

        let start = try frame(ofRow: 0, in: sidebar).center
        let waited = Waited()
        DispatchQueue.main.async { [weak self, weak sidebar, weak window] in
            guard let self, let sidebar, let window else { return }
            sidebar.animates = false
            sidebar.update(profiles: [], workspaces: sidebar.lastInfos)
            waited.rebuild = sidebar.rebuildSkippedDuringDrag
            waited.update = sidebar.deferredDragUpdate != nil
            self.post(.leftMouseUp, at: start, in: sidebar, window: window)
        }
        sidebar.mouseDown(with: try mouse(.leftMouseDown, at: start, in: sidebar, window: window))

        XCTAssertEqual([waited.rebuild, waited.update], [true, true], "the press was tracked: both waited for its end")
        XCTAssertNil(sidebar.workspaceDrag)
        let still = try XCTUnwrap(ring())
        XCTAssertNil(still.animationKeys(), "the rows were rebuilt for what may move now")
        XCTAssertNotNil(still.lineDashPattern)
        XCTAssertFalse(sidebar.rebuildSkippedDuringDrag, "the rebuild was made: the next press owes none")
    }
}

/// A button that is held until a moment, then up.
@MainActor
private final class Press {
    private let until: Date
    private var found: [@MainActor () -> Void]

    init(until: Date, found: [@MainActor () -> Void]) {
        self.until = until
        self.found = found
    }

    func holds() -> Bool {
        guard Date() >= until else { return true }
        if !found.isEmpty { found.removeFirst()() }
        return false
    }
}

@MainActor
private final class LaterMouseUp {
    var wasNeeded = false
}

/// What waited for a tracked press to end.
@MainActor
private final class Waited {
    var rebuild = false
    var update = false
}

private extension NSRect {
    var center: NSPoint { NSPoint(x: midX, y: midY) }
}
