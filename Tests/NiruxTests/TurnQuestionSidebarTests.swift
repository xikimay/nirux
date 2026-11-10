import AppKit
import XCTest
@testable import Nirux

/// The question a Claude turn ended on, on its card: the question with
/// Reply…, and Yes / No when a plain yes or no answers it; the click that
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

    private let yesNo = SidebarTurnQuestion(text: "Shall I merge it?", turnEndedAt: 1_005, isYesNo: true)
    private let open = SidebarTurnQuestion(text: "Which branch should this go on?", turnEndedAt: 1_005, isYesNo: false)

    private func answers(_ hitAreas: [SidebarHitArea]) -> [SidebarTurnAnswer] {
        hitAreas.compactMap {
            if case let .turnAnswer(2, 1, 1_005, answer) = $0.region { return answer }
            return nil
        }
    }

    func testCardOffersYesAndNoOnlyForAYesNoQuestion() {
        let card = workspace([column(yesNo)])
        XCTAssertEqual(card.cardActions, [.turnQuestion(columnIndex: 1, yesNo, showsQuestion: false)], "the status line says it")
        let result = SidebarWorkspaceCardRenderer(workspace: card, sidebarWidth: 260, yOffset: 800).render()
        XCTAssertEqual(Set(answers(result.hitAreas)), [.yes, .no, .reply])
        XCTAssertEqual(result.approvalButtons.count, 3, "they arm like Allow / Deny")
        XCTAssertFalse(result.views.contains { ($0 as? NSTextField)?.stringValue == "Shall I merge it?" }, "said once")
        XCTAssertEqual(
            800 - result.bottomY, SidebarExpandedMetrics.workspaceHeight(for: card, sidebarWidth: 260), accuracy: 0.5,
            "layout matches the metrics the scroll view is sized with"
        )

        let openResult = SidebarWorkspaceCardRenderer(workspace: workspace([column(open)]), sidebarWidth: 260, yOffset: 800)
            .render()
        XCTAssertEqual(answers(openResult.hitAreas), [.reply])
        XCTAssertEqual(workspace([column(nil)]).cardActions, [])
    }

    /// When the status line says something else first (another column's
    /// dialog), the question comes with its buttons.
    func testQuestionComesWithItsButtonsUnderAnotherStatus() {
        let permission = ColumnInfo(
            index: 0, processName: "claude", abbreviatedCwd: "~/p", isFocused: false, isWebView: false,
            webTitle: nil, terminalTitle: nil, agentStatus: .needsAttention, isEditor: false, editorFileName: nil,
            attentionReason: .permission(tool: "Bash", summary: "npm run migrate")
        )
        let card = workspace([permission, column(yesNo)])
        XCTAssertEqual(card.cardActions, [.turnQuestion(columnIndex: 1, yesNo, showsQuestion: true)])
        let result = SidebarWorkspaceCardRenderer(workspace: card, sidebarWidth: 260, yOffset: 800).render()
        XCTAssertTrue(result.views.contains { ($0 as? NSTextField)?.stringValue == "Shall I merge it?" })
    }

    func testOnlyASingleClickReleasedOnTheSameAnswerAnswers() {
        let yes = SidebarHitRegion.turnAnswer(workspaceIndex: 2, columnIndex: 1, turnEndedAt: 1_005, answer: .yes)
        let no = SidebarHitRegion.turnAnswer(workspaceIndex: 2, columnIndex: 1, turnEndedAt: 1_005, answer: .no)
        let laterYes = SidebarHitRegion.turnAnswer(workspaceIndex: 2, columnIndex: 1, turnEndedAt: 2_000, answer: .yes)
        func answers(
            _ released: SidebarHitRegion?, clicks: Int = 1, armedAtPress: Bool = true, armedAtRelease: Bool = true
        ) -> SidebarTurnAnswerClick? {
            SidebarView.turnAnswerClick(
                pressed: yes, released: released, clickCount: clicks, armedAtPress: armedAtPress, armedAtRelease: armedAtRelease
            )
        }
        XCTAssertEqual(answers(yes), SidebarTurnAnswerClick(workspaceIndex: 2, columnIndex: 1, turnEndedAt: 1_005, answer: .yes))
        XCTAssertNil(answers(no), "slid onto No")
        XCTAssertNil(answers(laterYes), "a question the button didn't show")
        XCTAssertNil(answers(.actionBlock(workspaceIndex: 2)))
        XCTAssertNil(answers(nil))
        XCTAssertNil(answers(yes, clicks: 2))
        XCTAssertNil(answers(yes, armedAtPress: false))
        XCTAssertNil(answers(yes, armedAtRelease: false))
        XCTAssertNotEqual(SidebarView.armedButtonKey(for: yes), SidebarView.armedButtonKey(for: laterYes), "arms again")
        XCTAssertNotEqual(SidebarView.armedButtonKey(for: yes), SidebarView.armedButtonKey(for: no))
    }

    func testYesAndNoTypeAPlainWord() {
        XCTAssertEqual(SidebarTurnAnswer.yes.typedText, "yes")
        XCTAssertEqual(SidebarTurnAnswer.no.typedText, "no")
        XCTAssertNil(SidebarTurnAnswer.reply.typedText, "the user writes it")
    }
}
