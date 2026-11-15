import AppKit
import XCTest
@testable import Nirux

/// The glass interface's inbox and the rail's callout
/// (docs/design/glass-interface.md).
@MainActor
final class RequestInboxViewTests: XCTestCase {
    private var clock: TimeInterval = 100

    private func requests(_ ids: [String]) throws -> [WaitingRequest] {
        try ids.map { id in
            RequestCardViewTests.request(.permission(try XCTUnwrap(RequestCardViewTests.approval("npm run \(id)"))), id: id, title: "Task \(id)")
        }
    }

    private func inbox(_ requests: [WaitingRequest]) -> RequestInboxView {
        let inbox = RequestInboxView(level: .opaque, arming: RequestArming(now: { [unowned self] in self.clock }))
        inbox.show(requests)
        inbox.frame = NSRect(x: 0, y: 0, width: RequestInboxView.width, height: inbox.fittingHeight(maximum: 900))
        inbox.layoutSubtreeIfNeeded()
        return inbox
    }

    private func key(_ characters: String) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
            characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: 0
        ))
    }

    /// The requests stand in their order, the first chosen, each once; ↑ ↓
    /// move the choice, which stays on its request as others go; Escape
    /// closes.
    func testTheRequestsStandInOrderAndTheChoiceFollows() throws {
        let inbox = inbox(try requests(["a", "b", "c"]))
        let tops = ["a", "b", "c"].compactMap { inbox.cards[$0]?.frame.minY }
        XCTAssertEqual(tops, tops.sorted())
        XCTAssertEqual(Set(tops).count, 3)
        XCTAssertEqual(inbox.chosenID, "a")
        XCTAssertTrue(inbox.cards["a"]?.isChosen == true)

        inbox.keyDown(with: try key(String(UnicodeScalar(NSDownArrowFunctionKey)!)))
        inbox.keyDown(with: try key(String(UnicodeScalar(NSDownArrowFunctionKey)!)))
        inbox.keyDown(with: try key(String(UnicodeScalar(NSDownArrowFunctionKey)!)))
        XCTAssertEqual(inbox.chosenID, "c", "it stops at the end")
        inbox.keyDown(with: try key(String(UnicodeScalar(NSUpArrowFunctionKey)!)))
        XCTAssertEqual(inbox.chosenRequest?.id, "b")
        inbox.show(try requests(["c", "b"]))
        XCTAssertEqual(inbox.chosenID, "b", "the choice stays on its request")
        inbox.show(try requests(["c"]))
        XCTAssertEqual(inbox.chosenID, "c")
        XCTAssertNil(inbox.cards["a"])
        inbox.show(try requests(["c", "d", "c"]))
        XCTAssertEqual(inbox.requests.map(\.id), ["c", "d"], "a request listed twice shows once")

        var closed = 0
        inbox.onClose = { closed += 1 }
        inbox.keyDown(with: try key("\u{1b}"))
        XCTAssertEqual(closed, 1)
    }

    /// An answer's button that arrived, moved up or slid under a scroll
    /// waits before it takes a click; the answer names its request.
    func testAButtonThatMovedWaitsBeforeItAnswers() throws {
        let inbox = inbox(try requests(["a", "b"]))
        var answered: [(String, RequestChoice)] = []
        inbox.onAnswer = { request, choice, _ in answered.append((request.id, choice)) }
        func allow(_ id: String) throws -> NiruxButton { try XCTUnwrap(inbox.cards[id]?.answerButtons[.permission(.allow)]) }

        try allow("b").performClick(nil)
        XCTAssertTrue(answered.isEmpty, "just arrived")
        clock += SidebarView.approvalArmingDelay
        try allow("b").performClick(nil)
        XCTAssertEqual(answered.map(\.0), ["b"])
        XCTAssertEqual(answered.first?.1, .permission(.allow))

        inbox.show(try requests(["b"]))
        inbox.layoutSubtreeIfNeeded()
        try allow("b").performClick(nil)
        XCTAssertEqual(answered.count, 1, "it moved up under the pointer")
        clock += SidebarView.approvalArmingDelay
        try allow("b").performClick(nil)
        XCTAssertEqual(answered.count, 2)

        let clip = try XCTUnwrap(inbox.cards["b"]?.enclosingScrollView?.contentView)
        NotificationCenter.default.post(name: NSView.boundsDidChangeNotification, object: clip)
        try allow("b").performClick(nil)
        XCTAssertEqual(answered.count, 2, "the list scrolled")
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
        XCTAssertTrue(inbox.cards["a"]?.isAccessibilitySelected() == true)
        inbox.show([])
        XCTAssertEqual(inbox.accessibilityLabel(), "No agent waits for you")
        XCTAssertFalse(inbox.emptyLabel.isHidden)
    }

    /// The callout shows one request with "Open task" and how many more
    /// wait; it answers like the inbox, and Escape closes it.
    func testTheCalloutAnswersOpensAndCloses() throws {
        let request = try requests(["a"])[0]
        let callout = RequestCalloutView(level: .opaque, arming: RequestArming(now: { [unowned self] in self.clock }))
        callout.show(request, othersWaiting: 2)
        callout.frame = NSRect(x: 0, y: 0, width: RequestCalloutView.width, height: callout.fittingHeight)
        callout.layoutSubtreeIfNeeded()
        XCTAssertEqual(callout.moreLabel.stringValue, "2 more · ⌘J")
        XCTAssertFalse(callout.moreLabel.isHidden)
        XCTAssertLessThanOrEqual(callout.moreLabel.frame.maxY, callout.bounds.height - Theme.Space.sm, "inside the callout")

        var opened: [String] = [], answered: [RequestChoice] = [], closed = 0
        callout.onOpenTask = { opened.append($0) }
        callout.onAnswer = { _, choice, _ in answered.append(choice) }
        callout.onClose = { closed += 1 }
        callout.card.openButton.performClick(nil)
        XCTAssertEqual(opened, ["task-a"])
        clock += SidebarView.approvalArmingDelay
        callout.card.answerButtons[.permission(.deny)]?.performClick(nil)
        XCTAssertEqual(answered, [.permission(.deny)])
        callout.keyDown(with: try key("\u{1b}"))
        XCTAssertEqual(closed, 1)

        callout.show(request, othersWaiting: 0)
        XCTAssertTrue(callout.moreLabel.isHidden)
    }
}
