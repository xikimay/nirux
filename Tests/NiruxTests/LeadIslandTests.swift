import AppKit
import XCTest
@testable import Nirux

/// The Lead island (LeadIslandView): its capsule beside the command bar and its panel.
@MainActor
final class LeadIslandTests: XCTestCase {
    private func island() throws -> Plan {
        var plan = Plan()
        try plan.add(Plan.Line(id: "a", kind: .lead, title: "Run the noon train", by: .lead, at: 1), to: .top)
        try plan.add(Plan.Line(id: "t", kind: .todo, title: "Reply to the printer", by: .user, at: 1), to: .top)
        try plan.add(Plan.Line(id: "b", kind: .lead, title: "Close yesterday's tasks", by: .lead, at: 1), to: .top)
        try plan.add(Plan.Line(id: "p", kind: .session, title: "Page texts", by: .lead, at: 1, after: "t"), to: .top)
        return plan
    }

    /// Now, For you with Done, then Next, a planned session saying what it waits for.
    func testThePanelSaysNowForYouAndNextAndDoneChecks() throws {
        let plan = try island()
        let panel = LeadIslandPanel(island: plan.island) { plan.line($0)?.title }
        var done: [String] = []
        panel.onDone = { done.append($0) }
        let views = { (view: NSView) -> [NSView] in
            var all: [NSView] = []
            var queue = [view]
            while let next = queue.popLast() {
                all.append(next)
                queue += next.subviews
            }
            return all
        }(panel.view)
        let texts = views.compactMap { ($0 as? NSTextField)?.stringValue }
        for text in ["Now · Lead", "Run the noon train", "For you", "Reply to the printer", "Next", "Close yesterday's tasks", "Page texts · after “Reply to the printer”"] {
            XCTAssertTrue(texts.contains(text), "\(text) in \(texts)")
        }
        let button = try XCTUnwrap(views.compactMap { $0 as? NiruxButton }.first { $0.accessibilityLabel() == "Done: Reply to the printer" })
        button.performClick(nil)
        XCTAssertEqual(done, ["t"])
    }

    /// The capsule says the Lead's line and the to-dos; the toolbar shows it left of the bar, then takes it away.
    func testTheToolbarShowsTheIslandBesideTheBarThenTakesItAway() throws {
        let host = NiruxApp.makeMainWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800))
        host.isReleasedWhenClosed = false
        defer { host.close() }
        let toolbar = CommandBarToolbar(bar: CommandBarView(level: .opaque))
        toolbar.install(in: host)
        XCTAssertFalse(toolbar.toolbar.items.contains { $0.view === toolbar.island })
        XCTAssertFalse(CommandBarToolbar(bar: CommandBarView(level: .opaque)).showIsland(LeadIslandView.Content(now: nil, forYou: 0)),
                       "with no window, the sidebar keeps the Lead's lines")
        toolbar.showIsland(LeadIslandView.Content(now: "Run the noon train", forYou: 1))
        XCTAssertEqual(toolbar.toolbar.items.map(\.itemIdentifier), [CommandBarToolbar.islandItemID, CommandBarToolbar.barItemID])
        host.contentView?.superview?.layoutSubtreeIfNeeded()
        XCTAssertTrue(toolbar.showIsland(LeadIslandView.Content(now: "Run the noon train", forYou: 1)), "on screen beside the bar")
        XCTAssertEqual(toolbar.island.button.accessibilityLabel(), "Lead, Run the noon train, 1 for you")
        toolbar.showIsland(nil)
        XCTAssertEqual(toolbar.toolbar.items.map(\.itemIdentifier), [CommandBarToolbar.barItemID])
    }
}
