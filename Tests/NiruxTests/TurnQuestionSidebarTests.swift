import AppKit
import XCTest
@testable import Nirux

/// The question a Claude turn ended on, on its card: the choices the
/// message lists, the question whole, then on their own line Reply…, Yes /
/// No when a plain yes or no answers it, and Dismiss; the click that
/// answers.
@MainActor
final class TurnQuestionSidebarTests: XCTestCase {
    private func column(_ question: SidebarTurnQuestion?) -> ColumnInfo {
        ColumnInfo(
            index: 1, processName: "claude", abbreviatedCwd: "~/p", isFocused: false, isWebView: false,
            webTitle: nil, terminalTitle: nil, agentStatus: .needsAttention, isEditor: false, editorFileName: nil,
            attentionReason: question.map { .askedInReply($0.text) }, turnQuestion: question
        )
    }

    private func workspace(_ columns: [ColumnInfo]) -> WorkspaceInfo {
        WorkspaceInfo(
            id: "ws", index: 2, title: "fix-login", profileID: WorkspaceProfile.defaultID, isInactive: false,
            columnCount: columns.count, focusedColumn: 0, gitBranch: nil, notification: nil, isActive: false,
            columns: columns, prInfo: nil, diffStats: nil, purpose: nil, nextStep: nil, blocker: nil,
            phase: .active, lastSummary: nil, lastActivityAt: nil
        )
    }

    private let columnID = UUID()
    private var yesNo: SidebarTurnQuestion {
        SidebarTurnQuestion(text: "Shall I merge it?", turnEndedAt: 1_005, isYesNo: true, columnID: columnID)
    }
    private var open: SidebarTurnQuestion {
        SidebarTurnQuestion(text: "Which branch should this go on?", turnEndedAt: 1_005, isYesNo: false, columnID: columnID)
    }

    private func answers(_ hitAreas: [SidebarHitArea]) -> [SidebarTurnAnswer] {
        hitAreas.compactMap {
            if case let .turnAnswer(2, 1, question, answer) = $0.region, question.turnEndedAt == 1_005 { return answer }
            return nil
        }
    }

    private func render(_ card: WorkspaceInfo) -> SidebarWorkspaceCardRenderResult {
        SidebarWorkspaceCardRenderer(workspace: card, sidebarWidth: 260, yOffset: 800).render()
    }

    private func labels(_ result: SidebarWorkspaceCardRenderResult) -> [NSTextField] {
        result.views.compactMap { $0 as? NSTextField }
    }

    private func frame(of answer: SidebarTurnAnswer, in result: SidebarWorkspaceCardRenderResult) -> NSRect? {
        result.hitAreas.first {
            if case .turnAnswer(_, _, _, answer) = $0.region { return true }
            return false
        }?.frame
    }

    func testCardOffersYesAndNoOnlyForAYesNoQuestion() throws {
        let card = workspace([column(yesNo)])
        XCTAssertEqual(card.cardActions, [.turnQuestion(columnIndex: 1, yesNo)])
        let result = render(card)
        XCTAssertEqual(Set(answers(result.hitAreas)), [.yes, .no, .reply, .dismiss])
        XCTAssertEqual(result.approvalButtons.count, 4, "they arm like Allow / Deny")
        // The line names it, the block has it: said once. Where no block
        // follows (the catch-up card), the row still says the question.
        XCTAssertEqual(labels(result).filter { $0.stringValue.contains("Shall I merge it?") }.map(\.stringValue), ["Shall I merge it?"])
        XCTAssertTrue(labels(result).contains { $0.stringValue == "Needs you · a question" })
        XCTAssertEqual(card.rowSummary.status.text, "Needs you · Shall I merge it?")
        XCTAssertEqual(
            800 - result.bottomY, SidebarExpandedMetrics.workspaceHeight(for: card, sidebarWidth: 260), accuracy: 0.5,
            "layout matches the metrics the scroll view is sized with"
        )
        // Dismiss, quiet at the left of the buttons' line.
        let dismiss = try XCTUnwrap(frame(of: .dismiss, in: result))
        let reply = try XCTUnwrap(frame(of: .reply, in: result))
        XCTAssertEqual(dismiss.midY, reply.midY)
        XCTAssertLessThanOrEqual(dismiss.maxX, reply.minX)

        let openResult = render(workspace([column(open)]))
        XCTAssertEqual(Set(answers(openResult.hitAreas)), [.reply, .dismiss])
        XCTAssertEqual(workspace([column(nil)]).cardActions, [])
    }

    /// A long question is read whole: it wraps on lines of its own, over
    /// the buttons, and its card is as tall as its lines.
    func testQuestionWrapsWholeAboveItsButtons() throws {
        let text = "Do you want me to merge the pull request now and deploy the billing service to staging before the freeze on Friday?"
        let long = SidebarTurnQuestion(text: text, turnEndedAt: 1_005, isYesNo: true, columnID: columnID)
        let card = workspace([column(long)])
        let result = render(card)
        let asked = try XCTUnwrap(labels(result).first { $0.stringValue == text })
        let lines = asked.frame.height / SidebarExpandedMetrics.questionLineHeight
        XCTAssertGreaterThan(lines, 2, "more than the buttons' line ever held")
        XCTAssertEqual(asked.frame.width, 260 - (SidebarExpandedMetrics.workspaceInsetX + SidebarExpandedMetrics.cardPaddingX) * 2)
        for answer in [SidebarTurnAnswer.yes, .no, .reply, .dismiss] {
            XCTAssertLessThanOrEqual(try XCTUnwrap(frame(of: answer, in: result)).maxY, asked.frame.minY + 3, "\(answer) under it")
        }
        // A click on the question is the row's, as on any of its lines;
        // between the buttons it does nothing.
        func region(at point: NSPoint) -> SidebarHitRegion? { result.hitAreas.first { $0.frame.contains(point) }?.region }
        guard case .workspace(2)? = region(at: NSPoint(x: asked.frame.midX, y: asked.frame.midY)) else {
            return XCTFail("the question's lines select the row")
        }
        let dismiss = try XCTUnwrap(frame(of: .dismiss, in: result))
        let reply = try XCTUnwrap(frame(of: .reply, in: result))
        guard case .actionBlock? = region(at: NSPoint(x: (dismiss.maxX + reply.minX) / 2, y: reply.midY)) else {
            return XCTFail("inert between the buttons")
        }
        XCTAssertEqual(800 - result.bottomY, SidebarExpandedMetrics.workspaceHeight(for: card, sidebarWidth: 260), accuracy: 0.5)
        XCTAssertEqual(
            SidebarExpandedMetrics.workspaceHeight(for: card, sidebarWidth: 260)
                - SidebarExpandedMetrics.workspaceHeight(for: workspace([column(yesNo)]), sidebarWidth: 260),
            (lines - 1) * SidebarExpandedMetrics.questionLineHeight, accuracy: 0.5, "taller by its lines alone"
        )
    }

    /// The choices the message lists come first, in its order, under
    /// their own markers; then the question.
    func testChoicesComeAboveTheQuestion() throws {
        let which = SidebarTurnQuestion(
            text: "Which **one** of the two?", turnEndedAt: 1_005, isYesNo: false, columnID: columnID,
            choices: [
                TurnEndChoice(marker: "1.", text: "Give every test its own temporary database, which is slower on CI"),
                TurnEndChoice(marker: nil, text: "**Keep** the `shared` one"),
            ]
        )
        let card = workspace([column(which)])
        let result = render(card)
        let first = try XCTUnwrap(labels(result).first { $0.stringValue == "1.\t\(which.choices[0].text)" })
        let second = try XCTUnwrap(
            labels(result).first { $0.stringValue == "•\tKeep the shared one" }, "bold and code marks are no words"
        )
        let asked = try XCTUnwrap(labels(result).first { $0.stringValue == "Which one of the two?" })
        XCTAssertEqual(asked.toolTip, which.text, "as the agent wrote it")
        XCTAssertGreaterThan(first.frame.height, SidebarExpandedMetrics.questionLineHeight, "a choice wraps too")
        XCTAssertGreaterThanOrEqual(first.frame.minY, second.frame.maxY)
        XCTAssertGreaterThanOrEqual(second.frame.minY, asked.frame.maxY)
        let reply = try XCTUnwrap(frame(of: .reply, in: result))
        XCTAssertLessThanOrEqual(reply.maxY, asked.frame.minY + 3, "the buttons under them all")
        XCTAssertGreaterThanOrEqual(reply.minY, result.bottomY, "inside its card")
        XCTAssertEqual(800 - result.bottomY, SidebarExpandedMetrics.workspaceHeight(for: card, sidebarWidth: 260), accuracy: 0.5)
        XCTAssertNotEqual(column(which), column(open), "choices redraw the card")
        // One indent for a list, past its widest marker.
        XCTAssertEqual(SidebarQuestionText.choices(which.choices).indent, SidebarExpandedMetrics.choiceIndent)
        let wide = SidebarQuestionText.choices([TurnEndChoice(marker: "(10)", text: "Ship"), TurnEndChoice(marker: "(11)", text: "Wait")])
        XCTAssertGreaterThan(wide.indent, SidebarExpandedMetrics.choiceIndent)
    }

    /// When the status line says something else first (another column's
    /// dialog), the question comes whole all the same.
    func testQuestionComesWithItsButtonsUnderAnotherStatus() {
        let permission = ColumnInfo(
            index: 0, processName: "claude", abbreviatedCwd: "~/p", isFocused: false, isWebView: false,
            webTitle: nil, terminalTitle: nil, agentStatus: .needsAttention, isEditor: false, editorFileName: nil,
            attentionReason: .permission(tool: "Bash", summary: "npm run migrate")
        )
        let card = workspace([permission, column(yesNo)])
        XCTAssertEqual(card.cardActions, [.turnQuestion(columnIndex: 1, yesNo)])
        let shown = labels(render(card)).map(\.stringValue)
        XCTAssertTrue(shown.contains("Shall I merge it?"))
        XCTAssertTrue(shown.contains("Needs you · Bash: npm run migrate"), "the line keeps its own sentence")
    }

    /// A question dialog on its row: each of its questions whole over its
    /// options, numbered as the terminal numbers them, then where to
    /// answer. Nothing to press: a click on it leads to the dialog.
    func testDialogShowsEveryQuestionAndOption() throws {
        let dialog = AgentDialog(questions: [
            .init(text: "Which database should the import job write to while the migration runs?", options: [
                .init(label: "Staging replica (Recommended)", detail: "Safe to wipe; refreshed from production every night"),
                .init(label: "Local **Postgres**", detail: nil),
            ]),
            .init(text: "And when?", options: [.init(label: "Now", detail: nil), .init(label: "Tonight", detail: "after the backup")]),
        ])
        var asking = ColumnInfo(
            index: 1, processName: "claude", abbreviatedCwd: "~/p", isFocused: false, isWebView: false,
            webTitle: nil, terminalTitle: nil, agentStatus: .needsAttention, isEditor: false, editorFileName: nil,
            attentionReason: .question("Which database should the import job write to…"),
            openDialog: .question("Which database should the import job write to…")
        )
        XCTAssertEqual(workspace([asking]).cardActions, [], "a dialog whose hook said nothing more")
        XCTAssertEqual(workspace([asking]).rowSummary.lineText, "Needs you · Which database should the import job write to…")
        let plain = asking
        asking.dialog = dialog
        XCTAssertNotEqual(asking, plain, "what it asks redraws the card")
        let card = workspace([asking])
        XCTAssertEqual(card.cardActions, [.dialog(columnIndex: 1, dialog)])
        XCTAssertEqual(card.rowSummary.lineText, "Needs you · a question")

        let result = render(card)
        func label(_ text: String) throws -> NSTextField { try XCTUnwrap(labels(result).first { $0.stringValue == text }, text) }
        // Top to bottom.
        let stack = try [
            dialog.questions[0].text,
            "1.\tStaging replica (Recommended) — Safe to wipe; refreshed from production every night",
            "2.\tLocal Postgres",
            "And when?",
            "1.\tNow",
            "2.\tTonight — after the backup",
            "Answer in the terminal",
        ].map(label)
        XCTAssertGreaterThan(stack[0].frame.height, SidebarExpandedMetrics.questionLineHeight, "whole, on its lines")
        for (above, below) in zip(stack, stack.dropFirst()) {
            XCTAssertGreaterThanOrEqual(above.frame.minY, below.frame.maxY, "\(above.stringValue) over \(below.stringValue)")
        }
        // As tall as what it draws: the hint's line ends the block, a row's
        // padding above the card's edge.
        let hint = try XCTUnwrap(stack.last)
        XCTAssertEqual(hint.frame.minY, result.bottomY + SidebarExpandedMetrics.rowPaddingY - 1, accuracy: 0.5)
        XCTAssertEqual(800 - result.bottomY, SidebarExpandedMetrics.workspaceHeight(for: card, sidebarWidth: 260), accuracy: 0.5)
        // A click anywhere on it brings the dialog's column in front,
        // selected row or not, whichever column the row's own click picks.
        XCTAssertTrue(result.approvalButtons.isEmpty)
        for shown in [stack[0], stack[2], hint] {
            let point = NSPoint(x: shown.frame.midX, y: shown.frame.midY)
            guard case .column(workspaceIndex: 2, columnIndex: 1)? = result.hitAreas.first(where: { $0.frame.contains(point) })?.region
            else { return XCTFail("\(shown.stringValue) leads to the dialog's column") }
        }
        XCTAssertEqual(stack[1].toolTip, "1. Staging replica (Recommended) — Safe to wipe; refreshed from production every night")

        // What its hook lets through is never cut: drawn past a turn
        // question's eight lines and a choice's six.
        func words(_ count: Int) -> String { Array(repeating: "sentences", count: count).joined(separator: " ") }
        let longest = AgentDialog(questions: [.init(text: words(29) + " which one?", options: [
            .init(label: words(8) + "s", detail: words(16) + "s"),
        ])])
        XCTAssertEqual(longest.questions[0].text.count, 300)
        XCTAssertEqual(AgentDialog.bounded(longest.questions), longest, "at its bounds")
        asking.dialog = longest
        let drawn = render(workspace([asking]))
        let tall = labels(drawn)
        let lineHeight = SidebarExpandedMetrics.questionLineHeight
        let question = try XCTUnwrap(tall.first { $0.stringValue == longest.questions[0].text })
        XCTAssertGreaterThan(question.frame.height, 8 * lineHeight)
        XCTAssertEqual(question.maximumNumberOfLines, SidebarExpandedMetrics.dialogMaxLines, "its label takes them all")
        let under = try XCTUnwrap(tall.first { $0.stringValue == "Answer in the terminal" })
        XCTAssertEqual(under.frame.minY, drawn.bottomY + SidebarExpandedMetrics.rowPaddingY - 1, accuracy: 0.5, "and its block is as tall")
        XCTAssertEqual(
            question.frame.height, SidebarQuestionText.questionHeight(longest.questions[0].text, width: question.frame.width, maxLines: 99),
            accuracy: 0.5
        )
        let option = try XCTUnwrap(tall.first { $0.stringValue.hasPrefix("1.\t") })
        var uncapped = SidebarQuestionText.options(longest.questions[0])
        uncapped.maxLines = 99
        XCTAssertGreaterThan(option.frame.height, 6 * lineHeight)
        XCTAssertEqual(option.frame.height, uncapped.height(width: option.frame.width), accuracy: 0.5)

        // Several questions with all they offer would take the sidebar:
        // such a block lists the labels, and a tooltip says what each
        // option means.
        let many = AgentDialog(questions: (1...4).map { number in
            .init(text: "Question \(number): which of these should the import job use?", options: (1...4).map {
                .init(label: "Option \($0)", detail: "What option \($0) means, in a sentence long enough to wrap")
            })
        })
        XCTAssertTrue(SidebarExpandedMetrics.dialogShowsDetails(dialog, width: 224))
        XCTAssertFalse(SidebarExpandedMetrics.dialogShowsDetails(many, width: 224))
        asking.dialog = many
        let compact = render(workspace([asking]))
        let listed = labels(compact).filter { $0.stringValue == "1.\tOption 1" }
        XCTAssertEqual(listed.count, 4, "every question's options")
        XCTAssertEqual(listed.first?.toolTip, "1. Option 1 — What option 1 means, in a sentence long enough to wrap")
        let where_ = try XCTUnwrap(labels(compact).first { $0.stringValue == "Answer in the terminal" })
        XCTAssertEqual(where_.frame.minY, compact.bottomY + SidebarExpandedMetrics.rowPaddingY - 1, accuracy: 0.5, "as tall as what it draws")
    }

    /// "Dismiss Question" in the row's menu, for each question that stands
    /// in its columns: also while its card has no buttons (subagents at
    /// work).
    func testRowMenuDismissesItsQuestions() throws {
        _ = NSApplication.shared
        let sidebar = SidebarView(frame: NSRect(x: 0, y: 0, width: 260, height: 600))
        sidebar.isExpanded = true
        var dismissed: [(UUID, TimeInterval)] = []
        sidebar.onQuestionDismissed = { dismissed.append(($0, $1)) }
        sidebar.update(profiles: [], workspaces: [workspace([column(nil)])])
        XCTAssertFalse(sidebar.workspaceActionMenu(workspaceIndex: 2, columnIndex: nil).items.contains {
            $0.title == SidebarView.dismissQuestionTitle
        })
        var working = column(nil)
        working.questionAskedAt = 1_005
        working.id = columnID
        // A second column that asks, column 3 of the task.
        let otherID = UUID()
        var other = ColumnInfo(
            index: 3, processName: "claude", abbreviatedCwd: "~/p", isFocused: false, isWebView: false,
            webTitle: nil, terminalTitle: nil, agentStatus: .needsAttention, isEditor: false, editorFileName: nil
        )
        other.questionAskedAt = 2_000
        other.id = otherID
        sidebar.update(profiles: [], workspaces: [workspace([working, other])])
        func dismiss(fromColumn columnIndex: Int?) throws {
            let menu = sidebar.workspaceActionMenu(workspaceIndex: 2, columnIndex: columnIndex)
            menu.performActionForItem(at: try XCTUnwrap(menu.items.firstIndex { $0.title == SidebarView.dismissQuestionTitle }))
        }
        try dismiss(fromColumn: nil)
        XCTAssertEqual(dismissed.map(\.0), [columnID, otherID], "the row's menu: each of its questions")
        XCTAssertEqual(dismissed.map(\.1), [1_005, 2_000])
        dismissed = []
        try dismiss(fromColumn: 3)
        XCTAssertEqual(dismissed.map(\.0), [otherID], "a column's menu: its own")
    }

    func testOnlyASingleClickReleasedOnTheSameAnswerAnswers() {
        let later = SidebarTurnQuestion(text: "Shall I merge it?", turnEndedAt: 2_000, isYesNo: true, columnID: columnID)
        let yes = SidebarHitRegion.turnAnswer(workspaceIndex: 2, columnIndex: 1, question: yesNo, answer: .yes)
        let no = SidebarHitRegion.turnAnswer(workspaceIndex: 2, columnIndex: 1, question: yesNo, answer: .no)
        let laterYes = SidebarHitRegion.turnAnswer(workspaceIndex: 2, columnIndex: 1, question: later, answer: .yes)
        let moved = SidebarHitRegion.turnAnswer(workspaceIndex: 0, columnIndex: 3, question: yesNo, answer: .yes)
        func answers(
            _ released: SidebarHitRegion?, clicks: Int = 1, armedAtPress: Bool = true, armedAtRelease: Bool = true
        ) -> SidebarTurnAnswerClick? {
            SidebarView.turnAnswerClick(
                pressed: yes, released: released, clickCount: clicks, armedAtPress: armedAtPress, armedAtRelease: armedAtRelease
            )
        }
        XCTAssertEqual(answers(yes), SidebarTurnAnswerClick(question: yesNo, answer: .yes))
        XCTAssertEqual(answers(moved), SidebarTurnAnswerClick(question: yesNo, answer: .yes), "its card moved meanwhile")
        XCTAssertEqual(SidebarView.armedButtonKey(for: yes), SidebarView.armedButtonKey(for: moved), "the same button wherever it is")
        XCTAssertNil(answers(no), "slid onto No")
        XCTAssertNil(answers(laterYes), "a question the button didn't show")
        let otherColumn = SidebarTurnQuestion(text: "Shall I merge it?", turnEndedAt: 1_005, isYesNo: true, columnID: UUID())
        let otherYes = SidebarHitRegion.turnAnswer(workspaceIndex: 2, columnIndex: 2, question: otherColumn, answer: .yes)
        XCTAssertNil(answers(otherYes), "another column's")
        XCTAssertNotEqual(SidebarView.armedButtonKey(for: yes), SidebarView.armedButtonKey(for: otherYes), "each column its own")
        XCTAssertNil(answers(.actionBlock(workspaceIndex: 2)))
        XCTAssertNil(answers(nil))
        XCTAssertNil(answers(yes, clicks: 2))
        XCTAssertNil(answers(yes, armedAtPress: false))
        XCTAssertNil(answers(yes, armedAtRelease: false))
        XCTAssertNotEqual(SidebarView.armedButtonKey(for: yes), SidebarView.armedButtonKey(for: laterYes), "arms again")
        XCTAssertNotEqual(SidebarView.armedButtonKey(for: yes), SidebarView.armedButtonKey(for: no))
    }

    /// A new question redraws the card, whatever else stays the same.
    func testANewQuestionIsAChangeOfTheRow() {
        let later = SidebarTurnQuestion(text: "Shall I merge it?", turnEndedAt: 2_000, isYesNo: true, columnID: columnID)
        XCTAssertNotEqual(column(yesNo), column(later))
        XCTAssertNotEqual(column(yesNo).hashValue, column(later).hashValue)
    }

    func testYesAndNoTypeAPlainWord() {
        XCTAssertEqual(SidebarTurnAnswer.yes.typedText, "yes")
        XCTAssertEqual(SidebarTurnAnswer.no.typedText, "no")
        XCTAssertNil(SidebarTurnAnswer.reply.typedText, "the user writes it")
        XCTAssertNil(SidebarTurnAnswer.dismiss.typedText, "nothing is typed")
    }
}
