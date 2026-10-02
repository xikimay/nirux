import XCTest
@testable import Nirux

/// What ⌘P lists and in which order: the commands, then the workspaces,
/// each workspace with its agents' state.
final class QuickSwitchTests: XCTestCase {
    private typealias Candidate = PaletteRanking.Candidate

    private let commands = [
        Candidate(title: "New Terminal", keys: ["Open a new terminal column"]),
        Candidate(title: "New Workspace", keys: ["Create a new workspace"]),
        Candidate(title: "Open Browser", keys: ["Open a URL in a new WebView column"])
    ]

    private func workspace(
        _ title: String,
        branch: String? = nil,
        space: String = "main",
        folder: String = "/Users/me/Projects/app",
        isInactive: Bool = false,
        agent: QuickSwitchAgentState? = nil
    ) -> QuickSwitchWorkspace {
        QuickSwitchWorkspace(
            id: title, title: title, branch: branch, spaceName: space, spaceColorHex: "#7AA2F7",
            folder: folder, isInactive: isInactive, agent: agent
        )
    }

    private func rank(_ query: String, _ workspaces: [QuickSwitchWorkspace]) -> [PaletteRanking.RankedSection] {
        PaletteRanking.rank(query: query, sections: [commands, workspaces.map(\.candidate)])
    }

    // MARK: - Ranking

    /// ⌘P opened without typing lists what it always did first.
    func testEmptyQueryListsTheCommandsThenEveryWorkspaceInactiveLast() {
        let workspaces = [workspace("old-spike", isInactive: true), workspace("api"), workspace("web")]

        XCTAssertEqual(rank("", workspaces), [
            PaletteRanking.RankedSection(section: 0, rows: [0, 1, 2]),
            PaletteRanking.RankedSection(section: 1, rows: [1, 2, 0])
        ])
    }

    /// Typing a workspace's name puts it on top, where Return opens it.
    func testTypingAWorkspaceNamePutsItFirst() {
        let ranked = rank("billing", [workspace("api"), workspace("billing-fix")])

        XCTAssertEqual(ranked, [PaletteRanking.RankedSection(section: 1, rows: [1])], "no command matches")

        // Open Browser's subtitle matches too, below the workspace's title.
        let mixed = rank("web", [workspace("api"), workspace("web")])
        XCTAssertEqual(mixed, [
            PaletteRanking.RankedSection(section: 1, rows: [1]),
            PaletteRanking.RankedSection(section: 0, rows: [2])
        ])
    }

    func testCommandsStayFirstWhenTheyMatchBest() {
        let ranked = rank("nt", [workspace("notes")])

        XCTAssertEqual(ranked.map(\.section), [0, 1])
        XCTAssertEqual(ranked.first?.rows.first, 0, "New Terminal")
    }

    /// A workspace is found by its branch, its space and its folder's name,
    /// not by the folders above.
    func testWorkspaceMatchesItsBranchSpaceAndFolder() {
        let found = workspace("login", branch: "feat/oauth", space: "Clients", folder: "/Users/me/Projects/acme-portal")

        XCTAssertEqual(rank("oauth", [found]).last?.rows, [0])
        XCTAssertEqual(rank("clients", [found]).last?.rows, [0])
        XCTAssertEqual(rank("portal", [found]).last?.rows, [0])
        XCTAssertNil(rank("projects", [found]).first { $0.section == 1 })
    }

    /// Inactive workspaces list below the active ones, however well they
    /// match.
    func testInactiveMatchesListBelowActiveOnes() {
        let ranked = rank("api", [workspace("api", isInactive: true), workspace("rapid-ui")])

        XCTAssertEqual(ranked.first { $0.section == 1 }?.rows, [1, 0])
    }

    // MARK: - Rows

    func testSubtitleSkipsWhatTheRowAlreadySays() {
        let sameAsBranch = workspace("feat/x", branch: "feat/x", space: "Work")
        XCTAssertEqual(sameAsBranch.subtitle(folderDisplay: "~/app", showsSpace: false), "~/app")
        XCTAssertEqual(sameAsBranch.subtitle(folderDisplay: "~/app", showsSpace: true), "Work · ~/app")

        let named = workspace("Login page", branch: "feat/x", space: "Work")
        XCTAssertEqual(named.subtitle(folderDisplay: "~/app", showsSpace: true), "feat/x · Work · ~/app")
    }

    /// The badge says what needs the user most: a failure, else the
    /// longest wait, else work going on.
    func testAgentStateShowsTheMostPressingColumn() {
        let dialog = AgentWait(reason: .permission(tool: "Bash", summary: nil), since: 1_000)
        let older = AgentWait(reason: .question(nil), since: 400)
        let failure = AgentWait(reason: .apiError(kind: "overloaded", detail: nil), since: 1_100)

        XCTAssertEqual(QuickSwitchAgentState.summary(waits: [dialog, older, failure], isWorking: true), .failed(failure.reason))
        XCTAssertEqual(QuickSwitchAgentState.summary(waits: [dialog, older], isWorking: true), .waiting(since: 400))
        XCTAssertEqual(QuickSwitchAgentState.summary(waits: [], isWorking: true), .working)
        XCTAssertNil(QuickSwitchAgentState.summary(waits: [], isWorking: false))

        XCTAssertEqual(QuickSwitchAgentState.waiting(since: 400).label(now: 1_120), "waiting 12m")
        XCTAssertEqual(QuickSwitchAgentState.failed(failure.reason).label(now: 1_120), "API error")
        XCTAssertEqual(QuickSwitchAgentState.failed(.exitedMidTurn).label(now: 1_120), "exited mid-turn")
        XCTAssertEqual(QuickSwitchAgentState.working.label(now: 1_120), "working")
    }

    // MARK: - Palette list

    /// Headers take no click; the first row under one brings it into view.
    func testHeadersAreNotRows() {
        let layout = PaletteListLayout(items: [.header("Commands"), .row(0), .row(1), .header("Workspaces"), .row(2)])
        let header = PaletteListLayout.headerHeight
        let row = PaletteListLayout.rowHeight

        XCTAssertNil(layout.row(atContentY: header - 1))
        XCTAssertEqual(layout.row(atContentY: header), 0)
        XCTAssertEqual(layout.row(atContentY: header + row * 2 - 1), 1)
        XCTAssertNil(layout.row(atContentY: header + row * 2 + 1), "the second header")
        XCTAssertEqual(layout.row(atContentY: header * 2 + row * 2), 2)
        XCTAssertNil(layout.row(atContentY: layout.totalHeight))

        XCTAssertEqual(layout.visibleSpan(ofRow: 2)?.top, header + row * 2, "with its header")
        XCTAssertEqual(layout.visibleSpan(ofRow: 1)?.top, header + row)
    }
}
