import AppKit
import XCTest
@testable import Nirux

/// The glass interface's inbox and the rail's callout
/// (docs/design/glass-interface.md).
@MainActor
final class RequestInboxViewTests: XCTestCase {
    private var clock: TimeInterval = 100

    /// A permission for each name, on its own task unless `task` says.
    private func requests(_ names: [String], task: String? = nil) throws -> [WaitingRequest] {
        try names.map { name in
            RequestCardViewTests.request(
                .permission(try XCTUnwrap(RequestCardViewTests.approval("npm run \(name)"))), task: task ?? name
            )
        }
    }

    private func id(_ name: String) -> String { "permission r-npm run \(name)" }

    private func inbox(_ requests: [WaitingRequest], maximum: CGFloat = 900) -> RequestInboxView {
        let inbox = RequestInboxView(level: .opaque, now: { [weak self] in self?.clock ?? 0 })
        inbox.show(requests)
        inbox.frame = NSRect(x: 0, y: 0, width: RequestInboxView.width, height: inbox.fittingHeight(maximum: maximum))
        inbox.layoutSubtreeIfNeeded()
        return inbox
    }

    /// `requests` shown, the inbox sized to them as its host sizes it.
    private func show(_ requests: [WaitingRequest], in inbox: RequestInboxView, maximum: CGFloat = 900) {
        inbox.show(requests)
        inbox.frame.size.height = inbox.fittingHeight(maximum: maximum)
        inbox.layoutSubtreeIfNeeded()
    }

    private func key(_ characters: String, _ type: NSEvent.EventType = .keyDown) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(
            with: type, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
            characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: 0
        ))
    }

    private var down: String { String(UnicodeScalar(NSDownArrowFunctionKey)!) }

    /// The requests stand in their order, the first chosen, each once; ↑ ↓
    /// move the choice, which stays on its request as others go, or falls
    /// to the one in its place; opening chooses the oldest; Escape closes.
    func testTheRequestsStandInOrderAndTheChoiceFollows() throws {
        let inbox = inbox(try requests(["a", "b", "c"]))
        let tops = ["a", "b", "c"].compactMap { inbox.cards[id($0)]?.frame.minY }
        XCTAssertEqual(tops, tops.sorted())
        XCTAssertEqual(Set(tops).count, 3)
        XCTAssertEqual(inbox.chosenID, id("a"))
        XCTAssertTrue(inbox.cards[id("a")]?.isChosen == true)

        for _ in 0..<3 { inbox.keyDown(with: try key(down)) }
        XCTAssertEqual(inbox.chosenID, id("c"), "it stops at the end")
        inbox.keyDown(with: try key(String(UnicodeScalar(NSUpArrowFunctionKey)!)))
        XCTAssertEqual(inbox.chosenRequest?.taskID, "task-b")
        inbox.show(try requests(["c", "b"]))
        XCTAssertEqual(inbox.chosenID, id("b"), "the choice stays on its request")
        inbox.show(try requests(["c"]))
        XCTAssertEqual(inbox.chosenID, id("c"))
        XCTAssertNil(inbox.cards[id("a")])
        inbox.show(try requests(["c", "d", "c"]))
        XCTAssertEqual(inbox.requests.map(\.taskID), ["task-c", "task-d"], "a request listed twice shows once")
        inbox.show(try requests(["c", "d", "e"]))
        inbox.choose(id("d"))
        inbox.show(try requests(["c", "e"]))
        XCTAssertEqual(inbox.chosenID, id("e"), "answered elsewhere: the next one still listed")
        inbox.show(try requests(["a", "b", "c", "d"]))
        inbox.choose(id("b"))
        inbox.show(try requests(["c", "d"]))
        XCTAssertEqual(inbox.chosenID, id("c"), "a and b answered elsewhere: c, the next one after b")
        inbox.choose(id("d"))
        inbox.show(try requests(["c"]))
        XCTAssertEqual(inbox.chosenID, id("c"), "nothing after it: the nearest before")
        inbox.opened()
        XCTAssertEqual(inbox.chosenID, id("c"), "the inbox opens on the oldest")
        inbox.show(try requests(["f"]))
        XCTAssertEqual(inbox.chosenID, id("f"), "none of them left: the first")

        var closed = 0
        inbox.onClose = { closed += 1 }
        inbox.keyDown(with: try key("\u{1b}"))
        XCTAssertEqual(closed, 0, "not while Escape is held: its repeats would reach a terminal")
        inbox.keyUp(with: try key("\u{1b}", .keyUp))
        XCTAssertEqual(closed, 1, "on its release")
    }

    /// The choice comes into view; a refresh, even one that takes the chosen
    /// request away, scrolls nothing; the cards fit the clip, beside a
    /// legacy scroller too.
    func testTheChoiceComesIntoViewAndARefreshStaysPut() throws {
        let names = (0..<12).map { "task\($0)" }
        let inbox = inbox(try requests(names), maximum: 320)
        let clip = try XCTUnwrap(inbox.cards[id("task0")]?.enclosingScrollView?.contentView)
        for _ in 0..<11 { inbox.keyDown(with: try key(down)) }
        inbox.layoutSubtreeIfNeeded()
        let last = try XCTUnwrap(inbox.cards[id("task11")])
        XCTAssertTrue(clip.documentVisibleRect.contains(last.frame), "the chosen request is in view")
        XCTAssertLessThanOrEqual(last.frame.maxX, clip.frame.width, "inside the clip")
        let scroll = try XCTUnwrap(last.enclosingScrollView)
        scroll.scrollerStyle = .legacy
        inbox.needsLayout = true
        inbox.layoutSubtreeIfNeeded()
        scroll.tile()
        XCTAssertLessThan(clip.frame.width, scroll.frame.width, "a legacy scroller takes its place")
        XCTAssertLessThanOrEqual(last.frame.maxX, clip.frame.width, "the cards leave it room")

        clip.scroll(to: .zero)
        let list = try XCTUnwrap(last.superview)
        let views = list.subviews
        var later = try requests(names)
        later[0].waited = "2m"
        inbox.show(later)
        inbox.layoutSubtreeIfNeeded()
        XCTAssertEqual(clip.bounds.origin.y, 0, "the wait ticked: no jump back to the choice")
        XCTAssertTrue(zip(list.subviews, views).allSatisfy { $0 === $1 } && list.subviews.count == views.count,
                      "nor a card or a line rebuilt or moved")
        func lines() -> [NSView] { list.subviews.filter { !($0 is RequestCardView) } }
        let before = lines()
        later[3] = try requests(["other"])[0]
        inbox.show(later)
        XCTAssertTrue(zip(lines(), before).allSatisfy { $0 === $1 } && lines().count == before.count,
                      "one request in another's place: the lines stay")
        clip.scroll(to: NSPoint(x: 0, y: 200))
        later.removeLast()
        inbox.show(later)
        inbox.layoutSubtreeIfNeeded()
        XCTAssertEqual(inbox.chosenID, id("task10"))
        XCTAssertEqual(clip.bounds.origin.y, 200, "the chosen request went: the list stays where it is")
    }

    /// An answer's button that arrived, moved up, slid under a scroll, or
    /// opened with the inbox waits before it takes a click; one that stayed
    /// put keeps its arming; a request that takes another's place in the
    /// same task gets a card of its own; the answer names its request.
    func testAButtonThatMovedWaitsBeforeItAnswers() throws {
        let inbox = inbox(try requests(["a", "b"]))
        var answered: [(String, RequestChoice)] = []
        inbox.onAnswer = { request, choice, _ in answered.append((request.id, choice)) }
        func allow(_ name: String) throws -> NiruxButton { try XCTUnwrap(inbox.cards[id(name)]?.answerButtons[.permission(.allow)]) }
        let delay = SidebarView.approvalArmingDelay

        try allow("b").performClick(nil)
        XCTAssertTrue(answered.isEmpty, "just arrived")
        clock += delay
        try allow("b").performClick(nil)
        XCTAssertEqual(answered.map(\.0), [id("b")])
        XCTAssertEqual(answered.first?.1, .permission(.allow))

        show(try requests(["a", "b", "c"]), in: inbox)
        try allow("b").performClick(nil)
        XCTAssertEqual(answered.count, 2, "a request arriving below leaves it armed")

        show(try requests(["b", "c"]), in: inbox)
        try allow("b").performClick(nil)
        XCTAssertEqual(answered.count, 2, "it moved up under the pointer")
        clock += delay
        try allow("b").performClick(nil)
        XCTAssertEqual(answered.count, 3)

        let clip = try XCTUnwrap(inbox.cards[id("b")]?.enclosingScrollView?.contentView)
        NotificationCenter.default.post(name: NSView.boundsDidChangeNotification, object: clip)
        try allow("b").performClick(nil)
        XCTAssertEqual(answered.count, 3, "the list scrolled")
        clock += delay

        let window = NSWindow(contentRect: inbox.frame, styleMask: .borderless, backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        inbox.choose(id("c"))
        window.contentView = inbox
        inbox.layoutSubtreeIfNeeded()
        try allow("b").performClick(nil)
        XCTAssertEqual(answered.count, 3, "the inbox just moved into its window")
        XCTAssertEqual(inbox.chosenID, id("c"), "moving it keeps the choice")
        clock += delay
        inbox.opened()
        try allow("b").performClick(nil)
        XCTAssertEqual(answered.count, 3, "the inbox just opened")
        clock += delay

        clock += delay
        window.setFrameOrigin(NSPoint(x: 300, y: 200))
        NotificationCenter.default.post(name: NSWindow.didMoveNotification, object: window)
        inbox.layoutSubtreeIfNeeded()
        try allow("b").performClick(nil)
        XCTAssertEqual(answered.count, 3, "its window moved")
        clock += delay
        let resting = inbox.frame
        inbox.frame = NSRect(x: resting.minX, y: resting.minY - 50, width: resting.width, height: resting.height + 50)
        inbox.layoutSubtreeIfNeeded()
        try allow("b").performClick(nil)
        XCTAssertEqual(answered.count, 4, "grown from its top: nothing slid on screen, nothing waits")
        inbox.setFrameOrigin(NSPoint(x: 40, y: inbox.frame.minY))
        inbox.layoutSubtreeIfNeeded()
        try allow("b").performClick(nil)
        XCTAssertEqual(answered.count, 4, "it moved in its window")
        clock += delay

        let replacing = try requests(["e"], task: "b")
        show(replacing + (try requests(["c"])), in: inbox)
        XCTAssertNil(inbox.cards[id("b")])
        try allow("e").performClick(nil)
        XCTAssertEqual(answered.count, 4, "another request in b's place: its own card, unarmed")
    }

    /// VoiceOver hears how many wait, then each request: its task, what it
    /// wants, how long it has waited.
    func testVoiceOverHearsEachRequest() throws {
        let inbox = inbox(try requests(["a", "b"]))
        XCTAssertEqual(inbox.accessibilityLabel(), "2 requests waiting for you")
        func groups(_ element: Any) -> [String] {
            guard let view = element as? NSView else { return [] }
            if view is RequestCardView { return [view.accessibilityLabel() ?? "?"] }
            return NSAccessibility.unignoredChildren(from: view.accessibilityChildren() ?? []).flatMap(groups)
        }
        XCTAssertEqual(groups(inbox), ["Task a, wants to run, waiting 1m", "Task b, wants to run, waiting 1m"])
        XCTAssertTrue(inbox.cards[id("a")]?.isAccessibilitySelected() == true)
        inbox.show([])
        XCTAssertEqual(inbox.accessibilityLabel(), "No agent waits for you")
        XCTAssertFalse(inbox.emptyLabel.isHidden)
    }

    /// The callout shows one request with "Open task" and how many more
    /// wait; it arms like the inbox (the "more" line coming and going moves
    /// nothing), and Escape closes it.
    func testTheCalloutAnswersOpensAndCloses() throws {
        let request = try requests(["a"])[0]
        let callout = RequestCalloutView(level: .opaque, now: { [weak self] in self?.clock ?? 0 })
        func show(more: Int) {
            callout.show(request, othersWaiting: more)
            callout.frame = NSRect(x: 0, y: 0, width: RequestCalloutView.width, height: callout.fittingHeight)
            callout.layoutSubtreeIfNeeded()
        }
        show(more: 2)
        XCTAssertEqual(callout.moreLabel.stringValue, "2 more · ⌘J")
        XCTAssertFalse(callout.moreLabel.isHidden)
        XCTAssertLessThanOrEqual(callout.moreLabel.frame.maxY, callout.bounds.height - Theme.Space.sm, "inside the callout")

        var opened: [String] = [], answered: [RequestChoice] = [], closed = 0
        callout.onOpenTask = { opened.append($0) }
        callout.onAnswer = { _, choice, _ in answered.append(choice) }
        callout.onClose = { closed += 1 }
        callout.card.openButton.performClick(nil)
        XCTAssertEqual(opened, ["task-a"])
        let deny = try XCTUnwrap(callout.card.answerButtons[.permission(.deny)])
        deny.performClick(nil)
        XCTAssertEqual(answered, [], "just shown")
        clock += SidebarView.approvalArmingDelay
        show(more: 0)
        XCTAssertTrue(callout.moreLabel.isHidden)
        deny.performClick(nil)
        XCTAssertEqual(answered, [.permission(.deny)], "the line below went: the buttons didn't move")
        callout.keyDown(with: try key("\u{1b}"))
        XCTAssertEqual(closed, 0, "not while Escape is held")
        callout.keyUp(with: try key("\u{1b}", .keyUp))
        XCTAssertEqual(closed, 1)
        XCTAssertEqual(callout.card.openButton.acceptsPress?(try XCTUnwrap(NSEvent.mouseEvent(
            with: .leftMouseDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
            context: nil, eventNumber: 0, clickCount: 2, pressure: 1
        ))), false, "a double-click's second press doesn't open the task")

        clock += SidebarView.approvalArmingDelay
        let window = NSWindow(contentRect: callout.frame, styleMask: .borderless, backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = callout
        deny.performClick(nil)
        XCTAssertEqual(answered.count, 1, "the callout just opened beside its icon")
        clock += SidebarView.approvalArmingDelay
        callout.setFrameOrigin(NSPoint(x: 0, y: 30))
        callout.layoutSubtreeIfNeeded()
        deny.performClick(nil)
        XCTAssertEqual(answered.count, 1, "it followed its icon")
        clock += SidebarView.approvalArmingDelay

        // Held on a's Deny while the host shows b, the same buttons, and
        // released once they armed: b isn't answered.
        let event = try XCTUnwrap(NSEvent.mouseEvent(
            with: .leftMouseDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
            context: nil, eventNumber: 0, clickCount: 1, pressure: 1
        ))
        XCTAssertEqual(deny.acceptsPress?(event), true)
        let other = RequestCardViewTests.request(.permission(try XCTUnwrap(RequestCardViewTests.approval("npm run a", id: "b"))), task: "b")
        callout.show(other, othersWaiting: 0)
        callout.layoutSubtreeIfNeeded()
        clock += SidebarView.approvalArmingDelay
        deny.performClick(nil)
        XCTAssertEqual(answered.count, 1, "the press was on a")
    }
}
