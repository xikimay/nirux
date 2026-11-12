import XCTest
@testable import Nirux

/// The Board as stages, drawn (docs/design/board-stages.md, section 5):
/// what a line shows and how it is joined to the others, what a click
/// says, how the view follows its content without building itself again,
/// the folds, "Merged today", the header and the columns on a narrow
/// Board, and a line as it is painted. Nothing is put on screen.
@MainActor
final class BoardStagesViewTests: XCTestCase {
    private let now: TimeInterval = 1_794_405_600
    /// Never shown; kept for as long as the test runs.
    private var windows: [NSWindow] = []

    private func line(
        _ id: String, state: BoardStages.State = .waiting, phrase: String = "Checks running", since: TimeInterval? = nil,
        rail: Bool = true, title: String? = nil, detail: String? = nil, pullRequest: String = "#52"
    ) -> BoardStages.Line {
        BoardStages.Line(
            id: id, title: title ?? id.capitalized, station: .checks, state: state,
            rail: rail ? BoardStages.Rail(marks: [.done, .done, .current, .ahead]) : nil,
            phrase: BoardStages.Phrase(text: phrase, detail: detail), pullRequest: rail ? pullRequest : "", since: since
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
        _ sections: [BoardStagesView.Section], order: BoardStages.Order = .sidebar, now: TimeInterval? = nil,
        lead: BoardStages.State = .working
    ) -> BoardStagesView.Content {
        BoardStagesView.Content(
            header: BoardStagesView.Header(
                name: "nirux-public", color: Theme.Color.accent, summary: "1 repository · 3 tasks",
                lead: BoardStagesView.Lead(state: lead, text: "Lead · reviewing #438")
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

    /// The colour a button's title is set in.
    private func titleColor(of button: NSButton) -> NSColor? {
        let title = button.attributedTitle
        return title.length == 0 ? nil : title.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
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
        // Its folder becomes a repository: the same line, with a rail.
        view.show(content([section(units: [.task(line("folder"), subtasks: []), .task(line("task"), subtasks: [])])]))
        view.layoutSubtreeIfNeeded()
        XCTAssertEqual(view.lineViews.map(\.noRailLabel.isHidden), [true, true])
    }

    func testACutTextShowsWholeUnderThePointer() throws {
        let long = "A task whose title is far too long for the column it is given on any Board"
        let flaky = "testFoldKeepsFocus failed once in the last 40 runs"
        let view = board(content([section(units: [
            .task(line("long", phrase: "Checks failed · likely flaky", title: long, detail: flaky, pullRequest: "#123456 · on #123455"), subtasks: []),
            .task(line("short", pullRequest: "#1451 · on #1450"), subtasks: [])
        ])]))
        // What AppKit asks the line, which takes the mouse for its words.
        let said = { (line: BoardStagesLineView, label: NSTextField) -> String in
            line.view(line, stringForToolTip: 0, point: NSPoint(x: label.frame.midX, y: label.frame.midY), userData: nil)
        }
        let cut = view.lineViews[0]
        XCTAssertEqual(said(cut, cut.titleLabel), long)
        XCTAssertEqual(said(cut, cut.phraseLabel), flaky, "what the phrase can't hold")
        XCTAssertEqual(said(cut, cut.pullRequestLabel), "#123456 · on #123455")
        let whole = view.lineViews[1]
        XCTAssertEqual([whole.titleLabel, whole.phraseLabel, whole.timeLabel].map { said(whole, $0) }, ["", "", ""], "nothing more to say")
        XCTAssertEqual(said(whole, whole.pullRequestLabel), "", "a fork's pull request past #999 is whole in its column")

        // On a narrow Board the phrase is cut too, and the pull request has no column.
        view.setFrameSize(NSSize(width: 600, height: 600))
        view.layoutSubtreeIfNeeded()
        view.show(content([section(units: [.task(line(
            "long", phrase: "Checks failed · likely flaky, as its last runs on main say", title: long, detail: flaky
        ), subtasks: [])])]))
        view.layoutSubtreeIfNeeded()
        XCTAssertEqual(said(cut, cut.phraseLabel), "Checks failed · likely flaky, as its last runs on main say\n\(flaky)")
        XCTAssertTrue(cut.pullRequestLabel.isHidden)
        XCTAssertEqual(said(cut, cut.pullRequestLabel), "")

        let merged = BoardStagesMergedEntryView(BoardStages.Merged(lineID: nil, title: long, number: 7, mergedAt: 0), now: 0)
        merged.frame = NSRect(x: 0, y: 0, width: 200, height: 18)
        merged.layoutSubtreeIfNeeded()
        XCTAssertEqual(merged.toolTip, long, "a merged entry's title too")
        merged.show(BoardStages.Merged(lineID: nil, title: long + ", again", number: 7, mergedAt: 0), now: 0)
        merged.layoutSubtreeIfNeeded()
        XCTAssertEqual(merged.toolTip, long + ", again")
        merged.frame.size.width = merged.fittingWidth
        merged.layoutSubtreeIfNeeded()
        XCTAssertNil(merged.toolTip)
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
        let view = board(content([section(units: [
            .task(line("task"), subtasks: [line("sub")]), .task(line("gone"), subtasks: []),
            .stack(title: "Stack · 2 pull requests on main", [line("one"), line("two")])
        ], withoutTask: remote)]))
        let fold = try XCTUnwrap(view.foldButton(section: "nirux"))
        try click(fold)
        XCTAssertEqual(view.lineViews.map(\.line.id), ["task", "sub", "gone", "one", "two", "pr9"])
        XCTAssertTrue(view.foldButton(section: "nirux") === fold, "its own click keeps the fold's button, and the keyboard on it")
        let kept = Array(view.lineViews.prefix(2))
        let document = try XCTUnwrap(view.scrollView.documentView)
        let captions = { document.subviews.compactMap { $0 as? NSTextField } }
        let caption = try XCTUnwrap(captions().first)

        let asking = line("task", state: .needsYou, phrase: "Needs you · a question", since: now - 60)
        view.show(content([section(units: [
            .task(line("new"), subtasks: []), .task(asking, subtasks: [line("sub"), line("extra")]),
            .stack(title: "Stack · 3 pull requests on main", [line("one"), line("two"), line("three")])
        ], withoutTask: remote)]))
        let ids = ["new", "task", "sub", "extra", "one", "two", "three", "pr9"]
        XCTAssertEqual(view.lineViews.map(\.line.id), ids, "the fold stays open across a change")
        guard view.lineViews.count == 8, kept.count == 2 else { return }
        XCTAssertTrue(view.lineViews[1] === kept[0] && view.lineViews[2] === kept[1],
                      "a line keeps its view: a press in flight on it isn't lost")
        XCTAssertEqual(kept[0].phraseLabel.stringValue, "Needs you · a question")
        XCTAssertEqual(kept[0].phraseLabel.textColor, Theme.Color.waiting)
        XCTAssertEqual(kept[0].timeLabel.stringValue, "1 min")
        XCTAssertEqual(kept[1].link, .subtask(isLast: false), "no longer the last of its task's")
        XCTAssertTrue(view.foldButton(section: "nirux") === fold, "so does the fold")
        XCTAssertTrue(captions().count == 1 && captions().first === caption, "and a stack's title")
        XCTAssertEqual(caption.stringValue, "Stack · 3 pull requests on main")
        let drawn = document.subviews.compactMap { $0 as? BoardStagesLineView }
        XCTAssertEqual(drawn.map(\.line.id), ids, "the line that left is gone from the Board, the others in the order they are read")
        let tops = document.subviews.map(\.frame.minY)
        XCTAssertEqual(tops, tops.sorted(), "every view from the top, as VoiceOver reads them")
        XCTAssertLessThan(fold.frame.maxY, view.lineViews[7].frame.maxY, "the unfolded lines under their fold")
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
        print("SCROLLER-STYLE this runner prefers: \(NSScroller.preferredScrollerStyle == .overlay ? "overlay" : "legacy")")
        view.show(content([section(units: many)]))
        let document = try XCTUnwrap(view.scrollView.documentView)
        XCTAssertGreaterThan(document.frame.height, view.scrollView.contentSize.height)
        XCTAssertEqual(view.scrollView.contentSize.width, 940, "its scroller takes no width from the lines, whatever the Mac's setting")
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

    func testTheHeaderGivesWayOnANarrowBoardTheNameLast() {
        let view = board(content([]))
        XCTAssertEqual([view.nameLabel.stringValue, view.leadLabel.stringValue], ["nirux-public", "Lead · reviewing #438"])
        let whole: [NSView] = [view.nameLabel, view.summaryLabel, view.leadDot, view.leadLabel, view.orderSwitch]
        XCTAssertTrue(whole.allSatisfy { !$0.isHidden })
        let row = [view.nameLabel.frame, view.summaryLabel.frame, view.leadDot.frame, view.leadLabel.frame, view.orderSwitch.frame]
        XCTAssertTrue(zip(row, row.dropFirst()).allSatisfy { $0.maxX <= $1.minX }, "name, summary, Lead, switch: none over another")
        XCTAssertEqual(view.leadDot.toolTip, "Lead · reviewing #438", "the Lead's dot says its line where that one has no room")

        // The widths each gives way at, from what the header's words measure here.
        let name = ColumnHeaderView.textWidth(view.nameLabel)
        let lead = ColumnHeaderView.textWidth(view.leadLabel)
        let padding = BoardStagesView.Metrics.padding
        // The space's dot, the order switch and what is around them.
        let rest = 2 * padding + 18 + 12 + view.orderSwitch.frame.width
        let at = { (width: CGFloat) in self.board(self.content([], lead: .needsYou), width: width) }
        let shown = { (view: BoardStagesView) -> [Bool] in
            let parts: [NSView] = [view.summaryLabel, view.leadLabel, view.leadDot, view.orderSwitch]
            return parts.map { !$0.isHidden }
        }

        let withSummary = name + 12 + 60 + 12 + 16 + lead + rest
        XCTAssertEqual(shown(at(withSummary)), [true, true, true, true])
        let withoutSummary = at(withSummary - 1)
        XCTAssertEqual(shown(withoutSummary), [false, true, true, true], "the summary is the first to go")
        XCTAssertEqual(withoutSummary.leadLabel.frame.width, lead)

        let cutLead = at(name + 12 + 16 + lead + rest - 1)
        XCTAssertEqual(shown(cutLead), [false, true, true, true])
        XCTAssertEqual(cutLead.leadLabel.frame.width, lead - 1, "then the Lead's line is cut")
        let dotAlone = at(name + 12 + 16 + 60 + rest - 1)
        XCTAssertEqual(shown(dotAlone), [false, false, true, true], "then it goes: its dot stays, and the summary doesn't come back")
        XCTAssertEqual(dotAlone.leadDot.layer?.backgroundColor, Theme.Color.waiting.cgColor, "amber is never hidden")
        XCTAssertEqual(dotAlone.leadDot.frame.maxX, dotAlone.orderSwitch.frame.minX - 12)
        XCTAssertEqual(dotAlone.nameLabel.frame.width, name)

        let withoutSwitch = at(60 + 20 + rest - 1)
        XCTAssertEqual(shown(withoutSwitch), [false, false, true, false], "then the order switch")
        XCTAssertEqual(withoutSwitch.nameLabel.frame.width, name, "the name is the last to give way")
        XCTAssertEqual(withoutSwitch.leadDot.frame.maxX, withoutSwitch.bounds.width - padding)
        let tiny = at(120)
        XCTAssertEqual(tiny.nameLabel.frame.maxX, tiny.leadDot.frame.minX - 12, "cut before the Lead's dot")
        XCTAssertFalse(tiny.leadDot.isHidden)

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
        let telegram = BoardStages.Merged(lineID: "telegram", title: "Remove Telegram", number: 287, mergedAt: now - 3600)
        let cloud = BoardStages.Merged(lineID: nil, title: "From the cloud", number: 198, mergedAt: now - 7200)
        let view = board(content([section(units: [], merged: [telegram, cloud])]))
        var opened: [String] = []
        view.onOpen = { opened.append($0) }
        let merged = try XCTUnwrap(view.mergedView(section: "nirux"))
        XCTAssertEqual(merged.entries.map(\.titleLabel.stringValue), ["Remove Telegram", "From the cloud"])
        guard merged.entries.count == 2 else { return }
        let entry = merged.entries[0]
        XCTAssertEqual(entry.detailLabel.stringValue.prefix(7), "#287 · ")
        try click(merged.entries[1])
        XCTAssertEqual(opened, [], "a pull request without a task here has nothing to open")
        try click(entry)
        XCTAssertEqual(opened, ["telegram"])
        XCTAssertTrue(merged.moreButton.isHidden, "all of them fit")

        // As on a line: a release needs its press, on the entry; a double click opens nothing more.
        let on = try target(at: entry).location
        let off = try target(at: merged.entries[1]).location
        entry.mouseUp(with: try mouse(.leftMouseUp, at: on, in: view.window))
        entry.mouseDown(with: try mouse(.leftMouseDown, at: on, in: view.window))
        entry.mouseUp(with: try mouse(.leftMouseUp, at: off, in: view.window))
        entry.mouseDown(with: try mouse(.leftMouseDown, at: on, in: view.window, clicks: 2))
        entry.mouseUp(with: try mouse(.leftMouseUp, at: on, in: view.window, clicks: 2))
        XCTAssertEqual(opened, ["telegram"])

        // Its task asks under a press: the same entry, painted again in amber.
        entry.wantsLayer = true
        let layer = try XCTUnwrap(entry.layer)
        layer.displayIfNeeded()
        XCTAssertFalse(layer.needsDisplay())
        entry.mouseDown(with: try mouse(.leftMouseDown, at: on, in: view.window))
        var asking = telegram
        asking.needsYou = true
        view.show(content([section(units: [], merged: [asking, cloud])]))
        view.layoutSubtreeIfNeeded()
        XCTAssertTrue(view.mergedView(section: "nirux") === merged && merged.entries.first === entry)
        XCTAssertEqual(entry.dotColor, Theme.Color.waiting)
        XCTAssertTrue(layer.needsDisplay())
        entry.mouseUp(with: try mouse(.leftMouseUp, at: on, in: view.window))
        XCTAssertEqual(opened, ["telegram", "telegram"], "the press in flight isn't lost")

        // The day goes on: what left is gone, what stays keeps its entry and takes its new words.
        asking.title = "Remove Telegram, for good"
        let newer = BoardStages.Merged(lineID: nil, title: "Newer", number: 300, mergedAt: now - 60, needsYou: true)
        view.show(content([section(units: [], merged: [newer, asking])]))
        XCTAssertEqual(merged.entries.map(\.pullRequest.number), [300, 287])
        XCTAssertTrue(merged.entries.last === entry)
        XCTAssertEqual(merged.subviews.count, 4, "the caption, the two entries, the button")
        XCTAssertEqual(entry.titleLabel.stringValue, "Remove Telegram, for good")
    }

    func testMergedTodayKeepsToTwoRowsUntilAsked() throws {
        var day = (0..<40).map { BoardStages.Merged(lineID: "t\($0)", title: "Fix \($0)", number: 400 + $0, mergedAt: now - 60) }
        day[29].needsYou = true
        let view = board(content([section(units: [.task(line("task"), subtasks: [])], merged: day)]))
        let merged = try XCTUnwrap(view.mergedView(section: "nirux"))
        let shown = merged.entries.filter { !$0.isHidden }
        let last = try XCTUnwrap(shown.last)
        XCTAssertEqual(Set(shown.map(\.frame.minY)).count, 2, "two rows, however many merged")
        XCTAssertLessThan(shown.count, day.count)
        XCTAssertEqual(shown.first?.pullRequest.number, 429, "amber is never behind the fold: who needs the user comes first")
        XCTAssertEqual(merged.moreButton.attributedTitle.string, "+\(day.count - shown.count) more")
        XCTAssertEqual(titleColor(of: merged.moreButton), Theme.Color.textTertiary)
        XCTAssertFalse(merged.moreButton.isHidden)
        XCTAssertEqual([merged.moreButton.frame.minY, merged.moreButton.frame.height], [last.frame.minY, last.frame.height],
                       "on the last row, as an entry")
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

        // More of them need the user than two rows hold: the button says so, in amber.
        let asking = board(content([section(units: [], merged: day.map { BoardStages.Merged(
            lineID: $0.lineID, title: $0.title, number: $0.number, mergedAt: $0.mergedAt, needsYou: true
        ) })]))
        let all = try XCTUnwrap(asking.mergedView(section: "nirux"))
        let hidden = all.entries.filter(\.isHidden).count
        XCTAssertGreaterThan(hidden, 1)
        XCTAssertEqual(all.moreButton.attributedTitle.string, "+\(hidden) more · \(hidden) need you")
        XCTAssertEqual(titleColor(of: all.moreButton), Theme.Color.waiting)
        // It is longer than an entry: it takes the place of as many as it needs.
        let outside = stride(from: CGFloat(600), through: 1000, by: 8).filter { width in
            asking.setFrameSize(NSSize(width: width, height: 600))
            asking.layoutSubtreeIfNeeded()
            return all.moreButton.frame.maxX > width - BoardStagesView.Metrics.padding
        }
        XCTAssertEqual(outside, [], "widths where the button runs past the Board")
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

        // The last two need the user: one shows, the other is counted on the button.
        let asking = long.enumerated().map { index, pullRequest in
            BoardStages.Merged(
                lineID: pullRequest.lineID, title: pullRequest.title, number: pullRequest.number, mergedAt: pullRequest.mergedAt,
                needsYou: index >= 2
            )
        }
        let waiting = try XCTUnwrap(board(content([section(units: [], merged: asking)]), width: 500).mergedView(section: "nirux"))
        XCTAssertEqual(waiting.entries.filter { !$0.isHidden }.map(\.pullRequest.number), [402])
        XCTAssertEqual(waiting.moreButton.attributedTitle.string, "+3 more · 1 needs you")
        XCTAssertEqual(waiting.moreButton.accessibilityLabel(), "3 more pull requests merged today, 1 needs you")
        XCTAssertLessThanOrEqual(waiting.moreButton.frame.maxX, 500 - BoardStagesView.Metrics.padding)
    }

    // MARK: - Columns

    func testTheColumnsGrowWithTheBoardWithoutAJump() {
        let wide = BoardStagesView.Columns(width: 940)
        XCTAssertEqual([wide.task.width, wide.rail.width, wide.phrase.width], [280, 180, 224])
        XCTAssertEqual(wide.task.minX, BoardStagesView.Metrics.padding)
        XCTAssertEqual(wide.time?.maxX, 940 - BoardStagesView.Metrics.padding, "the columns fill the width")
        XCTAssertEqual(wide.stations.map { $0 - wide.rail.minX }, [10, 63, 116, 169], "the mockup's stations")

        // From where a rail shows, a point more of Board gives the task's
        // column and the rail a point at most, and takes none back; the
        // columns end at the padding once the phrase shows, before it else.
        var previous = BoardStagesView.Columns(width: 306)
        var jumps: [CGFloat] = []
        var overflows: [CGFloat] = []
        for width in stride(from: CGFloat(307), through: 2000, by: 1) {
            let columns = BoardStagesView.Columns(width: width)
            let steps = [columns.task.width - previous.task.width, columns.rail.width - previous.rail.width]
            if steps.contains(where: { $0 < 0 || $0 > 1 }) { jumps.append(width) }
            let last = columns.time ?? columns.pullRequest ?? (columns.phrase.width > 0 ? columns.phrase : columns.rail)
            let end = width - BoardStagesView.Metrics.padding
            if last.maxX > end || (columns.phrase.width > 0 && last.maxX < end) { overflows.append(width) }
            previous = columns
        }
        XCTAssertEqual(jumps, [], "widths where a title or a rail shrinks, or jumps, as the Board widens")
        XCTAssertEqual(overflows, [], "widths where the columns don't end at the padding")
        XCTAssertEqual(BoardStagesView.Columns(width: 1800).task.width, 280, "a wide Board doesn't push the rails away from the titles")

        // Each station's title over its station.
        let view = board(content([]))
        for (title, station) in zip(view.stationTitles, wide.stations) {
            XCTAssertEqual(title.frame.midX, station, accuracy: 0.5, title.stringValue)
        }
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

        XCTAssertNil(BoardStagesView.Columns(width: 831).pullRequest)
        XCTAssertNil(BoardStagesView.Columns(width: 831).time, "never the time without the pull request")
        let withPullRequest = BoardStagesView.Columns(width: 832)
        XCTAssertNotNil(withPullRequest.pullRequest, "the pull request first, once the phrase keeps 180 pt beside it")
        XCTAssertNil(withPullRequest.time)
        XCTAssertGreaterThanOrEqual(withPullRequest.phrase.width, BoardStagesView.Metrics.minimumPhrase)
        XCTAssertNil(BoardStagesView.Columns(width: 895).time)
        XCTAssertNotNil(BoardStagesView.Columns(width: 896).time, "then the time")

        let view = board(content([section(units: [.task(line("task", since: now - 60), subtasks: [])])]), width: 600)
        let shown = view.lineViews[0]
        XCTAssertTrue(shown.timeLabel.isHidden && shown.pullRequestLabel.isHidden)
        XCTAssertEqual(view.stationTitles.map(\.isHidden), [false, true, true, false], "a tight rail names its two ends")
        XCTAssertEqual(view.stationTitles[0].frame.midX, stations[0], accuracy: 0.5)
        XCTAssertEqual(view.stationTitles[3].frame.midX, stations[3], accuracy: 0.5)
        XCTAssertEqual(board(content([])).stationTitles.map(\.isHidden), [false, false, false, false])
    }

    func testANarrowerBoardKeepsEachLinesDotAndTitle() {
        // A phrase of a word says nothing: it goes under 70 pt.
        XCTAssertEqual(BoardStagesView.Columns(width: 392).phrase.width, 70)
        XCTAssertEqual(BoardStagesView.Columns(width: 391).phrase.width, 0)
        // Then the rail, once a title would have less than 140 pt beside it.
        let least = BoardStagesView.Columns(width: 306)
        XCTAssertEqual([least.task.width, least.rail.width, least.phrase.width], [140, 116, 0])
        let tiny = BoardStagesView.Columns(width: 305)
        XCTAssertEqual([tiny.task.width, tiny.rail.width, tiny.phrase.width], [269, 0, 0], "the title takes the line")
        XCTAssertEqual(tiny.stations, [])

        let view = board(content([section(units: [.task(line("task"), subtasks: []), .task(line("folder", rail: false), subtasks: [])])]), width: 300)
        XCTAssertEqual(view.stationTitles.map(\.isHidden), [true, true, true, true])
        for shown in view.lineViews {
            XCTAssertTrue(shown.phraseLabel.isHidden && shown.noRailLabel.isHidden && shown.pullRequestLabel.isHidden)
            XCTAssertEqual(shown.titleLabel.frame.maxX, 300 - BoardStagesView.Metrics.padding)
        }
    }

    // MARK: - The rail

    /// What `draw` paints at 1x into a bitmap: each pixel's colour, rows
    /// counted from the top. (The bitmap isn't flipped: what a line draws
    /// at y is on row `height - 1 - y`.)
    private func paint(width: Int, height: Int, _ draw: () -> Void) throws -> (CGFloat, CGFloat) -> NSColor? {
        let rep = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
            isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ))
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: rep))
        draw()
        return { x, y in rep.colorAt(x: Int(x), y: Int(y)) }
    }

    /// The rail, 180 by 20, its stations on the middle row. (Its
    /// segments, a quarter point off the stations' line, fill row 9.)
    private func paint(_ rail: BoardStages.Rail, state: BoardStages.State) throws -> (CGFloat, CGFloat) -> NSColor? {
        try paint(width: 180, height: 20) { BoardStagesLineView.draw(rail, state: state, stations: [10, 63, 116, 169], y: 10) }
    }

    /// How far an opaque pixel is from `expected`, its three components added.
    private func distance(_ color: NSColor?, to expected: NSColor) -> CGFloat? {
        guard let color = color?.usingColorSpace(.deviceRGB), let expected = expected.usingColorSpace(.deviceRGB), color.alphaComponent > 0.9
        else { return nil }
        return abs(color.redComponent - expected.redComponent) + abs(color.greenComponent - expected.greenComponent)
            + abs(color.blueComponent - expected.blueComponent)
    }

    private func isClose(_ color: NSColor?, to expected: NSColor) -> Bool { (distance(color, to: expected) ?? 1) < 0.06 }

    private func isEmpty(_ color: NSColor?) -> Bool { (color?.alphaComponent ?? 0) < 0.05 }

    func testALineIsPaintedInItsStateAndAgainWhenItChanges() throws {
        let units = { (state: BoardStages.State) in
            [BoardStages.Unit.task(self.line("task"), subtasks: [self.line("sub", state: state), self.line("last")])]
        }
        let view = board(content([section(units: units(.needsYou))]))
        let sub = view.lineViews[1]
        let station = BoardStagesView.Columns(width: 940).stations[2]
        var pixel = try paint(width: 940, height: 34) { sub.draw(sub.bounds) }
        XCTAssertTrue(isClose(pixel(sub.dotCenter.x, 17), to: Theme.Color.waiting), "its dot in its state's colour")
        XCTAssertTrue(isClose(pixel(station, 17), to: Theme.Color.waiting), "as its current station")
        // What joins it to its task fills whole pixels at 1x: the line
        // down, then the elbow's end.
        let x = BoardStagesView.Metrics.connectorX - 1
        XCTAssertTrue(isClose(pixel(x, 2), to: Theme.Color.textDisabled) && isEmpty(pixel(x - 1, 2)) && isEmpty(pixel(x + 1, 2)))
        XCTAssertTrue(isClose(pixel(x + 12, 17), to: Theme.Color.textDisabled) && isEmpty(pixel(x + 12, 16)) && isEmpty(pixel(x + 12, 18)))

        sub.wantsLayer = true
        let layer = try XCTUnwrap(sub.layer)
        layer.displayIfNeeded()
        XCTAssertFalse(layer.needsDisplay())
        view.show(content([section(units: units(.failed))]))
        XCTAssertTrue(view.lineViews[1] === sub && layer.needsDisplay(), "a change of state paints the line again")
        pixel = try paint(width: 940, height: 34) { sub.draw(sub.bounds) }
        XCTAssertTrue(isClose(pixel(sub.dotCenter.x, 17), to: Theme.Color.error))

        // Too narrow for a rail: the dot, and nothing after.
        let tiny = BoardStagesLineView(line("alone"), link: .none)
        tiny.frame = NSRect(x: 0, y: 0, width: 300, height: 34)
        let narrow = try paint(width: 300, height: 34) { tiny.draw(tiny.bounds) }
        XCTAssertTrue(isClose(narrow(tiny.dotCenter.x, 17), to: Theme.Color.textTertiary))
        XCTAssertTrue((40..<300).allSatisfy { isEmpty(narrow(CGFloat($0), 16)) && isEmpty(narrow(CGFloat($0), 17)) })
    }

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
        // Two digits are set smaller, to stay inside the ring: their ink,
        // in the twelve columns between its sides.
        let tenth = try paint(BoardStages.Rail(marks: [.done, .current, .ahead, .ahead], queueOrder: 88), state: .failed)
        let inked = (163...174).filter { x in
            (6...13).contains { (distance(tenth(CGFloat(x), CGFloat($0)), to: Theme.Color.canvas) ?? 0) > 0.5 }
        }
        let width = (inked.last ?? 0) - (inked.first ?? 0) + 1
        XCTAssertTrue((8...11).contains(width), "\(width) columns of ink")
    }
}
