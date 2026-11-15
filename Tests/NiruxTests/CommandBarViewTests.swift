import AppKit
import XCTest
@testable import Nirux

/// The glass interface's command bar (docs/design/glass-interface.md).
@MainActor
final class CommandBarViewTests: XCTestCase {
    private func content(waiting: Int = 2, task: String? = "Fix checkout rounding") -> CommandBarView.Content {
        CommandBarView.Content(
            spaceName: "Acme", spaceColor: Theme.Color.working, taskTitle: task,
            taskIcon: task == nil ? nil : StateIcon(.working, stage: 1), taskDetail: task == nil ? nil : "working 12m",
            waitingCount: waiting
        )
    }

    private func bar(width: CGFloat = 600, _ content: CommandBarView.Content) -> CommandBarView {
        let bar = CommandBarView(level: .opaque)
        bar.frame = NSRect(x: 0, y: 0, width: width, height: CommandBarView.height)
        bar.show(content)
        bar.layoutSubtreeIfNeeded()
        return bar
    }

    /// The space, the task and its state, the search, and the count of
    /// agents waiting, only while one waits; a space with nothing open says
    /// so.
    func testItShowsWhatItIsGiven() {
        let full = bar(content())
        XCTAssertEqual(full.spaceLabel.stringValue, "Acme")
        XCTAssertEqual(full.taskLabel.stringValue, "Fix checkout rounding")
        XCTAssertEqual(full.detailLabel.stringValue, "· working 12m")
        XCTAssertEqual(full.taskIcon.icon, StateIcon(.working, stage: 1))
        XCTAssertFalse(full.waitingBadge.isHidden)
        XCTAssertEqual(full.waitingButton.accessibilityLabel(), "2 agents waiting for you, Command J")
        XCTAssertEqual(full.taskButton.accessibilityLabel(), "Fix checkout rounding, Working, at Code, working 12m")
        full.show(content(waiting: 0))
        full.layoutSubtreeIfNeeded()
        XCTAssertTrue(full.waitingBadge.isHidden && full.waitingButton.isHidden, "nothing waits: no badge")
        let empty = bar(content(waiting: 0, task: nil))
        XCTAssertEqual(empty.taskLabel.stringValue, "Nothing open")
        XCTAssertTrue(empty.taskIcon.isHidden)
    }

    /// As the bar narrows, the task's detail goes first, then the space's
    /// name, then the search's key; the signs stay, and nothing overlaps.
    func testItGivesWayInOrder() {
        let bar = bar(width: 640, content(waiting: 12))
        var hiddenAt: [String: CGFloat] = [:]
        for width in stride(from: 640, through: 200, by: -4) {
            bar.frame.size.width = CGFloat(width)
            bar.layoutSubtreeIfNeeded()
            let slots: [(String, NSView)] = [
                ("detail", bar.detailLabel), ("space name", bar.spaceLabel), ("search key", bar.searchKey),
            ]
            for (name, view) in slots where view.isHidden && hiddenAt[name] == nil { hiddenAt[name] = CGFloat(width) }
            for (name, view) in slots where hiddenAt[name] != nil {
                XCTAssertTrue(view.isHidden, "\(name) came back at \(width) pt")
            }
            for sign in [bar.spaceChip, bar.taskIcon, bar.searchIcon, bar.waitingBadge] {
                XCTAssertFalse(sign.isHidden, "a sign went at \(width) pt")
            }
            let visible = [bar.spaceChip, bar.spaceLabel, bar.spaceChevron, bar.taskIcon, bar.taskLabel, bar.detailLabel,
                           bar.searchIcon, bar.searchKey, bar.waitingBadge, bar.waitingKey].filter { !$0.isHidden }
            for (left, right) in zip(visible, visible.dropFirst()) {
                XCTAssertLessThanOrEqual(left.frame.maxX, right.frame.minX + 0.5, "overlap at \(width) pt")
            }
            XCTAssertLessThanOrEqual(bar.waitingKey.frame.maxX, CGFloat(width), "inside the bar at \(width) pt")
        }
        let detail = try? XCTUnwrap(hiddenAt["detail"]), name = try? XCTUnwrap(hiddenAt["space name"])
        let key = try? XCTUnwrap(hiddenAt["search key"])
        XCTAssertGreaterThan(detail ?? 0, name ?? 0, "the detail goes before the space's name")
        XCTAssertGreaterThan(name ?? 0, key ?? 0, "the space's name goes before the search's key")
    }

    /// Each segment acts on its own.
    func testEachSegmentActs() {
        let bar = bar(content())
        var pressed: [String] = []
        bar.onSpace = { pressed.append("space") }
        bar.onTask = { pressed.append("task") }
        bar.onSearch = { pressed.append("search") }
        bar.onWaiting = { pressed.append("waiting") }
        for button in [bar.spaceButton, bar.taskButton, bar.searchButton, bar.waitingButton] { button.performClick(nil) }
        XCTAssertEqual(pressed, ["space", "task", "search", "waiting"])
        XCTAssertEqual(bar.spaceButton.accessibilityLabel(), "Space: Acme")
        XCTAssertEqual(bar.searchButton.accessibilityLabel(), "Search, Command P")
    }
}
