import XCTest
@testable import Nirux

/// The Board as stages, drawn (docs/design/board-stages.md, sections 5 and
/// 7): what a line shows and how it is joined to the others, what a click
/// says and where, what each place says under the pointer, how the view
/// follows its content without building itself again, the folds, "Merged
/// today", the header and the columns on a narrow Board, and a line as it
/// is painted. Nothing is put on screen.
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
        _ id: String = "nirux", units: [BoardStages.Unit], withoutTask: [BoardStages.Unit] = [], merged: [BoardStages.Merged] = [],
        status: ColumnHeaderView.Status? = nil
    ) -> BoardStagesView.Section {
        BoardStagesView.Section(
            id: id, title: id, detail: "xikimay/\(id)", status: status,
            lines: BoardStages.Section(id: id, units: units, withoutTask: withoutTask, merged: merged)
        )
    }

    private func content(
        _ sections: [BoardStagesView.Section], order: BoardStages.Order = .sidebar, now: TimeInterval? = nil,
        lead: BoardStages.State = .working, leadText: String = "Lead · reviewing #438", name: String = "nirux-public"
    ) -> BoardStagesView.Content {
        BoardStagesView.Content(
            header: BoardStagesView.Header(
                name: name, color: Theme.Color.accent, summary: "1 repository · 3 tasks",
                lead: BoardStagesView.Lead(state: lead, text: leadText)
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
        XCTAssertTrue(view.lineViews.allSatisfy { $0.titleLabel.frame.minX > $0.dotCenter.x + BoardStagesView.Metrics.dot / 2 },
                      "a title after its dot")

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
        // (That press is over: a release back on the line isn't its click.)
        sub.mouseUp(with: try mouse(.leftMouseUp, at: down.location, in: view.window))
        XCTAssertEqual(opened, ["sub", "task"], "a release needs its press, on the same line")
        // The second click of a double click doesn't open it again.
        sub.mouseDown(with: try mouse(.leftMouseDown, at: down.location, in: view.window, clicks: 2))
        sub.mouseUp(with: try mouse(.leftMouseUp, at: down.location, in: view.window, clicks: 2))
        XCTAssertEqual(opened, ["sub", "task"])
        // VoiceOver presses the line as a button.
        XCTAssertEqual(sub.accessibilityRole(), .button)
        XCTAssertTrue(sub.accessibilityPerformPress())
        XCTAssertEqual(opened, ["sub", "task", "sub"])
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
            .task(
                line("long", phrase: "Checks failed · likely flaky", title: long, detail: flaky, pullRequest: "#123456 · on #123455"),
                subtasks: []
            ),
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
        let title = { merged.view(merged, stringForToolTip: 0, point: NSPoint(x: merged.titleLabel.frame.midX, y: 9), userData: nil) }
        XCTAssertEqual(title(), long, "a merged entry's title too")
        XCTAssertEqual(merged.toolTipText(at: NSPoint(x: merged.detailLabel.frame.midX, y: 9)), long, "wherever on the entry")
        XCTAssertEqual(merged.hints.map(\.rect), [merged.bounds])
        merged.show(BoardStages.Merged(lineID: nil, title: long + ", again", number: 7, mergedAt: 0), now: 0)
        merged.layoutSubtreeIfNeeded()
        XCTAssertEqual(title(), long + ", again")
        merged.frame.size.width = merged.fittingWidth
        merged.layoutSubtreeIfNeeded()
        XCTAssertEqual(title(), "")
        XCTAssertTrue(merged.hints.isEmpty)
    }

    // MARK: - What a line offers

    /// Presses the mouse on `line` at `x` on its middle row, and releases it there, or at `upX`.
    private func press(_ line: BoardStagesLineView, at x: CGFloat, releaseAt upX: CGFloat? = nil, clicks: Int = 1) throws {
        let down = line.convert(NSPoint(x: x, y: line.bounds.midY), to: nil)
        let up = line.convert(NSPoint(x: upX ?? x, y: line.bounds.midY), to: nil)
        line.mouseDown(with: try mouse(.leftMouseDown, at: down, in: line.window, clicks: clicks))
        line.mouseUp(with: try mouse(.leftMouseUp, at: up, in: line.window, clicks: clicks))
    }

    private func with(_ line: BoardStages.Line, _ change: (inout BoardStages.Line) -> Void) -> BoardStages.Line {
        var line = line
        change(&line)
        return line
    }

    /// A line whose Merge station offers `change`, blocked or not.
    private func offering(
        _ id: String, _ change: BoardStages.QueueOffer.Change, _ number: Int, blocked: String? = nil, state: BoardStages.State = .waiting
    ) -> BoardStages.Line {
        with(line(id, state: state)) { $0.offer = BoardStages.QueueOffer(change: change, number: number, blocked: blocked) }
    }

    private func tasks(_ lines: [BoardStages.Line]) -> [BoardStages.Unit] {
        lines.map { .task($0, subtasks: []) }
    }

    func testAClickOnTheMergeStationChangesTheQueuesListWhereItCan() throws {
        let lines = { (joining: BoardStages.Line) in
            [
                joining, self.offering("refused", .add, 53, blocked: "Can’t join the queue: draft"), self.offering("listed", .remove, 54),
                self.offering("held", .remove, 55, blocked: "The queue is running."), self.line("plain")
            ]
        }
        let view = board(content([section(units: tasks(lines(offering("joining", .add, 52))))]))
        var opened: [String] = []
        var offered: [String] = []
        view.onOpen = { opened.append($0) }
        view.onOffer = { section, offer in offered.append("\(section) \(offer.change) #\(offer.number)") }
        let merge = BoardStagesView.Columns(width: 940).stations[3]
        let joining = view.lineViews[0]
        let add = BoardStagesLineView.Target.offer(BoardStages.QueueOffer(change: .add, number: 52))

        try press(joining, at: merge)
        XCTAssertEqual(offered, ["nirux add #52"], "the station is the list's control")
        XCTAssertEqual(opened, [], "not a click on the line")
        // Twenty points at least around the station, the line's height; beside it, the line.
        XCTAssertEqual([merge - 11, merge + 10].map { joining.target(at: NSPoint(x: $0, y: 17)) }, [add, add])
        XCTAssertEqual([0, 33].map { joining.target(at: NSPoint(x: merge, y: $0)) }, [add, add])
        XCTAssertEqual([merge - 12, merge + 11].map { joining.target(at: NSPoint(x: $0, y: 17)) }, [.line, .line])
        try press(joining, at: merge - 12)
        XCTAssertEqual([offered.count, opened.count], [1, 1])
        // Pressed on the station and released beside it, or the other way: neither click.
        try press(joining, at: merge, releaseAt: merge - 40)
        try press(joining, at: merge - 40, releaseAt: merge)
        XCTAssertEqual([offered.count, opened.count], [1, 1])
        // One in the list leaves it by a click on its number.
        try press(view.lineViews[2], at: merge)
        XCTAssertEqual(offered, ["nirux add #52", "nirux remove #54"])
        // Where a click changes nothing (refused, locked, no offer), the station is the line's.
        for index in [1, 3, 4] { try press(view.lineViews[index], at: merge) }
        XCTAssertEqual(opened, ["joining", "refused", "held", "plain"])
        XCTAssertEqual(offered.count, 2)
        // The station acts at each click: a second one, at once, isn't the end of a double click.
        try press(joining, at: merge, clicks: 2)
        XCTAssertEqual(offered.count, 3)

        // A press in flight outlives a change that leaves its offer as it was.
        let down = joining.convert(NSPoint(x: merge, y: joining.bounds.midY), to: nil)
        joining.mouseDown(with: try mouse(.leftMouseDown, at: down, in: joining.window))
        view.show(content([section(units: tasks(lines(with(offering("joining", .add, 52)) { $0.title = "Joining, renamed" })))]))
        view.layoutSubtreeIfNeeded()
        XCTAssertTrue(view.lineViews[0] === joining)
        joining.mouseUp(with: try mouse(.leftMouseUp, at: down, in: joining.window))
        XCTAssertEqual(offered.count, 4)
        // What was pressed is no longer what is offered: it joined the list meanwhile, or the list is locked.
        for changed in [offering("joining", .remove, 52), offering("joining", .add, 52, blocked: "The queue is running.")] {
            view.show(content([section(units: tasks(lines(offering("joining", .add, 52))))]))
            joining.mouseDown(with: try mouse(.leftMouseDown, at: down, in: joining.window))
            view.show(content([section(units: tasks(lines(changed)))]))
            view.layoutSubtreeIfNeeded()
            joining.mouseUp(with: try mouse(.leftMouseUp, at: down, in: joining.window))
        }
        XCTAssertEqual([offered.count, opened.count], [4, 4], "neither queued nor opened")

        // VoiceOver reaches it by name; the line stays one button, and says why its station refuses.
        let listed = view.lineViews[2]
        XCTAssertEqual(listed.accessibilityCustomActions()?.map(\.name), ["Remove from Queue"])
        XCTAssertEqual(listed.accessibilityCustomActions()?.first?.handler?(), true)
        XCTAssertEqual(offered.count, 5)
        XCTAssertEqual(offered.last, "nirux remove #54")
        XCTAssertNil(joining.accessibilityCustomActions(), "nothing to do while it is blocked")
        XCTAssertNil(view.lineViews[4].accessibilityCustomActions())
        XCTAssertEqual(view.lineViews.map { $0.accessibilityHelp() }, [
            "The queue is running.", "Can’t join the queue: draft", nil, "The queue is running.", nil
        ])
        // An action named before the list was locked does what a click then does: nothing.
        let stale = try XCTUnwrap(listed.accessibilityCustomActions()?.first)
        view.show(content([section(units: tasks([
            offering("joining", .add, 52), offering("refused", .add, 53, blocked: "Can’t join the queue: draft"),
            offering("listed", .remove, 54, blocked: "The queue is running."), line("plain")
        ]))]))
        XCTAssertTrue(view.lineViews[2] === listed)
        XCTAssertEqual(stale.handler?(), false)
        XCTAssertEqual(offered.count, 5)
        XCTAssertNil(joining.accessibilityHelp(), "its station acts again: nothing left to say why not")
        // Nor for another pull request than the one it was named for.
        let named = try XCTUnwrap(joining.accessibilityCustomActions()?.first)
        view.show(content([section(units: tasks([offering("joining", .add, 99)]))]))
        XCTAssertTrue(view.lineViews[0] === joining)
        XCTAssertEqual(named.handler?(), false)
        XCTAssertEqual(offered.count, 5)
    }

    func testAClickNeedsItsLineInSight() throws {
        // More lines than the Board is tall: the last ones are below what shows.
        let many = (1...30).map { offering("task\($0)", .add, $0) }
        let view = board(content([section(units: tasks(many))]))
        var offered: [Int] = []
        view.onOffer = { _, offer in offered.append(offer.number) }
        let merge = BoardStagesView.Columns(width: 940).stations[3]
        let last = try XCTUnwrap(view.lineViews.last)
        XCTAssertGreaterThan(last.frame.minY, view.scrollView.documentVisibleRect.maxY)
        try press(last, at: merge)
        XCTAssertEqual(offered, [], "a release where the line doesn't show is no click")
        XCTAssertEqual(last.handRects, [], "nor is a hand shown there")
        // Scrolled to: it is in sight, and acts.
        view.scrollView.contentView.scroll(to: NSPoint(x: 0, y: last.frame.maxY - view.scrollView.contentSize.height))
        try press(last, at: merge)
        XCTAssertEqual(offered, [30])
        XCTAssertEqual(last.handRects, [NSRect(x: merge - 11, y: 0, width: 22, height: 34)], "a hand on the station that acts")
        XCTAssertEqual(view.lineViews[0].handRects, [])
        let refused = BoardStagesLineView(offering("refused", .add, 53, blocked: "Can’t join the queue: draft"), link: .none)
        refused.frame = NSRect(x: 0, y: 0, width: 940, height: 34)
        XCTAssertEqual(refused.handRects, [], "none where a click on the station is the line's")
    }

    func testALineSaysWhichSectionItIsListedIn() throws {
        let retarget = BoardStages.Link.retarget(number: 53, onto: "main")
        let based = { (id: String) in
            self.with(self.line(id, state: .idle, phrase: "Base #52 merged · Retarget to main")) { $0.phrase.link = retarget }
        }
        let view = board(content([
            section("nirux", units: tasks([offering("first", .add, 1), based("moving")])),
            section("site", units: tasks([offering("second", .add, 2), based("staying")]))
        ]))
        var said: [String] = []
        view.onOffer = { section, offer in said.append("\(section) #\(offer.number)") }
        view.onLink = { section, line, link in said.append("\(section) \(line) \(link.title)") }
        let merge = BoardStagesView.Columns(width: 940).stations[3]
        let moving = view.lineViews[1]
        try press(view.lineViews[0], at: merge)
        try press(view.lineViews[2], at: merge)
        try click(moving.linkLabel)
        try click(view.lineViews[3].linkLabel)
        XCTAssertEqual(said, ["nirux #1", "site #2", "nirux moving Retarget to main", "site staying Retarget to main"])
        // A line listed in another section keeps its view, and says the section it is in now.
        view.show(content([
            section("nirux", units: tasks([offering("first", .add, 1)])),
            section("site", units: tasks([offering("second", .add, 2), based("staying"), based("moving")]))
        ]))
        view.layoutSubtreeIfNeeded()
        XCTAssertTrue(view.lineViews[3] === moving)
        try click(moving.linkLabel)
        XCTAssertEqual(said.last, "site moving Retarget to main")
    }

    func testTheLinkEndingAPhraseIsATargetOfItsOwn() throws {
        let retarget = BoardStages.Link.retarget(number: 53, onto: "main")
        let based = with(line("based", state: .idle, phrase: "Base #52 merged · Retarget to main")) { $0.phrase.link = retarget }
        let view = board(content([section(units: tasks([
            based,
            with(line("merged", state: .merged, phrase: "Merged · Clean up")) { $0.phrase.link = .cleanUp },
            // A build that can't change GitHub: the same words, and no link.
            line("inert", state: .idle, phrase: "Base #52 merged · Retarget to main", detail: "Dry run."),
            // In the queue's list, on a merged base: a station and a link.
            with(offering("both", .remove, 53, state: .idle)) { $0.phrase = based.phrase }
        ]))]))
        var opened: [String] = []
        var linked: [String] = []
        var offered = 0
        view.onOpen = { opened.append($0) }
        view.onLink = { section, line, link in linked.append("\(section) \(line) \(link.title)") }
        view.onOffer = { _, _ in offered += 1 }
        let shown = view.lineViews[0]
        let merged = view.lineViews[1]
        let inert = view.lineViews[2]
        XCTAssertEqual([shown.phraseLabel.stringValue, shown.linkLabel.stringValue], ["Base #52 merged ·", "Retarget to main"])
        XCTAssertEqual(shown.linkLabel.textColor, Theme.Color.accent)
        XCTAssertEqual(merged.linkLabel.frame.minX, merged.phraseLabel.frame.maxX, "right after the words before it")
        XCTAssertEqual(merged.phraseLabel.frame.width, ColumnHeaderView.textWidth(merged.phraseLabel), "which take their own width")
        XCTAssertEqual(merged.linkLabel.frame.width, ColumnHeaderView.textWidth(merged.linkLabel))
        XCTAssertEqual(inert.phraseLabel.stringValue, "Base #52 merged · Retarget to main")
        XCTAssertTrue(inert.linkLabel.isHidden)

        try click(shown.linkLabel)
        try click(merged.linkLabel)
        XCTAssertEqual(linked, ["nirux based Retarget to main", "nirux merged Clean up"])
        XCTAssertEqual(opened, [], "not a click on the line")
        try click(shown.phraseLabel)
        try click(inert.phraseLabel)
        XCTAssertEqual(opened, ["based", "inert"], "the words before a link, or without one, are the line's")
        try press(inert, at: shown.linkLabel.frame.midX)
        XCTAssertEqual([linked.count, opened.count], [2, 3], "where a link would be")
        // The link is a target the line's height, over its own words and no further.
        let link = shown.linkLabel.frame
        XCTAssertEqual([NSPoint(x: link.minX, y: 0), NSPoint(x: link.maxX - 1, y: 33)].map(shown.target(at:)), [.link(retarget), .link(retarget)])
        XCTAssertEqual([link.minX - 1, link.maxX].map { shown.target(at: NSPoint(x: $0, y: 17)) }, [.line, .line])
        // A double click follows it once; pressed on it and released on the words, or on the station, it isn't followed.
        try press(merged, at: merged.linkLabel.frame.midX, clicks: 2)
        XCTAssertEqual(linked.count, 2)
        try press(shown, at: link.midX, releaseAt: shown.phraseLabel.frame.midX)
        let both = view.lineViews[3]
        let merge = BoardStagesView.Columns(width: 940).stations[3]
        try press(both, at: merge, releaseAt: both.linkLabel.frame.midX)
        try press(both, at: both.linkLabel.frame.midX, releaseAt: merge)
        XCTAssertEqual([linked.count, opened.count, offered], [2, 3, 0])

        // A hand on what a click does something of its own on: a station that acts, a link.
        XCTAssertEqual(merged.handRects, [NSRect(x: merged.linkLabel.frame.minX, y: 0, width: merged.linkLabel.frame.width, height: 34)])
        XCTAssertEqual(both.handRects.map(\.midX), [merge, both.linkLabel.frame.midX])
        XCTAssertEqual(inert.handRects, [])

        // VoiceOver reaches the link by its name, after the station's click, and as a click does.
        XCTAssertEqual(both.accessibilityCustomActions()?.map(\.name), ["Remove from Queue", "Retarget to main"])
        let action = try XCTUnwrap(shown.accessibilityCustomActions()?.first)
        XCTAssertEqual(action.name, "Retarget to main")
        XCTAssertEqual(action.handler?(), true)
        XCTAssertEqual(linked.last, "nirux based Retarget to main")
        XCTAssertNil(inert.accessibilityCustomActions())
        XCTAssertEqual(shown.accessibilityLabel(), "Based, at Checks, Base #52 merged · Retarget to main, #52", "the phrase whole")

        // The line no longer has its link (retargeted): its words alone, the line's; the action named before does nothing.
        view.show(content([section(units: tasks([line("based", state: .idle, phrase: "Checks running")]))]))
        view.layoutSubtreeIfNeeded()
        XCTAssertTrue(view.lineViews[0] === shown)
        XCTAssertEqual([shown.phraseLabel.stringValue, shown.linkLabel.stringValue], ["Checks running", ""])
        XCTAssertTrue(shown.linkLabel.isHidden)
        XCTAssertEqual(shown.target(at: NSPoint(x: link.midX, y: 17)), .line)
        XCTAssertEqual(action.handler?(), false)
        XCTAssertEqual(linked.count, 3)
        // A phrase that doesn't end with its link's words is shown as it is, without one.
        let odd = BoardStagesLineView(with(line("odd", phrase: "Retarget to main, then merge")) { $0.phrase.link = retarget }, link: .none)
        XCTAssertEqual([odd.phraseLabel.stringValue, odd.linkLabel.stringValue], ["Retarget to main, then merge", ""])
        XCTAssertNil(odd.accessibilityCustomActions(), "nor to VoiceOver")
    }

    func testOnANarrowBoardTheWordsBeforeALinkGiveWay() throws {
        let retarget = BoardStages.Link.retarget(number: 53, onto: "main")
        let phrase = "Base #52 merged · Retarget to main"
        let hint = "Bases #53 on main, as GitHub does when a merged branch is deleted"
        let based = with(line("based", state: .idle, phrase: phrase)) { $0.phrase.link = retarget }
        let view = board(content([section(units: tasks([based]))]))
        let shown = view.lineViews[0]
        let said = { (label: NSTextField) -> String in
            shown.view(shown, stringForToolTip: 0, point: NSPoint(x: label.frame.midX, y: label.frame.midY), userData: nil)
        }
        let words = ColumnHeaderView.textWidth(shown.phraseLabel)
        let link = ColumnHeaderView.textWidth(shown.linkLabel)
        XCTAssertEqual([said(shown.phraseLabel), said(shown.linkLabel)], ["", hint], "whole: the words add nothing, the link what its click does")

        // The widths where the phrase's column holds the link and some of the words, the link alone, less than the link.
        let widths = (392...940).map { CGFloat($0) }
        let column = { (width: CGFloat) in BoardStagesView.Columns(width: width).phrase }
        let cut = try XCTUnwrap(widths.first { column($0).width >= link + 30 && column($0).width < link + words })
        let alone = try XCTUnwrap(widths.last { column($0).width >= link && column($0).width < link + 30 })
        let less = try XCTUnwrap(widths.first { column($0).width > 0 && column($0).width < link })
        let resize = { (width: CGFloat) in
            view.setFrameSize(NSSize(width: width, height: 600))
            view.layoutSubtreeIfNeeded()
        }
        resize(cut)
        XCTAssertEqual(shown.linkLabel.frame.width, link, "the link stays whole")
        XCTAssertEqual(shown.linkLabel.frame.maxX, column(cut).maxX)
        XCTAssertEqual(shown.phraseLabel.frame, NSRect(x: column(cut).minX, y: 9, width: column(cut).width - link, height: 16), "its words give way")
        XCTAssertEqual([said(shown.phraseLabel), said(shown.linkLabel)], [phrase, "\(phrase)\n\(hint)"], "the phrase whole under the pointer")

        resize(alone)
        XCTAssertTrue(shown.phraseLabel.isHidden, "a letter or two and an ellipsis say nothing")
        XCTAssertGreaterThan(column(alone).width - link, 20, "though they had some room")
        XCTAssertEqual(shown.linkLabel.frame, NSRect(x: column(alone).minX, y: 9, width: link, height: 16))
        XCTAssertEqual(said(shown.linkLabel), "\(phrase)\n\(hint)", "the link has the words then")
        XCTAssertEqual(shown.target(at: NSPoint(x: shown.linkLabel.frame.midX, y: 17)), .link(retarget))

        resize(less)
        XCTAssertEqual(shown.linkLabel.frame.width, column(less).width, "no wider than its column")
        XCTAssertEqual(said(shown.linkLabel), "\(phrase)\n\(hint)")

        // A link too long for the column is cut, and leaves its words half of it: the line still says what it is about.
        resize(940)
        let long = BoardStages.Link.retarget(number: 53, onto: "release/2026-11-a-branch-with-a-name-far-too-long-for-any-column")
        view.show(content([section(units: tasks([
            with(line("based", state: .idle, phrase: "Base #52 merged · \(long.title)")) { $0.phrase.link = long }
        ]))]))
        view.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(ColumnHeaderView.textWidth(shown.linkLabel), column(940).width)
        XCTAssertEqual(shown.phraseLabel.frame.width, words, "its words whole, in less than half the column")
        XCTAssertEqual(shown.linkLabel.frame, NSRect(x: column(940).minX + words, y: 9, width: column(940).width - words, height: 16))
        XCTAssertEqual([said(shown.phraseLabel), said(shown.linkLabel)],
                       ["Base #52 merged · \(long.title)", "Base #52 merged · \(long.title)\n\(long.hint)"],
                       "the phrase whole under the pointer, on its words as on its link")
        let sharing = try XCTUnwrap(widths.first { column($0).width >= 120 && column($0).width / 2 < words })
        resize(sharing)
        XCTAssertEqual([shown.phraseLabel.frame.width, shown.linkLabel.frame.width], [column(sharing).width / 2, column(sharing).width / 2])
        let tight = try XCTUnwrap(widths.last { column($0).width > 0 && column($0).width < 120 })
        resize(tight)
        XCTAssertTrue(shown.phraseLabel.isHidden, "no room for some of both")
        XCTAssertEqual(shown.linkLabel.frame.width, column(tight).width)

        // Words that are whole stay, however short.
        resize(940)
        view.show(content([section(units: tasks([with(line("based", state: .merged, phrase: "Up · Clean up")) { $0.phrase.link = .cleanUp }]))]))
        view.layoutSubtreeIfNeeded()
        XCTAssertEqual(shown.phraseLabel.stringValue, "Up ·")
        XCTAssertLessThan(ColumnHeaderView.textWidth(shown.phraseLabel), 30)
        XCTAssertEqual([shown.phraseLabel.isHidden, shown.phraseLabel.frame.width == ColumnHeaderView.textWidth(shown.phraseLabel)], [false, true])
        view.show(content([section(units: tasks([based]))]))

        // No column for a phrase: no link to click, or to say anything.
        resize(380)
        XCTAssertEqual(column(380).width, 0)
        XCTAssertTrue(shown.phraseLabel.isHidden && shown.linkLabel.isHidden)
        XCTAssertTrue((0..<380).allSatisfy { shown.target(at: NSPoint(x: CGFloat($0), y: 17)) == .line })
        XCTAssertEqual(shown.hints.map(\.text), [])
        XCTAssertEqual(shown.handRects, [])
    }

    func testEachPlaceOfALineSaysItsOwnUnderThePointer() throws {
        let checks = "test: ●\nlint: ✓"
        let address = "Stack: #52 → #53 → #54, on main\nhttps://github.com/acme/app/pull/53"
        let told = with(line("told", pullRequest: "#53 · 2/3")) {
            $0.offer = BoardStages.QueueOffer(change: .add, number: 53)
            $0.tooltips = BoardStages.Tooltips(
                title: "feat/told · /p/app.told",
                stations: [.reviews: "Code review ran on another commit", .checks: checks, .merge: "Add to Queue"], pullRequest: address
            )
        }
        let long = "A task whose title is far too long for the column it is given on any Board"
        let view = board(content([section(units: tasks([
            told, with(told) { $0.title = long }, with(told) { $0.pullRequest = "#123456 · on #123455" },
            with(line("bare", rail: false)) { $0.tooltips.stations = [.merge: "Add to Queue"] }, line("plain")
        ]))]))
        let shown = view.lineViews[0]
        let stations = BoardStagesView.Columns(width: 940).stations
        let at = { (line: BoardStagesLineView, x: CGFloat) in
            line.view(line, stringForToolTip: 0, point: NSPoint(x: x, y: line.bounds.midY), userData: nil)
        }
        XCTAssertEqual(at(shown, shown.titleLabel.frame.midX), "feat/told · /p/app.told", "where its work is")
        XCTAssertEqual(at(view.lineViews[1], shown.titleLabel.frame.midX), "\(long)\nfeat/told · /p/app.told", "after a title that is cut")
        XCTAssertEqual(stations.map { at(shown, $0) }, ["", "Code review ran on another commit", checks, "Add to Queue"],
                       "each station its own; Code has nothing to add")
        XCTAssertEqual([at(shown, stations[1] - 11), at(shown, stations[1] + 10)], Array(repeating: "Code review ran on another commit", count: 2))
        XCTAssertEqual([at(shown, stations[1] - 12), at(shown, stations[1] + 11)], ["", ""], "between two stations, nothing")
        XCTAssertEqual(at(shown, shown.pullRequestLabel.frame.midX), address)
        XCTAssertEqual(at(view.lineViews[2], shown.pullRequestLabel.frame.midX), "#123456 · on #123455\n\(address)",
                       "after a pull request that is cut, though its title is whole")
        XCTAssertEqual(at(shown, shown.phraseLabel.frame.midX), "", "a phrase that is whole has nothing to add")
        XCTAssertEqual(stations.map { at(view.lineViews[3], $0) }, ["", "", "", ""], "no rail, no station")

        // Each place is one AppKit asks about: registered as a tooltip's, where the line is.
        XCTAssertEqual(Set(shown.hints.map(\.text)),
                       ["feat/told · /p/app.told", address, "Code review ran on another commit", checks, "Add to Queue"])
        let station = NSRect(x: stations[3] - 11, y: 0, width: 22, height: 34)
        XCTAssertTrue(shown.hints.contains { $0.rect == station && $0.text == "Add to Queue" })
        let registered = shown.trackingAreas
        for hint in shown.hints {
            XCTAssertTrue(registered.contains { $0.rect == hint.rect }, "\(hint.text) at \(hint.rect), among \(registered.map(\.rect))")
        }
        XCTAssertTrue(view.lineViews[4].hints.isEmpty && view.lineViews[4].trackingAreas.isEmpty, "a line with nothing to add registers nothing")

        // Other words in the same places: asked for when shown, without registering them again (a tooltip being read stays up).
        view.show(content([section(units: tasks([with(told) { $0.tooltips.stations[.checks] = "test: ✓\nlint: ✓" }]))]))
        view.layoutSubtreeIfNeeded()
        XCTAssertTrue(view.lineViews[0] === shown)
        XCTAssertEqual(at(shown, stations[2]), "test: ✓\nlint: ✓")
        XCTAssertEqual(shown.trackingAreas.count, registered.count)
        XCTAssertTrue(zip(shown.trackingAreas, registered).allSatisfy { $0 === $1 })
        // A place that comes (the phrase's, with a detail) or goes leaves the others' as they are.
        let checksArea = try XCTUnwrap(registered.first { $0.rect.midX == stations[2] })
        view.show(content([section(units: tasks([with(told) { $0.phrase.detail = "test started 4 minutes ago" }]))]))
        view.layoutSubtreeIfNeeded()
        XCTAssertEqual(at(shown, shown.phraseLabel.frame.midX), "test started 4 minutes ago")
        XCTAssertEqual(shown.trackingAreas.count, registered.count + 1)
        XCTAssertTrue(shown.trackingAreas.contains { $0 === checksArea })
        view.show(content([section(units: tasks([told]))]))
        view.layoutSubtreeIfNeeded()
        XCTAssertEqual(shown.trackingAreas.count, registered.count, "the phrase's is gone")
        XCTAssertTrue(shown.trackingAreas.contains { $0 === checksArea })
        // A narrower Board moves them with the stations.
        view.setFrameSize(NSSize(width: 700, height: 600))
        view.layoutSubtreeIfNeeded()
        let narrow = NSRect(x: BoardStagesView.Columns(width: 700).stations[3] - 11, y: 0, width: 22, height: 34)
        XCTAssertNotEqual(narrow, station)
        XCTAssertEqual(at(shown, narrow.midX), "Add to Queue")
        XCTAssertTrue(shown.trackingAreas.contains { $0.rect == narrow })
        XCTAssertFalse(shown.trackingAreas.contains { $0.rect == station }, "the earlier place is gone")
    }

    // MARK: - The pointer

    /// The place of `x` on `line`'s middle row, in its window.
    private func place(_ x: CGFloat, on line: BoardStagesLineView) -> NSPoint {
        line.convert(NSPoint(x: x, y: line.bounds.midY), to: nil)
    }

    private func moved(to location: NSPoint, in view: NSView) throws -> NSEvent {
        try mouse(.mouseMoved, at: location, in: view.window, clicks: 0)
    }

    func testTheBoardLightsTheMergeStationUnderThePointer() throws {
        let lines = { (blocked: String?) in
            [
                self.offering("joining", .add, 52, blocked: blocked), self.offering("refused", .add, 53, blocked: "Can’t join the queue: draft"),
                self.offering("listed", .remove, 54), self.line("plain")
            ]
        }
        let view = board(content([section(units: tasks(lines(nil)))]))
        let joining = view.lineViews[0]
        let merge = BoardStagesView.Columns(width: 940).stations[3]
        let lit = { view.lineViews.map(\.isStationHovered) }

        // One area for the whole Board, wherever its lines are: it hears the pointer move, come and go.
        view.updateTrackingAreas()
        view.updateTrackingAreas()
        let areas = view.trackingAreas.filter { $0.owner === view }
        XCTAssertEqual(areas.count, 1)
        XCTAssertEqual(areas.first?.options, [.mouseEnteredAndExited, .mouseMoved, .activeInActiveApp, .inVisibleRect])
        XCTAssertTrue(view.lineViews.allSatisfy { line in !line.trackingAreas.contains { $0.options.contains(.mouseMoved) } })

        joining.wantsLayer = true
        let layer = try XCTUnwrap(joining.layer)
        layer.displayIfNeeded()
        view.mouseMoved(with: try moved(to: place(merge - 40, on: joining), in: view))
        XCTAssertEqual(lit(), [false, false, false, false])
        XCTAssertFalse(layer.needsDisplay(), "beside the station, nothing changes")
        view.mouseMoved(with: try moved(to: place(merge + 10, on: joining), in: view))
        XCTAssertEqual(lit(), [true, false, false, false])
        XCTAssertTrue(layer.needsDisplay(), "on it, the line is painted again")
        layer.displayIfNeeded()
        view.mouseMoved(with: try moved(to: place(merge - 40, on: joining), in: view))
        XCTAssertEqual(lit(), [false, false, false, false])
        XCTAssertTrue(layer.needsDisplay(), "and again once the pointer left it")
        // Entering the Board on a station lights it; entering elsewhere doesn't.
        view.mouseEntered(with: try moved(to: place(merge, on: view.lineViews[2]), in: view))
        XCTAssertEqual(lit(), [false, false, true, false])
        view.mouseEntered(with: try moved(to: place(merge - 40, on: view.lineViews[2]), in: view))
        XCTAssertEqual(lit(), [false, false, false, false])
        // A station that refuses, or offers nothing, says so in its tooltip only.
        view.mouseMoved(with: try moved(to: place(merge, on: view.lineViews[1]), in: view))
        view.mouseMoved(with: try moved(to: place(merge, on: view.lineViews[3]), in: view))
        XCTAssertEqual(lit(), [false, false, false, false])
        view.mouseMoved(with: try moved(to: place(merge, on: joining), in: view))
        // The pointer left something inside the Board (a button's own area): it is still on the station.
        view.mouseExited(with: try moved(to: place(merge, on: joining), in: view))
        XCTAssertEqual(lit(), [true, false, false, false])
        view.mouseExited(with: try moved(to: NSPoint(x: -10, y: -10), in: view))
        XCTAssertEqual(lit(), [false, false, false, false], "the pointer left the Board")

        // A press that leaves the station, its button down, no longer lights it: no other event says so.
        view.mouseMoved(with: try moved(to: place(merge, on: joining), in: view))
        joining.mouseDown(with: try mouse(.leftMouseDown, at: place(merge, on: joining), in: view.window))
        joining.mouseDragged(with: try mouse(.leftMouseDragged, at: place(merge - 40, on: joining), in: view.window))
        XCTAssertEqual(lit(), [false, false, false, false])
        joining.mouseUp(with: try mouse(.leftMouseUp, at: place(merge, on: joining), in: view.window))
        XCTAssertEqual(lit(), [true, false, false, false], "released back on it")

        // The lines move under a still pointer: the Board asks where it is, at each change.
        let still = place(merge, on: joining)
        view.pointerLocation = { still }
        view.show(content([section(units: tasks(Array(lines(nil).reversed())))]))
        view.layoutSubtreeIfNeeded()
        XCTAssertEqual(view.lineViews.map(\.line.id), ["plain", "listed", "refused", "joining"])
        XCTAssertEqual(lit(), [false, false, false, false], "the line now under the pointer offers nothing; the one that left is dark")
        view.show(content([section(units: tasks(lines("The queue is running.")))]))
        XCTAssertEqual(lit(), [false, false, false, false], "locked under the pointer")
        view.show(content([section(units: tasks(lines(nil)))]))
        XCTAssertEqual(lit(), [true, false, false, false], "and open again")
        // A narrower Board moves the station away from under it.
        view.setFrameSize(NSSize(width: 700, height: 600))
        XCTAssertEqual(lit(), [false, false, false, false])
        view.setFrameSize(NSSize(width: 940, height: 600))
        XCTAssertEqual(lit(), [true, false, false, false])
        // The app is no longer the active one: its windows don't hear the pointer leave.
        view.pointerLocation = { nil }
        NotificationCenter.default.post(name: NSApplication.didResignActiveNotification, object: NSApp)
        XCTAssertEqual(lit(), [false, false, false, false])
        view.pointerLocation = { still }
        NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: NSApp)
        XCTAssertEqual(lit(), [true, false, false, false])
        // A Board that doesn't show lights nothing, whatever asks; shown again, it asks where the pointer is.
        view.isHidden = true
        XCTAssertEqual(lit(), [false, false, false, false], "hidden")
        view.show(content([section(units: tasks(Array(lines(nil).prefix(3))))]))
        NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: NSApp)
        XCTAssertEqual(view.lineViews.map(\.isStationHovered), [false, false, false])
        view.isHidden = false
        XCTAssertEqual(view.lineViews.map(\.isStationHovered), [true, false, false])
    }

    func testOnlyAStationThatActsIsLit() throws {
        // In the queue's list, on a merged base: its station acts, and so does its link.
        let retarget = BoardStages.Link.retarget(number: 53, onto: "main")
        let both = with(offering("both", .remove, 53, state: .idle)) {
            $0.phrase = BoardStages.Phrase(text: "Base #52 merged · Retarget to main", link: retarget)
        }
        let view = board(content([section(units: tasks([both]))]))
        let shown = view.lineViews[0]
        view.mouseMoved(with: try moved(to: place(shown.linkLabel.frame.midX, on: shown), in: view))
        XCTAssertFalse(shown.isStationHovered, "the pointer on its link lights no station")
        view.mouseMoved(with: try moved(to: place(BoardStagesView.Columns(width: 940).stations[3], on: shown), in: view))
        XCTAssertTrue(shown.isStationHovered)
        XCTAssertNil(view.pointerLocation(), "a Board that isn't on screen doesn't hear the pointer: it asks for none")
    }

    func testTheListScrollsUnderAStillPointer() throws {
        let view = board(content([section(units: tasks((1...30).map { offering("task\($0)", .add, $0) }))]))
        let merge = BoardStagesView.Columns(width: 940).stations[3]
        let still = place(merge, on: view.lineViews[2])
        view.pointerLocation = { still }
        view.updateTrackingAreas()
        XCTAssertEqual(view.lineViews.firstIndex(where: \.isStationHovered), 2)
        // Two lines up: another line is under the pointer, which didn't move.
        let clip = view.scrollView.contentView
        clip.setBoundsOrigin(NSPoint(x: 0, y: clip.bounds.minY + 2 * BoardStagesView.Metrics.lineHeight))
        XCTAssertEqual(view.lineViews.filter(\.isStationHovered).map(\.line.id), ["task5"])
        // Over the columns' titles, a line scrolled under them is not under the pointer.
        let titles = view.convert(NSPoint(x: merge, y: BoardStagesView.Metrics.headerHeight + 10), to: nil)
        view.mouseMoved(with: try moved(to: titles, in: view))
        XCTAssertEqual(view.lineViews.filter(\.isStationHovered).map(\.line.id), [])
    }

    func testTheHoveredMergeStationIsPaintedWithItsSign() throws {
        let rail = BoardStages.Rail(marks: [.done, .done, .current, .ahead])
        // The rows of column `x`, and the columns of rows 9 and 10, that hold ink inside the ring: a sign's upright, its bar.
        let isInk = { (color: NSColor?) in (self.distance(color, to: Theme.Color.canvas) ?? 0) > 0.5 }
        let upright = { (pixel: (CGFloat, CGFloat) -> NSColor?) in (4...15).filter { isInk(pixel(169, CGFloat($0))) }.count }
        let bar = { (pixel: (CGFloat, CGFloat) -> NSColor?) in (163...174).filter { isInk(pixel(CGFloat($0), 10)) }.count }
        // A ring's top, which only part of a pixel holds: bright, or in a colour, within a wide margin.
        let ring = { (pixel: (CGFloat, CGFloat) -> NSColor?, color: NSColor) in (self.distance(pixel(168, 2), to: color) ?? 9) < 0.3 }

        let resting = try paint(rail, state: .waiting)
        XCTAssertTrue(isEmpty(resting(168, 2)), "at rest: a hollow dot, smaller than a ring")
        let joining = try paint(rail, state: .waiting, hovered: .add)
        XCTAssertTrue(ring(joining, Theme.Color.textPrimary), "a bright ring")
        XCTAssertEqual([upright(joining), bar(joining)], [8, 8], "a plus: an upright and a bar, on the station's centre")
        XCTAssertEqual([167, 168, 169, 170].map { isInk(joining(CGFloat($0), 7)) }, [false, true, true, false], "its upright two columns wide")
        XCTAssertTrue(isClose(joining(166, 10), to: Theme.Color.textPrimary) && isClose(joining(169, 7), to: Theme.Color.textPrimary))
        // In the list: a minus takes its number's place.
        let listed = BoardStages.Rail(marks: [.done, .done, .current, .ahead], queueOrder: 2)
        let leaving = try paint(listed, state: .waiting, hovered: .remove)
        XCTAssertTrue(ring(leaving, Theme.Color.textPrimary))
        XCTAssertEqual([upright(leaving), bar(leaving)], [2, 8], "a minus: its bar alone, two rows of it")
        let numbered = try paint(listed, state: .waiting)
        XCTAssertTrue(ring(numbered, Theme.Color.textDisabled), "at rest, its number in a grey ring")
        // At Merge, the ring keeps the state's colour: amber is never hidden.
        let asking = try paint(BoardStages.Rail(marks: [.done, .done, .done, .current]), state: .needsYou, hovered: .add)
        XCTAssertTrue(ring(asking, Theme.Color.waiting))
        XCTAssertTrue(isClose(asking(166, 10), to: Theme.Color.textPrimary), "its sign bright")

        // Through a line: the sign of what its station offers, only while one acts.
        let merge = BoardStagesView.Columns(width: 940).stations[3]
        let line = BoardStagesLineView(offering("listed", .remove, 54), link: .none)
        line.frame = NSRect(x: 0, y: 0, width: 940, height: 34)
        line.isStationHovered = true
        var pixel = try paint(line)
        XCTAssertTrue(isClose(pixel(merge - 3, 17), to: Theme.Color.textPrimary), "its bar")
        XCTAssertFalse(isInk(pixel(merge, 14)), "a minus, as it would leave the list")
        line.update(offering("listed", .remove, 54, blocked: "The queue is running."), link: .none)
        pixel = try paint(line)
        XCTAssertFalse(isClose(pixel(merge - 3, 17), to: Theme.Color.textPrimary), "locked: no sign, wherever the pointer is")
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
            section("nirux", units: [.task(line("a"), subtasks: [])], status: ColumnHeaderView.Status("nightly 12:14", tone: .neutral)),
            section("site", units: [.task(line("b"), subtasks: [])])
        ]))
        let first = try XCTUnwrap(view.sectionHeader(section: "nirux"))
        let second = try XCTUnwrap(view.sectionHeader(section: "site"))
        XCTAssertEqual([first.titleLabel.stringValue, second.titleLabel.stringValue], ["nirux", "site"])
        // A header: its name at the padding, then `owner/name`, its post-merge run at the right.
        XCTAssertEqual(first.titleLabel.frame.minX, BoardStagesView.Metrics.padding)
        XCTAssertGreaterThanOrEqual(first.detailLabel.frame.minX, first.titleLabel.frame.maxX)
        XCTAssertEqual([first.pill.isHidden, second.pill.isHidden], [false, true])
        XCTAssertEqual(first.pill.frame.maxX, 940 - BoardStagesView.Metrics.padding)
        XCTAssertLessThanOrEqual(first.detailLabel.frame.maxX, first.pill.frame.minX)
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
        let press = { (segment: Int) in
            view.orderSwitch.selectedSegment = segment
            view.orderSwitch.sendAction(view.orderSwitch.action, to: view.orderSwitch.target)
        }
        press(1)
        XCTAssertEqual(asked, [.progress])
        XCTAssertEqual(view.orderSwitch.selectedSegment, 0, "the switch shows the content's order, not the click")
        view.show(content([], order: .progress))
        XCTAssertEqual(view.orderSwitch.selectedSegment, 1, "it moves once the owner shows the order asked")
        press(0)
        XCTAssertEqual(asked, [.progress, .sidebar])
        XCTAssertEqual(view.orderSwitch.selectedSegment, 1)
    }

    func testTheHeaderGivesWayOnANarrowBoardTheNameLast() {
        let view = board(content([]))
        XCTAssertEqual([view.nameLabel.stringValue, view.leadLabel.stringValue], ["nirux-public", "Lead · reviewing #438"])
        let whole: [NSView] = [view.nameLabel, view.summaryLabel, view.leadDot, view.leadLabel, view.orderSwitch]
        XCTAssertTrue(whole.allSatisfy { !$0.isHidden })
        let row = [view.nameLabel.frame, view.summaryLabel.frame, view.leadDot.frame, view.leadLabel.frame, view.orderSwitch.frame]
        XCTAssertTrue(zip(row, row.dropFirst()).allSatisfy { $0.maxX <= $1.minX }, "name, summary, Lead, switch: none over another")
        XCTAssertEqual(view.leadDot.toolTip, "Lead · reviewing #438", "the Lead's dot says its line where that one has no room")
        XCTAssertEqual(view.summaryLabel.stringValue, "1 repository · 3 tasks")
        XCTAssertEqual(view.spaceDot.layer?.backgroundColor, Theme.Color.accent.cgColor)

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

        // The switch goes before the name is cut: at no width are both true.
        XCTAssertEqual(shown(at(name + 20 + rest)), [false, false, true, true])
        let withoutSwitch = at(name + 20 + rest - 1)
        XCTAssertEqual(shown(withoutSwitch), [false, false, true, false], "then the order switch")
        XCTAssertEqual(withoutSwitch.nameLabel.frame.width, name, "the name is the last to give way")
        XCTAssertEqual(withoutSwitch.leadDot.frame.maxX, withoutSwitch.bounds.width - padding)
        let narrowing = at(700)
        let cutBesideTheSwitch = stride(from: CGFloat(700), through: 100, by: -1).filter { width in
            narrowing.setFrameSize(NSSize(width: width, height: 600))
            return narrowing.nameLabel.frame.width < name && !narrowing.orderSwitch.isHidden
        }
        XCTAssertEqual(cutBesideTheSwitch, [], "widths where the name is cut beside the order switch")
        let tiny = at(120)
        XCTAssertEqual(tiny.nameLabel.frame.maxX, tiny.leadDot.frame.minX - 12, "cut before the Lead's dot")
        XCTAssertFalse(tiny.leadDot.isHidden)

        // A name longer than 160 pt keeps that much beside the switch.
        let long = board(content([], name: String(repeating: "nirux-", count: 12)), width: 600)
        XCTAssertFalse(long.orderSwitch.isHidden)
        XCTAssertGreaterThanOrEqual(long.nameLabel.frame.width, BoardStagesView.Metrics.minimumName)
        XCTAssertLessThan(long.nameLabel.frame.width, ColumnHeaderView.textWidth(long.nameLabel))
        XCTAssertEqual(long.nameLabel.frame.maxX, long.leadDot.frame.minX - 12)
        // A Lead's line shorter than 60 pt shows whole.
        let short = board(content([], leadText: "Lead"))
        XCTAssertFalse(short.leadLabel.isHidden)
        XCTAssertEqual(short.leadLabel.frame.width, ColumnHeaderView.textWidth(short.leadLabel))

        var withoutLead = content([])
        withoutLead.header.lead = nil
        view.show(withoutLead)
        XCTAssertTrue(view.leadLabel.isHidden && view.leadDot.isHidden, "a space without a Lead shows none")
    }

    func testAmberMeansAnAgentWaitsForTheUserAndNothingElse() throws {
        let states: [BoardStages.State] = [.needsYou, .failed, .working, .blocked, .waiting, .ready, .merged, .idle]
        XCTAssertEqual(states.filter { BoardStagesView.color(of: $0) == Theme.Color.waiting }, [.needsYou])
        XCTAssertEqual(states.filter { BoardStagesLineView.phraseColor(of: $0) == Theme.Color.waiting }, [.needsYou])
        XCTAssertEqual(states.filter { BoardStagesLineView.phraseColor(of: $0) == Theme.Color.error }, [.failed], "red for a failure only")
        let merged = { (needsYou: Bool) in
            BoardStagesMergedEntryView(BoardStages.Merged(lineID: "t", title: "T", number: 1, mergedAt: 0, needsYou: needsYou), now: 0)
        }
        XCTAssertEqual(merged(true).dotColor, Theme.Color.waiting, "a merged task whose agent asks: amber is never hidden")
        XCTAssertEqual(merged(false).dotColor, Theme.Color.done)
        for (needsYou, color) in [(true, Theme.Color.waiting), (false, Theme.Color.done)] {
            let entry = merged(needsYou)
            entry.frame = NSRect(x: 0, y: 0, width: 120, height: 18)
            let pixel = try paint(width: 120, height: 18) { entry.draw(entry.bounds) }
            XCTAssertTrue(isClose(pixel(3, 9), to: color), "its dot painted in that colour")
            XCTAssertEqual(entry.accessibilityLabel()?.hasSuffix(", needs you"), needsYou)
        }
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
        XCTAssertEqual(fold.accessibilityLabel(), "Pull requests without a task, 3")
        XCTAssertFalse(fold.isAccessibilityExpanded())
        XCTAssertEqual(view.lineViews.map(\.line.id), ["task"])
        try click(fold)
        XCTAssertTrue(fold.isAccessibilityExpanded())
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
        // A task opened since for the other one: its entry opens it.
        view.show(content([section(units: [], merged: [
            BoardStages.Merged(lineID: "late", title: "Newer", number: 300, mergedAt: now - 60, needsYou: true), asking
        ])]))
        view.layoutSubtreeIfNeeded()
        try click(try XCTUnwrap(merged.entries.first))
        XCTAssertEqual(opened, ["telegram", "telegram", "late"])
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
        XCTAssertEqual(shown.first?.frame.minX, merged.caption.frame.maxX + 18, "beside the caption, where there is room")
        XCTAssertTrue(shown.allSatisfy { $0.detailLabel.frame.minX >= $0.titleLabel.frame.maxX }, "a number after its title")
        XCTAssertGreaterThanOrEqual(merged.frame.minY, view.lineViews[0].frame.maxY, "under the section's lines")

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

    func testMergedTodayOffersToCleanUpWhatAWorktreeLeft() throws {
        let entry = { (id: String?, number: Int, cleanUp: BoardStages.CleanUp?) in
            BoardStages.Merged(lineID: id, title: "Fix \(number)", number: number, mergedAt: self.now - 3600, cleanUp: cleanUp)
        }
        let day = { (first: BoardStages.CleanUp?) in
            [entry("left", 287, first), entry("cleaning", 288, .running), entry("done", 289, nil), entry(nil, 290, .offered)]
        }
        let view = board(content([section(units: [], merged: day(.offered))]))
        var opened: [String] = []
        var linked: [String] = []
        view.onOpen = { opened.append($0) }
        view.onLink = { section, line, link in linked.append("\(section) \(line) \(link.title)") }
        let merged = try XCTUnwrap(view.mergedView(section: "nirux"))
        let left = merged.entries[0]
        let room = BoardStagesMergedEntryView.linkRoom
        XCTAssertEqual(merged.entries.map(\.linkLabel.stringValue), ["· Clean up", "· cleaning up…", "", ""],
                       "the last one has no task here: no worktree of its own to clean up")
        XCTAssertEqual(merged.entries.map(\.linkLabel.isHidden), [false, false, true, true])
        // Joined as a phrase's link is; the words alone in the link's colour, grey while a clean-up runs.
        let colors = { (entry: BoardStagesMergedEntryView) -> [NSColor?] in
            let words = entry.linkLabel.attributedStringValue
            return [0, 2].map { $0 < words.length ? words.attribute(.foregroundColor, at: $0, effectiveRange: nil) as? NSColor : nil }
        }
        XCTAssertEqual(colors(left), [Theme.Color.textTertiary, Theme.Color.accent])
        XCTAssertEqual(colors(merged.entries[1]), [Theme.Color.textTertiary, Theme.Color.textTertiary])
        XCTAssertEqual(merged.entries.map { $0.detailLabel.stringValue.hasSuffix("·") }, [false, false, false, false])
        XCTAssertEqual(left.linkLabel.frame.minX, left.detailLabel.frame.maxX, "after its number and its time")
        XCTAssertEqual(left.frame.width, left.fittingWidth, "whole, with its link")
        XCTAssertEqual(left.linkLabel.frame.maxX, left.bounds.maxX)
        XCTAssertEqual(merged.entries.prefix(2).map(\.linkLabel.frame.width), [room, room], "one room, whatever the clean-up does")
        XCTAssertTrue(merged.entries.prefix(2).allSatisfy { ColumnHeaderView.textWidth($0.linkLabel) <= room }, "which holds the longer words")
        XCTAssertEqual(merged.entries.map(\.hasLink), [true, true, false, false])
        let plain = merged.entries[2]
        XCTAssertEqual(plain.fittingWidth, plain.detailLabel.frame.maxX, "without a link, no room for one")

        // "Clean up" is a link of its own; the rest of the entry opens its task.
        try click(left.linkLabel)
        XCTAssertEqual(linked, ["nirux left Clean up"])
        XCTAssertEqual(opened, [])
        try click(left.titleLabel)
        try click(left.detailLabel)
        XCTAssertEqual(opened, ["left", "left"])
        // A clean-up that runs is no link: its words are the entry's.
        try click(merged.entries[1].linkLabel)
        XCTAssertEqual(opened, ["left", "left", "cleaning"])
        // Without a task here, nothing to clean up, nor to open.
        try click(merged.entries[3])
        XCTAssertEqual([linked.count, opened.count], [1, 3])
        // The link's place is the entry's height, over its own words; a press on it released on the title is no click.
        let link = left.linkLabel.frame
        XCTAssertEqual([NSPoint(x: link.minX, y: 0), NSPoint(x: link.maxX - 1, y: 17)].map(left.target(at:)), [.cleanUp, .cleanUp])
        XCTAssertEqual(left.target(at: NSPoint(x: link.minX - 1, y: 9)), .entry)
        let onLink = left.convert(NSPoint(x: link.midX, y: 9), to: nil)
        let onTitle = left.convert(NSPoint(x: left.titleLabel.frame.midX, y: 9), to: nil)
        left.mouseDown(with: try mouse(.leftMouseDown, at: onLink, in: view.window))
        left.mouseUp(with: try mouse(.leftMouseUp, at: onTitle, in: view.window))
        left.mouseDown(with: try mouse(.leftMouseDown, at: onTitle, in: view.window))
        left.mouseUp(with: try mouse(.leftMouseUp, at: onLink, in: view.window))
        // A double click asks once.
        left.mouseDown(with: try mouse(.leftMouseDown, at: onLink, in: view.window, clicks: 2))
        left.mouseUp(with: try mouse(.leftMouseUp, at: onLink, in: view.window, clicks: 2))
        XCTAssertEqual([linked.count, opened.count], [1, 3])

        // Under the pointer the link says what its click does; a hand shows on it.
        let place = NSRect(x: link.minX, y: 0, width: link.width, height: 18)
        XCTAssertEqual(left.view(left, stringForToolTip: 0, point: NSPoint(x: link.midX, y: 9), userData: nil),
                       "Checks the worktree, then asks what goes")
        XCTAssertEqual(left.hints.map(\.rect), [place])
        XCTAssertTrue(left.trackingAreas.contains { $0.rect == place })
        XCTAssertEqual(left.handRects, [place])
        XCTAssertEqual(merged.entries.dropFirst().map(\.handRects.count), [0, 0, 0])
        XCTAssertEqual(merged.entries[1].hints.count, 0, "a clean-up that runs says nothing more")
        // VoiceOver: an entry is a button that opens its task, with "Clean up" as an action by name; none without a task.
        XCTAssertEqual(merged.entries.map { $0.accessibilityRole() }, [.button, .button, .button, .staticText])
        XCTAssertEqual(merged.entries.prefix(3).map { $0.accessibilityLabel()?.components(separatedBy: ", ").last }, [
            "Clean up", "cleaning up…", left.accessibilityLabel()?.components(separatedBy: ", ")[2]
        ])
        XCTAssertTrue(left.accessibilityPerformPress())
        XCTAssertEqual([linked.count, opened.last], [1, "left"] as [AnyHashable?], "a press opens the task: it doesn't clean up")
        XCTAssertFalse(merged.entries[3].accessibilityPerformPress())
        let action = try XCTUnwrap(left.accessibilityCustomActions()?.first)
        XCTAssertEqual(left.accessibilityCustomActions()?.map(\.name), ["Clean up"])
        XCTAssertEqual(action.handler?(), true)
        XCTAssertEqual(linked, ["nirux left Clean up", "nirux left Clean up"])
        XCTAssertEqual(merged.entries.dropFirst().map { $0.accessibilityCustomActions()?.count }, [nil, nil, nil])

        // The clean-up starts: the same entry, its link gone, and the row as it was: the entries after it
        // don't move under the pointer. The press in flight on it, and the action named before, do nothing.
        let frames = merged.entries.map(\.frame)
        left.mouseDown(with: try mouse(.leftMouseDown, at: onLink, in: view.window))
        view.show(content([section(units: [], merged: day(.running))]))
        view.layoutSubtreeIfNeeded()
        XCTAssertTrue(merged.entries[0] === left)
        XCTAssertEqual(left.linkLabel.stringValue, "· cleaning up…")
        XCTAssertEqual(merged.entries.map(\.frame), frames)
        left.mouseUp(with: try mouse(.leftMouseUp, at: onLink, in: view.window))
        XCTAssertEqual(action.handler?(), false)
        XCTAssertEqual([linked.count, opened.count], [2, 4])
        XCTAssertEqual(left.handRects, [])
        XCTAssertEqual(left.hints.count, 0)
    }

    func testAnEntryTooNarrowForItsLinkKeepsItsTitle() throws {
        let long = "A fix whose title is long enough to be worth reading"
        let alone = BoardStagesMergedEntryView(
            BoardStages.Merged(lineID: "left", title: long, number: 287, mergedAt: now - 3600, cleanUp: .offered), now: now
        )
        let widths = { (width: CGFloat) -> [CGFloat] in
            alone.frame = NSRect(x: 0, y: 0, width: width, height: 18)
            alone.layoutSubtreeIfNeeded()
            return [alone.titleLabel.frame.width, alone.detailLabel.frame.width, alone.linkLabel.frame.width]
        }
        let said = { (label: NSTextField) in alone.toolTipText(at: NSPoint(x: label.frame.midX, y: 9)) }
        let room = BoardStagesMergedEntryView.linkRoom
        let whole = widths(alone.fittingWidth)
        XCTAssertEqual(whole, [ColumnHeaderView.textWidth(alone.titleLabel), ColumnHeaderView.textWidth(alone.detailLabel), room])
        XCTAssertEqual([said(alone.titleLabel), said(alone.detailLabel)], [nil, nil], "whole: nothing more to say")
        // The title gives way first, and is then whole under the pointer, wherever on the entry but on its link.
        XCTAssertEqual(widths(alone.fittingWidth - 20), [whole[0] - 20, whole[1], room])
        XCTAssertEqual([said(alone.titleLabel), said(alone.detailLabel), said(alone.linkLabel)], [
            long, long, "Checks the worktree, then asks what goes"
        ])
        XCTAssertEqual(alone.linkLabel.frame.maxX, alone.bounds.maxX, "inside the entry")
        // Down to 40 pt of it; then the link goes, whole, and the title has its room.
        let fixed = alone.fittingWidth - whole[0]
        XCTAssertEqual(widths(fixed + 40), [40, whole[1], room])
        XCTAssertEqual(widths(fixed + 39), [39 + room, whole[1], 0])
        XCTAssertTrue(alone.linkLabel.isHidden)
        XCTAssertEqual(alone.target(at: NSPoint(x: alone.bounds.maxX - 5, y: 9)), .entry, "no link to click")
        XCTAssertEqual(alone.hints.map(\.rect), [alone.bounds], "the title's alone, over the whole entry")
        XCTAssertEqual(alone.handRects, [])
        // The number and the time last, and never past the entry.
        XCTAssertEqual(widths(16 + whole[1]), [0, whole[1], 0])
        XCTAssertEqual(alone.detailLabel.frame.maxX, alone.bounds.maxX)
        XCTAssertEqual(said(alone.detailLabel), long, "a title that gave way entirely is still said")
        XCTAssertEqual(widths(16 + whole[1] - 10), [0, whole[1] - 10, 0])
        // A short title is whole before the link shows.
        alone.show(BoardStages.Merged(lineID: "left", title: "Fix", number: 287, mergedAt: now - 3600, cleanUp: .offered), now: now)
        let short = ColumnHeaderView.textWidth(alone.titleLabel)
        XCTAssertLessThan(short, 40)
        XCTAssertEqual(widths(16 + short + whole[1] + room), [short, whole[1], room])
        XCTAssertEqual(widths(16 + short + whole[1] + room - 1), [short, whole[1], 0])

        // On a narrow Board the entries stay where they are whatever their links: a clean-up that ends
        // moves neither the block nor what comes under it. A link with no room beside the caption isn't shown.
        let day = { (cleanUp: BoardStages.CleanUp?) in
            (0..<3).map { BoardStages.Merged(lineID: "t\($0)", title: long, number: 400 + $0, mergedAt: self.now - 60, cleanUp: cleanUp) }
        }
        let view = board(content([section(units: [], merged: day(.offered)), section("site", units: [.task(line("next"), subtasks: [])])]),
                         width: 320)
        let merged = try XCTUnwrap(view.mergedView(section: "nirux"))
        let first = try XCTUnwrap(merged.entries.first)
        XCTAssertLessThan(first.frame.minY, merged.caption.frame.maxY, "beside the caption")
        XCTAssertTrue(first.linkLabel.isHidden, "no room for the link there")
        XCTAssertGreaterThanOrEqual(first.titleLabel.frame.width, 40)
        let next = try XCTUnwrap(view.sectionHeader(section: "site")).frame
        for state in [BoardStages.CleanUp.running, nil] {
            view.show(content([section(units: [], merged: day(state)), section("site", units: [.task(line("next"), subtasks: [])])]))
            view.layoutSubtreeIfNeeded()
            XCTAssertEqual(try XCTUnwrap(view.sectionHeader(section: "site")).frame, next, "\(String(describing: state))")
        }
        // Wide enough, the link shows beside the caption.
        view.setFrameSize(NSSize(width: 700, height: 600))
        view.show(content([section(units: [], merged: day(.offered)), section("site", units: [.task(line("next"), subtasks: [])])]))
        view.layoutSubtreeIfNeeded()
        XCTAssertFalse(first.linkLabel.isHidden)
        XCTAssertLessThan(first.frame.minY, merged.caption.frame.maxY)
    }

    /// Counts what asks AppKit for a view's cursor places again.
    private final class CursorWindow: NSWindow {
        var asked: [NSView] = []
        override func invalidateCursorRects(for view: NSView) {
            asked.append(view)
            super.invalidateCursorRects(for: view)
        }
    }

    func testAHandIsAskedForAgainWhereItNoLongerIsWhatAppKitHolds() throws {
        let window = CursorWindow(contentRect: NSRect(x: 0, y: 0, width: 940, height: 100), styleMask: [.borderless], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        windows.append(window)
        let holder = NSView(frame: window.contentLayoutRect)
        window.contentView = holder
        let entry = BoardStagesMergedEntryView(
            BoardStages.Merged(lineID: "left", title: "Fix 287", number: 287, mergedAt: now - 3600, cleanUp: .offered), now: now
        )
        let line = BoardStagesLineView(offering("joining", .add, 52), link: .none)
        holder.addSubview(entry)
        holder.addSubview(line)
        entry.frame = NSRect(x: 0, y: 0, width: entry.fittingWidth, height: 18)
        line.frame = NSRect(x: 0, y: 40, width: 940, height: 34)
        for view in [entry, line] as [NSView] { view.layoutSubtreeIfNeeded() }
        // AppKit takes the places a view gives it, as it does once the window shows.
        entry.resetCursorRects()
        line.resetCursorRects()
        XCTAssertEqual([entry.handRects.count, line.handRects.count], [1, 1])
        window.asked = []
        entry.needsLayout = true
        line.needsLayout = true
        for view in [entry, line] as [NSView] { view.layoutSubtreeIfNeeded() }
        XCTAssertTrue(window.asked.isEmpty, "nothing changed: AppKit holds what they would give")
        // The clean-up starts; the list locks: no hand left, where AppKit still holds one.
        entry.show(BoardStages.Merged(lineID: "left", title: "Fix 287", number: 287, mergedAt: now - 3600, cleanUp: .running), now: now)
        line.update(offering("joining", .add, 52, blocked: "The queue is running."), link: .none)
        for view in [entry, line] as [NSView] { view.layoutSubtreeIfNeeded() }
        XCTAssertEqual([entry.handRects.count, line.handRects.count], [0, 0])
        XCTAssertTrue(window.asked.contains { $0 === entry } && window.asked.contains { $0 === line }, "each asks for its places again")
    }

    func testAnEntrysPlacesAndItsHandFollowWhatShows() throws {
        let long = "A fix whose title is far too long for the row it is given on any Board at all, whatever its width"
        let day = { (cleanUp: BoardStages.CleanUp?, title: String) in
            [BoardStages.Merged(lineID: "left", title: title, number: 287, mergedAt: self.now - 3600, cleanUp: cleanUp)]
        }
        // Lines enough for "Merged today" to be below what shows.
        let lines = (1...30).map { BoardStages.Unit.task(self.line("task\($0)"), subtasks: []) }
        let view = board(content([section(units: lines, merged: day(.offered, long))]), width: 500)
        let merged = try XCTUnwrap(view.mergedView(section: "nirux"))
        let entry = try XCTUnwrap(merged.entries.first)
        XCTAssertLessThan(entry.titleLabel.frame.width, ColumnHeaderView.textWidth(entry.titleLabel))
        XCTAssertEqual(entry.hints.count, 2, "its title, cut, and its link")
        XCTAssertEqual(entry.handRects, [], "out of sight: no hand")
        var linked = 0
        view.onLink = { _, _, _ in linked += 1 }
        let onLink = entry.convert(NSPoint(x: entry.linkLabel.frame.midX, y: 9), to: nil)
        entry.mouseDown(with: try mouse(.leftMouseDown, at: onLink, in: view.window))
        entry.mouseUp(with: try mouse(.leftMouseUp, at: onLink, in: view.window))
        XCTAssertEqual(linked, 0, "nor a click")
        view.scrollView.contentView.scroll(to: NSPoint(x: 0, y: merged.frame.maxY - view.scrollView.contentSize.height))
        XCTAssertEqual(entry.handRects.count, 1)
        try click(entry.linkLabel)
        XCTAssertEqual(linked, 1)

        // The clean-up starts: the link's place goes, and the title's covers the whole entry, "cleaning up…" included.
        XCTAssertEqual(entry.trackingAreas.count, 2)
        view.show(content([section(units: lines, merged: day(.running, long))]))
        view.layoutSubtreeIfNeeded()
        XCTAssertTrue(merged.entries.first === entry)
        XCTAssertEqual(entry.hints.map(\.rect), [entry.bounds])
        XCTAssertEqual(entry.toolTipText(at: NSPoint(x: entry.linkLabel.frame.midX, y: 9)), long)
        let title = try XCTUnwrap(entry.trackingAreas.first)
        XCTAssertEqual(entry.trackingAreas.count, 1)
        // Other words in the same place: asked for when shown, the place kept as it was registered.
        view.show(content([section(units: lines, merged: day(.running, long + ", again"))]))
        view.layoutSubtreeIfNeeded()
        XCTAssertTrue(entry.trackingAreas.first === title, "a tooltip being read stays up")
        XCTAssertEqual(entry.toolTipText(at: NSPoint(x: 20, y: 9)), long + ", again")
    }

    func testAnEntryGoneBehindTheButtonOpensNothing() throws {
        let day = (0..<40).map { BoardStages.Merged(lineID: "t\($0)", title: "Fix \($0)", number: 400 + $0, mergedAt: now - 60) }
        let view = board(content([section(units: [], merged: day)]))
        var opened: [String] = []
        view.onOpen = { opened.append($0) }
        let merged = try XCTUnwrap(view.mergedView(section: "nirux"))
        let first = try XCTUnwrap(merged.entries.first)
        let on = try target(at: first).location
        XCTAssertFalse(first.isHidden)
        // Pressed; then the day's other tasks all ask for the user, and come before it: it is behind "+N more" at the release.
        first.mouseDown(with: try mouse(.leftMouseDown, at: on, in: view.window))
        view.show(content([section(units: [], merged: day.enumerated().map { index, entry in
            var entry = entry
            entry.needsYou = index > 0
            return entry
        })]))
        view.layoutSubtreeIfNeeded()
        XCTAssertTrue(merged.entries.last === first && first.isHidden)
        first.mouseUp(with: try mouse(.leftMouseUp, at: on, in: view.window))
        XCTAssertEqual(opened, [], "what no longer shows opens nothing")
        // Shown again where it was, a new press and its release open it.
        view.show(content([section(units: [], merged: day)]))
        view.layoutSubtreeIfNeeded()
        XCTAssertFalse(first.isHidden)
        try click(first)
        XCTAssertEqual(opened, ["t0"])
        // Pressed, then it leaves the list (its task is listed again): the release opens nothing.
        first.mouseDown(with: try mouse(.leftMouseDown, at: on, in: view.window))
        view.show(content([section(units: [], merged: Array(day.dropFirst()))]))
        view.layoutSubtreeIfNeeded()
        XCTAssertNil(first.window)
        first.mouseUp(with: try mouse(.leftMouseUp, at: on, in: view.window))
        XCTAssertEqual(opened, ["t0"])
    }

    func testCleanUpByNameIsAnEntrysWhileItShows() throws {
        let day = (0..<40).map {
            BoardStages.Merged(lineID: "t\($0)", title: "Fix \($0)", number: 400 + $0, mergedAt: now - 60, cleanUp: .offered)
        }
        let view = board(content([section(units: [], merged: day)]))
        var linked: [String] = []
        view.onLink = { _, line, _ in linked.append(line) }
        let merged = try XCTUnwrap(view.mergedView(section: "nirux"))
        let first = try XCTUnwrap(merged.entries.first)
        let action = try XCTUnwrap(first.accessibilityCustomActions()?.first)
        XCTAssertEqual(action.handler?(), true)
        XCTAssertEqual(linked, ["t0"])
        // Gone behind "+N more": VoiceOver does what a click then does, nothing.
        view.show(content([section(units: [], merged: day.enumerated().map { index, entry in
            var entry = entry
            entry.needsYou = index > 0
            return entry
        })]))
        view.layoutSubtreeIfNeeded()
        XCTAssertTrue(merged.entries.last === first && first.isHidden)
        XCTAssertEqual(action.handler?(), false)
        var opened: [String] = []
        view.onOpen = { opened.append($0) }
        XCTAssertFalse(first.accessibilityPerformPress(), "nor does a press open its task")
        // Shown again, then out of the list altogether: nothing either.
        view.show(content([section(units: [], merged: day)]))
        view.layoutSubtreeIfNeeded()
        XCTAssertFalse(first.isHidden)
        view.show(content([section(units: [], merged: Array(day.dropFirst()))]))
        view.layoutSubtreeIfNeeded()
        XCTAssertNil(first.window)
        XCTAssertFalse(first.isHidden)
        XCTAssertEqual(action.handler?(), false)
        XCTAssertFalse(first.accessibilityPerformPress())
        XCTAssertEqual(linked, ["t0"])
        XCTAssertEqual(opened, [])
        XCTAssertTrue(merged.entries[0].accessibilityPerformPress(), "one that shows opens its task")
        XCTAssertEqual(opened, ["t1"])
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
        XCTAssertEqual(wide.stations.map { $0 - wide.rail.minX }, [10, 61, 111, 162], "evenly, on whole points")

        // From where a phrase shows, a point more of Board gives the
        // task's column and the rail a point at most, and takes none back;
        // from where a rail shows, the columns end at the padding.
        var previous = BoardStagesView.Columns(width: 392)
        var jumps: [CGFloat] = []
        var overflows: [CGFloat] = []
        for width in stride(from: CGFloat(306), through: 2000, by: 1) {
            let columns = BoardStagesView.Columns(width: width)
            let steps = [columns.task.width - previous.task.width, columns.rail.width - previous.rail.width]
            if width > 392, steps.contains(where: { $0 < 0 || $0 > 1 }) { jumps.append(width) }
            let last = columns.time ?? columns.pullRequest ?? (columns.phrase.width > 0 ? columns.phrase : columns.rail)
            if last.maxX != width - BoardStagesView.Metrics.padding { overflows.append(width) }
            if width >= 392 { previous = columns }
        }
        XCTAssertEqual(jumps, [], "widths where a title or a rail shrinks, or jumps, as the Board widens")
        XCTAssertEqual(overflows, [], "widths where the columns don't end at the padding")
        XCTAssertEqual(BoardStagesView.Columns(width: 1800).task.width, 280, "a wide Board doesn't push the rails away from the titles")
        XCTAssertEqual(BoardStagesView.Columns(width: 680).rail.width, 148, "two fifths of a point of rail per point of Board, from 600")

        // Each title over its column, each station's over its station.
        let view = board(content([]))
        XCTAssertEqual(view.columnTitles.map(\.stringValue), ["Task", "Now", "Pull request"])
        XCTAssertEqual(view.columnTitles.map(\.frame.minX), [wide.task.minX, wide.phrase.minX, wide.pullRequest?.minX ?? 0])
        XCTAssertEqual(view.columnTitles.map(\.isHidden), [false, false, false])
        for (title, station) in zip(view.stationTitles, wide.stations) {
            XCTAssertEqual(title.frame.midX, station, accuracy: 0.5, title.stringValue)
        }
        // No two titles touch, at any width: the stations', then "Now".
        let crowded = stride(from: CGFloat(306), through: 1000, by: 1).filter { width in
            view.setFrameSize(NSSize(width: width, height: 600))
            let titles = (view.stationTitles + [view.columnTitles[1]]).filter { !$0.isHidden }.map(\.frame)
            return zip(titles, titles.dropFirst()).contains { $0.maxX + 4 > $1.minX }
        }
        XCTAssertEqual(crowded, [], "widths where two titles touch")
    }

    func testTheRailTightensThenTheColumnsGiveWayOnANarrowBoard() {
        let narrow = BoardStagesView.Columns(width: 600)
        XCTAssertEqual([narrow.task.width, narrow.rail.width, narrow.phrase.width], [225, 116, 195],
                       "the rail tightens before the titles are cut")
        XCTAssertNil(narrow.pullRequest)
        XCTAssertNil(narrow.time)
        let stations = narrow.stations
        XCTAssertEqual(stations.first, narrow.rail.minX + 10)
        XCTAssertEqual(stations.last, narrow.rail.maxX - 18, "the last one clear of the next column")
        XCTAssertTrue(zip(stations, stations.dropFirst()).allSatisfy { $1 - $0 >= 29 }, "its stations closer, never touching")

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
        XCTAssertEqual(view.columnTitles.map(\.isHidden), [false, false, true], "no title for a column that isn't there")
        XCTAssertEqual(view.stationTitles.map(\.isHidden), [false, true, true, false], "a tight rail names its two ends")
        XCTAssertEqual(view.stationTitles[0].frame.midX, stations[0], accuracy: 0.5)
        XCTAssertEqual(view.stationTitles[3].frame.midX, stations[3], accuracy: 0.5)
        XCTAssertEqual(board(content([])).stationTitles.map(\.isHidden), [false, false, false, false])
    }

    func testANarrowerBoardKeepsEachLinesDotAndTitle() throws {
        // A phrase of a word says nothing: under 70 pt it goes, and the title takes its place.
        let last = BoardStagesView.Columns(width: 392)
        XCTAssertEqual([last.task.width, last.rail.width, last.phrase.width], [142, 116, 70])
        let without = BoardStagesView.Columns(width: 391)
        XCTAssertEqual([without.task.width, without.rail.width, without.phrase.width], [225, 116, 0])
        // Then the rail, once a title would have less than 140 pt beside it.
        let least = BoardStagesView.Columns(width: 306)
        XCTAssertEqual([least.task.width, least.rail.width, least.phrase.width], [140, 116, 0])
        let tiny = BoardStagesView.Columns(width: 305)
        XCTAssertEqual([tiny.task.width, tiny.rail.width, tiny.phrase.width], [269, 0, 0], "the title takes the line")
        XCTAssertEqual(tiny.stations, [])

        let merged = [BoardStages.Merged(lineID: nil, title: "Fix", number: 7, mergedAt: now - 60)]
        let view = board(content([section(
            units: [.task(line("task"), subtasks: []), .task(line("folder", rail: false), subtasks: [])], merged: merged
        )]), width: 300)
        XCTAssertEqual(view.stationTitles.map(\.isHidden), [true, true, true, true])
        XCTAssertEqual(view.columnTitles.map(\.isHidden), [false, true, true])
        for shown in view.lineViews {
            XCTAssertTrue(shown.phraseLabel.isHidden && shown.noRailLabel.isHidden && shown.pullRequestLabel.isHidden)
            XCTAssertEqual(shown.titleLabel.frame.maxX, 300 - BoardStagesView.Metrics.padding)
        }
        // "Merged today" has no room beside its caption: its entries start under it.
        let closing = try XCTUnwrap(view.mergedView(section: "nirux"))
        let entry = try XCTUnwrap(closing.entries.first)
        XCTAssertEqual(entry.frame.minX, BoardStagesView.Metrics.padding)
        XCTAssertGreaterThanOrEqual(entry.frame.minY, closing.caption.frame.maxY)
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

    /// A line as it paints itself, in its own coordinates: row y is its y.
    private func paint(_ line: BoardStagesLineView) throws -> (CGFloat, CGFloat) -> NSColor? {
        try paint(width: Int(line.bounds.width), height: Int(line.bounds.height)) {
            let flip = NSAffineTransform()
            flip.translateX(by: 0, yBy: line.bounds.height)
            flip.scaleX(by: 1, yBy: -1)
            flip.concat()
            line.draw(line.bounds)
        }
    }

    /// The rail, 180 by 20, its stations on the middle row. (Its
    /// segments, a quarter point off the stations' line, fill row 9.)
    private func paint(
        _ rail: BoardStages.Rail, state: BoardStages.State, hovered: BoardStages.QueueOffer.Change? = nil
    ) throws -> (CGFloat, CGFloat) -> NSColor? {
        try paint(width: 180, height: 20) {
            BoardStagesLineView.draw(rail, state: state, stations: [10, 63, 116, 169], y: 10, hovered: hovered)
        }
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
        var pixel = try paint(sub)
        XCTAssertTrue(isClose(pixel(sub.dotCenter.x, 17), to: Theme.Color.waiting), "its dot in its state's colour")
        XCTAssertTrue(isClose(pixel(station, 17), to: Theme.Color.waiting), "as its current station")

        sub.wantsLayer = true
        let layer = try XCTUnwrap(sub.layer)
        layer.displayIfNeeded()
        XCTAssertFalse(layer.needsDisplay())
        view.show(content([section(units: units(.failed))]))
        XCTAssertTrue(view.lineViews[1] === sub && layer.needsDisplay(), "a change of state paints the line again")
        pixel = try paint(sub)
        XCTAssertTrue(isClose(pixel(sub.dotCenter.x, 17), to: Theme.Color.error))

        // Too narrow for a rail: the dot, and nothing after.
        let tiny = BoardStagesLineView(line("alone"), link: .none)
        tiny.frame = NSRect(x: 0, y: 0, width: 300, height: 34)
        let narrow = try paint(tiny)
        XCTAssertTrue(isClose(narrow(tiny.dotCenter.x, 17), to: Theme.Color.textTertiary))
        XCTAssertTrue((40..<300).allSatisfy { isEmpty(narrow(CGFloat($0), 16)) && isEmpty(narrow(CGFloat($0), 17)) })
    }

    func testWhatJoinsALineToItsOwnIsPaintedOnWholePixels() throws {
        let view = board(content([section(units: [
            .task(line("task"), subtasks: [line("first"), line("last")]),
            .stack(title: "Stack · 2 pull requests on main", [line("one"), line("two")]),
            .task(line("alone"), subtasks: [])
        ])]))
        let painted = try view.lineViews.map { try paint($0) }
        // The connector's column: one whole pixel at 1x, not two halves.
        let x = BoardStagesView.Metrics.connectorX - 1
        let isLine = { (pixel: (CGFloat, CGFloat) -> NSColor?, y: CGFloat) in
            self.isClose(pixel(x, y), to: Theme.Color.textDisabled) && self.isEmpty(pixel(x - 1, y)) && self.isEmpty(pixel(x + 1, y))
        }
        // Above each line's middle, then below it: what comes down to it, what goes on.
        let joined = painted.map { [isLine($0, 2), isLine($0, 31)] }
        XCTAssertEqual(joined, [
            [false, true],  // a task sends a line down to its sub-tasks
            [true, true],   // a sub-task, and the line goes on to the next
            [true, false],  // the last one ends it
            [false, true],  // a stack's first pull request starts its rail
            [true, false],  // its last ends it
            [false, false]  // a task alone has nothing
        ])
        // A sub-task's elbow ends in a whole row; the task's own dot stays at the line's edge.
        XCTAssertTrue(isClose(painted[1](x + 12, 16), to: Theme.Color.textDisabled))
        XCTAssertTrue(isEmpty(painted[1](x + 12, 15)) && isEmpty(painted[1](x + 12, 17)))
        XCTAssertTrue(isEmpty(painted[0](x + 12, 16)) && isEmpty(painted[5](x + 12, 16)), "no elbow on a task")
        // A stack's pull request has its place's number in a ring on the rail.
        XCTAssertTrue(isClose(painted[3](x - 8, 16), to: Theme.Color.textDisabled), "the ring's side")
        XCTAssertTrue(isClose(painted[3](x - 5, 16), to: Theme.Color.canvas), "inside it, the canvas")
        XCTAssertTrue(isEmpty(painted[1](x - 8, 16)), "none on a sub-task")
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
