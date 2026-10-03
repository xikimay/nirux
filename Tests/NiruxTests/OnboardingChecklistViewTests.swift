import AppKit
import XCTest
@testable import Nirux

@MainActor
final class OnboardingChecklistViewTests: XCTestCase {
    private func checklist(agents: Bool, skills: AgentSkillsStatus) -> OnboardingChecklist {
        OnboardingChecklist(
            agents: AgentCLIAvailability(claudePath: agents ? "/usr/local/bin/claude" : nil, codexPath: nil),
            skills: skills,
            hooks: AgentHooksStatus(claude: true, codex: true, installsHooks: true)
        )
    }

    private func buttons(in view: NSView) -> [OnboardingChecklistButton] {
        view.subviews.compactMap { $0 as? OnboardingChecklistButton }
    }

    private func button(_ label: String, in view: NSView) throws -> OnboardingChecklistButton {
        try XCTUnwrap(buttons(in: view).first { $0.accessibilityLabel() == label }, label)
    }

    func testCardOffersTheActionsOfUnfinishedSteps() throws {
        let card = OnboardingChecklistView()
        var actions: [OnboardingChecklistAction] = []
        card.onAction = { actions.append($0) }
        card.update(checklist: checklist(agents: false, skills: .missing), width: 244)

        XCTAssertGreaterThan(card.height, 200)
        XCTAssertEqual(card.frame.size, NSSize(width: 244, height: card.height))
        for subview in card.subviews {
            XCTAssertLessThanOrEqual(subview.frame.maxX, 244, "\(subview) overflows the card")
            XCTAssertLessThanOrEqual(subview.frame.maxY, card.height, "\(subview) overflows the card")
        }

        XCTAssertTrue(try button("Install", in: card).accessibilityPerformPress())
        XCTAssertTrue(try button("Check again", in: card).accessibilityPerformPress())
        XCTAssertTrue(try button("Hide Getting Started", in: card).accessibilityPerformPress())
        XCTAssertEqual(actions, [.installSkills, .checkAgain, .close])
        XCTAssertNotNil(try button("Copy brew install --cask codex", in: card))
        XCTAssertNil(buttons(in: card).first { $0.accessibilityLabel() == "Done" })
    }

    func testLongCommandsWrapInsteadOfTruncating() throws {
        let card = OnboardingChecklistView()
        card.update(checklist: checklist(agents: false, skills: .installed), width: 244)
        let long = try button("Copy curl -fsSL https://claude.ai/install.sh | bash", in: card)
        let short = try button("Copy brew install --cask codex", in: card)

        // The text column: card width minus the row indent and insets.
        let textColumn = long.frame.minX...(244 - 12)
        XCTAssertEqual(long.frame.maxX, textColumn.upperBound, accuracy: 0.5, "a long command takes the column")
        XCTAssertGreaterThan(long.frame.height, short.frame.height, "and wraps onto more lines")
        XCTAssertEqual(short.frame.height, 20)
        XCTAssertLessThan(short.frame.maxX, textColumn.upperBound)

        let unbounded = long.preferredSize(maxWidth: 1000)
        XCTAssertEqual(unbounded.height, 20, "one line when there is room")
    }

    func testCheckAgainAnswersWhenNothingChanged() throws {
        let card = OnboardingChecklistView()
        let unchanged = checklist(agents: false, skills: .installed)
        card.onAction = { _ in card.update(checklist: unchanged, width: 244) }
        card.update(checklist: unchanged, width: 244)
        let checkAgain = try button("Check again", in: card)

        XCTAssertTrue(checkAgain.accessibilityPerformPress())
        XCTAssertTrue(checkAgain.superview === card, "same card: the button stays")
        XCTAssertEqual(checkAgain.displayedTitle, "Not found")
        XCTAssertTrue(card.hasButton(at: card.convert(NSPoint(x: checkAgain.frame.midX, y: checkAgain.frame.midY), to: nil)))
    }

    func testCheckAgainStaysQuietWhenTheCheckFindsAnAgent() throws {
        let card = OnboardingChecklistView()
        card.onAction = { [unowned self] _ in card.update(checklist: checklist(agents: true, skills: .installed), width: 244) }
        card.update(checklist: checklist(agents: false, skills: .installed), width: 244)
        let checkAgain = try button("Check again", in: card)

        XCTAssertTrue(checkAgain.accessibilityPerformPress())
        XCTAssertNil(checkAgain.superview, "the rebuilt card dropped it")
        XCTAssertEqual(checkAgain.displayedTitle, "Check again", "no stale \"Not found\" announcement")
    }

    func testCompletedCardOffersDone() throws {
        let card = OnboardingChecklistView()
        var actions: [OnboardingChecklistAction] = []
        card.onAction = { actions.append($0) }
        card.update(checklist: checklist(agents: true, skills: .installed), width: 244)

        XCTAssertNil(buttons(in: card).first { $0.accessibilityLabel() == "Install" })
        XCTAssertTrue(try button("Done", in: card).accessibilityPerformPress())
        XCTAssertEqual(actions, [.close])
    }

    func testCardRebuildsOnlyWhenContentOrWidthChanges() {
        let card = OnboardingChecklistView()
        let incomplete = checklist(agents: false, skills: .missing)
        card.update(checklist: incomplete, width: 244)
        let firstSubviews = card.subviews.map(ObjectIdentifier.init)

        card.update(checklist: incomplete, width: 244)
        XCTAssertEqual(card.subviews.map(ObjectIdentifier.init), firstSubviews)

        card.update(checklist: checklist(agents: true, skills: .missing), width: 244)
        XCTAssertNotEqual(card.subviews.map(ObjectIdentifier.init), firstSubviews)
    }

    func testSidebarShowsCardInPlaceOfShortcutHint() throws {
        let sidebar = SidebarView(frame: NSRect(x: 0, y: 0, width: 260, height: 900))
        sidebar.isExpanded = true
        sidebar.update(profiles: [], workspaces: [SidebarTestData.workspace()])
        let hints = { sidebar.expandedViews.filter { $0 is SidebarShortcutHintView } }
        XCTAssertEqual(hints().count, 1)
        XCTAssertNil(sidebar.onboardingCardView)

        var received: [OnboardingChecklistAction] = []
        sidebar.onOnboardingAction = { received.append($0) }
        sidebar.onboardingChecklist = checklist(agents: false, skills: .missing)
        let card = try XCTUnwrap(sidebar.onboardingCardView)
        XCTAssertTrue(card.superview === sidebar.contentDocumentView)
        XCTAssertEqual(card.frame.minX, SidebarExpandedMetrics.workspaceInsetX)
        XCTAssertEqual(card.frame.width, 260 - SidebarExpandedMetrics.workspaceInsetX * 2)
        XCTAssertTrue(hints().isEmpty)
        XCTAssertTrue(try button("Install", in: card).accessibilityPerformPress())
        XCTAssertEqual(received, [.installSkills])

        // A heartbeat update with the same data keeps the same card.
        sidebar.update(profiles: [], workspaces: [SidebarTestData.workspace(title: "renamed")])
        XCTAssertTrue(sidebar.onboardingCardView === card)
        XCTAssertTrue(card.superview === sidebar.contentDocumentView)

        sidebar.onboardingChecklist = nil
        XCTAssertNil(sidebar.onboardingCardView)
        XCTAssertNil(card.superview)
        XCTAssertEqual(hints().count, 1)
    }

    func testRevealWaitsForTheCardWhileTheSidebarOpens() {
        let sidebar = SidebarView(frame: NSRect(x: 0, y: 0, width: 260, height: 400))
        sidebar.update(profiles: [], workspaces: [SidebarTestData.workspace()])
        sidebar.onboardingChecklist = checklist(agents: false, skills: .missing)
        sidebar.revealOnboardingCard()
        XCTAssertTrue(sidebar.revealsOnboardingCardOnNextBuild, "collapsed: nothing to scroll to yet")

        sidebar.isExpanded = true
        XCTAssertFalse(sidebar.revealsOnboardingCardOnNextBuild, "applied by the first build with the card")
        XCTAssertNotNil(sidebar.onboardingCardView?.superview)

        sidebar.revealOnboardingCard()
        sidebar.onboardingChecklist = nil
        XCTAssertFalse(sidebar.revealsOnboardingCardOnNextBuild)
    }
}

enum SidebarTestData {
    static func workspace(title: String = "ws 1") -> WorkspaceInfo {
        WorkspaceInfo(
            id: "ws-1", index: 0, title: title, profileID: WorkspaceProfile.defaultID,
            isInactive: false, columnCount: 1, focusedColumn: 0, gitBranch: nil,
            notification: nil, isActive: true,
            columns: [
                ColumnInfo(
                    index: 0, processName: "zsh", abbreviatedCwd: "~", isFocused: true,
                    isWebView: false, webTitle: nil, terminalTitle: nil, agentStatus: .idle,
                    isEditor: false, editorFileName: nil
                )
            ],
            prInfo: nil, diffStats: nil, purpose: nil, nextStep: nil, blocker: nil,
            phase: .active, lastSummary: nil, lastActivityAt: nil
        )
    }
}
