import AppKit
import XCTest
@testable import Nirux

/// The quick switcher and Next Waiting Agent in a real window (see
/// UIFlowHarness): type a workspace's name in ⌘P and press Return; press
/// ⌘J to go from one blocked agent to the next. Blocked agents are faked
/// through `quickSwitch.agentWait`: a real one needs a `claude` in front.
@MainActor
final class QuickSwitcherFlowTests: XCTestCase {
    /// Opens ⌘P and types `query`, as a user does.
    private func search(_ query: String, in harness: UIFlowHarness) throws -> CommandPalette {
        if harness.shell.commandPalette?.isVisible == true { harness.shell.commandPalette?.dismiss() }
        harness.shell.showCommandPalette()
        let palette = try XCTUnwrap(harness.shell.commandPalette)
        XCTAssertTrue(palette.isVisible)
        harness.type(query, into: try XCTUnwrap(palette.searchField))
        return palette
    }

    private func headers(_ palette: CommandPalette) -> [String] {
        palette.listLayout.items.compactMap {
            if case .header(let title) = $0 { return title }
            return nil
        }
    }

    private func index(of workspace: WorkspaceState, in shell: NiruxShellView) throws -> Int {
        try XCTUnwrap(shell.workspaces.firstIndex { $0 === workspace })
    }

    // MARK: - ⌘P

    func testTypingAWorkspaceNameOpensIt() throws {
        try UIFlowHarness.run { harness in
            let shell = harness.shell
            let repo = try XCTUnwrap(shell.activeWorkspace)
            shell.addWorkspace(title: "billing-fix", cwd: harness.worktree)
            let billing = try XCTUnwrap(shell.activeWorkspace)
            XCTAssertEqual(billing.title, "billing-fix")
            shell.switchToWorkspace(try index(of: repo, in: shell))

            // Without a query: the commands, as before, then the workspaces.
            let all = try search("", in: harness)
            XCTAssertEqual(all.searchField?.placeholderString, "Type a command or a workspace...")
            XCTAssertEqual(headers(all), ["Commands", "Workspaces"])
            XCTAssertEqual(all.filteredActions.first?.title, "Open Browser")
            XCTAssertEqual(all.filteredActions.suffix(2).map(\.title), ["repo", "billing-fix"])
            XCTAssertTrue(all.filteredActions.suffix(2).first?.subtitle.hasPrefix("Current · ") == true)

            // The last row, scrolled into view with its header: a click
            // there picks it, a click on the header nothing.
            for _ in 1..<all.filteredActions.count { harness.press(.down, in: all.panel) }
            let last = all.filteredActions.count - 1
            XCTAssertEqual(all.selectedIndex, last)
            XCTAssertGreaterThan(all.scrollY, 0)
            let rowItem = try XCTUnwrap(all.listLayout.itemIndex(ofRow: last))
            let rowView = try XCTUnwrap(all.rowViews[safe: rowItem])
            XCTAssertEqual(all.row(atListPoint: NSPoint(x: rowView.frame.midX, y: rowView.frame.midY)), last)
            let headerView = try XCTUnwrap(all.rowViews[safe: rowItem - 2])
            XCTAssertEqual(all.listLayout.items[rowItem - 2], .header("Workspaces"))
            XCTAssertNil(all.row(atListPoint: NSPoint(x: headerView.frame.midX, y: headerView.frame.midY)))

            // Back from URL input (Escape), the sections come back.
            all.switchToURLMode()
            all.switchToActionsMode()
            XCTAssertEqual(headers(all), ["Commands", "Workspaces"])
            XCTAssertEqual(all.searchField?.placeholderString, "Type a command or a workspace...")

            // A dialog has waited 12 minutes in it.
            let column = try XCTUnwrap(billing.columns.first)
            let since = Date().timeIntervalSince1970 - 12 * 60 - 5
            shell.quickSwitch.agentWait = { candidate, _, _ in
                candidate === column ? AgentWait(reason: .permission(tool: "Bash", summary: nil), since: since) : nil
            }

            let palette = try search("billing", in: harness)
            XCTAssertEqual(headers(palette), ["Workspaces"])
            XCTAssertEqual(palette.filteredActions.first?.title, "billing-fix")
            XCTAssertEqual(palette.filteredActions.first?.badge, PaletteBadge(text: "waiting 12m", tone: .waiting))
            XCTAssertEqual(palette.selectedIndex, 0)
            harness.press(.returnKey, in: palette.panel)

            XCTAssertFalse(palette.isVisible)
            XCTAssertIdentical(shell.activeWorkspace, billing)
        }
    }

    /// Opening an inactive workspace brings it on screen, alone under the
    /// folded INACTIVE header (#50): it stays inactive, the section folded.
    func testOpeningAnInactiveWorkspaceLeavesItInactive() throws {
        try UIFlowHarness.run { harness in
            let shell = harness.shell
            let repo = try XCTUnwrap(shell.activeWorkspace)
            shell.addWorkspace(title: "parked", cwd: harness.worktree)
            let parked = try XCTUnwrap(shell.activeWorkspace)
            harness.perform(
                ["Move to Inactive"],
                in: shell.sidebar.workspaceActionMenu(workspaceIndex: try index(of: parked, in: shell), columnIndex: nil)
            )
            shell.addWorkspace(title: "parking-lot", cwd: harness.worktree)
            shell.switchToWorkspace(try index(of: repo, in: shell))
            XCTAssertTrue(parked.isInactive)
            XCTAssertTrue(shell.sidebar.isInactiveSectionCollapsed)
            XCTAssertFalse(shell.sidebar.dotWorkspaceInfos.contains { $0.id == parked.id })

            // Below the active workspace that matches as well.
            let palette = try search("park", in: harness)
            XCTAssertEqual(headers(palette).first, "Workspaces")
            XCTAssertEqual(palette.filteredActions.prefix(2).map(\.title), ["parking-lot", "parked"])
            let row = palette.filteredActions[1]
            XCTAssertTrue(row.isDimmed)
            XCTAssertTrue(row.subtitle.hasPrefix("Inactive · "), row.subtitle)
            harness.press(.down, in: palette.panel)
            harness.press(.returnKey, in: palette.panel)

            XCTAssertIdentical(shell.activeWorkspace, parked)
            XCTAssertTrue(parked.isInactive, "opening it doesn't reactivate it")
            XCTAssertTrue(shell.sidebar.isInactiveSectionCollapsed, "nor unfold the section")
            XCTAssertTrue(shell.sidebar.dotWorkspaceInfos.contains { $0.id == parked.id }, "the sidebar lists it")
        }
    }

    /// Workspaces of every space are listed, found by their space's name.
    func testWorkspaceOfAnotherSpaceOpensWithItsSpace() throws {
        try UIFlowHarness.run { harness in
            let shell = harness.shell
            let repo = try XCTUnwrap(shell.activeWorkspace)
            let clients = shell.workspaceStore.createProfile(named: "Clients")
            shell.addWorkspace(title: "acme", cwd: harness.worktree, profileID: clients.id)
            let acme = try XCTUnwrap(shell.activeWorkspace)
            XCTAssertEqual(acme.profileID, clients.id)
            shell.switchToWorkspace(try index(of: repo, in: shell))
            XCTAssertEqual(shell.activeProfileID, WorkspaceProfile.defaultID)

            let palette = try search("clients", in: harness)
            let row = try XCTUnwrap(palette.filteredActions.first)
            XCTAssertEqual(row.title, "acme")
            XCTAssertTrue(row.subtitle.contains("Clients"), "several spaces: the row names its own")
            harness.press(.returnKey, in: palette.panel)

            XCTAssertIdentical(shell.activeWorkspace, acme)
            XCTAssertEqual(shell.activeProfileID, clients.id)
        }
    }

    // MARK: - ⌘J

    /// Longest wait first, then the next one at each press, whatever its
    /// workspace, space or column — an inactive workspace's too — then
    /// round again.
    func testNextWaitingAgentWalksFromTheLongestWait() throws {
        try UIFlowHarness.run { harness in
            let shell = harness.shell
            let repo = try XCTUnwrap(shell.activeWorkspace)

            // Two columns, the waiting one not focused.
            shell.addWorkspace(title: "second", cwd: harness.worktree)
            let second = try XCTUnwrap(shell.activeWorkspace)
            shell.addColumn()
            XCTAssertEqual(second.focusedIndex, 1)

            let clients = shell.workspaceStore.createProfile(named: "Clients")
            shell.addWorkspace(title: "acme", cwd: harness.worktree, profileID: clients.id)
            let acme = try XCTUnwrap(shell.activeWorkspace)

            shell.addWorkspace(title: "parked", cwd: harness.worktree, profileID: WorkspaceProfile.defaultID)
            let parked = try XCTUnwrap(shell.activeWorkspace)
            harness.perform(
                ["Move to Inactive"],
                in: shell.sidebar.workspaceActionMenu(workspaceIndex: try index(of: parked, in: shell), columnIndex: nil)
            )

            let now = Date().timeIntervalSince1970
            var waits: [ObjectIdentifier: AgentWait] = [
                ObjectIdentifier(second.columns[0]): AgentWait(reason: .question(nil), since: now - 300),
                ObjectIdentifier(acme.columns[0]): AgentWait(reason: .apiError(kind: "overloaded", detail: nil), since: now - 600),
                ObjectIdentifier(parked.columns[0]): AgentWait(reason: .permission(tool: "Bash", summary: nil), since: now - 100)
            ]
            shell.quickSwitch.agentWait = { column, _, _ in waits[ObjectIdentifier(column)] }
            shell.switchToWorkspace(try index(of: repo, in: shell))

            var landed: [String] = []
            @MainActor func press() throws {
                shell.jumpToNextWaitingAgent()
                let workspace = try XCTUnwrap(shell.activeWorkspace)
                landed.append("\(workspace.title)#\(workspace.focusedIndex)")
            }
            try press()
            try press()
            // Away and back by hand: the next press starts over at the
            // longest wait.
            shell.switchToWorkspace(try index(of: repo, in: shell))
            shell.switchToWorkspace(try index(of: second, in: shell))
            for _ in 0..<4 { try press() }
            XCTAssertEqual(landed, ["acme#0", "second#0", "acme#0", "second#0", "parked#0", "acme#0"])
            XCTAssertEqual(shell.activeProfileID, clients.id)
            XCTAssertTrue(parked.isInactive)
            XCTAssertTrue(shell.sidebar.isInactiveSectionCollapsed, "landing on an inactive workspace kept the section folded")
            XCTAssertFalse(shell.quickSwitch.hint?.isShowing ?? false)

            // Answered at the terminal: the next press starts over at the
            // longest wait left.
            waits[ObjectIdentifier(acme.columns[0])] = nil
            shell.jumpToNextWaitingAgent()
            XCTAssertIdentical(shell.activeWorkspace, second)

            // None left: a hint, and nothing moves.
            waits.removeAll()
            shell.jumpToNextWaitingAgent()
            XCTAssertIdentical(shell.activeWorkspace, second)
            XCTAssertEqual(shell.quickSwitch.hint?.text, NiruxShellView.noWaitingAgentHint)
            XCTAssertTrue(shell.quickSwitch.hint?.isShowing ?? false)
            XCTAssertIdentical(shell.quickSwitch.hint?.superview, shell)
        }
    }
}
