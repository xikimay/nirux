import AppKit
import XCTest
@testable import Nirux

/// The glass interface's rail (docs/design/glass-interface.md).
@MainActor
final class IconRailTests: XCTestCase {
    private var windows: [NSWindow] = []

    private func item(_ id: String, _ icon: StateIcon, selected: Bool = false) -> IconRail.Item {
        IconRail.Item(id: id, title: id.capitalized, icon: icon, isSelected: selected)
    }

    private var content: IconRail.Content {
        IconRail.Content(lead: item("lead", StateIcon(.working, stage: 2)), tasks: [
            item("checkout", StateIcon(.working, stage: 1), selected: true),
            item("export", StateIcon(.needsYou(.command), stage: 1)),
            item("login", StateIcon(.error, stage: 3)),
            item("filters", StateIcon(.merged)),
        ])
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

    /// The task on screen wears the halo; only a task waiting for the user
    /// wears the amber ring; the Lead shows its sign.
    func testTheHaloAndTheRingMarkWhatMatters() throws {
        let rail = rail(content)
        let views = rail.itemViews
        XCTAssertEqual(views.filter { !$0.value.halo.isHidden }.map(\.key), ["checkout"])
        XCTAssertEqual(views.filter { !$0.value.ring.isHidden }.map(\.key), ["export"])
        XCTAssertEqual(try XCTUnwrap(views["export"]).ring.layer?.borderColor, Theme.Color.waiting.cgColor)
        XCTAssertTrue(try XCTUnwrap(views["lead"]).iconView.isHidden, "the Lead shows its sign, not a state icon")
        let order = [rail.content.lead!] + rail.content.tasks
        let tops = order.compactMap { views[$0.id]?.frame.minY }
        XCTAssertEqual(tops, tops.sorted(), "in the sidebar's order, the Lead first")
    }

    /// A click goes to a task, once even in a double-click; on a waiting task
    /// it asks for the request, anchored to its icon, and a double-click goes
    /// to the task.
    func testAClickGoesToATaskOrAsksForItsRequest() throws {
        let rail = rail(content)
        var selected: [String] = [], requested: [(String, NSRect)] = []
        rail.onSelect = { selected.append($0) }
        rail.onRequest = { requested.append(($0, $1)) }
        func click(_ id: String, count: Int) throws {
            let view = try XCTUnwrap(rail.itemViews[id])
            let point = view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil)
            let event = try XCTUnwrap(NSEvent.mouseEvent(
                with: .leftMouseUp, location: point, modifierFlags: [], timestamp: 0,
                windowNumber: view.window?.windowNumber ?? 0, context: nil, eventNumber: 0, clickCount: count, pressure: 0
            ))
            view.mouseUp(with: event)
        }
        try click("checkout", count: 1)
        try click("checkout", count: 2)
        try click("export", count: 1)
        try click("export", count: 2)
        XCTAssertEqual(selected, ["checkout", "export"])
        XCTAssertEqual(requested.map(\.0), ["export"])
        let exportFrame = rail.convert(try XCTUnwrap(rail.itemViews["export"]).bounds, from: rail.itemViews["export"])
        XCTAssertEqual(requested.first?.1, exportFrame)
    }

    /// VoiceOver finds the Lead, each task by name and state, then the two
    /// buttons under the rail.
    func testVoiceOverFindsEveryTask() {
        let spoken = NSAccessibility.unignoredChildren(from: rail(content).accessibilityChildren() ?? []).map { element in
            (element as? NSCell)?.accessibilityLabel() ?? (element as? NSView)?.accessibilityLabel() ?? "?"
        }
        XCTAssertEqual(spoken, [
            "Lead, Working, at Reviews", "Checkout, Working, at Code", "Export, Needs you: a permission",
            "Login, Failed", "Filters, Merged", "Archived tasks", "New task",
        ])
    }

    /// A task keeps its view as its state changes; a gone task loses it; a
    /// long list scrolls the task on screen into view.
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

        var many = content
        many.tasks = (0..<40).map { item("task\($0)", StateIcon(.idle), selected: $0 == 39) }
        let long = self.rail(many, height: 400)
        long.revealSelection()
        let last = try XCTUnwrap(long.itemViews["task39"])
        let clip = try XCTUnwrap(last.enclosingScrollView?.contentView)
        XCTAssertTrue(clip.documentVisibleRect.intersects(last.frame), "the task on screen is in view")
    }
}
