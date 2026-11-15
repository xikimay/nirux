import AppKit
import XCTest
@testable import Nirux

/// The glass interface's rail (docs/design/glass-interface.md).
@MainActor
final class IconRailTests: XCTestCase {
    private var windows: [NSWindow] = []

    private func item(_ id: String, _ icon: StateIcon) -> IconRail.Item {
        IconRail.Item(id: id, title: id.capitalized, icon: icon)
    }

    private var content: IconRail.Content {
        IconRail.Content(lead: item("lead", StateIcon(.working, stage: 2)), tasks: [
            item("checkout", StateIcon(.working, stage: 1)),
            item("export", StateIcon(.needsYou(.command), stage: 1)),
            item("login", StateIcon(.error, stage: 3)),
            item("filters", StateIcon(.merged)),
        ], selectedID: "checkout")
    }

    /// The rail in a window that is never shown, laid out.
    private func rail(_ content: IconRail.Content, height: CGFloat = 480) -> IconRail {
        let rail = IconRail(level: .opaque)
        rail.frame = NSRect(x: 0, y: 0, width: IconRail.width, height: height)
        let window = NSWindow(contentRect: rail.frame, styleMask: .borderless, backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.contentView = rail
        windows.append(window)
        rail.show(content)
        rail.layoutSubtreeIfNeeded()
        return rail
    }

    private func spoken(_ rail: IconRail) -> [String] {
        NSAccessibility.unignoredChildren(from: rail.accessibilityChildren() ?? []).map { element in
            (element as? NSCell)?.accessibilityLabel() ?? (element as? NSView)?.accessibilityLabel() ?? "?"
        }
    }

    /// The task on screen wears the halo, and the pointer a fainter one; only
    /// a task waiting for the user wears the amber ring; the Lead shows its
    /// sign in its state's colour; the icons stand in the sidebar's order, 28
    /// pt apart, the Lead apart; an empty rail draws nothing.
    func testTheHaloAndTheRingMarkWhatMatters() throws {
        let rail = rail(content)
        let views = rail.itemViews
        XCTAssertEqual(views.filter { !$0.value.halo.isHidden }.map(\.key), ["checkout"])
        XCTAssertEqual(views.filter { $0.value.isAccessibilitySelected() }.map(\.key), ["checkout"], "VoiceOver knows it too")
        XCTAssertEqual(views.filter { !$0.value.ring.isHidden }.map(\.key), ["export"])
        XCTAssertEqual(try XCTUnwrap(views["export"]).ring.layer?.borderColor, Theme.Color.waiting.cgColor)
        let lead = try XCTUnwrap(views["lead"])
        XCTAssertTrue(lead.iconView.isHidden && !lead.leadIcon.isHidden, "the Lead shows its sign, not a state icon")
        XCTAssertEqual(lead.leadIcon.contentTintColor, Theme.Color.working)

        let order = [rail.content.lead!] + rail.content.tasks
        XCTAssertEqual(order.compactMap { views[$0.id]?.frame.minY }, [4, 40, 68, 96, 124])

        let login = try XCTUnwrap(views["login"])
        XCTAssertTrue(login.trackingAreas.contains { $0.owner === login && $0.options.contains(.mouseEnteredAndExited) }, "it hears the pointer")
        let event = try XCTUnwrap(NSEvent.enterExitEvent(
            with: .mouseEntered, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
            context: nil, eventNumber: 0, trackingNumber: 0, userData: nil
        ))
        login.mouseEntered(with: event)
        XCTAssertFalse(login.halo.isHidden)
        XCTAssertEqual(login.halo.layer?.backgroundColor, Theme.Color.fillHover.cgColor)
        login.mouseExited(with: event)
        XCTAssertTrue(login.halo.isHidden)
        login.mouseEntered(with: event)
        NotificationCenter.default.post(name: NSApplication.didResignActiveNotification, object: NSApp)
        XCTAssertTrue(login.halo.isHidden, "an inactive app doesn't hear the pointer leave: the halo goes")

        let empty = self.rail(IconRail.Content(lead: nil, tasks: []))
        XCTAssertTrue(empty.separator.isHidden && empty.itemViews.isEmpty, "an empty rail draws no line")
    }

    /// A click anywhere on an icon goes to its task, once even in a
    /// double-click; on a waiting task it asks for the request, anchored to
    /// the icon, and a double-click goes to the task, as VoiceOver's "Open
    /// task" does. A double-click whose first click never came here, or came
    /// long before, counts as a first click.
    func testAClickGoesToATaskOrAsksForItsRequest() throws {
        let rail = rail(content)
        var selected: [String] = [], requested: [(String, NSView)] = []
        rail.onSelect = { selected.append($0) }
        rail.onRequest = { requested.append(($0, $1)) }
        func click(_ id: String, count: Int, at time: TimeInterval = 0) throws {
            let view = try XCTUnwrap(rail.itemViews[id])
            let point = view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil)
            let target = try XCTUnwrap(rail.hitTest(rail.superview?.convert(point, from: nil) ?? point))
            XCTAssertTrue(target === view, "the click reaches \(id)'s icon, not a drawing on it")
            XCTAssertTrue(target.acceptsFirstMouse(for: nil), "it acts in a window in the background")
            XCTAssertFalse(target.mouseDownCanMoveWindow)
            func event(_ type: NSEvent.EventType) throws -> NSEvent {
                try XCTUnwrap(NSEvent.mouseEvent(
                    with: type, location: point, modifierFlags: [], timestamp: time,
                    windowNumber: view.window?.windowNumber ?? 0, context: nil, eventNumber: 0, clickCount: count, pressure: 0
                ))
            }
            target.mouseDown(with: try event(.leftMouseDown))
            target.mouseUp(with: try event(.leftMouseUp))
        }
        try click("checkout", count: 1)
        try click("checkout", count: 2)
        try click("export", count: 1)
        try click("export", count: 2)
        try click("login", count: 2)
        try click("lead", count: 1)
        try click("export", count: 1, at: 10)
        try click("export", count: 2, at: 60)
        XCTAssertEqual(selected, ["checkout", "export", "login", "lead"])
        XCTAssertEqual(requested.map(\.0), ["export", "export", "export"])
        XCTAssertTrue(requested.first?.1 === rail.itemViews["export"], "anchored to the icon itself")

        let export = try XCTUnwrap(rail.itemViews["export"])
        let open = try XCTUnwrap(export.accessibilityCustomActions()?.first)
        XCTAssertEqual(open.name, "Open task")
        XCTAssertEqual(open.handler?(), true)
        XCTAssertEqual(selected.last, "export")
        XCTAssertNil(rail.itemViews["checkout"]?.accessibilityCustomActions(), "only a waiting task needs it")
    }

    /// VoiceOver finds the Lead, each task by name and state in the rail's
    /// order, even after one arrives above the others, then the buttons
    /// under the rail.
    func testVoiceOverFindsEveryTask() {
        var archived = content
        archived.archivedCount = 2
        let rail = rail(archived)
        XCTAssertEqual(spoken(rail), [
            "Lead, Working, at Reviews", "Checkout, Working, at Code", "Export, Needs you: a permission",
            "Login, Failed", "Filters, Merged", "Archived tasks, 2", "New task", "Board",
        ])
        var arrived = content
        arrived.tasks.insert(item("audit", StateIcon(.idle)), at: 0)
        rail.show(arrived)
        XCTAssertEqual(Array(spoken(rail).prefix(3)), ["Lead, Working, at Reviews", "Audit, Idle", "Checkout, Working, at Code"])
    }

    /// A task keeps its view as its state changes; a gone task loses it; an
    /// id listed twice shows once; a long list keeps the task on screen in
    /// view by itself, when it shows and when it changes.
    func testViewsLastAndTheRailScrolls() throws {
        let rail = rail(content)
        let checkout = try XCTUnwrap(rail.itemViews["checkout"])
        var changed = content
        changed.tasks[0].icon = StateIcon(.needsYou(.question), stage: 1)
        changed.tasks.removeLast()
        rail.show(changed)
        XCTAssertTrue(rail.itemViews["checkout"] === checkout)
        XCTAssertFalse(checkout.ring.isHidden)
        XCTAssertNil(rail.itemViews["filters"])

        var twice = content
        twice.tasks += [twice.lead!, twice.tasks[0]]
        rail.show(twice)
        XCTAssertEqual(rail.content.tasks.map(\.id), ["checkout", "export", "login", "filters"])
        XCTAssertEqual(rail.itemViews.count, 5)

        var many = content
        many.tasks = (0..<40).map { item("task\($0)", StateIcon(.idle)) }
        many.selectedID = "task39"
        let long = self.rail(many, height: 400)
        let last = try XCTUnwrap(long.itemViews["task39"])
        let clip = try XCTUnwrap(last.enclosingScrollView?.contentView)
        XCTAssertTrue(clip.documentVisibleRect.contains(last.frame), "the task on screen is in view")
        many.selectedID = "task0"
        long.show(many)
        long.layoutSubtreeIfNeeded()
        let first = try XCTUnwrap(long.itemViews["task0"])
        XCTAssertTrue(clip.documentVisibleRect.contains(first.frame), "and the next one too")
        XCTAssertNotNil(long.iconFrame(of: "task0"))
        XCTAssertNil(long.iconFrame(of: "task39"), "scrolled out of view: no place to aim at")
    }

    private func button(in view: NSView) throws -> NSButton {
        func find(_ view: NSView) -> NSButton? { (view as? NSButton) ?? view.subviews.lazy.compactMap(find).first }
        return try XCTUnwrap(find(view))
    }

    /// Under the capsule, top to bottom: the archived tasks while there are
    /// some, a new task, then the Board at the rail's foot; each press
    /// reaches its callback, and the tooltips say the chords.
    func testTheButtonsUnderTheCapsule() throws {
        let rail = rail(content)
        XCTAssertTrue(rail.archivedButton.isHidden, "no archived task: no button")
        XCTAssertEqual(rail.boardButton.frame.maxY, rail.bounds.maxY, "the Board at the foot")
        XCTAssertEqual(rail.newButton.frame.maxY + Theme.Space.sm, rail.boardButton.frame.minY)
        var archived = content
        archived.archivedCount = 3
        rail.show(archived)
        rail.layoutSubtreeIfNeeded()
        XCTAssertFalse(rail.archivedButton.isHidden)
        XCTAssertEqual(rail.archivedButton.frame.maxY + Theme.Space.sm, rail.newButton.frame.minY)
        XCTAssertEqual(rail.boardButton.frame.maxY, rail.bounds.maxY)
        XCTAssertEqual(rail.archivedButton.toolTip, "Archived tasks (3)")
        XCTAssertEqual(rail.newButton.toolTip, "New task (\(NiruxShortcuts.newWorkspaceDisplay))")
        XCTAssertEqual(rail.boardButton.toolTip, "Board (\(NiruxShortcuts.board.chord.display))")

        var pressed: [String] = []
        rail.onArchived = { pressed.append("archived") }
        rail.onNew = { pressed.append("new") }
        rail.onBoard = { pressed.append("board") }
        for round in [rail.archivedButton, rail.newButton, rail.boardButton] { try button(in: round).performClick(nil) }
        XCTAssertEqual(pressed, ["archived", "new", "board"])
    }

    /// A working agent's icon breathes, at most 15 frames a second, the
    /// Lead's sign too; nothing else does, and nothing does while icons may
    /// not move. A breath keeps its beat across refreshes.
    func testWorkingIconsBreathe() throws {
        let rail = rail(content)
        func breath(_ view: NSView?) -> CABasicAnimation? {
            view?.layer?.animation(forKey: RailItemView.breathKey) as? CABasicAnimation
        }
        let checkout = try XCTUnwrap(rail.itemViews["checkout"])
        let lead = try XCTUnwrap(rail.itemViews["lead"])
        let beat = try XCTUnwrap(breath(checkout.iconView), "working")
        XCTAssertEqual(beat.preferredFrameRateRange.maximum, 15)
        XCTAssertEqual(beat.preferredFrameRateRange.minimum, 8)
        XCTAssertEqual(beat.preferredFrameRateRange.preferred, 12)
        XCTAssertNotNil(breath(lead.leadIcon), "the Lead's sign, which shows")
        XCTAssertNil(breath(lead.iconView), "not its hidden icon")
        for id in ["export", "login", "filters"] { XCTAssertNil(breath(rail.itemViews[id]?.iconView), id) }

        var refreshed = content
        refreshed.selectedID = "login"
        rail.show(refreshed)
        XCTAssertTrue(breath(checkout.iconView) === beat, "the same breath, its beat kept")
        rail.animates = false
        XCTAssertNil(breath(checkout.iconView))
        XCTAssertNil(breath(lead.leadIcon))
        rail.animates = true
        XCTAssertNotNil(breath(checkout.iconView))
        refreshed.tasks[0].icon = StateIcon(.idle)
        rail.show(refreshed)
        XCTAssertNil(breath(checkout.iconView), "its agent stopped")
    }

    /// A right-click on an icon opens its task's menu; an icon's frame is
    /// found by its task.
    func testAnIconsMenuAndFrame() throws {
        let rail = rail(content)
        rail.menuForTask = { NSMenu(title: $0) }
        let login = try XCTUnwrap(rail.itemViews["login"])
        let event = try XCTUnwrap(NSEvent.mouseEvent(
            with: .rightMouseDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
            context: nil, eventNumber: 0, clickCount: 1, pressure: 0
        ))
        XCTAssertEqual(login.menu(for: event)?.title, "login")
        XCTAssertEqual(rail.iconFrame(of: "login"), rail.convert(login.bounds, from: login))
        XCTAssertNil(rail.iconFrame(of: "gone"))
    }

    /// A born task's icon opens with a spring from just above its place, and
    /// the icons under it give way by one place, up the screen in the
    /// flipped list; nothing above moves, nor the buttons. A list that
    /// scrolls pushes nothing; icons that may not move stop their birth.
    func testABornIconOpensAndTheIconsUnderItGiveWay() throws {
        let rail = rail(content)
        let opens = CACurrentMediaTime() + 0.2
        rail.playBirth(of: "export", opens: opens)
        let born = try XCTUnwrap(rail.itemViews["export"]?.layer)
        let appear = try XCTUnwrap(born.animation(forKey: SidebarView.birthKey) as? CABasicAnimation)
        XCTAssertEqual(appear.beginTime, opens, accuracy: 0.001)
        let spring = try XCTUnwrap(born.animation(forKey: SidebarView.birthSpringKey) as? CASpringAnimation)
        XCTAssertEqual((spring.fromValue as? NSNumber)?.doubleValue, -8, "from above, in a flipped list")
        let key = SidebarView.birthPushKey("export")
        for id in ["login", "filters"] {
            let push = try XCTUnwrap(rail.itemViews[id]?.layer?.animation(forKey: key) as? CASpringAnimation, id)
            XCTAssertEqual((push.fromValue as? NSNumber)?.doubleValue, -Double(IconRail.pitch), id)
        }
        for id in ["lead", "checkout"] { XCTAssertNil(rail.itemViews[id]?.layer?.animation(forKey: key), id) }
        XCTAssertNil(rail.separator.layer?.animation(forKey: key), "the line is above it")
        for round in [rail.archivedButton, rail.newButton, rail.boardButton] { XCTAssertNil(round.layer?.animation(forKey: key)) }

        rail.animates = false
        XCTAssertNil(born.animation(forKey: SidebarView.birthKey))
        XCTAssertNil(rail.itemViews["login"]?.layer?.animation(forKey: key))

        var many = content
        many.tasks = (0..<40).map { item("task\($0)", StateIcon(.idle)) }
        many.selectedID = "task0"
        let long = self.rail(many, height: 400)
        long.playBirth(of: "task0", opens: opens)
        XCTAssertNotNil(long.itemViews["task0"]?.layer?.animation(forKey: SidebarView.birthKey))
        XCTAssertNil(long.itemViews["task1"]?.layer?.animation(forKey: SidebarView.birthPushKey("task0")), "the list scrolls")
        XCTAssertFalse(long.playBirth(of: "gone", opens: opens), "not shown: not played")
    }
}
