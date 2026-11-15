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

    static func request(_ kind: WaitingRequest.Kind, task: String = "a", title: String? = nil, waited: String = "1m") -> WaitingRequest {
        WaitingRequest(
            taskID: "task-\(task)", columnID: UUID(), taskTitle: title ?? "Task \(task)",
            icon: StateIcon(.needsYou(.command), stage: 1), waited: waited, kind: kind
        )
    }

    private func card(_ kind: WaitingRequest.Kind, trailing: RequestCardView.Trailing = .waited, width: CGFloat = 372) -> RequestCardView {
        let card = RequestCardView(trailing: trailing)
        card.show(Self.request(kind))
        card.frame = NSRect(x: 0, y: 0, width: width, height: card.fittingHeight(width: width))
        card.layoutSubtreeIfNeeded()
        return card
    }

    /// The answers in VoiceOver's order (the views'), which is also left to
    /// right.
    private func answers(_ card: RequestCardView) -> [String] {
        let buttons = card.subviews.compactMap { $0 as? NiruxButton }.filter { card.answerButtons.values.contains($0) }
        XCTAssertEqual(buttons.map(\.frame.minX), buttons.map(\.frame.minX).sorted(), "read left to right")
        return buttons.map(\.title)
    }

    /// Each kind shows the rows' answers in their order, or what stands in
    /// for them and the way to the terminal; VoiceOver names who asks.
    func testEachKindShowsItsAnswers() throws {
        let question = SidebarTurnQuestion(text: "Shall I merge it?", turnEndedAt: 5, isYesNo: true, columnID: UUID())
        let open = SidebarTurnQuestion(text: "Which branch?", turnEndedAt: 5, isYesNo: false, columnID: UUID())
        let mission = SidebarMissionQuestion(questionID: "q", parentTitle: "Lead", text: "Which base?", handOff: .parentClosed)

        let allow = card(.permission(try XCTUnwrap(Self.approval("npm test"))))
        XCTAssertEqual(answers(allow), ["Deny", "Allow"])
        XCTAssertEqual(allow.answerButtons[.permission(.allow)]?.kind, .primary)
        XCTAssertEqual(allow.answerButtons[.permission(.allow)]?.cell?.accessibilityLabel(), "Allow once Bash: npm test")
        XCTAssertEqual(allow.verbLabel.stringValue, "wants to run")
        XCTAssertTrue(allow.terminalButton.isHidden)
        let asks = card(.question(question))
        XCTAssertEqual(answers(asks), ["Dismiss", "Reply…", "No", "Yes"])
        XCTAssertEqual(asks.textLabel.accessibilityLabel(), "Claude asks: Shall I merge it?")
        XCTAssertEqual(answers(card(.question(open))), ["Dismiss", "Reply…"])
        XCTAssertEqual(answers(card(.mission(mission))), ["Reply…"])

        let sending = card(.permission(try XCTUnwrap(Self.approval("npm test", sent: .allow))))
        XCTAssertTrue(sending.answerButtons.isEmpty)
        XCTAssertEqual(sending.noteLabel.stringValue, "Allowing…")
        XCTAssertTrue(sending.terminalButton.isHidden)
        let lost = card(.permission(try XCTUnwrap(Self.approval("npm test", sent: .allow, now: 16))))
        XCTAssertEqual(lost.noteLabel.stringValue, "Not delivered — answer in the terminal")
        XCTAssertFalse(lost.terminalButton.isHidden, "the inbox leads to the terminal")
        let dialog = card(.dialog(question: "Which model?", more: 1))
        XCTAssertTrue(dialog.answerButtons.isEmpty)
        XCTAssertEqual(dialog.noteLabel.stringValue, "1 more question in the terminal")
        XCTAssertFalse(dialog.terminalButton.isHidden)
        XCTAssertTrue(card(.dialog(question: "Which model?", more: 0), trailing: .openTask).terminalButton.isHidden, "the callout has it on top")
        let trust = card(.terminal("Trust this folder?"))
        XCTAssertEqual(trust.noteLabel.stringValue, "Answer in the terminal")
        XCTAssertEqual(trust.textLabel.accessibilityLabel(), "The terminal asks: Trust this folder?")
    }

    /// An answer takes a single click on a button its container armed, and
    /// says which; the buttons stay while the wait ticks; "Open task"
    /// ignores a double-click's second press too.
    func testAnAnswerTakesOneArmedClick() throws {
        let card = card(.permission(try XCTUnwrap(Self.approval("npm test"))))
        var armed = false, answered: [RequestChoice] = []
        card.canAnswer = { _ in armed }
        card.onAnswer = { choice, _ in answered.append(choice) }
        let allow = try XCTUnwrap(card.answerButtons[.permission(.allow)])
        func event(_ type: NSEvent.EventType, _ count: Int) throws -> NSEvent {
            try XCTUnwrap(NSEvent.mouseEvent(
                with: type, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
                context: nil, eventNumber: 0, clickCount: count, pressure: 1
            ))
        }
        XCTAssertEqual(allow.acceptsPress?(try event(.leftMouseDown, 1)), false, "not armed: the press does nothing")
        allow.performClick(nil)
        XCTAssertEqual(answered, [], "nor the release")
        armed = true
        XCTAssertEqual(allow.acceptsPress?(try event(.leftMouseDown, 1)), true)
        XCTAssertEqual(allow.acceptsPress?(try event(.leftMouseDown, 2)), false, "the second press of a double-click does nothing")
        allow.performClick(nil)
        XCTAssertEqual(answered, [.permission(.allow)])

        var later = try XCTUnwrap(card.request)
        later.waited = "2m"
        card.show(later)
        XCTAssertTrue(card.answerButtons[.permission(.allow)] === allow, "the minute ticks, the buttons stay")
        XCTAssertEqual(card.terminalButton.acceptsPress?(try event(.leftMouseDown, 2)), false)
    }

    /// The command shows whole, every character, wrapped to fit its box; a
    /// long question wraps; the header gives way without overlapping.
    func testTheCommandIsWholeAndTheHeaderGivesWay() throws {
        let command = "rm -rf ./build && npm ci && npm run build -- --mode production --out ./dist/apps/web"
        let narrow = card(.permission(try XCTUnwrap(Self.approval(command))), width: 300)
        _ = narrow.fittingHeight(width: 500)
        XCTAssertGreaterThan(narrow.commandLines.count, 1, "measuring wider leaves the box as laid out")
        XCTAssertEqual(narrow.commandLines.joined(), command)
        let characterWidth = ("0" as NSString).size(withAttributes: [.font: SidebarExpandedMetrics.approvalFont]).width
        let widest = CGFloat(narrow.commandLines.map(\.count).max() ?? 0) * characterWidth
        XCTAssertLessThanOrEqual(widest, narrow.commandLabel.frame.width - 4, "no character cut at the edge")
        XCTAssertGreaterThanOrEqual(narrow.box.frame.height, CGFloat(narrow.commandLines.count) * SidebarExpandedMetrics.approvalLineHeight)

        let asks = card(.question(SidebarTurnQuestion(
            text: String(repeating: "Shall I switch the invoices to the receipts' font stack? ", count: 3),
            turnEndedAt: 5, isYesNo: true, columnID: UUID()
        )), width: 300)
        let lineHeight = NSLayoutManager().defaultLineHeight(for: try XCTUnwrap(asks.textLabel.font))
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
