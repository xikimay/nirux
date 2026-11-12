import AppKit
import XCTest
@testable import Nirux

/// The line written when the pointer comes back to the sidebar or Nirux
/// to the front: what it tells apart, when it is written, and that it
/// holds counts and booleans only.
@MainActor
final class SidebarStaleLogTests: XCTestCase {
    /// A clock the test moves by hand.
    private final class Clock {
        var time: CFTimeInterval = 9_000
    }

    private func row(_ id: String, index: Int, archived: Bool = false, active: Bool = false) -> WorkspaceInfo {
        WorkspaceInfo(
            id: id, index: index, title: id, profileID: WorkspaceProfile.defaultID, isInactive: archived, columnCount: 0,
            focusedColumn: 0, gitBranch: "feat/\(id)", notification: nil, isActive: active, columns: [], prInfo: nil,
            diffStats: nil, purpose: nil, nextStep: nil, blocker: nil, phase: archived ? .parked : .active, lastSummary: nil,
            lastActivityAt: nil
        )
    }

    /// An expanded sidebar in a window that is never shown.
    private func sidebar(_ rows: [WorkspaceInfo], clock: Clock) -> (SidebarView, NSWindow) {
        _ = NSApplication.shared
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 660))
        let sidebar = SidebarView(frame: NSRect(x: 0, y: 0, width: 260, height: 660))
        sidebar.clock = { clock.time }
        host.addSubview(sidebar)
        let window = NSWindow(contentRect: host.bounds, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        sidebar.isExpanded = true
        sidebar.update(profiles: [], workspaces: rows)
        host.layoutSubtreeIfNeeded()
        return (sidebar, window)
    }

    private func mouse(_ type: NSEvent.EventType, at point: NSPoint, in sidebar: SidebarView, window: NSWindow) throws -> NSEvent {
        try XCTUnwrap(NSEvent.mouseEvent(
            with: type, location: sidebar.convert(point, to: nil), modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
            eventNumber: 0, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0
        ))
    }

    /// A move, a press, a scroll or a right-click on the sidebar is told
    /// when the pointer had left it alone for two seconds, with how long
    /// that was: once, not at every move after it.
    func testThePointerComingBackIsToldOnce() throws {
        let clock = Clock()
        let (sidebar, window) = sidebar([row("a", index: 0, active: true)], clock: clock)
        defer { window.close() }
        var told: [String] = []
        sidebar.onPointerReturn = { gesture, idle in told.append("\(gesture.rawValue) \(idle.map { String(format: "%.1f", $0) } ?? "-")") }
        // Under the rows: nothing to press.
        let empty = NSPoint(x: 130, y: 40)

        sidebar.mouseMoved(with: try mouse(.mouseMoved, at: empty, in: sidebar, window: window))
        XCTAssertEqual(told, ["move -"], "the first time ever")
        clock.time += 1.5
        sidebar.mouseDown(with: try mouse(.leftMouseDown, at: empty, in: sidebar, window: window))
        clock.time += 1.5
        sidebar.mouseMoved(with: try mouse(.mouseMoved, at: empty, in: sidebar, window: window))
        XCTAssertEqual(told, ["move -"], "it never left for two seconds")
        clock.time += 2.5
        sidebar.mouseDown(with: try mouse(.leftMouseDown, at: empty, in: sidebar, window: window))
        XCTAssertEqual(told, ["move -", "press 2.5"])
        clock.time += 0.5
        sidebar.mouseMoved(with: try mouse(.mouseMoved, at: empty, in: sidebar, window: window))
        XCTAssertEqual(told, ["move -", "press 2.5"])
        clock.time += 2.5
        sidebar.mouseMoved(with: try mouse(.mouseMoved, at: empty, in: sidebar, window: window))
        XCTAssertEqual(told, ["move -", "press 2.5", "move 2.5"])

        // A scroll and a right-click move the list or open a menu on it:
        // told as well, and they count as the pointer being there.
        clock.time += 2.5
        let wheel = try XCTUnwrap(CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: -4, wheel2: 0, wheel3: 0))
        sidebar.contentScrollView.scrollWheel(with: try XCTUnwrap(NSEvent(cgEvent: wheel)))
        XCTAssertEqual(told.last, "scroll 2.5")
        clock.time += 1.5
        _ = sidebar.menu(for: try mouse(.rightMouseDown, at: empty, in: sidebar, window: window))
        XCTAssertEqual(told.count, 4, "the scroll was the pointer there")
        clock.time += 2.5
        _ = sidebar.menu(for: try mouse(.rightMouseDown, at: empty, in: sidebar, window: window))
        XCTAssertEqual(told.last, "menu 2.5")
        clock.time += 1.5
        sidebar.contentScrollView.scrollWheel(with: try XCTUnwrap(NSEvent(cgEvent: wheel)))
        XCTAssertEqual(told.count, 5, "and so was the right-click")
    }

    /// A press is told before it acts: the line says how the sidebar was
    /// found, not what the click made of it.
    func testAPressIsToldBeforeItActs() throws {
        let (sidebar, window) = sidebar([row("a", index: 0, active: true), row("b", index: 1)], clock: Clock())
        defer { window.close() }
        var order: [String] = []
        sidebar.onPointerReturn = { _, _ in order.append("told") }
        sidebar.onWorkspaceClicked = { _ in order.append("clicked") }
        let rowFrame = try XCTUnwrap(sidebar.hitAreas.first { if case .workspace(1) = $0.region { true } else { false } }?.frame)
        let point = sidebar.convert(NSPoint(x: rowFrame.midX, y: rowFrame.midY), from: sidebar.contentDocumentView)

        // The press is followed by its release: the drag loop takes it as a click.
        NSApp.postEvent(try mouse(.leftMouseUp, at: point, in: sidebar, window: window), atStart: false)
        sidebar.mouseDown(with: try mouse(.leftMouseDown, at: point, in: sidebar, window: window))

        XCTAssertEqual(order, ["told", "clicked"])
    }

    /// The facts count the list held and what is in it: a layer that
    /// backs no view, a view no render made and whose layer isn't in the
    /// list, the picture of a row that left while it may still show, what
    /// waits behind a tracked press, and how long ago the rows were
    /// rebuilt.
    func testTheFactsCountWhatIsHeldAndDrawn() throws {
        let clock = Clock()
        let (sidebar, window) = sidebar(
            [row("a", index: 0, active: true), row("b", index: 1), row("c", index: 2)], clock: clock
        )
        defer { window.close() }
        var facts = sidebar.drawnFacts()
        XCTAssertEqual([facts.held, facts.foldGhosts, facts.foldPulls], [3, 0, 0])
        XCTAssertEqual([facts.isExpanded, facts.fits, facts.animates], [true, true, true])
        XCTAssertEqual([facts.isDragTracked, facts.hasDeferredUpdate, facts.skippedRebuild], [false, false, false])
        XCTAssertEqual(facts.sinceRebuild, 0)

        // Once AppKit has made its display pass, every row's layer is in
        // the list's and no other is.
        let list = sidebar.contentDocumentView
        let deadline = Date().addingTimeInterval(5)
        while sidebar.drawnFacts().viewsWithoutLayer > 0, Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        var layers = sidebar.drawnFacts()
        XCTAssertEqual([layers.strayLayers, layers.viewsWithoutLayer, layers.leftoverViews], [0, 0, 0])
        let strayLayer = CALayer()
        try XCTUnwrap(list.layer).addSublayer(strayLayer)
        let orphan = NSView(frame: NSRect(x: 0, y: 0, width: 10, height: 10))
        orphan.wantsLayer = true
        list.addSubview(orphan)
        try XCTUnwrap(orphan.layer).removeFromSuperlayer()
        layers = sidebar.drawnFacts()
        XCTAssertEqual([layers.strayLayers, layers.viewsWithoutLayer, layers.leftoverViews], [1, 1, 1], "a view no render made")
        strayLayer.removeFromSuperlayer()
        orphan.removeFromSuperview()

        // "b" leaves: its picture folds away and "c" comes up.
        clock.time += 5
        sidebar.update(profiles: [], workspaces: [row("a", index: 0, active: true), row("c", index: 1)])
        facts = sidebar.drawnFacts()
        XCTAssertEqual([facts.held, facts.foldGhosts], [2, 1], "its fold's animation is on the picture")
        XCTAssertGreaterThan(facts.foldPulls, 0)
        clock.time += 3
        facts = sidebar.drawnFacts()
        XCTAssertEqual([facts.sinceRebuild, facts.sinceUpdate], [3, 3])

        // The fold over, the picture stays in the list, unseen, until the
        // next rebuild: not counted. One that isn't transparent is.
        let picture = try XCTUnwrap(
            sidebar.expandedViews.first { $0.identifier == SidebarView.foldGhostID }?.layer?.sublayers?.first
        )
        picture.removeAnimation(forKey: SidebarView.foldLeaveKey)
        XCTAssertEqual(sidebar.drawnFacts().foldGhosts, 0)
        picture.opacity = 0.5
        XCTAssertEqual(sidebar.drawnFacts().foldGhosts, 1, "a picture of the gone row still drawn")
        picture.opacity = 0

        // A row press is tracked: the update and the rebuild wait.
        sidebar.workspaceDrag = SidebarWorkspaceDrag(
            workspaceID: "a", title: "a", rowFrame: .zero, groupRowFrames: [], position: 0, startPoint: .zero
        )
        clock.time += 4
        sidebar.update(profiles: [], workspaces: [row("a", index: 0, active: true)])
        sidebar.rebuildContent()
        facts = sidebar.drawnFacts()
        XCTAssertEqual([facts.isDragTracked, facts.hasDeferredUpdate, facts.skippedRebuild], [true, true, true])
        XCTAssertEqual(facts.held, 2, "the list held is still the one before")
        XCTAssertEqual([facts.sinceRebuild, facts.sinceUpdate], [7, 0], "the update came; nothing was rebuilt")

        // A drag's own view is in the list on purpose.
        let leftover = facts.leftoverViews
        let dragGhost = NSView(frame: NSRect(x: 0, y: 0, width: 10, height: 10))
        list.addSubview(dragGhost)
        XCTAssertEqual(sidebar.drawnFacts().leftoverViews, leftover + 1)
        sidebar.dragGhostView = dragGhost
        XCTAssertEqual(sidebar.drawnFacts().leftoverViews, leftover)
    }

    /// Each field under its own name, in counts, booleans and seconds.
    func testTheLineNamesEachFact() {
        var facts = SidebarStaleLog.Facts(trigger: .press, pointerIdle: 12.34)
        facts.stored = 7
        facts.holdsStored = false
        facts.drawn = SidebarView.DrawnFacts(
            held: 8, strayLayers: 1, viewsWithoutLayer: 2, leftoverViews: 5, needsDisplay: true,
            foldGhosts: 3, foldPulls: 4, isDragTracked: true, hasDeferredUpdate: false, skippedRebuild: true,
            animates: false, isExpanded: true, fits: false, sinceRebuild: 4.06, sinceUpdate: nil
        )
        facts.sinceRefresh = 6
        XCTAssertTrue(SidebarStaleLog.line(SidebarStaleLog.Facts(trigger: .front)).contains(" refresh=- "), "no refresh yet")
        facts.heartbeatRuns = true
        facts.isAppActive = false
        facts.isWindowKey = true
        facts.windowShows = false
        facts.isDisplayAsleep = true
        facts.isSessionOut = false
        facts.sinceWake = 30.5
        facts.sinceUnlock = nil
        facts.sinceSessionReturn = 31
        facts.sinceFront = 3.2
        facts.sinceUncovered = 3.3

        XCTAssertEqual(
            SidebarStaleLog.line(facts),
            "trigger=press idle=12.3 store=7 held=8 same=0 stray=1 nolayer=2 leftover=5 needsDisplay=1 ghosts=3 "
                + "pulls=4 drag=1 deferred=0 skipped=1 animates=0 expanded=1 fits=0 rebuild=4.1 update=- refresh=6.0 heartbeat=1 "
                + "active=0 key=1 visible=0 displayAsleep=1 sessionOut=0 wake=30.5 unlock=- session=31.0 front=3.2 uncovered=3.3"
        )
    }

    /// The shell's line says when the sidebar holds a list that isn't the
    /// store's, keeps what may leave the screen behind, and never names a
    /// task.
    func testTheShellsLineTellsAListBehindTheStore() throws {
        try withShell { shell, folder in
            let clock = Clock()
            shell.sidebar.clock = { clock.time }
            let log = Lines()
            var lines: [String] { log.written }
            shell.sideEffects.logSidebarState = { log.written.append($0) }
            shell.sideEffects.windowShows = { _ in false }
            // Not this Mac's display, which may sleep.
            shell.agentLights.isDisplayAsleep = false
            shell.agentLights.isSessionInactive = false
            shell.addWorkspace(title: "secret-one", cwd: folder)
            shell.addWorkspace(title: "secret-two", cwd: folder)
            let idle = ProcessSnapshot(entries: [])
            shell.updateSidebar(snapshot: idle)

            // No refresh has read the agents yet.
            shell.lastMetadataRefreshAt = 0
            shell.sidebar.notePointer(.move)
            XCTAssertEqual(lines.count, 1)
            XCTAssertTrue(try XCTUnwrap(lines.last).hasPrefix("trigger=move idle=- store=3 held=3 same=1 "), lines.last ?? "")
            XCTAssertTrue(try XCTUnwrap(lines.last).contains(" refresh=- heartbeat=0 "), lines.last ?? "")
            shell.refreshMetadata(snapshot: idle)

            // The store loses a task and nothing tells the sidebar.
            shell.workspaceStore.removeWorkspace(try XCTUnwrap(shell.workspaces.first { $0.title == "secret-one" }))
            clock.time += 3
            shell.sidebar.notePointer(.press)
            XCTAssertTrue(try XCTUnwrap(lines.last).hasPrefix("trigger=press idle=3.0 store=2 held=3 same=0 "), lines.last ?? "")
            XCTAssertNotNil(try XCTUnwrap(lines.last).firstMatch(of: /\brefresh=[0-9]/), "a refresh came: \(lines.last ?? "")")

            shell.updateSidebar(snapshot: idle)
            clock.time += 3
            shell.sidebar.notePointer(.move)
            XCTAssertTrue(try XCTUnwrap(lines.last).hasPrefix("trigger=move idle=3.0 store=2 held=2 same=1 "), lines.last ?? "")
            XCTAssertTrue(try XCTUnwrap(lines.last).hasSuffix(" wake=- unlock=- session=- front=- uncovered=-"), lines.last ?? "")

            // Archived in the store, the sidebar not told: the same tasks
            // in the same order, not where the store has them.
            let last = try XCTUnwrap(shell.workspaces.firstIndex { $0.title == "secret-two" })
            XCTAssertTrue(shell.workspaceStore.setWorkspaceInactive(at: last, true))
            clock.time += 3
            shell.sidebar.notePointer(.press)
            XCTAssertTrue(try XCTUnwrap(lines.last).hasPrefix("trigger=press idle=3.0 store=2 held=2 same=0 "), lines.last ?? "")
            shell.updateSidebar(snapshot: idle)

            // The window's first word on its occlusion, shown at launch,
            // is no uncovering.
            shell.sideEffects.windowShows = { _ in true }
            shell.noteSidebarStaleLogEvent(.occlusion)
            clock.time += 3
            shell.sidebar.notePointer(.scroll)
            XCTAssertTrue(try XCTUnwrap(lines.last).hasPrefix("trigger=scroll idle=3.0 "), lines.last ?? "")
            XCTAssertTrue(try XCTUnwrap(lines.last).hasSuffix(" front=- uncovered=-"), lines.last ?? "")
            shell.sideEffects.windowShows = { _ in false }

            // What may leave the screen behind, as it happens (told by
            // hand: a test's shell doesn't follow the system).
            shell.noteSidebarStaleLogEvent(.wake)
            clock.time += 1
            shell.noteSidebarStaleLogEvent(.sessionReturn)
            clock.time += 1
            shell.noteSidebarStaleLogEvent(.unlock)
            clock.time += 1
            // Covered; then it shows again.
            shell.noteSidebarStaleLogEvent(.occlusion)
            shell.sideEffects.windowShows = { _ in true }
            clock.time += 1
            shell.noteSidebarStaleLogEvent(.occlusion)
            clock.time += 1
            shell.noteSidebarStaleLogEvent(.occlusion)
            clock.time += 1
            // Nirux comes to the front: a line of its own, for a shell
            // that follows the system.
            let before = lines.count
            shell.sidebarStaleLogCameToFront()
            XCTAssertEqual(lines.count, before, "a test's shell writes nothing at an activation")
            shell.sidebarStaleLog.followsSystem = true
            shell.sidebarStaleLogCameToFront()
            XCTAssertEqual(lines.count, before + 1)
            let front = try XCTUnwrap(lines.last)
            XCTAssertTrue(front.hasPrefix("trigger=front idle=- store=2 held=2 same=1 "), front)
            XCTAssertTrue(front.hasSuffix(" visible=1 displayAsleep=0 sessionOut=0 wake=6.0 unlock=4.0 session=5.0 front=- uncovered=2.0"), front)
            clock.time += 2
            shell.sidebar.notePointer(.move)
            XCTAssertTrue(try XCTUnwrap(lines.last).hasSuffix(" front=2.0 uncovered=4.0"), lines.last ?? "")

            XCTAssertEqual(lines.filter { $0.contains("secret") || $0.contains(folder) }, [], "no title, no path")
            for line in lines {
                XCTAssertNotNil(
                    line.wholeMatch(of: /([A-Za-z]+=(move|press|scroll|menu|front|-|[0-9]+(\.[0-9]+)?))( [A-Za-z]+=(move|press|scroll|menu|front|-|[0-9]+(\.[0-9]+)?))*/),
                    "counts, booleans and seconds only: \(line)"
                )
            }
        }
    }

    /// The unlock is heard when it happens: a distributed notification
    /// reaches its observer while the center holds the app's others, as
    /// it does while Nirux is in the background.
    func testADistributedNotificationIsHeardWhileTheCenterHoldsTheOthers() {
        let center = DistributedNotificationCenter.default()
        let wasSuspended = center.suspended
        center.suspended = true
        defer { center.suspended = wasSuspended }
        let name = Notification.Name("com.xikimay.nirux.tests.\(UUID().uuidString)")
        let heard = Lines()
        let observer = ImmediateDistributedObserver(name: name) { heard.written.append("heard") }
        center.postNotificationName(name, object: nil)
        let deadline = Date().addingTimeInterval(10)
        while heard.written.isEmpty, Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        XCTAssertEqual(heard.written, ["heard"])
        withExtendedLifetime(observer) {}
    }

    /// The lines a shell wrote.
    private final class Lines {
        var written: [String] = []
    }

    /// A shell in a window that is never shown, its state in a folder of
    /// its own; `body` gets a folder to open workspaces in.
    private func withShell(_ body: (NiruxShellView, String) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("nirux-stale-log-\(UUID().uuidString)").path
        let stateDirectory = root + "/state"
        let folder = root + "/work"
        for path in [stateDirectory, folder] {
            try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        }
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
        let shell = NiruxShellView(frame: NSRect(x: 0, y: 0, width: 1200, height: 800))
        shell.stopHeartbeat()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800), styleMask: [.titled, .closable, .resizable],
            backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = shell
        defer { window.close() }
        try body(shell, folder)
    }
}
