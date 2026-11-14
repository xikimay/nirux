import XCTest
@testable import Nirux

/// The glass interface's state icons (docs/design/glass-interface.md).
@MainActor
final class StateIconTests: XCTestCase {
    private let marks: [SidebarRowMark] = [
        .needsYou, .error, .working, .asking, .blocked, .readyToMerge, .merged, .idle, .finished, .checksRunning
    ]

    /// Amber is the colour of an agent waiting for the user, and of nothing
    /// else; the reason it waits picks the glyph.
    func testAmberMeansOnlyThatAnAgentWaitsForTheUser() {
        for mark in marks {
            for reason in [StateIcon.Reason.command, .question, nil] {
                let icon = StateIcon(mark: mark, reason: reason, station: .checks)
                XCTAssertEqual(icon.color == Theme.Color.waiting, mark == .needsYou, "\(mark)")
            }
        }
        XCTAssertEqual(StateIcon.Reason(.permission(tool: "Bash", summary: "npm run migrate")), .command)
        XCTAssertEqual(StateIcon.Reason(.stillWaiting(.permission(tool: nil, summary: nil), waited: 900)), .command)
        XCTAssertEqual(StateIcon.Reason(.question("Which branch?")), .question)
        XCTAssertEqual(StateIcon.Reason(.askedInReply("Shall I merge it?")), .question)
        XCTAssertEqual(StateIcon.Reason(nil), .question, "an agent without hooks falling silent may be asking")
        XCTAssertNil(StateIcon.Reason(.turnFinished))
        XCTAssertNil(StateIcon.Reason(.apiError(kind: nil, detail: nil)))
        XCTAssertEqual(StateIcon(mark: .needsYou).kind, .needsYou(.question))
    }

    /// The ring fills a quarter per station: Code one, Merge all four.
    func testTheRingFillsWithTheBoardsStations() {
        XCTAssertEqual(BoardStages.Station.allCases.map { StateIcon.stage(of: $0) }, [1, 2, 3, 4])
        XCTAssertEqual(StateIcon.stage(of: nil), 0)
        XCTAssertEqual(StateIcon(.idle, stage: 7).stage, 4)
        XCTAssertEqual(StateIcon(.idle, stage: -1).stage, 0)
    }

    /// The view says what it shows, and says it again when the icon changes.
    func testTheViewTellsVoiceOverItsState() {
        let view = StateIconView(StateIcon(.working, stage: 1))
        XCTAssertEqual(view.accessibilityLabel(), "Working")
        view.icon = StateIcon(mark: .needsYou, reason: .command)
        XCTAssertEqual(view.accessibilityLabel(), "Needs you: a permission")
        XCTAssertEqual(view.intrinsicContentSize, NSSize(width: 14, height: 14))
    }
}
