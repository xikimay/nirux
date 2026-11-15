import AppKit
import XCTest
@testable import Nirux

/// The glass interface's inbox and the rail's callout
/// (docs/design/glass-interface.md).
@MainActor
final class RequestInboxViewTests: XCTestCase {
    private var clock: TimeInterval = 100
    private var windows: [NSWindow] = []

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

    private func key(_ characters: String) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
            characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: 0
        ))
    }

    private var down: String { String(UnicodeScalar(NSDownArrowFunctionKey)!) }

    /// The requests stand in their order, the first chosen, each once; ↑ ↓
    /// move the choice, which stays on its request as others go; Escape
    /// closes.
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

        var closed = 0
        inbox.onClose = { closed += 1 }
        inbox.keyDown(with: try key("\u{1b}"))
        XCTAssertEqual(closed, 1)
    }

    /// The choice comes into view; a refresh that keeps it scrolls nothing;
    /// the cards fit the clip, beside a legacy scroller too.
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
        var later = try requests(names)
        later[0].waited = "2m"
        inbox.show(later)
        inbox.layoutSubtreeIfNeeded()
        XCTAssertEqual(clip.bounds.origin.y, 0, "the wait ticked: no jump back to the choice")
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

        inbox.show(try requests(["a", "b", "c"]))
        inbox.layoutSubtreeIfNeeded()
        try allow("b").performClick(nil)
        XCTAssertEqual(answered.count, 2, "a request arriving below leaves it armed")

        inbox.show(try requests(["b", "c"]))
        inbox.layoutSubtreeIfNeeded()
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
        windows.append(window)
        window.contentView = inbox
        inbox.layoutSubtreeIfNeeded()
        try allow("b").performClick(nil)
        XCTAssertEqual(answered.count, 3, "the inbox just opened")
        clock += delay

        let replacing = try requests(["e"], task: "b")
        inbox.show(replacing + (try requests(["c"])))
        inbox.layoutSubtreeIfNeeded()
        XCTAssertNil(inbox.cards[id("b")])
        try allow("e").performClick(nil)
        XCTAssertEqual(answered.count, 3, "another request in b's place: its own card, unarmed")
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
        XCTAssertEqual(closed, 1)
    }
}
