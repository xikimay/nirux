import AppKit
import XCTest
@testable import Nirux

/// One request in the glass interface's inbox and callout
/// (docs/design/glass-interface.md).
@MainActor
final class RequestCardViewTests: XCTestCase {
    static func approval(_ text: String, sent: PermissionApproval.Behavior? = nil, now: TimeInterval = 11) -> SidebarPermissionApproval? {
        var request = AgentPermissionRequest(toolName: "Bash", summary: text, key: "k", agentID: nil, sessionID: "s", requestedAt: 0)
        var ticket = PermissionApprovalTicket(requestID: "r-\(text)", deadline: 100, text: text)
        ticket.sent = sent
        ticket.sentAt = sent.map { _ in 10 }
        request.approval = ticket
        return SidebarPermissionApproval(request, now: now)
    }

    static func request(_ kind: WaitingRequest.Kind, id: String = "a", title: String = "Add CSV export") -> WaitingRequest {
        WaitingRequest(id: id, taskID: "task-\(id)", taskTitle: title, icon: StateIcon(.needsYou(.command), stage: 1), waited: "1m", kind: kind)
    }

    private func card(_ kind: WaitingRequest.Kind, trailing: RequestCardView.Trailing = .waited, width: CGFloat = 372) -> RequestCardView {
        let card = RequestCardView(trailing: trailing)
        card.show(Self.request(kind))
        card.frame = NSRect(x: 0, y: 0, width: width, height: card.fittingHeight(width: width))
        card.layoutSubtreeIfNeeded()
        return card
    }

    private func answers(_ card: RequestCardView) -> [String] {
        card.subviews.compactMap { $0 as? NiruxButton }
            .filter { !$0.isHidden && card.answerButtons.values.contains($0) }
            .sorted { $0.frame.minX < $1.frame.minX }
            .map(\.title)
    }

    /// Each kind shows the rows' answers in their order, or what stands in
    /// for them: the decision on its way, where to answer.
    func testEachKindShowsItsAnswers() throws {
        let question = SidebarTurnQuestion(text: "Shall I merge it?", turnEndedAt: 5, isYesNo: true, columnID: UUID())
        let open = SidebarTurnQuestion(text: "Which branch?", turnEndedAt: 5, isYesNo: false, columnID: UUID())
        let mission = SidebarMissionQuestion(questionID: "q", parentTitle: "Lead", text: "Which base?", handOff: .parentClosed)
        let permission = try XCTUnwrap(Self.approval("npm test"))

        let allow = card(.permission(permission))
        XCTAssertEqual(answers(allow), ["Deny", "Allow"])
        XCTAssertEqual(allow.answerButtons[.permission(.allow)]?.kind, .primary)
        XCTAssertEqual(allow.answerButtons[.permission(.allow)]?.cell?.accessibilityLabel(), "Allow once Bash: npm test")
        XCTAssertEqual(allow.verbLabel.stringValue, "wants to run")
        XCTAssertEqual(answers(card(.question(question))), ["Dismiss", "Reply…", "No", "Yes"])
        XCTAssertEqual(answers(card(.question(open))), ["Dismiss", "Reply…"])
        XCTAssertEqual(answers(card(.mission(mission))), ["Reply…"])

        let sending = card(.permission(try XCTUnwrap(Self.approval("npm test", sent: .allow))))
        XCTAssertTrue(sending.answerButtons.isEmpty)
        XCTAssertEqual(sending.noteLabel.stringValue, "Allowing…")
        let dialog = card(.dialog(question: "Which model?", more: 1))
        XCTAssertTrue(dialog.answerButtons.isEmpty)
        XCTAssertEqual(dialog.noteLabel.stringValue, "1 more question in the terminal")
        XCTAssertFalse(dialog.terminalButton.isHidden, "the inbox leads to the terminal")
        XCTAssertTrue(card(.dialog(question: "Which model?", more: 0), trailing: .openTask).terminalButton.isHidden, "the callout has it on top")
        XCTAssertEqual(card(.terminal("Trust this folder?")).noteLabel.stringValue, "Answer in the terminal")
    }

    /// An answer takes a single click on a button its container armed, and
    /// says which answer it was.
    func testAnAnswerTakesOneArmedClick() throws {
        let card = card(.permission(try XCTUnwrap(Self.approval("npm test"))))
        var armed = false, answered: [RequestChoice] = []
        card.canAnswer = { _ in armed }
        card.onAnswer = { choice, _ in answered.append(choice) }
        let allow = try XCTUnwrap(card.answerButtons[.permission(.allow)])
        func press(_ count: Int) throws -> Bool {
            let event = try XCTUnwrap(NSEvent.mouseEvent(
                with: .leftMouseDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
                context: nil, eventNumber: 0, clickCount: count, pressure: 1
            ))
            return allow.acceptsPress?(event) ?? true
        }
        XCTAssertFalse(try press(1), "not armed yet")
        allow.performClick(nil)
        XCTAssertEqual(answered, [], "nor on its release")
        armed = true
        XCTAssertTrue(try press(1))
        XCTAssertFalse(try press(2), "the second press of a double-click does nothing")
        allow.performClick(nil)
        XCTAssertEqual(answered, [.permission(.allow)])
    }

    /// The command shows whole, every character, wrapped at the box's
    /// width; a long question wraps; the header gives way without
    /// overlapping.
    func testTheCommandIsWholeAndTheHeaderGivesWay() throws {
        let command = "rm -rf ./build && npm ci && npm run build -- --mode production --out ./dist/apps/web"
        let narrow = card(.permission(try XCTUnwrap(Self.approval(command))), width: 300)
        XCTAssertGreaterThan(narrow.commandLines.count, 1)
        XCTAssertEqual(narrow.commandLines.joined(), command)
        XCTAssertGreaterThanOrEqual(narrow.box.frame.height, CGFloat(narrow.commandLines.count) * SidebarExpandedMetrics.approvalLineHeight)

        let asks = card(.question(SidebarTurnQuestion(
            text: String(repeating: "Shall I switch the invoices to the receipts' font stack? ", count: 3),
            turnEndedAt: 5, isYesNo: true, columnID: UUID()
        )), width: 300)
        let lineHeight = ceil(try XCTUnwrap(asks.textLabel.font).boundingRectForFont.height)
        XCTAssertGreaterThan(asks.textLabel.frame.height, 2 * lineHeight, "a long question wraps")

        let long = RequestCardView(trailing: .waited)
        long.show(Self.request(.terminal("Trust this folder?"), title: String(repeating: "Checkout rounding ", count: 6)))
        long.frame = NSRect(x: 0, y: 0, width: 300, height: long.fittingHeight(width: 300))
        long.layoutSubtreeIfNeeded()
        XCTAssertLessThanOrEqual(long.titleLabel.frame.maxX, long.verbLabel.frame.minX)
        XCTAssertLessThanOrEqual(long.verbLabel.frame.maxX, long.waitedLabel.frame.minX)
        XCTAssertGreaterThan(long.verbLabel.frame.width, 0, "the verb stays")
        XCTAssertLessThanOrEqual(long.waitedLabel.frame.maxX, 300 - RequestCardView.padding)
    }
}
