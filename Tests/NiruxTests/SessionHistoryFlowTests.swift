import AppKit
import XCTest
@testable import Nirux

/// Past sessions in ⌘P, and Resume, in a real window (see UIFlowHarness):
/// the session history is written to the throwaway state directory, and
/// launches go to the harness's double.
@MainActor
final class SessionHistoryFlowTests: XCTestCase {
    private static let flowID = "6f1c2a3e-0d4b-4e5f-8a9b-1c2d3e4f5a60"
    private static let codexID = "019a4b2c-7d8e-7f90-a1b2-c3d4e5f60718"
    private static let restoredID = "a1b2c3d4-e5f6-4a7b-8c9d-0e1f2a3b4c5d"
    private static let emptyID = "b2c3d4e5-f6a7-4b8c-9d0e-1f2a3b4c5d6e"
    private static let goneID = "c3d4e5f6-a7b8-4c9d-8e0f-2a3b4c5d6e7f"
    private static let siblingID = "d4e5f6a7-b8c9-4d0e-9f1a-3b4c5d6e7f80"
    private static let lostID = "e5f6a7b8-c9d0-4e1f-8a2b-4c5d6e7f8091"
    private static let forgottenID = "f6a7b8c9-d0e1-4f2a-9b3c-5d6e7f8091a2"

    static func session(
        _ sessionID: String, title: String, folder: String, agent: AgentHookEvent.Kind = .claude,
        workspaceID: String? = nil, checkout: AgentSessionRecord.Checkout? = nil, hoursAgo: Double = 1
    ) -> AgentSessionRecord {
        let lastActivity = Date().timeIntervalSince1970 - hoursAgo * 3600
        var record = AgentSessionRecord(
            schemaVersion: 1, agent: agent, sessionID: sessionID, startedAt: lastActivity - 60, lastStartAt: lastActivity - 60,
            lastActivityAt: lastActivity, endedAt: lastActivity, status: .idle, hasConversation: true
        )
        record.name = title
        record.cwd = folder
        record.workspaceID = workspaceID
        record.checkout = checkout
        return record
    }

    /// Writes the current space's history and has the shell read it again.
    static func seed(_ records: [AgentSessionRecord], in harness: UIFlowHarness) throws {
        let url = try XCTUnwrap(AgentSessionLedger.fileURL(
            spaceID: harness.shell.activeProfileID, stateDirectory: Persistence.stateDirectory
        ))
        XCTAssertTrue(url.path.hasPrefix(harness.stateDirectory))
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        let lines = try records.map { String(decoding: try encoder.encode($0), as: UTF8.self) + "\n" }
        try lines.joined().write(to: url, atomically: true, encoding: .utf8)
        harness.shell.sessionLedger = AgentSessionLedger()
    }

    /// Opens ⌘P, types `title` and picks its row with the arrow keys and
    /// Return.
    private func resumeFromPalette(_ title: String, in harness: UIFlowHarness) throws {
        if harness.shell.commandPalette?.isVisible == true { harness.shell.commandPalette?.dismiss() }
        harness.shell.showCommandPalette()
        let palette = try XCTUnwrap(harness.shell.commandPalette)
        harness.type(title, into: try XCTUnwrap(palette.searchField))
        let position = try XCTUnwrap(palette.filteredActions.firstIndex { $0.title == title }, "no row \(title)")
        for _ in 0..<position { harness.press(.down, in: palette.panel) }
        XCTAssertEqual(palette.filteredActions[safe: palette.selectedIndex]?.title, title)
        harness.press(.returnKey, in: palette.panel)
        XCTAssertFalse(palette.isVisible)
    }

    private func headers(_ palette: CommandPalette) -> [String] {
        palette.listLayout.items.compactMap {
            if case .header(let title) = $0 { return title }
            return nil
        }
    }

    func testPastSessionsResumeInTheirWorkspaceUnlessAColumnHoldsThem() throws {
        try UIFlowHarness.run { harness in
            let shell = harness.shell
            let workspace = try XCTUnwrap(shell.activeWorkspace)
            let flow = Self.session(
                Self.flowID, title: "feat/flow", folder: harness.worktree, workspaceID: workspace.id,
                checkout: AgentSessionRecord.Checkout(branch: "feat/flow", worktreeRoot: harness.worktree, mainCheckout: harness.repo),
                hoursAgo: 2
            )
            let codex = Self.session(Self.codexID, title: "codex-task", folder: harness.worktree, agent: .codex, workspaceID: workspace.id)
            let restored = Self.session(Self.restoredID, title: "restored-task", folder: harness.repo)
            var unprompted = Self.session(Self.emptyID, title: "empty-task", folder: harness.repo)
            unprompted.hasConversation = false
            // Hand-edited: not an id a launch line may hold.
            let forged = Self.session("--dangerously-skip-permissions", title: "forged-task", folder: harness.repo)
            try Self.seed([flow, codex, restored, unprompted, forged], in: harness)
            workspace.addColumn(
                deferredAgent: DeferredAgentLaunch(agent: .claude(resume: .session(Self.restoredID), mode: .default), title: nil, lastStatus: nil),
                agentUUID: UUID().uuidString, cwd: harness.repo
            )
            let restoredColumn = try XCTUnwrap(workspace.columns[safe: workspace.focusedIndex])

            // Ended and prompted sessions no column holds, most recent first.
            harness.shell.showCommandPalette()
            let palette = try XCTUnwrap(shell.commandPalette)
            XCTAssertEqual(headers(palette), ["Commands", "Workspaces", "Sessions"])
            XCTAssertEqual(palette.filteredActions.suffix(2).map(\.title), ["codex-task", "feat/flow"])
            XCTAssertFalse(palette.filteredActions.contains { $0.title == "forged-task" })
            XCTAssertEqual(palette.filteredActions.last?.subtitle, "2 h ago · \(harness.worktree.abbreviatedPath())")
            palette.dismiss()
            shell.resumeSession(forged, spaceID: shell.activeProfileID)
            XCTAssertEqual(shell.toast?.message, "This session’s id can’t be resumed")
            XCTAssertEqual(shell.sessionResume.inFlight, [])

            // A restored column resumes its own session. Before the run loop
            // turns: once on screen, it would resume by itself.
            workspace.focusedIndex = 0
            shell.resumeSession(restored, spaceID: shell.activeProfileID)
            XCTAssertIdentical(workspace.columns[safe: workspace.focusedIndex], restoredColumn)
            XCTAssertEqual(harness.restoredAgentLaunches.count, 1)
            XCTAssertTrue(harness.restoredAgentLaunches[0].hasPrefix("command claude --resume '\(Self.restoredID)'"))
            XCTAssertFalse(restoredColumn.isAwaitingResume)

            // Its folder still has its branch: a new column there, at once.
            let columnCount = workspace.columns.count
            try resumeFromPalette("feat/flow", in: harness)
            harness.waitUntil("the resume") { harness.agentLaunches.count == 1 }
            XCTAssertTrue(harness.agentLaunches[0].hasPrefix("command claude --resume '\(Self.flowID)'"), harness.agentLaunches[0])
            XCTAssertEqual(workspace.columns.count, columnCount + 1)
            XCTAssertIdentical(shell.activeWorkspace, workspace)
            let resumed = try XCTUnwrap(workspace.columns[safe: workspace.focusedIndex])
            XCTAssertEqual(resumed.launchDirectory, harness.worktree)

            // Its agent isn't a process yet: picking it again goes there.
            workspace.focusedIndex = 0
            shell.resumeSession(flow, spaceID: shell.activeProfileID)
            XCTAssertIdentical(workspace.columns[safe: workspace.focusedIndex], resumed)
            XCTAssertEqual(harness.agentLaunches.count, 1)

            // Codex is told the folder, or it would ask.
            shell.resumeSession(codex, spaceID: shell.activeProfileID)
            harness.waitUntil("the Codex resume") { harness.agentLaunches.count == 2 }
            XCTAssertTrue(
                harness.agentLaunches[1].hasPrefix("command codex resume '\(Self.codexID)' -C '\(harness.worktree)'"),
                harness.agentLaunches[1]
            )
            // Saved with its thread before its first turn, as a restore is.
            let codexColumn = try XCTUnwrap(workspace.columns[safe: workspace.focusedIndex])
            let launched = ForegroundProcess(
                instance: ProcessInstance(pid: 4242, startedAt: 1), name: "codex",
                arguments: ["codex", "resume", Self.codexID, "-C", harness.worktree]
            )
            XCTAssertEqual(codexColumn.persistedCodexSessionID(foregroundProcess: launched), Self.codexID)
        }
    }

    /// Its worktree was cleaned up, its workspace closed: the worktree
    /// comes back on its branch, without a question, in a new workspace,
    /// where the next session of that worktree resumes too.
    func testACleanedUpWorktreeComesBackInANewWorkspace() throws {
        try UIFlowHarness.run { harness in
            let gone = harness.root + "/repo.feat-gone"
            try UIFlowHarness.git(["worktree", "add", "-q", "-b", "feat/gone", gone], at: harness.repo)
            try UIFlowHarness.git(["worktree", "remove", gone], at: harness.repo)
            let checkout = AgentSessionRecord.Checkout(branch: "feat/gone", worktreeRoot: gone, mainCheckout: harness.repo)
            let sibling = Self.session(
                Self.siblingID, title: "gone-task", folder: gone, workspaceID: "closed-workspace", checkout: checkout, hoursAgo: 3
            )
            try Self.seed([
                Self.session(Self.goneID, title: "gone-task", folder: gone, workspaceID: "closed-workspace", checkout: checkout),
                sibling
            ], in: harness)
            let workspaceCount = harness.shell.workspaces.count

            try resumeFromPalette("gone-task", in: harness)
            harness.waitUntil("the resume") { harness.agentLaunches.count == 1 }
            XCTAssertEqual(harness.alerts, [])
            XCTAssertEqual(GitWorktree.currentBranch(at: gone), "feat/gone")
            XCTAssertEqual(harness.shell.workspaces.count, workspaceCount + 1)
            let workspace = try XCTUnwrap(harness.shell.activeWorkspace)
            XCTAssertEqual(workspace.title, "gone-task")
            XCTAssertEqual(workspace.cwd, gone)
            XCTAssertTrue(harness.agentLaunches[0].hasPrefix("command claude --resume '\(Self.goneID)'"))
            XCTAssertEqual(harness.shell.toast?.message, "The worktree is back at \(gone.abbreviatedPath())")

            harness.shell.resumeSession(sibling, spaceID: harness.shell.activeProfileID)
            harness.waitUntil("the second resume") { harness.agentLaunches.count == 2 }
            XCTAssertEqual(harness.shell.workspaces.count, workspaceCount + 1)
            XCTAssertEqual(workspace.columns.count, 2)
            XCTAssertTrue(harness.agentLaunches[1].hasPrefix("command claude --resume '\(Self.siblingID)'"))
        }
    }

    /// The history has a session running in a column whose agent no longer
    /// shows it (its binding dropped after a `^Z`): the panel lists it as
    /// open there, and Return goes to that column rather than starting it
    /// again.
    func testASessionTheHistoryHasRunningGoesToItsColumn() throws {
        try UIFlowHarness.run { harness in
            let shell = harness.shell
            let workspace = try XCTUnwrap(shell.activeWorkspace)
            let column = try XCTUnwrap(workspace.columns.first)
            // First, and its refresh with it: with no real agent in the
            // column, a refresh would end the session.
            shell.addColumn()
            XCTAssertNotIdentical(workspace.columns[safe: workspace.focusedIndex], column)
            let now = Date().timeIntervalSince1970
            for (event, source, at) in [(AgentHookEvent.Name.sessionStart, "startup", now - 60), (.userPromptSubmit, nil, now - 30)] {
                shell.sessionLedger.record(AgentSessionObservation(
                    agent: .claude, sessionID: Self.flowID, event: event, source: source, timestamp: at,
                    agentProcess: ProcessInstance(pid: 4242, startedAt: 1), name: "live-task", cwd: harness.repo,
                    transcriptPath: nil, checkout: nil, pullRequest: nil, workspaceID: workspace.id,
                    workspaceTitle: workspace.title, agentUUID: column.agentUUID, columnIndex: 0
                ), spaceID: shell.activeProfileID)
            }

            shell.showSessionHistory()
            let panel = try XCTUnwrap(shell.sessionHistoryPanel)
            XCTAssertEqual(panel.items, [.header("Open"), .row(0)])
            harness.press(.returnKey, in: panel.searchField?.window)
            XCTAssertIdentical(workspace.columns[safe: workspace.focusedIndex], column)
            XCTAssertEqual(harness.agentLaunches, [])
        }
    }

    /// Two sessions of one cleaned-up worktree, resumed at once: both plan
    /// to bring it back, the second finds it back and resumes there.
    func testTwoResumesOfOneWorktreeBringItBackOnce() throws {
        try UIFlowHarness.run { harness in
            let gone = harness.root + "/repo.feat-gone"
            try UIFlowHarness.git(["worktree", "add", "-q", "-b", "feat/gone", gone], at: harness.repo)
            try UIFlowHarness.git(["worktree", "remove", gone], at: harness.repo)
            let checkout = AgentSessionRecord.Checkout(branch: "feat/gone", worktreeRoot: gone, mainCheckout: harness.repo)
            let first = Self.session(Self.goneID, title: "gone-task", folder: gone, workspaceID: "closed-workspace", checkout: checkout)
            let second = Self.session(Self.siblingID, title: "gone-task", folder: gone, workspaceID: "closed-workspace", checkout: checkout)
            try Self.seed([first, second], in: harness)
            let workspaceCount = harness.shell.workspaces.count

            harness.shell.resumeSession(first, spaceID: harness.shell.activeProfileID)
            harness.shell.resumeSession(second, spaceID: harness.shell.activeProfileID)
            harness.waitUntil("both resumes") { harness.agentLaunches.count == 2 }
            XCTAssertEqual(harness.shell.workspaces.count, workspaceCount + 1)
            XCTAssertEqual(harness.shell.activeWorkspace?.columns.count, 2)
            XCTAssertEqual(harness.alerts, [])
            // One checkout, whole: two `worktree add` at once break it.
            XCTAssertEqual(GitWorktree.currentBranch(at: gone), "feat/gone")
            XCTAssertEqual(try UIFlowHarness.git(["status", "--porcelain"], at: gone), "")
            XCTAssertEqual(harness.shell.toast?.message, "The worktree is back at \(gone.abbreviatedPath())")
        }
    }

    /// A post-checkout hook that fails leaves the worktree behind: it
    /// resumes there, and git's error shows.
    func testAFailingCheckoutHookStillResumes() throws {
        try UIFlowHarness.run { harness in
            let hooks = harness.root + "/hooks"
            try FileManager.default.createDirectory(atPath: hooks, withIntermediateDirectories: true)
            try "#!/bin/sh\necho hook-refused >&2\nexit 3\n".write(toFile: hooks + "/post-checkout", atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hooks + "/post-checkout")
            let gone = harness.root + "/repo.feat-gone"
            try UIFlowHarness.git(["worktree", "add", "-q", "-b", "feat/gone", gone], at: harness.repo)
            try UIFlowHarness.git(["worktree", "remove", gone], at: harness.repo)
            try UIFlowHarness.git(["config", "core.hooksPath", hooks], at: harness.repo)
            let checkout = AgentSessionRecord.Checkout(branch: "feat/gone", worktreeRoot: gone, mainCheckout: harness.repo)
            try Self.seed([Self.session(Self.goneID, title: "gone-task", folder: gone, checkout: checkout)], in: harness)

            try resumeFromPalette("gone-task", in: harness)
            harness.waitUntil("the resume") { harness.agentLaunches.count == 1 }
            XCTAssertEqual(harness.shell.toast?.message, "The worktree is back, but git reported: hook-refused")
            XCTAssertEqual(harness.shell.activeWorkspace?.cwd, gone)
        }
    }

    /// Resuming in the main checkout asks first; a session whose
    /// transcript is gone says so.
    func testAResumeElsewhereAsksFirst() throws {
        try UIFlowHarness.run { harness in
            let lost = Self.session(
                Self.lostID, title: "lost-task", folder: harness.root + "/repo.feat-lost",
                checkout: AgentSessionRecord.Checkout(
                    branch: "feat/lost", worktreeRoot: harness.root + "/repo.feat-lost", mainCheckout: harness.repo
                )
            )
            var forgotten = Self.session(Self.forgottenID, title: "forgotten-task", folder: harness.repo)
            forgotten.transcriptPath = harness.root + "/missing.jsonl"
            try Self.seed([lost, forgotten], in: harness)
            let workspaceCount = harness.shell.workspaces.count

            // Return answers Cancel, the first button.
            try resumeFromPalette("lost-task", in: harness)
            harness.waitUntil("the question") { harness.alerts.count == 1 }
            XCTAssertEqual(harness.alerts, ["Resume “lost-task”?"])
            harness.waitUntil("the cancel") { harness.shell.sessionResume.inFlight.isEmpty }
            XCTAssertEqual(harness.agentLaunches, [])

            harness.alertResponses = [.alertSecondButtonReturn]
            try resumeFromPalette("lost-task", in: harness)
            harness.waitUntil("the resume") { harness.agentLaunches.count == 1 }
            XCTAssertEqual(harness.alerts.count, 2)
            // The workspace open on the main checkout takes it.
            XCTAssertEqual(harness.shell.workspaces.count, workspaceCount)
            let workspace = try XCTUnwrap(harness.shell.activeWorkspace)
            XCTAssertEqual(workspace.cwd, harness.repo)
            XCTAssertEqual(workspace.columns[safe: workspace.focusedIndex]?.launchDirectory, harness.repo)
            XCTAssertEqual(workspace.columns.count, 2)

            try resumeFromPalette("forgotten-task", in: harness)
            let message = SessionHistory.message(.transcriptGone, agent: .claude)
            harness.waitUntil("the toast") { harness.shell.toast?.message == message }
            XCTAssertEqual(harness.agentLaunches.count, 1)
        }
    }
}
