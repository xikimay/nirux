import XCTest
@testable import Nirux

/// The Board as stages, drawn (docs/design/board-stages.md, section 5):
/// what a line shows and how it is joined to the others, what a click
/// says, how the view follows its content without building itself again,
/// the folds, "Merged today", the columns on a narrow Board, and the rail
/// as it is painted. Nothing is put on screen.
@MainActor
final class BoardStagesViewTests: XCTestCase {
    private let now: TimeInterval = 1_794_405_600
    /// Never shown; kept for as long as the test runs.
    private var windows: [NSWindow] = []

    private func line(
        _ id: String, state: BoardStages.State = .waiting, phrase: String = "Checks running", since: TimeInterval? = nil,
        rail: Bool = true
    ) -> BoardStages.Line {
        BoardStages.Line(
            id: id, title: id.capitalized, station: .checks, state: state,
            rail: rail ? BoardStages.Rail(marks: [.done, .done, .current, .ahead]) : nil,
            phrase: BoardStages.Phrase(text: phrase), pullRequest: rail ? "#52" : "", since: since
        )
    }

    private func section(
        _ id: String = "nirux", units: [BoardStages.Unit], withoutTask: [BoardStages.Unit] = [], merged: [BoardStages.Merged] = []
    ) -> BoardStagesView.Section {
        BoardStagesView.Section(
            id: id, title: id, detail: "xikimay/\(id)", status: nil,
            lines: BoardStages.Section(id: id, units: units, withoutTask: withoutTask, merged: merged)
        )
    }

    private func content(
        _ sections: [BoardStagesView.Section], order: BoardStages.Order = .sidebar, now: TimeInterval? = nil
    ) -> BoardStagesView.Content {
        BoardStagesView.Content(
            header: BoardStagesView.Header(
                name: "nirux-public", color: Theme.Color.accent, summary: "1 repository · 3 tasks",
                lead: BoardStagesView.Lead(state: .working, text: "Lead · reviewing #438")
            ),
            order: order, sections: sections, now: now ?? self.now
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

    /// What is under `view`'s middle. A window that is never shown drops
    /// events sent with `sendEvent`, so the tests hit-test by hand.
    private func target(at view: NSView) throws -> (view: NSView, location: NSPoint) {
        let window = try XCTUnwrap(view.window)
        let contentView = try XCTUnwrap(window.contentView)
        contentView.layoutSubtreeIfNeeded()
        let frameView = try XCTUnwrap(contentView.superview)
        let location = view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil)
        return (try XCTUnwrap(contentView.hitTest(frameView.convert(location, from: nil))), location)
    }

    private func mouse(_ type: NSEvent.EventType, at location: NSPoint, in window: NSWindow?, clicks: Int = 1) throws -> NSEvent {
        try XCTUnwrap(NSEvent.mouseEvent(
            with: type, location: location, modifierFlags: [], timestamp: 0, windowNumber: window?.windowNumber ?? 0,
            context: nil, eventNumber: 0, clickCount: clicks, pressure: 1
        ))
    }

    /// Presses and releases the mouse on what is under `view`'s middle; a
    /// button is pressed by its own `performClick`, which doesn't wait for
    /// the mouse to come up.
    private func click(_ view: NSView) throws {
        let hit = try target(at: view)
        guard hit.view === view || view.isDescendant(of: hit.view) else {
            return XCTFail("\(hit.view) is under the pointer, not \(view)")
        }
        if let button = hit.view as? NSButton { return button.performClick(nil) }
        hit.view.mouseDown(with: try mouse(.leftMouseDown, at: hit.location, in: view.window))
        hit.view.mouseUp(with: try mouse(.leftMouseUp, at: hit.location, in: view.window))
    }

    // MARK: - Lines

    func testTheLinesAreDrawnInOrderEachJoinedToItsOwn() throws {
        let view = board(content([section(units: [
            .task(line("task"), subtasks: [line("first"), line("last")]),
            .stack(title: "Stack · 2 pull requests on main", [line("one"), line("two")]),
            .task(line("alone"), subtasks: [])
        ])]))
        XCTAssertEqual(view.lineViews.map(\.line.id), ["task", "first", "last", "one", "two", "alone"])
        XCTAssertEqual(view.lineViews.map(\.link), [
            .head, .subtask(isLast: false), .subtask(isLast: true), .stack(number: 1, isLast: false),
            .stack(number: 2, isLast: true), .none
        ])
        let frames = view.lineViews.map(\.frame)
        XCTAssertEqual(frames.map(\.height), Array(repeating: BoardStagesView.Metrics.lineHeight, count: 6))
        XCTAssertTrue(zip(frames, frames.dropFirst()).allSatisfy { $0.maxY <= $1.minY }, "from the top, none over another")
        XCTAssertEqual(frames[3].minY - frames[2].maxY, BoardStagesView.Metrics.captionHeight, "the stack's title sits above its lines")
        let inset = view.lineViews.map { $0.dotCenter.x - BoardStagesView.Metrics.connectorX }
        XCTAssertEqual(inset, [0, 26, 26, 26, 26, 0], "a sub-task and a stack's line sit in from their connector")

        let header = try XCTUnwrap(view.sectionHeader(section: "nirux"))
        XCTAssertEqual([header.titleLabel.stringValue, header.detailLabel.stringValue], ["nirux", "xikimay/nirux"])
        XCTAssertLessThanOrEqual(header.frame.maxY, frames[0].minY, "the repository's header above its lines")
    }

    func testALineShowsItsWordsInItsStatesColour() {
        let asking = line("asking", state: .needsYou, phrase: "Needs you · a question")
        let view = board(content([section(units: [.task(asking, subtasks: [line("sub")])])]))
        let shown = view.lineViews[0]
        XCTAssertEqual([shown.titleLabel.stringValue, shown.phraseLabel.stringValue, shown.pullRequestLabel.stringValue],
                       ["Asking", "Needs you · a question", "#52"])
        XCTAssertEqual(shown.phraseLabel.textColor, Theme.Color.waiting)
        XCTAssertEqual(view.lineViews[1].phraseLabel.textColor, Theme.Color.textTertiary)
        let columns = BoardStagesView.Columns(width: 940)
        for line in view.lineViews {
            XCTAssertLessThanOrEqual(line.titleLabel.frame.maxX, columns.task.maxX, "the title stops before the rail")
            XCTAssertEqual(line.phraseLabel.frame.minX, columns.phrase.minX)
        }
        XCTAssertEqual(shown.accessibilityLabel(), "Asking, at Checks, Needs you · a question, #52")
        XCTAssertEqual(view.lineViews[1].accessibilityLabel(), "Sub, sub-task, at Checks, Checks running, #52")
        var queued = line("queued")
        queued.rail?.queueOrder = 2
        XCTAssertEqual(BoardStagesLineView.accessibilityLabel(of: queued, link: .stack(number: 1, isLast: false)),
                       "Queued, stack place 1, at Checks, Checks running, #52, queue place 2")
    }

    func testAClickOnALineOpensItsTask() throws {
        let view = board(content([section(units: [.task(line("task"), subtasks: [line("sub"), line("other")])])]))
        var opened: [String] = []
        view.onOpen = { opened.append($0) }
        let sub = view.lineViews[1]
        XCTAssertTrue(try target(at: sub.titleLabel).view === sub, "the whole line is one target: its words don't take the mouse")
        try click(sub.titleLabel)
        try click(view.lineViews[0])
        XCTAssertEqual(opened, ["sub", "task"])

        // Pressed on a line, released on another: no click, for either.
        let down = try target(at: sub)
        let elsewhere = try target(at: view.lineViews[2])
        sub.mouseDown(with: try mouse(.leftMouseDown, at: down.location, in: view.window))
        sub.mouseUp(with: try mouse(.leftMouseUp, at: elsewhere.location, in: view.window))
        view.lineViews[2].mouseUp(with: try mouse(.leftMouseUp, at: elsewhere.location, in: view.window))
        XCTAssertEqual(opened, ["sub", "task"], "a release needs its press, on the same line")
        // The second click of a double click doesn't open it again.
        sub.mouseDown(with: try mouse(.leftMouseDown, at: down.location, in: view.window, clicks: 2))
        sub.mouseUp(with: try mouse(.leftMouseUp, at: down.location, in: view.window, clicks: 2))
        XCTAssertEqual(opened, ["sub", "task"])
    }

    func testALineWithoutARepositorySaysSoInPlaceOfItsRail() {
        let view = board(content([section(units: [.task(line("folder", rail: false), subtasks: []), .task(line("task"), subtasks: [])])]))
        XCTAssertEqual(view.lineViews.map(\.noRailLabel.isHidden), [false, true])
        XCTAssertEqual(view.lineViews[0].noRailLabel.stringValue, "no pull request")
        XCTAssertEqual(view.lineViews[0].accessibilityLabel(), "Folder, Checks running")
    }

    // MARK: - Following the content

    func testTheClockMovesWithoutBuildingTheLinesAgain() {
        let units = [BoardStages.Unit.task(line("task", since: now - 12 * 60), subtasks: [line("still")])]
        let view = board(content([section(units: units)]))
        let drawn = view.lineViews
        XCTAssertEqual(drawn.map(\.timeLabel.stringValue), ["12 min", ""], "a line without a clock shows none")
        view.show(content([section(units: units)], now: now + 3600))
        XCTAssertEqual(view.lineViews.map(\.timeLabel.stringValue), ["1 h", ""])
        XCTAssertTrue(zip(view.lineViews, drawn).allSatisfy { $0 === $1 }, "only the clock changed")
        let seconds: [TimeInterval] = [30, 60, 3599, 3600, 82_800, 86_400, 176_400]
        XCTAssertEqual(seconds.map(BoardStagesView.duration), ["now", "1 min", "59 min", "1 h", "23 h", "1 d", "2 d"])
    }

    func testAChangeOfItsLinesUpdatesThemWhereTheyAre() throws {
        let remote = [BoardStages.Unit.task(line("pr9"), subtasks: [])]
        let before = content([section(units: [.task(line("task"), subtasks: [line("sub")]), .task(line("gone"), subtasks: [])], withoutTask: remote)])
        let view = board(before)
        try click(try XCTUnwrap(view.foldButton(section: "nirux")))
        XCTAssertEqual(view.lineViews.map(\.line.id), ["task", "sub", "gone", "pr9"])
        let kept = Array(view.lineViews.prefix(2))
        let document = try XCTUnwrap(view.scrollView.documentView)

        let asking = line("task", state: .needsYou, phrase: "Needs you · a question", since: now - 60)
        view.show(content([section(
            units: [.task(line("new"), subtasks: []), .task(asking, subtasks: [line("sub"), line("extra")])], withoutTask: remote
        )]))
        XCTAssertEqual(view.lineViews.map(\.line.id), ["new", "task", "sub", "extra", "pr9"], "the fold stays open across a change")
        guard view.lineViews.count == 5, kept.count == 2 else { return }
        XCTAssertTrue(view.lineViews[1] === kept[0] && view.lineViews[2] === kept[1],
                      "a line keeps its view: a press in flight on it isn't lost")
        XCTAssertEqual(kept[0].phraseLabel.stringValue, "Needs you · a question")
        XCTAssertEqual(kept[0].phraseLabel.textColor, Theme.Color.waiting)
        XCTAssertEqual(kept[0].timeLabel.stringValue, "1 min")
        XCTAssertEqual(kept[1].link, .subtask(isLast: false), "no longer the last of its task's")
        let drawn = document.subviews.compactMap { $0 as? BoardStagesLineView }
        XCTAssertEqual(Set(drawn.map(\.line.id)), ["new", "task", "sub", "extra", "pr9"], "the line that left is gone from the Board")
        XCTAssertTrue(view.lineViews.allSatisfy { $0.superview === document })
        XCTAssertLessThan(view.lineViews[0].frame.minY, view.lineViews[1].frame.minY, "laid out again, in the new order")
        let fold = try XCTUnwrap(view.foldButton(section: "nirux"))
        XCTAssertLessThan(fold.frame.maxY, view.lineViews[4].frame.maxY, "the unfolded lines under their fold")
    }

    func testSectionsComeInOrderEachUnderItsHeader() throws {
        let view = board(content([
            section("nirux", units: [.task(line("a"), subtasks: [])]), section("site", units: [.task(line("b"), subtasks: [])])
        ]))
        let first = try XCTUnwrap(view.sectionHeader(section: "nirux"))
        let second = try XCTUnwrap(view.sectionHeader(section: "site"))
        XCTAssertEqual([first.titleLabel.stringValue, second.titleLabel.stringValue], ["nirux", "site"])
        let ys = [first.frame.minY, view.lineViews[0].frame.minY, second.frame.minY, view.lineViews[1].frame.minY]
        XCTAssertEqual(ys, ys.sorted())
        XCTAssertEqual(Set(ys).count, 4, "each in its own place")
        view.show(content([section("site", units: [.task(line("b"), subtasks: [])])]))
        XCTAssertNil(view.sectionHeader(section: "nirux"), "a repository that left the space")
        XCTAssertTrue(view.sectionHeader(section: "site") === second, "the one that stays keeps its header")

        // A Board taller than its column scrolls; a resize lays it out again.
        let many = (0..<40).map { BoardStages.Unit.task(line("t\($0)"), subtasks: []) }
        view.show(content([section(units: many)]))
        let document = try XCTUnwrap(view.scrollView.documentView)
        XCTAssertGreaterThan(document.frame.height, view.scrollView.contentSize.height)
        view.setFrameSize(NSSize(width: 600, height: 600))
        view.layoutSubtreeIfNeeded()
        XCTAssertEqual(view.lineViews[0].frame.width, 600)
        XCTAssertEqual(view.lineViews[0].phraseLabel.frame.minX, BoardStagesView.Columns(width: 600).phrase.minX)
    }

    // MARK: - Header

    func testTheOrderSwitchSaysTheOrderAsked() {
        let view = board(content([]))
        var asked: [BoardStages.Order] = []
        view.onOrder = { asked.append($0) }
        XCTAssertEqual(view.orderSwitch.selectedSegment, 0, "the sidebar's order, as the content says")
        for segment in [1, 0] {
            view.orderSwitch.selectedSegment = segment
            view.orderSwitch.sendAction(view.orderSwitch.action, to: view.orderSwitch.target)
        }
        XCTAssertEqual(asked, [.progress, .sidebar])
        view.show(content([], order: .progress))
        XCTAssertEqual(view.orderSwitch.selectedSegment, 1, "the switch follows the content, not the click")
    }

    func testTheSpacesNameIsTheLastToGiveWay() {
        let view = board(content([]))
        XCTAssertEqual([view.nameLabel.stringValue, view.leadLabel.stringValue], ["nirux-public", "Lead · reviewing #438"])
        XCTAssertTrue([view.nameLabel, view.summaryLabel, view.leadLabel].allSatisfy { !$0.isHidden })
        let row = [view.nameLabel.frame, view.summaryLabel.frame, view.leadDot.frame, view.leadLabel.frame, view.orderSwitch.frame]
        XCTAssertTrue(zip(row, row.dropFirst()).allSatisfy { $0.maxX <= $1.minX }, "name, summary, Lead, switch: none over another")

        let narrow = board(content([]), width: 380)
        XCTAssertTrue(narrow.leadLabel.isHidden && narrow.leadDot.isHidden && narrow.summaryLabel.isHidden,
                      "on a narrow Board the Lead and the summary go")
        XCTAssertEqual(narrow.nameLabel.frame.width, ColumnHeaderView.textWidth(narrow.nameLabel), "before the name is cut")
        XCTAssertLessThanOrEqual(narrow.nameLabel.frame.maxX, narrow.orderSwitch.frame.minX)

        var withoutLead = content([])
        withoutLead.header.lead = nil
        view.show(withoutLead)
        XCTAssertTrue(view.leadLabel.isHidden && view.leadDot.isHidden, "a space without a Lead shows none")
    }

    func testAmberMeansAnAgentWaitsForTheUserAndNothingElse() {
        let states: [BoardStages.State] = [.needsYou, .failed, .working, .blocked, .waiting, .ready, .merged, .idle]
        XCTAssertEqual(states.filter { BoardStagesView.color(of: $0) == Theme.Color.waiting }, [.needsYou])
        XCTAssertEqual(states.filter { BoardStagesLineView.phraseColor(of: $0) == Theme.Color.waiting }, [.needsYou])
        XCTAssertEqual(states.filter { BoardStagesLineView.phraseColor(of: $0) == Theme.Color.error }, [.failed], "red for a failure only")
        let merged = { (needsYou: Bool) in
            BoardStagesMergedEntryView(BoardStages.Merged(lineID: "t", title: "T", number: 1, mergedAt: 0, needsYou: needsYou), now: 0)
        }
        XCTAssertEqual(merged(true).dotColor, Theme.Color.waiting, "a merged task whose agent asks: amber is never hidden")
        XCTAssertEqual(merged(false).dotColor, Theme.Color.done)
    }

    // MARK: - Folded and merged

    func testThePullRequestsWithoutATaskStartFolded() throws {
        let view = board(content([section(
            units: [.task(line("task"), subtasks: [])],
            withoutTask: [
                .stack(title: "Stack · 2 pull requests on main", [line("pr1", since: now - 120), line("pr2")]),
                .task(line("pr3"), subtasks: [])
            ]
        )]))
        let fold = try XCTUnwrap(view.foldButton(section: "nirux"))
        XCTAssertEqual(fold.attributedTitle.string, "▸ Pull requests without a task · 3", "it counts pull requests")
        XCTAssertEqual(view.lineViews.map(\.line.id), ["task"])
        try click(fold)
        XCTAssertEqual(view.lineViews.map(\.line.id), ["task", "pr1", "pr2", "pr3"])
        let first = try XCTUnwrap(view.lineViews.dropFirst().first)
        XCTAssertEqual(first.timeLabel.stringValue, "2 min", "unfolded with its clock")
        let unfolded = try XCTUnwrap(view.foldButton(section: "nirux"))
        XCTAssertEqual(unfolded.attributedTitle.string, "▾ Pull requests without a task · 3")
        XCTAssertLessThanOrEqual(unfolded.frame.maxY, first.frame.minY, "its lines under it")
        try click(unfolded)
        XCTAssertEqual(view.lineViews.map(\.line.id), ["task"])
        XCTAssertNil(board(content([section(units: [])])).foldButton(section: "nirux"), "no fold without any")
    }

    func testMergedTodayOpensTheTaskStillOpen() throws {
        let view = board(content([section(units: [], merged: [
            BoardStages.Merged(lineID: nil, title: "From the cloud", number: 198, mergedAt: now - 3600),
            BoardStages.Merged(lineID: "telegram", title: "Remove Telegram", number: 287, mergedAt: now - 7200)
        ])]))
        var opened: [String] = []
        view.onOpen = { opened.append($0) }
        let merged = try XCTUnwrap(view.mergedView(section: "nirux"))
        XCTAssertEqual(merged.entries.map(\.titleLabel.stringValue), ["From the cloud", "Remove Telegram"])
        XCTAssertEqual(merged.entries[1].detailLabel.stringValue.prefix(7), "#287 · ")
        try click(merged.entries[0])
        XCTAssertEqual(opened, [], "a pull request without a task here has nothing to open")
        try click(merged.entries[1])
        XCTAssertEqual(opened, ["telegram"])
        XCTAssertTrue(merged.moreButton.isHidden, "all of them fit")
    }

    func testMergedTodayKeepsToTwoRowsUntilAsked() throws {
        let day = (0..<40).map { BoardStages.Merged(lineID: "t\($0)", title: "Fix \($0)", number: 400 + $0, mergedAt: now - 60) }
        let view = board(content([section(units: [.task(line("task"), subtasks: [])], merged: day)]))
        let merged = try XCTUnwrap(view.mergedView(section: "nirux"))
        let shown = merged.entries.filter { !$0.isHidden }
        XCTAssertEqual(Set(shown.map(\.frame.minY)).count, 2, "two rows, however many merged")
        XCTAssertLessThan(shown.count, day.count)
        XCTAssertEqual(merged.moreButton.attributedTitle.string, "+\(day.count - shown.count) more")
        XCTAssertFalse(merged.moreButton.isHidden)
        for control in shown as [NSView] + [merged.moreButton] {
            XCTAssertTrue(merged.bounds.contains(control.frame), "inside the line")
            XCTAssertLessThanOrEqual(control.frame.maxX, 940 - BoardStagesView.Metrics.padding, "and inside the Board")
        }
        let rows = Dictionary(grouping: shown, by: \.frame.minY).values.map { $0.map(\.frame.minX).min() }
        XCTAssertEqual(Set(rows).count, 1, "the second row starts under the first entry")

        let folded = merged.frame.height
        try click(merged.moreButton)
        let whole = try XCTUnwrap(view.mergedView(section: "nirux"))
        XCTAssertTrue(whole.entries.allSatisfy { !$0.isHidden } && whole.moreButton.isHidden, "every pull request merged today")
        XCTAssertGreaterThan(whole.frame.height, folded)
        XCTAssertTrue(whole.entries.allSatisfy { whole.bounds.contains($0.frame) })
    }

    func testAMergedEntryTooLongForItsRowGivesItsTitleAway() throws {
        let long = (0..<4).map {
            BoardStages.Merged(
                lineID: "t\($0)", title: "A pull request whose title is far too long for a narrow Board to hold, number \($0)",
                number: 400 + $0, mergedAt: now - 60
            )
        }
        let view = board(content([section(units: [], merged: long)]), width: 500)
        let merged = try XCTUnwrap(view.mergedView(section: "nirux"))
        let shown = merged.entries.filter { !$0.isHidden }
        let first = try XCTUnwrap(shown.first)
        XCTAssertEqual(shown.count, 1, "a row each: one, then the rest behind the button")
        XCTAssertEqual(first.detailLabel.frame.width, ColumnHeaderView.textWidth(first.detailLabel), "the number and the time stay whole")
        XCTAssertLessThanOrEqual(first.detailLabel.frame.maxX, first.bounds.maxX)
        XCTAssertLessThan(first.titleLabel.frame.width, ColumnHeaderView.textWidth(first.titleLabel), "the title gives way")
        XCTAssertEqual(merged.moreButton.attributedTitle.string, "+3 more")
        XCTAssertEqual(merged.moreButton.frame.minX, first.frame.minX, "in the place of the entry it stands for")
        XCTAssertGreaterThan(merged.moreButton.frame.minY, first.frame.minY)
        XCTAssertLessThanOrEqual(merged.moreButton.frame.maxX, 500 - BoardStagesView.Metrics.padding)
        XCTAssertTrue(merged.bounds.contains(merged.moreButton.frame))
    }

    // MARK: - Columns

    func testTheColumnsGrowWithTheBoardWithoutAJump() {
        let wide = BoardStagesView.Columns(width: 940)
        XCTAssertEqual([wide.task.width, wide.rail.width, wide.phrase.width], [280, 180, 238])
        XCTAssertEqual(wide.task.minX, BoardStagesView.Metrics.padding)
        XCTAssertEqual(wide.time?.maxX, 940 - BoardStagesView.Metrics.padding, "the columns fill the width")
        XCTAssertEqual(wide.stations.map { $0 - wide.rail.minX }, [10, 63, 116, 169], "the mockup's stations")

        // Widening the Board never moves a rail back, nor shortens a title,
        // and its last column ends at the padding.
        var previous = BoardStagesView.Columns(width: 299)
        var jumps: [CGFloat] = []
        var overflows: [CGFloat] = []
        for width in stride(from: CGFloat(300), through: 2000, by: 1) {
            let columns = BoardStagesView.Columns(width: width)
            if columns.task.width < previous.task.width || columns.rail.width < previous.rail.width { jumps.append(width) }
            // (Up to a gap short of it, where the phrase has no room yet.)
            let last = columns.time ?? columns.pullRequest ?? (columns.phrase.width > 0 ? columns.phrase : columns.rail)
            let end = width - BoardStagesView.Metrics.padding
            if last.maxX > end || last.maxX < end - BoardStagesView.Metrics.gap { overflows.append(width) }
            previous = columns
        }
        XCTAssertEqual(jumps, [], "widths where a title or a rail shrinks as the Board widens")
        XCTAssertEqual(overflows, [], "widths where the columns don't end at the padding")
        XCTAssertEqual(BoardStagesView.Columns(width: 1800).task.width, 280, "a wide Board doesn't push the rails away from the titles")
    }

    func testTheRailTightensThenTheColumnsGiveWayOnANarrowBoard() {
        let narrow = BoardStagesView.Columns(width: 600)
        XCTAssertEqual([narrow.task.width, narrow.rail.width, narrow.phrase.width], [225, 116, 195],
                       "the rail tightens before the titles are cut")
        XCTAssertNil(narrow.pullRequest)
        XCTAssertNil(narrow.time)
        let stations = narrow.stations
        XCTAssertEqual(stations.first, narrow.rail.minX + 10)
        XCTAssertEqual(stations.last, narrow.rail.maxX - 11)
        XCTAssertTrue(zip(stations, stations.dropFirst()).allSatisfy { $1 - $0 >= 31 }, "its stations closer, never touching")

        XCTAssertNil(BoardStagesView.Columns(width: 817).pullRequest)
        XCTAssertNil(BoardStagesView.Columns(width: 817).time, "never the time without the pull request")
        let withPullRequest = BoardStagesView.Columns(width: 818)
        XCTAssertNotNil(withPullRequest.pullRequest, "the pull request first, once the phrase keeps 180 pt beside it")
        XCTAssertNil(withPullRequest.time)
        XCTAssertGreaterThanOrEqual(withPullRequest.phrase.width, BoardStagesView.Metrics.minimumPhrase)
        XCTAssertNil(BoardStagesView.Columns(width: 881).time)
        XCTAssertNotNil(BoardStagesView.Columns(width: 882).time, "then the time")
        let tiny = BoardStagesView.Columns(width: 300)
        XCTAssertEqual([tiny.task.width, tiny.phrase.width], [134, 0], "the phrase goes before the title and the rail")

        let view = board(content([section(units: [.task(line("task", since: now - 60), subtasks: [])])]), width: 600)
        let shown = view.lineViews[0]
        XCTAssertTrue(shown.timeLabel.isHidden && shown.pullRequestLabel.isHidden)
        XCTAssertEqual(view.stationTitles.map(\.isHidden), [false, true, true, false], "a tight rail names its two ends")
        XCTAssertEqual(board(content([])).stationTitles.map(\.isHidden), [false, false, false, false])
    }

    // MARK: - The rail

    /// The rail painted at 1x into a bitmap 180 by 20, its stations on the
    /// middle row: each pixel's colour, rows counted from the top. (The
    /// bitmap isn't flipped: the segments, a quarter point off the
    /// stations' line, fill row 9.)
    private func paint(_ rail: BoardStages.Rail, state: BoardStages.State) throws -> (CGFloat, CGFloat) -> NSColor? {
        let rep = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 180, pixelsHigh: 20, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
            isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ))
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: rep))
        BoardStagesLineView.draw(rail, state: state, stations: [10, 63, 116, 169], y: 10)
        return { x, y in rep.colorAt(x: Int(x), y: Int(y)) }
    }

    private func isClose(_ color: NSColor?, to expected: NSColor) -> Bool {
        guard let color = color?.usingColorSpace(.deviceRGB), let expected = expected.usingColorSpace(.deviceRGB), color.alphaComponent > 0.9
        else { return false }
        return abs(color.redComponent - expected.redComponent) + abs(color.greenComponent - expected.greenComponent)
            + abs(color.blueComponent - expected.blueComponent) < 0.06
    }

    private func isEmpty(_ color: NSColor?) -> Bool { (color?.alphaComponent ?? 0) < 0.05 }

    func testTheRailIsPaintedAsItsMarksSay() throws {
        let pixel = try paint(BoardStages.Rail(marks: [.done, .skipped, .current, .ahead]), state: .failed)
        XCTAssertTrue(isClose(pixel(10, 10), to: Theme.Color.textSecondary), "a station done: a filled dot")
        XCTAssertTrue(isEmpty(pixel(63, 5)) && isEmpty(pixel(60, 10)), "no Reviews station: a gap")
        XCTAssertTrue(isClose(pixel(116, 10), to: Theme.Color.error), "the current one in the state's colour")
        XCTAssertTrue(isClose(pixel(120, 10), to: Theme.Color.error) && isEmpty(pixel(15, 10)), "and larger than one done")
        XCTAssertTrue(isClose(pixel(169, 10), to: Theme.Color.canvas), "one ahead: hollow")
        XCTAssertTrue(isClose(pixel(35, 9), to: Theme.Color.textTertiary) && isClose(pixel(90, 9), to: Theme.Color.textTertiary),
                      "solid up to the current station")
        let after = (126...160).map { CGFloat($0) }
        XCTAssertTrue(after.contains { isEmpty(pixel($0, 9)) } && after.contains { !isEmpty(pixel($0, 9)) }, "dotted after it")

        // The queue's number on Merge: in the state's colour when the line is there.
        let ring = { (pixel: (CGFloat, CGFloat) -> NSColor?) in pixel(169, 2)?.usingColorSpace(.deviceRGB) }
        let stopped = try XCTUnwrap(ring(try paint(BoardStages.Rail(marks: [.done, .done, .done, .current], queueOrder: 1), state: .failed)))
        XCTAssertGreaterThan(stopped.redComponent, stopped.blueComponent + 0.15, "stopped at Merge: its ring is red")
        let queued = try XCTUnwrap(ring(try paint(BoardStages.Rail(marks: [.done, .current, .ahead, .ahead], queueOrder: 1), state: .failed)))
        XCTAssertLessThan(abs(queued.redComponent - queued.blueComponent), 0.1, "in the list, not at Merge yet: grey")
        let plain = try paint(BoardStages.Rail(marks: [.done, .current, .ahead, .ahead]), state: .failed)
        XCTAssertTrue(isEmpty(plain(169, 2)), "no ring without a place in the queue")
    }
}
