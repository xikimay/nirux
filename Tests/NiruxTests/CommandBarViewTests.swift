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
        full.show(content(waiting: 0))
        full.layoutSubtreeIfNeeded()
        XCTAssertTrue(full.waitingBadge.isHidden && full.waitingButton.isHidden, "nothing waits: no badge")
        let empty = bar(content(waiting: 0, task: nil))
        XCTAssertEqual(empty.taskLabel.stringValue, "Nothing open")
        XCTAssertTrue(empty.taskIcon.isHidden)
    }

    /// As the bar narrows, the task's detail goes first, then the space's
    /// name, then the search's key; the signs stay, and nothing overlaps.
    func testItGivesWayInOrder() throws {
        let bar = bar(width: 640, content(waiting: 12))
        var hiddenAt: [String: CGFloat] = [:]
        for width in stride(from: 640, through: 200, by: -4) {
            bar.frame.size.width = CGFloat(width)
            bar.layoutSubtreeIfNeeded()
            let slots: [(String, NSView)] = [
                ("detail", bar.detailLabel), ("space name", bar.spaceLabel), ("search key", bar.searchKey),
                ("waiting key", bar.waitingKey),
            ]
            func textWidth(_ label: NSTextField) -> CGFloat { ceil(label.attributedStringValue.size().width) + 4 }
            if !bar.detailLabel.isHidden {
                XCTAssertGreaterThanOrEqual(bar.detailLabel.frame.width, textWidth(bar.detailLabel), "a shown detail is whole at \(width) pt")
            }
            if !bar.detailLabel.isHidden || !bar.spaceLabel.isHidden {
                XCTAssertGreaterThanOrEqual(bar.taskLabel.frame.width, min(textWidth(bar.taskLabel), 120) - 0.5,
                                            "the title keeps its floor before anything gives way, at \(width) pt")
            }
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
            XCTAssertLessThanOrEqual(visible.last?.frame.maxX ?? 0, CGFloat(width), "inside the bar at \(width) pt")
        }
        let detail = try XCTUnwrap(hiddenAt["detail"], "the detail never went")
        let name = try XCTUnwrap(hiddenAt["space name"], "the space's name never went")
        let key = try XCTUnwrap(hiddenAt["search key"], "the search's key never went")
        XCTAssertGreaterThan(detail, name, "the detail goes before the space's name")
        XCTAssertGreaterThan(name, key, "the space's name goes before the search's key")
        let waitingKey = try XCTUnwrap(hiddenAt["waiting key"], "the waiting count's key never went")
        XCTAssertGreaterThan(key, waitingKey, "the search's key goes before the waiting count's key")
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
        // A press on the search segment while ⌘P shows closes the palette,
        // as one on the title bar's Search does.
        bar.frame.origin = NSPoint(x: 20, y: 20)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 100), styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView?.addSubview(bar)
        bar.layoutSubtreeIfNeeded()
        func press(_ button: NSButton) -> NSEvent? {
            NSEvent.mouseEvent(
                with: .leftMouseDown, location: button.convert(NSPoint(x: button.bounds.midX, y: button.bounds.midY), to: nil),
                modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1
            )
        }
        XCTAssertTrue(press(bar.searchButton).map(CommandPalette.isSearchButtonPress) == true)
        XCTAssertTrue(press(bar.taskButton).map(CommandPalette.isSearchButtonPress) == false)
    }

    /// VoiceOver finds the four segments, named, and nothing else: it reads
    /// what AppKit exposes (a control's cell), not the controls' own labels.
    func testVoiceOverFindsFourNamedSegments() {
        func spoken(_ bar: CommandBarView) -> [String] {
            NSAccessibility.unignoredChildren(from: bar.accessibilityChildren() ?? []).map { element in
                (element as? NSCell)?.accessibilityLabel() ?? (element as? NSView)?.accessibilityLabel() ?? "?"
            }
        }
        XCTAssertEqual(spoken(bar(content())), [
            "Space: Acme", "Fix checkout rounding, Working, at Code, working 12m",
            "Search, Command P", "2 agents waiting for you, Command J",
        ])
        XCTAssertEqual(spoken(bar(content(waiting: 0, task: nil))), ["Space: Acme", "Nothing open", "Search, Command P"])
    }
}
