import XCTest
@testable import Nirux

/// docs/sidebar-groups.md: a Mission child listed under its parent.
@MainActor
final class SidebarGroupsTests: XCTestCase {

    /// `parents` maps a child's id to its parent's: the child gets a
    /// Mission whose parent is that workspace.
    private func makeStore(
        _ ids: [String], parents: [String: String] = [:], inactive: Set<String> = []
    ) -> WorkspaceStore {
        let store = WorkspaceStore()
        store.missionParentID = { missionID in parents[String(missionID.dropFirst("mission-".count))] }
        for id in ids {
            let workspace = WorkspaceState(
                id: id, title: id, cwd: "/tmp/\(id)", missionID: parents[id] == nil ? nil : "mission-\(id)"
            )
            workspace.isInactive = inactive.contains(id)
            store.appendWorkspace(workspace, activate: false)
        }
        return store
    }

    private func visibleIDs(_ store: WorkspaceStore) -> [String] {
        store.visibleWorkspaceIndices.map { store.workspaces[$0].id }
    }

    private func index(_ id: String, in store: WorkspaceStore) -> Int {
        store.workspaces.firstIndex { $0.id == id }!
    }

    // MARK: - Order

    func testChildrenFollowTheirParentDepthFirst() {
        let store = makeStore(["a", "b", "a1", "b1", "a2", "a1x"], parents: ["a1": "a", "a2": "a", "b1": "b", "a1x": "a1"])
        XCTAssertEqual(visibleIDs(store), ["a", "a1", "a1x", "a2", "b", "b1"])
        XCTAssertEqual(store.groupParentIndex(of: index("a1x", in: store)), index("a1", in: store))
        XCTAssertNil(store.groupParentIndex(of: index("a", in: store)))
    }

    func testChildInAnotherSectionThanItsParentIsTopLevel() {
        let store = makeStore(["a", "a1", "z"], parents: ["a1": "a"], inactive: ["a1", "z"])
        XCTAssertEqual(visibleIDs(store), ["a", "a1", "z"])
        XCTAssertNil(store.groupParentIndex(of: index("a1", in: store)))
    }

    func testChildOfAClosedOrElsewhereParentIsTopLevel() {
        let store = makeStore(["b", "a1", "c1"], parents: ["a1": "gone", "c1": "c"])
        let other = WorkspaceProfile(id: "other", name: "other", colorHex: "#FF0000")
        store.replaceProfiles([WorkspaceProfile.defaultProfile, other], activeProfileID: WorkspaceProfile.defaultID)
        let parent = WorkspaceState(id: "c", title: "c", cwd: "/tmp/c")
        parent.profileID = "other"
        store.appendWorkspace(parent, activate: false)
        XCTAssertEqual(visibleIDs(store), ["b", "a1", "c1"])
        XCTAssertNil(store.groupParentIndex(of: index("a1", in: store)))
        XCTAssertNil(store.groupParentIndex(of: index("c1", in: store)))
    }

    // MARK: - Folding

    func testFoldedParentFoldsEveryDescendant() {
        let store = makeStore(["a", "a1", "a1x", "b"], parents: ["a1": "a", "a1x": "a1"])
        store.workspaces[index("a", in: store)].isGroupFolded = true
        XCTAssertFalse(store.isInFoldedGroup(index("a", in: store)))
        XCTAssertTrue(store.isInFoldedGroup(index("a1", in: store)))
        XCTAssertTrue(store.isInFoldedGroup(index("a1x", in: store)))
        XCTAssertFalse(store.isInFoldedGroup(index("b", in: store)))
    }

    // MARK: - Moves

    func testTopLevelMoveCarriesItsChildren() {
        let store = makeStore(["a", "a1", "b", "c"], parents: ["a1": "a"])
        XCTAssertTrue(store.moveWorkspace(at: index("a", in: store), delta: 1))
        XCTAssertEqual(visibleIDs(store), ["b", "a", "a1", "c"])
        XCTAssertTrue(store.moveWorkspace(at: index("a", in: store), toPosition: 2))
        XCTAssertEqual(visibleIDs(store), ["b", "c", "a", "a1"])
    }

    func testChildMovesAmongItsSiblingsOnly() {
        let store = makeStore(["a", "a1", "a2", "b"], parents: ["a1": "a", "a2": "a"])
        XCTAssertFalse(store.moveWorkspace(at: index("a1", in: store), delta: -1))
        XCTAssertFalse(store.moveWorkspace(at: index("a2", in: store), delta: 1))
        XCTAssertTrue(store.moveWorkspace(at: index("a2", in: store), toPosition: 0))
        XCTAssertEqual(visibleIDs(store), ["a", "a2", "a1", "b"])
    }

    // MARK: - Store order

    private func storeIDs(_ store: WorkspaceStore) -> [String] {
        store.workspaces.map(\.id)
    }

    /// A group dissolves in place: a closed parent leaves its children
    /// where it was, not at the bottom.
    func testMissionChildIsStoredAfterItsParentsGroup() {
        let store = makeStore(["a", "b", "a1", "a2", "a1x"], parents: ["a1": "a", "a2": "a", "a1x": "a1"])
        XCTAssertEqual(storeIDs(store), ["a", "a1", "a1x", "a2", "b"])
        store.removeWorkspace(store.workspaces[0])
        XCTAssertEqual(visibleIDs(store), ["a1", "a1x", "a2", "b"])
    }

    func testNewChildUnfoldsItsParent() {
        let store = makeStore(["a", "a1"], parents: ["a1": "a", "a2": "a"])
        store.workspaces[0].isGroupFolded = true
        store.appendWorkspace(WorkspaceState(id: "a2", title: "a2", cwd: "/tmp/a2", missionID: "mission-a2"))
        XCTAssertFalse(store.workspaces[0].isGroupFolded)
    }

    /// State saved before groups: the children at the bottom of the store.
    func testMovedGroupIsStoredTogether() {
        let store = makeStore(["a", "b", "c"])
        store.missionParentID = { $0 == "mission-a1" ? "a" : nil }
        store.replaceWorkspaces(store.workspaces + [WorkspaceState(id: "a1", title: "a1", cwd: "/tmp/a1", missionID: "mission-a1")])
        XCTAssertTrue(store.moveWorkspace(at: index("a", in: store), delta: 1))
        XCTAssertEqual(storeIDs(store), ["b", "a", "a1", "c"])
        XCTAssertTrue(store.moveWorkspace(at: index("c", in: store), delta: -1))
        XCTAssertEqual(storeIDs(store), ["b", "c", "a", "a1"])
    }

    func testClosingAFoldedParentSelectsTheNextCardNotAHiddenChild() {
        let store = makeStore(["a", "a1", "b"], parents: ["a1": "a"])
        store.workspaces[index("a", in: store)].isGroupFolded = true
        XCTAssertEqual(store.fallbackIndexAfterClosingWorkspace(at: index("a", in: store)), index("b", in: store))
    }

    func testAdjacentWorkspaceSkipsFoldedChildren() {
        let store = makeStore(["a", "a1", "b"], parents: ["a1": "a"])
        store.workspaces[index("a", in: store)].isGroupFolded = true
        store.selectWorkspace(id: "a")
        XCTAssertEqual(store.selectAdjacentWorkspace(delta: 1), index("b", in: store))
        // On screen, a folded child steps out like any card.
        store.selectWorkspace(id: "a1")
        XCTAssertEqual(store.selectAdjacentWorkspace(delta: 1), index("b", in: store))
    }

    // MARK: - Persistence

    func testFoldedStateRoundTrips() throws {
        let folded = PersistedWorkspace(
            title: "a", cwd: "/tmp/a", columns: [], focusedColumnIndex: 0, isGroupFolded: true
        )
        let decoded = try JSONDecoder().decode(PersistedWorkspace.self, from: JSONEncoder().encode(folded))
        XCTAssertTrue(decoded.isGroupFolded)
        let old = Data(#"{"title":"a","cwd":"/tmp/a","columns":[],"focusedColumnIndex":0,"isInactive":false,"lastSummaryIsManual":false}"#.utf8)
        XCTAssertFalse(try JSONDecoder().decode(PersistedWorkspace.self, from: old).isGroupFolded)
    }

    // MARK: - Sidebar

    private func info(
        _ id: String, index: Int, parent: String? = nil, isFolded: Bool = false, inFoldedGroup: Bool = false,
        isActive: Bool = false, isInactive: Bool = false, isWaiting: Bool = false, prState: String? = nil,
        ciStatus: String? = nil, isMissionCompleted: Bool = false
    ) -> WorkspaceInfo {
        let waiting = ColumnInfo(
            index: 0, processName: "claude", abbreviatedCwd: nil, isFocused: false, isWebView: false,
            webTitle: nil, terminalTitle: nil, agentStatus: .needsAttention, isEditor: false, editorFileName: nil
        )
        let pullRequest = prState.map {
            PRInfo(
                number: 1, state: $0, isDraft: false, ciStatus: ciStatus, checks: [], reviewDecision: nil,
                mergeable: nil, url: "https://github.com/o/r/pull/1", additions: nil, deletions: nil, changedFiles: nil
            )
        }
        return WorkspaceInfo(
            id: id, index: index, title: id, profileID: WorkspaceProfile.defaultID, isInactive: isInactive,
            columnCount: isWaiting ? 1 : 0, focusedColumn: 0, gitBranch: nil, notification: nil, isActive: isActive,
            columns: isWaiting ? [waiting] : [], prInfo: pullRequest, diffStats: nil, purpose: nil, nextStep: nil,
            blocker: nil, phase: .active, lastSummary: nil, lastActivityAt: nil,
            groupParentID: parent, isGroupFolded: isFolded, isInFoldedGroup: inFoldedGroup,
            isMissionCompleted: isMissionCompleted
        )
    }

    private func expandedSidebar(_ infos: [WorkspaceInfo]) -> SidebarView {
        let sidebar = SidebarView(frame: NSRect(x: 0, y: 0, width: 260, height: 900))
        sidebar.isExpanded = true
        sidebar.update(profiles: [], workspaces: infos)
        return sidebar
    }

    private func cardFrames(_ sidebar: SidebarView) -> [Int: NSRect] {
        var frames: [Int: NSRect] = [:]
        for area in sidebar.hitAreas {
            if case .workspace(let index) = area.region { frames[index] = area.frame }
        }
        return frames
    }

    func testChildCardIsIndentedUnderItsParentsSummaryRow() throws {
        let sidebar = expandedSidebar([info("a", index: 0), info("a1", index: 1, parent: "a"), info("b", index: 2)])
        let cards = cardFrames(sidebar)
        XCTAssertEqual(try XCTUnwrap(cards[1]).minX - XCTUnwrap(cards[0]).minX, SidebarExpandedMetrics.groupIndent)
        XCTAssertEqual(try XCTUnwrap(cards[2]).minX, try XCTUnwrap(cards[0]).minX)
        let toggle = try XCTUnwrap(sidebar.hitAreas.first {
            if case .link(let url, _) = $0.region { return url == SidebarView.groupToggleActionURL(workspaceIndex: 0) }
            return false
        })
        XCTAssertLessThan(toggle.frame.maxY, try XCTUnwrap(cards[0]).minY)
        XCTAssertGreaterThan(toggle.frame.minY, try XCTUnwrap(cards[1]).maxY)
    }

    func testFoldedGroupListsOnlyTheChildOnScreenOrAskingTheUser() {
        let sidebar = expandedSidebar([
            info("a", index: 0, isFolded: true),
            info("quiet", index: 1, parent: "a", inFoldedGroup: true),
            info("waiting", index: 2, parent: "a", inFoldedGroup: true, isWaiting: true),
            info("on-screen", index: 3, parent: "a", inFoldedGroup: true, isActive: true)
        ])
        XCTAssertEqual(cardFrames(sidebar).keys.sorted(), [0, 2, 3])
        XCTAssertEqual(sidebar.railWorkspaceInfos.map(\.id), ["a", "waiting", "on-screen"])
    }

    func testSummaryCountsWhereFoldedChildrenStand() {
        let members = [
            info("w", index: 1, parent: "a", isWaiting: true),
            info("red", index: 2, parent: "a", prState: "OPEN", ciStatus: "FAILURE"),
            info("merged", index: 3, parent: "a", prState: "MERGED"),
            info("completed", index: 4, parent: "a", isMissionCompleted: true)
        ]
        XCTAssertEqual(SidebarView.groupSummary(members: members, isFolded: false).string, "▾ 4 workspaces")
        XCTAssertEqual(
            SidebarView.groupSummary(members: members, isFolded: true).string,
            "▸ 4 · 1 waiting · ✕ 1 · 2 done"
        )
        XCTAssertEqual(SidebarView.groupSummary(members: [members[0]], isFolded: true).string, "▸ 1 · 1 waiting")
        let quiet = info("q", index: 5, parent: "a")
        XCTAssertEqual(SidebarView.groupSummary(members: [quiet], isFolded: true).string, "▸ 1 workspace")
    }

    func testSummaryCountsGrandchildren() {
        let sidebar = expandedSidebar([
            info("a", index: 0), info("a1", index: 1, parent: "a"), info("a1x", index: 2, parent: "a1")
        ])
        XCTAssertEqual(sidebar.groupMembers(of: sidebar.lastInfos[0]).map(\.id), ["a1", "a1x"])
    }

    /// A parent and its children are one drop target; a child's siblings
    /// are its parent's other children.
    func testDragBlockSpansTheParentItsRowAndItsChildren() throws {
        let sidebar = expandedSidebar([info("a", index: 0), info("a1", index: 1, parent: "a"), info("b", index: 2)])
        let cards = cardFrames(sidebar)
        let block = try XCTUnwrap(sidebar.blockFrame(of: sidebar.lastInfos[0]))
        XCTAssertEqual(block.maxY, try XCTUnwrap(cards[0]).maxY)
        XCTAssertEqual(block.minY, try XCTUnwrap(cards[1]).minY)
        XCTAssertEqual(sidebar.blockFrame(of: sidebar.lastInfos[2]), cards[2])
    }

    /// An inactive parent listed only for being on screen: its children
    /// stay folded with the section, so no row offers them.
    func testNoSummaryRowWhenTheChildrenCantShow() {
        let parent = info("a", index: 0, isActive: true, isInactive: true)
        let sidebar = expandedSidebar([info("b", index: 2), parent, info("a1", index: 1, parent: "a", isInactive: true)])
        XCTAssertFalse(sidebar.showsGroupToggle(parent))
        sidebar.toggleInactiveSection()
        XCTAssertTrue(sidebar.showsGroupToggle(parent))
    }
}
