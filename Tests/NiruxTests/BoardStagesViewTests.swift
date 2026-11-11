import XCTest
@testable import Nirux

/// The Board as stages, drawn (docs/design/board-stages.md): which lines
/// it shows and how each is joined to the others, what a click says, the
/// fold of the pull requests without a task, "Merged today", and the
/// columns that give way on a narrow Board. Nothing is put on screen.
@MainActor
final class BoardStagesViewTests: XCTestCase {
    private let now: TimeInterval = 1_794_405_600
    /// Never shown; kept for as long as the test runs.
    private var windows: [NSWindow] = []

    private func line(_ id: String, since: TimeInterval? = nil, rail: Bool = true) -> BoardStages.Line {
        BoardStages.Line(
            id: id, title: id.capitalized, station: .checks, state: .waiting,
            rail: rail ? BoardStages.Rail(marks: [.done, .done, .current, .ahead]) : nil,
            phrase: BoardStages.Phrase(text: "Checks running"), pullRequest: rail ? "#52" : "", since: since
        )
    }

    private func content(
        units: [BoardStages.Unit], withoutTask: [BoardStages.Unit] = [], merged: [BoardStages.Merged] = [], now: TimeInterval? = nil
    ) -> BoardStagesView.Content {
        BoardStagesView.Content(
            header: BoardStagesView.Header(
                name: "nirux-public", color: Theme.Color.accent, summary: "1 repository · 3 tasks",
                lead: BoardStagesView.Lead(state: .working, text: "Lead · reviewing #438")
            ),
            order: .sidebar,
            sections: [BoardStagesView.Section(
                id: "nirux", title: "nirux", detail: "xikimay/nirux", status: nil,
                lines: BoardStages.Section(id: "nirux", units: units, withoutTask: withoutTask, merged: merged)
            )],
            now: now ?? self.now
        )
    }

    /// The view in a window that is never shown, laid out at `width`.
    private func board(_ content: BoardStagesView.Content, width: CGFloat = 940) -> BoardStagesView {
        let view = BoardStagesView(frame: NSRect(x: 0, y: 0, width: width, height: 600))
        let window = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.contentView = view
        windows.append(window)
        view.show(content)
        view.layoutSubtreeIfNeeded()
        return view
    }

    /// Clicks what is under `view`'s middle: `view` itself, or the line it
    /// is in, which takes the mouse for its words. A window that is never
    /// shown drops events sent with `sendEvent`, so they are hit-tested
    /// and handed over by hand; a button's own press would wait for the
    /// mouse to come up.
    private func click(_ view: NSView) throws {
        let window = try XCTUnwrap(view.window)
        let contentView = try XCTUnwrap(window.contentView)
        contentView.layoutSubtreeIfNeeded()
        let frameView = try XCTUnwrap(contentView.superview)
        let location = view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil)
        let hitView = try XCTUnwrap(contentView.hitTest(frameView.convert(location, from: nil)))
        XCTAssertTrue(hitView === view || view.isDescendant(of: hitView) && hitView is BoardStagesLineView,
                      "\(hitView) is under the pointer, not \(view)")
        if let button = hitView as? NSButton { return button.performClick(nil) }
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = try XCTUnwrap(NSEvent.mouseEvent(
                with: type, location: location, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                context: nil, eventNumber: 0, clickCount: 1, pressure: 1
            ))
            if type == .leftMouseDown { hitView.mouseDown(with: event) } else { hitView.mouseUp(with: event) }
        }
    }

    // MARK: - Lines

    func testTheLinesAreDrawnInOrderEachJoinedToItsOwn() {
        let view = board(content(units: [
            .task(line("task"), subtasks: [line("first"), line("last")]),
            .stack(title: "Stack · 2 pull requests on main", [line("one"), line("two")]),
            .task(line("alone"), subtasks: [])
        ]))
        XCTAssertEqual(view.lineViews.map(\.line.id), ["task", "first", "last", "one", "two", "alone"])
        XCTAssertEqual(view.lineViews.map(\.link), [
            .head, .subtask(isLast: false), .subtask(isLast: true), .stack(number: 1, isLast: false),
            .stack(number: 2, isLast: true), .none
        ])
        let frames = view.lineViews.map(\.frame)
        XCTAssertEqual(frames.map(\.height), Array(repeating: BoardStagesView.Metrics.lineHeight, count: 6))
        XCTAssertEqual(frames.map(\.minY), frames.map(\.minY).sorted(), "from the top, none over another")
        XCTAssertEqual(frames[3].minY - frames[2].maxY, BoardStagesView.Metrics.captionHeight, "the stack's title sits above its lines")
        let inset = view.lineViews.map { $0.dotCenter.x - BoardStagesView.Metrics.connectorX }
        XCTAssertEqual(inset, [0, 26, 26, 26, 26, 0], "a sub-task and a stack's line sit in from their connector")
    }

    func testAClickOnALineOpensItsTask() throws {
        let view = board(content(units: [.task(line("task"), subtasks: [line("sub")])]))
        var opened: [String] = []
        view.onOpen = { opened.append($0) }
        try click(view.lineViews[1].titleLabel)
        try click(view.lineViews[0])
        XCTAssertEqual(opened, ["sub", "task"], "anywhere on the line, its words included")
    }

    func testALineWithoutARepositorySaysSoInPlaceOfItsRail() {
        let view = board(content(units: [.task(line("folder", rail: false), subtasks: []), .task(line("task"), subtasks: [])]))
        XCTAssertEqual(view.lineViews.map(\.noRailLabel.isHidden), [false, true])
        XCTAssertEqual(view.lineViews[0].noRailLabel.stringValue, "no pull request")
        XCTAssertEqual(BoardStagesLineView.accessibilityLabel(of: line("folder", rail: false)), "Folder, Checks running")
        XCTAssertEqual(BoardStagesLineView.accessibilityLabel(of: line("task")), "Task, at Checks, Checks running, #52")
    }

    func testTheClockMovesWithoutBuildingTheLinesAgain() {
        let units = [BoardStages.Unit.task(line("task", since: now - 12 * 60), subtasks: [line("still")])]
        let view = board(content(units: units))
        let drawn = view.lineViews
        XCTAssertEqual(drawn.map(\.timeLabel.stringValue), ["12 min", ""], "a line without a clock shows none")
        view.show(content(units: units, now: now + 3600))
        XCTAssertEqual(view.lineViews.map(\.timeLabel.stringValue), ["1 h", ""])
        XCTAssertTrue(zip(view.lineViews, drawn).allSatisfy { $0 === $1 }, "only the clock changed")
        XCTAssertEqual([30, 60, 59 * 60 + 59, 23 * 3600, 49 * 3600].map(BoardStagesView.duration), ["now", "1 min", "59 min", "23 h", "2 d"])
    }

    // MARK: - Header

    func testTheOrderSwitchSaysTheOrderAsked() {
        let view = board(content(units: []))
        var asked: [BoardStages.Order] = []
        view.onOrder = { asked.append($0) }
        XCTAssertEqual(view.orderSwitch.selectedSegment, 0, "the sidebar's order, as the content says")
        for segment in [1, 0] {
            view.orderSwitch.selectedSegment = segment
            view.orderSwitch.sendAction(view.orderSwitch.action, to: view.orderSwitch.target)
        }
        XCTAssertEqual(asked, [.progress, .sidebar])
        XCTAssertEqual(view.nameLabel.stringValue, "nirux-public")
        XCTAssertEqual(view.leadLabel.stringValue, "Lead · reviewing #438")
        XCTAssertFalse(view.leadLabel.frame.intersects(view.orderSwitch.frame), "the Lead sits before the switch")
        var withoutLead = content(units: [])
        withoutLead.header.lead = nil
        view.show(withoutLead)
        XCTAssertTrue(view.leadLabel.isHidden && view.leadDot.isHidden, "a space without a Lead shows none")
    }

    func testAmberMeansAnAgentWaitsForTheUserAndNothingElse() {
        let states: [BoardStages.State] = [.needsYou, .failed, .working, .blocked, .waiting, .ready, .merged, .idle]
        let amber = states.filter { BoardStagesView.color(of: $0) == Theme.Color.waiting }
        XCTAssertEqual(amber, [.needsYou])
        XCTAssertEqual(states.filter { BoardStagesLineView.phraseColor(of: $0) == Theme.Color.waiting }, [.needsYou])
        XCTAssertEqual(states.filter { BoardStagesLineView.phraseColor(of: $0) == Theme.Color.error }, [.failed], "red for a failure only")
    }

    // MARK: - Folded and merged

    func testThePullRequestsWithoutATaskStartFolded() throws {
        let view = board(content(
            units: [.task(line("task"), subtasks: [])],
            withoutTask: [.stack(title: "Stack · 2 pull requests on main", [line("pr1"), line("pr2")]), .task(line("pr3"), subtasks: [])]
        ))
        let fold = try XCTUnwrap(view.foldButton(section: "nirux"))
        XCTAssertEqual(fold.attributedTitle.string, "▸ Pull requests without a task · 3", "it counts pull requests")
        XCTAssertEqual(view.lineViews.map(\.line.id), ["task"])
        try click(fold)
        XCTAssertEqual(view.lineViews.map(\.line.id), ["task", "pr1", "pr2", "pr3"])
        XCTAssertEqual(view.foldButton(section: "nirux")?.attributedTitle.string, "▾ Pull requests without a task · 3")
        try click(try XCTUnwrap(view.foldButton(section: "nirux")))
        XCTAssertEqual(view.lineViews.map(\.line.id), ["task"])
        XCTAssertNil(board(content(units: [])).foldButton(section: "nirux"), "no fold without any")
    }

    func testMergedTodayOpensTheTaskStillOpen() throws {
        let view = board(content(units: [], merged: [
            BoardStages.Merged(lineID: "telegram", title: "Remove Telegram", number: 287, mergedAt: now - 3600),
            BoardStages.Merged(lineID: nil, title: "From the cloud", number: 198, mergedAt: now - 7200)
        ]))
        var opened: [String] = []
        view.onOpen = { opened.append($0) }
        let merged = try XCTUnwrap(view.subviews.compactMap { $0 as? NSScrollView }.first?.documentView?.subviews
            .compactMap { $0 as? BoardStagesMergedView }.first)
        XCTAssertEqual(merged.entries.map { $0 is NSButton }, [true, false], "a pull request without a task here has nothing to open")
        try click(merged.entries[0])
        XCTAssertEqual(opened, ["telegram"])
        XCTAssertTrue(merged.entries.allSatisfy { merged.bounds.contains($0.frame) }, "inside its line")
    }

    // MARK: - Columns

    func testTheTimeThenThePullRequestGiveWayOnANarrowBoard() {
        let wide = BoardStagesView.Columns(width: 940)
        XCTAssertEqual(wide.rail.width, BoardStagesView.Metrics.railWidth)
        XCTAssertEqual(wide.time?.maxX, 940 - BoardStagesView.Metrics.padding, "the columns fill the width")
        XCTAssertEqual(wide.task.minX, BoardStagesView.Metrics.padding)
        XCTAssertLessThan(wide.task.width, wide.phrase.width, "the phrase gets a little more than the title")

        let narrower = BoardStagesView.Columns(width: 700)
        XCTAssertNotNil(narrower.pullRequest)
        XCTAssertNil(narrower.time, "the time goes first")
        let narrow = BoardStagesView.Columns(width: 600)
        XCTAssertNil(narrow.pullRequest, "then the pull request")
        XCTAssertNil(narrow.time)
        XCTAssertEqual(narrow.phrase.maxX, 600 - BoardStagesView.Metrics.padding)
        XCTAssertGreaterThanOrEqual(narrow.task.width + narrow.phrase.width, BoardStagesView.Metrics.minimumText)
        let tiny = BoardStagesView.Columns(width: 120)
        XCTAssertEqual([tiny.task.width, tiny.phrase.width], [0, 0], "never a negative width")

        let view = board(content(units: [.task(line("task", since: now - 60), subtasks: [])]), width: 600)
        XCTAssertTrue(view.lineViews[0].timeLabel.isHidden && view.lineViews[0].pullRequestLabel.isHidden)
        XCTAssertFalse(view.lineViews[0].phraseLabel.isHidden)
    }
}
