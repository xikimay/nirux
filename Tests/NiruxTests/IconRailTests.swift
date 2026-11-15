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
        let event = try XCTUnwrap(NSEvent.enterExitEvent(
            with: .mouseEntered, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
            context: nil, eventNumber: 0, trackingNumber: 0, userData: nil
        ))
        login.mouseEntered(with: event)
        XCTAssertFalse(login.halo.isHidden)
        XCTAssertEqual(login.halo.layer?.backgroundColor, Theme.Color.fillHover.cgColor)
        login.mouseExited(with: event)
        XCTAssertTrue(login.halo.isHidden)

        let empty = self.rail(IconRail.Content(lead: nil, tasks: []))
        XCTAssertTrue(empty.separator.isHidden && empty.itemViews.isEmpty, "an empty rail draws no line")
    }

    /// A click anywhere on an icon goes to its task, once even in a
    /// double-click; on a waiting task it asks for the request, anchored to
    /// the icon, and a double-click goes to the task, as VoiceOver's "Open
    /// task" does. A double-click whose first click never came here counts
    /// as a first click.
    func testAClickGoesToATaskOrAsksForItsRequest() throws {
        let rail = rail(content)
        var selected: [String] = [], requested: [(String, NSView)] = []
        rail.onSelect = { selected.append($0) }
        rail.onRequest = { requested.append(($0, $1)) }
        func click(_ id: String, count: Int) throws {
            let view = try XCTUnwrap(rail.itemViews[id])
            let point = view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil)
            let target = try XCTUnwrap(rail.hitTest(rail.superview?.convert(point, from: nil) ?? point))
            XCTAssertTrue(target === view, "the click reaches \(id)'s icon, not a drawing on it")
            XCTAssertTrue(target.acceptsFirstMouse(for: nil), "it acts in a window in the background")
            func event(_ type: NSEvent.EventType) throws -> NSEvent {
                try XCTUnwrap(NSEvent.mouseEvent(
                    with: type, location: point, modifierFlags: [], timestamp: 0,
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
        XCTAssertEqual(selected, ["checkout", "export", "login", "lead"])
        XCTAssertEqual(requested.map(\.0), ["export"])
        XCTAssertTrue(requested.first?.1 === rail.itemViews["export"], "anchored to the icon itself")

        let export = try XCTUnwrap(rail.itemViews["export"])
        let open = try XCTUnwrap(export.accessibilityCustomActions()?.first)
        XCTAssertEqual(open.name, "Open task")
        XCTAssertEqual(open.handler?(), true)
        XCTAssertEqual(selected.last, "export")
        XCTAssertNil(rail.itemViews["checkout"]?.accessibilityCustomActions(), "only a waiting task needs it")
    }

    /// VoiceOver finds the Lead, each task by name and state in the rail's
    /// order, even after one arrives above the others, then the two buttons
    /// under the rail.
    func testVoiceOverFindsEveryTask() {
        let rail = rail(content)
        XCTAssertEqual(spoken(rail), [
            "Lead, Working, at Reviews", "Checkout, Working, at Code", "Export, Needs you: a permission",
            "Login, Failed", "Filters, Merged", "Archived tasks", "New task",
        ])
        var arrived = content
        arrived.tasks.insert(item("audit", StateIcon(.idle)), at: 0)
        rail.show(arrived)
        XCTAssertEqual(Array(spoken(rail).prefix(3)), ["Lead, Working, at Reviews", "Audit, Idle", "Checkout, Working, at Code"])
    }

    /// A task keeps its view as its state changes; a gone task loses it; an
    /// id listed twice shows once; a long list keeps the task on screen in
    /// view by itself.
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
    }
}
