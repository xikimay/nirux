import AppKit
import XCTest
@testable import Nirux

/// A press on a task's row is tracked until its mouse-up, and the sidebar
/// puts its updates and rebuilds aside meanwhile: the gesture has to end,
/// and what was put aside has to come back.
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
        _ = NSApplication.shared
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

    /// The button is held for a moment (the drag's ticks are running by
    /// then), then reads up; `released` runs when the gesture first sees it.
    private func releaseButton(of sidebar: SidebarView, after delay: TimeInterval = 0.6, released: @escaping @MainActor () -> Void = {}) {
        let press = Press(until: Date().addingTimeInterval(delay), released: released)
        sidebar.rowPressHolds = { _ in press.holds() }
    }

    /// What ended a stuck drag before: the next click's mouse-up, long
    /// after, here at `point`. What it returns says whether that was needed.
    private func laterMouseUp(at point: NSPoint, in sidebar: SidebarView, window: NSWindow) -> LaterMouseUp {
        let later = LaterMouseUp()
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self, weak sidebar, weak window] in
            guard let self, let sidebar, let window, sidebar.workspaceDrag != nil,
                  let mouseUp = try? self.mouse(.leftMouseUp, at: point, in: sidebar, window: window)
            else { return }
            later.wasNeeded = true
            NSApp.postEvent(mouseUp, atStart: false)
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
        releaseButton(of: sidebar)

        let start = try frame(ofRow: 1, in: sidebar).center
        NSApp.postEvent(
            try mouse(.leftMouseDragged, at: NSPoint(x: start.x, y: start.y - 10), in: sidebar, window: window), atStart: false
        )
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

    /// The button can read up a moment before its mouse-up is handed
    /// over: that mouse-up still drops the row where it was dragged.
    func testAMouseUpRightBehindTheButtonStillDropsTheRow() throws {
        let (sidebar, window) = sidebar([row("a", index: 0, active: true), row("b", index: 1), row("c", index: 2)])
        defer { window.close() }
        var moved: [[Int]] = []
        sidebar.onWorkspaceReordered = { moved.append([$0, $1]) }

        let start = try frame(ofRow: 0, in: sidebar).center
        let below = NSPoint(x: start.x, y: try frame(ofRow: 2, in: sidebar).minY + 2)
        releaseButton(of: sidebar) { [weak self, weak sidebar, weak window] in
            guard let self, let sidebar, let window,
                  let mouseUp = try? self.mouse(.leftMouseUp, at: below, in: sidebar, window: window)
            else { return }
            NSApp.postEvent(mouseUp, atStart: false)
        }
        NSApp.postEvent(
            try mouse(.leftMouseDragged, at: NSPoint(x: start.x, y: start.y - 10), in: sidebar, window: window), atStart: false
        )
        NSApp.postEvent(try mouse(.leftMouseDragged, at: below, in: sidebar, window: window), atStart: false)
        let later = laterMouseUp(at: below, in: sidebar, window: window)
        sidebar.mouseDown(with: try mouse(.leftMouseDown, at: start, in: sidebar, window: window))

        XCTAssertFalse(later.wasNeeded, "the gesture never saw the button up")
        XCTAssertNil(sidebar.workspaceDrag)
        XCTAssertEqual(moved, [[0, 2]])
    }

    /// Rows that may no longer move mid-drag (the window got covered) are
    /// rebuilt still when the drag ends, even when the refresh put aside
    /// meanwhile brings the same rows.
    func testARebuildSkippedDuringADragIsMadeAtItsEnd() throws {
        let checksRunning = PRInfo(
            number: 39, state: "OPEN", isDraft: false, ciStatus: "PENDING", checks: [], reviewDecision: nil, mergeable: nil,
            url: "https://example.test/pull/39", additions: nil, deletions: nil, changedFiles: nil
        )
        let rows = [row("a", index: 0, active: true), row("pr", index: 1, pr: checksRunning)]
        let (sidebar, window) = sidebar(rows)
        defer { window.close() }
        sidebar.rowPressHolds = { _ in true }
        let ring = { () -> CAShapeLayer? in
            sidebar.expandedViews.first { $0.identifier == SidebarWorkspaceCardRenderer.checksRingID }?
                .layer?.sublayers?.first as? CAShapeLayer
        }
        XCTAssertNotNil(try XCTUnwrap(ring()).animation(forKey: SidebarWorkspaceCardRenderer.checksRingKey), "the ring turns")

        let start = try frame(ofRow: 0, in: sidebar).center
        DispatchQueue.main.async { [weak self, weak sidebar, weak window] in
            guard let self, let sidebar, let window,
                  let mouseUp = try? self.mouse(.leftMouseUp, at: start, in: sidebar, window: window)
            else { return }
            sidebar.animates = false
            sidebar.update(profiles: [], workspaces: sidebar.lastInfos)
            NSApp.postEvent(mouseUp, atStart: false)
        }
        sidebar.mouseDown(with: try mouse(.leftMouseDown, at: start, in: sidebar, window: window))

        XCTAssertNil(sidebar.workspaceDrag)
        let still = try XCTUnwrap(ring())
        XCTAssertNil(still.animationKeys(), "the rows were rebuilt for what may move now")
        XCTAssertNotNil(still.lineDashPattern)
    }
}

/// A button that is held until a moment, then up.
@MainActor
private final class Press {
    private let until: Date
    private let released: @MainActor () -> Void
    private var told = false

    init(until: Date, released: @escaping @MainActor () -> Void) {
        self.until = until
        self.released = released
    }

    func holds() -> Bool {
        guard Date() >= until else { return true }
        if !told {
            told = true
            released()
        }
        return false
    }
}

@MainActor
private final class LaterMouseUp {
    var wasNeeded = false
}

private extension NSRect {
    var center: NSPoint { NSPoint(x: midX, y: midY) }
}
