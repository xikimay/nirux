import XCTest
@testable import Nirux

/// What ⌘P lists and in which order: the commands, then the workspaces,
/// each workspace with its agents' state.
final class QuickSwitchTests: XCTestCase {
    private typealias Candidate = PaletteRanking.Candidate
    private typealias Section = PaletteRanking.RankedSection

    private let commands = [
        Candidate(title: "New Terminal", keys: ["Open a new terminal column"]),
        Candidate(title: "New Workspace", keys: ["Create a new workspace"]),
        Candidate(title: "Open Browser", keys: ["Open a URL in a new WebView column"]),
        Candidate(title: "Toggle Web Inspector", keys: ["Inspect the focused browser column"]),
        Candidate(title: "Open Codex", keys: ["Launch OpenAI Codex in a new terminal"])
    ]

    private func workspace(
        _ title: String,
        branch: String? = nil,
        space: String = "main",
        folder: String = "/Users/me/Projects/app",
        isInactive: Bool = false,
        isCurrent: Bool = false,
        showsSpace: Bool = false
    ) -> QuickSwitchWorkspace {
        QuickSwitchWorkspace(
            id: title, title: title, branch: branch, spaceName: space, spaceColorHex: "#7AA2F7",
            folder: folder, isInactive: isInactive, isCurrent: isCurrent, showsSpace: showsSpace, agent: nil
        )
    }

    private func rank(_ query: String, _ workspaces: [QuickSwitchWorkspace]) -> [Section] {
        PaletteRanking.rank(query: query, sections: [commands, workspaces.map(\.candidate)])
    }

    /// The workspace rows `query` lists, in order.
    private func workspaceRows(_ query: String, _ workspaces: [QuickSwitchWorkspace]) -> [Int]? {
        rank(query, workspaces).first { $0.section == 1 }?.rows
    }

    // MARK: - Sections

    /// ⌘P opened without typing lists what it always did first.
    func testEmptyQueryListsTheCommandsThenEveryWorkspaceInactiveLast() {
        let workspaces = [workspace("old-spike", isInactive: true), workspace("api"), workspace("web")]

        XCTAssertEqual(rank("", workspaces), [
            Section(section: 0, rows: [0, 1, 2, 3, 4]),
            Section(section: 1, rows: [1, 2, 0])
        ])
    }

    /// Typing a workspace's name puts it on top, where Return opens it.
    func testTypingAWorkspaceNamePutsItFirst() {
        XCTAssertEqual(rank("billing", [workspace("api"), workspace("billing-fix")]), [Section(section: 1, rows: [1])])

        // Open Browser's subtitle ("WebView") matches too, loosely.
        XCTAssertEqual(rank("webv", [workspace("webview-crash")]).map(\.section), [1, 0])
    }

    /// A command's name, or its initials, keeps the commands on top even
    /// when a workspace's name matches better…
    func testTypingACommandNameKeepsTheCommandsFirst() {
        let workspaces = [workspace("browser-tabs"), workspace("ntfy-alerts")]

        XCTAssertEqual(rank("browser", workspaces).map(\.section), [0, 1])
        XCTAssertEqual(rank("nt", workspaces).first?.section, 0)
        XCTAssertEqual(rank("nt", workspaces).first?.rows.first, 0, "New Terminal's initials")
        XCTAssertEqual(rank("new t", workspaces).first?.rows.first, 0)
    }

    /// …unless a workspace bears that very name.
    func testWorkspaceNamedExactlyLikeTheQueryLeads() {
        XCTAssertEqual(rank("web", [workspace("api"), workspace("web")]).map(\.section), [1, 0])
        XCTAssertEqual(rank("codex", [workspace("Codex")]).first, Section(section: 1, rows: [0]))
    }

    /// A section is judged by the row it shows first, where Return goes:
    /// not by an inactive row listed below it.
    func testSectionIsJudgedByItsFirstRow() {
        let workspaces = [workspace("terminal-fix", isInactive: true), workspace("repo", branch: "feat/terraform")]
        let ranked = rank("erm", workspaces)

        XCTAssertEqual(ranked.map(\.section), [0, 1])
        XCTAssertEqual(workspaceRows("erm", workspaces), [1, 0])
    }

    func testQueryNamesATitleByAWordStartOrConsecutiveInitials() {
        XCTAssertEqual(PaletteRanking.naming(query: "New Terminal", title: "new terminal"), .exact)
        XCTAssertEqual(PaletteRanking.naming(query: "new t", title: "New Terminal"), .wordStart)
        XCTAssertEqual(PaletteRanking.naming(query: "quick", title: "feat/quick-switcher"), .wordStart)
        XCTAssertEqual(PaletteRanking.naming(query: "nt", title: "New Terminal"), .initials)
        XCTAssertEqual(PaletteRanking.naming(query: "cw", title: "Resize Column (Cycle Width)"), .initials)
        XCTAssertEqual(PaletteRanking.naming(query: "ss", title: "Show/Hide Sidebar"), .none, "a word skipped")
        XCTAssertEqual(PaletteRanking.naming(query: "erm", title: "New Terminal"), .none)
    }

    // MARK: - Workspaces

    /// A workspace is found by its branch, its space and its folder's name,
    /// not by the folders above.
    func testWorkspaceMatchesItsBranchSpaceAndFolder() {
        let found = workspace(
            "login", branch: "feat/oauth", space: "Clients", folder: "/Users/me/Projects/acme-portal", showsSpace: true
        )

        XCTAssertEqual(workspaceRows("oauth", [found]), [0])
        XCTAssertEqual(workspaceRows("clients", [found]), [0])
        XCTAssertEqual(workspaceRows("portal", [found]), [0])
        XCTAssertNil(workspaceRows("projects", [found]))
    }

    /// With a single space, its name ("main") would match every workspace.
    func testTheOnlySpaceIsNotSearched() {
        let workspaces = [workspace("api"), workspace("web", branch: "main")]

        XCTAssertEqual(workspaceRows("main", workspaces), [1], "its branch only")
    }

    /// Inactive workspaces list below the active ones that match as well;
    /// the title typed, or a word of it, outranks a looser match — not
    /// initials, which are a guess.
    func testInactiveWorkspacesListBelowActiveOnesThatMatchAsWell() {
        XCTAssertEqual(workspaceRows("api", [workspace("api-old", isInactive: true), workspace("api-new")]), [1, 0])
        XCTAssertEqual(workspaceRows("api", [workspace("api", isInactive: true), workspace("api-v2")]), [0, 1])
        XCTAssertEqual(workspaceRows("api", [workspace("api-old", isInactive: true), workspace("rapid-ui")]), [0, 1])
        XCTAssertEqual(workspaceRows("api", [workspace("feat/add-payment-integration", isInactive: true), workspace("rapid-ui")]), [1, 0])
    }

    func testSubtitleSaysWhatTheTitleDoesNot() {
        let sameAsBranch = workspace("feat/x", branch: "feat/x", space: "Work")
        XCTAssertEqual(sameAsBranch.subtitle(folderDisplay: "~/app"), "~/app")

        let named = workspace("Login page", branch: "feat/x", space: "Work", isCurrent: true, showsSpace: true)
        XCTAssertEqual(named.subtitle(folderDisplay: "~/app"), "Current · feat/x · Work · ~/app")

        let parked = workspace("parked", branch: "feat/y", isInactive: true)
        XCTAssertEqual(parked.subtitle(folderDisplay: "~/app"), "Inactive · feat/y · ~/app")
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
