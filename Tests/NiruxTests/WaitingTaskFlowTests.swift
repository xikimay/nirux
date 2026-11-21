import AppKit
import XCTest
@testable import Nirux

@MainActor
final class WaitingTaskFlowTests: XCTestCase {
    private func pullRequest(_ state: String) -> PRInfo {
        PRInfo(number: 42, state: state, isDraft: false, ciStatus: nil, checks: [], reviewDecision: nil,
               mergeable: nil, url: "https://github.com/o/r/pull/42", additions: nil, deletions: nil, changedFiles: nil)
    }

    private func upstreamTask(_ title: String, lead: UIFlowHarness.Lead, in harness: UIFlowHarness) throws -> WorkspaceState {
        harness.shell.addWorkspace(title: title, cwd: harness.worktree, profileID: lead.space, activate: false)
        return try XCTUnwrap(harness.shell.workspaces.first { $0.title == title })
    }

    private func start(
        _ title: String, after: String, template: String? = nil, lead: UIFlowHarness.Lead, in harness: UIFlowHarness
    ) throws -> WorkspaceState {
        var arguments = ["description": title]
        arguments["after"] = after
        arguments["template"] = template
        let result = try harness.callLeadTool(LeadTools.startTask, arguments, lead: lead)
        XCTAssertFalse(result.isError, "\(title): \(result.text)")
        return try XCTUnwrap(harness.shell.workspaces.first { $0.title == title })
    }

    func testMergeStartsTheRestoredRowFromTheNewRemoteTipOnce() throws {
        try UIFlowHarness.run { harness in
            let shell = harness.shell
            let lead = try harness.makeLead()
            let git = { (arguments: [String]) in try UIFlowHarness.git(arguments, at: harness.repo) }
            _ = try git(["remote", "add", "origin", harness.repo])
            _ = try git(["fetch", "origin", "main:refs/remotes/origin/main"])
            let upstream = try upstreamTask("Prepare catalog", lead: lead, in: harness)
            shell.refreshGitContextNow(for: upstream)
            harness.waitUntil("the upstream branch") { upstream.gitBranch != nil }
            upstream.prInfo = pullRequest("OPEN")
            let branches = try git(["branch", "--list"])
            let launched = harness.agentLaunches.count
            let task = try start("Publish catalog", after: upstream.title, template: "Bugfix", lead: lead, in: harness)
            XCTAssertEqual(try git(["branch", "--list"]), branches)
            XCTAssertEqual(harness.agentLaunches.count, launched)
            XCTAssertNil(task.missionID)
            XCTAssertFalse(FileManager.default.fileExists(atPath: task.cwd))
            XCTAssertFalse(NiruxShellView.isTask(task))
            let row = try XCTUnwrap(shell.sidebar.lastInfos.first { $0.id == task.id })
            XCTAssertEqual(row.rowSummary.mark, .blocked)
            XCTAssertTrue(row.rowSummary.status.text.contains("#42"))
            XCTAssertTrue(try harness.callLeadTool(LeadTools.tell, ["task": task.title, "message": "go"], lead: lead).isError)
            XCTAssertNil(shell.worktreeCleanupOffer(workspaceIndex: row.index))
            XCTAssertFalse(shell.worktreeCleanupCandidates().contains { $0.path == task.cwd || $0.workspaceIDs.contains(task.id) })
            XCTAssertNotNil(shell.sidebar.workspaceActionMenu(workspaceIndex: row.index, columnIndex: nil).item(withTitle: "Start Now"))
            XCTAssertTrue(try harness.callLeadTool(LeadTools.listTasks, lead: lead).text.contains(row.rowSummary.status.text))
            XCTAssertEqual(shell.persistedState().workspaces.first { $0.id == task.id }?.columns.count, 0)
            shell.saveState()
            shell.restoreState()
            let restored = try XCTUnwrap(shell.workspaces.first { $0.id == task.id })
            XCTAssertEqual(restored.mergeWaits, task.mergeWaits)
            restored.addColumn()
            XCTAssertEqual(restored.columns.count, 1)
            XCTAssertNil(restored.columns.first?.pty)
            let view = try XCTUnwrap(restored.columns.first?.waitingTask)
            XCTAssertEqual(view.facts?.description, task.title)
            XCTAssertEqual(view.facts?.state, row.waitingTask)
            _ = try git(["-c", "user.name=Test", "-c", "user.email=test@example.com", "commit", "--allow-empty", "-m", "merged"])
            let tip = try git(["rev-parse", "HEAD"])
            let oldTip = try git(["rev-parse", "refs/remotes/origin/main"])
            XCTAssertNotEqual(tip, oldTip)
            let source = try XCTUnwrap(shell.workspaces.first { $0.id == upstream.id })
            let beforeMerge = harness.agentLaunches.count
            for _ in 0..<2 { shell.followMergeWaits(awaiting: source, read: pullRequest("MERGED"), now: 41) }
            harness.waitUntil("the waiting row to launch", timeout: 30) { !restored.isWaitingTask }
            XCTAssertEqual(harness.agentLaunches.count, beforeMerge + 1)
            XCTAssertEqual(try UIFlowHarness.git(["rev-parse", "HEAD"], at: restored.cwd), tip)
            XCTAssertEqual(restored.columns.count, 1)
            XCTAssertNil(restored.columns.first?.waitingTask)
            let mission = try XCTUnwrap(MissionStore.shared.missions.first { $0.id == restored.missionID })
            XCTAssertEqual(mission.parentWorkspaceID, lead.workspace.id)
            XCTAssertEqual(mission.childWorkspaceID, task.id)
            XCTAssertEqual(restored.columns.first?.agentUUID, mission.childAgentUUID)
            let handover = try String(contentsOfFile: restored.cwd + "/.claude-handover.md", encoding: .utf8)
            XCTAssertTrue(handover.contains("Started after #42"), handover)
            XCTAssertTrue(handover.contains(task.title))
            XCTAssertTrue(handover.contains(try XCTUnwrap(TaskTemplates.defaults.first { $0.name == "Bugfix" }).body))
        }
    }

    func testInterruptedStartAndMissingRepositoryStayActionableAfterRestore() throws {
        try UIFlowHarness.run { harness in
            let shell = harness.shell
            let lead = try harness.makeLead()
            let upstream = try upstreamTask("Add accounts", lead: lead, in: harness)
            let task = try start("List accounts", after: upstream.title, lead: lead, in: harness)
            var state = try XCTUnwrap(Persistence.load())
            let index = try XCTUnwrap(state.workspaces.firstIndex { $0.id == task.id })
            state.workspaces[index].mergeWaits?[0].startingBranch = "feat/list-accounts"
            XCTAssertTrue(Persistence.save(state))
            let count = harness.agentLaunches.count
            shell.restoreState()
            let restored = try XCTUnwrap(shell.workspaces.first { $0.id == task.id })
            XCTAssertTrue(restored.waitingStart?.failure?.contains("feat/list-accounts") == true)
            XCTAssertEqual(count, harness.agentLaunches.count)
            XCTAssertNotNil(try XCTUnwrap(Persistence.load()).workspaces.first { $0.id == task.id }?.mergeWaits?.first?.failure)
            var spaces = shell.profiles
            let space = try XCTUnwrap(spaces.firstIndex { $0.id == lead.space })
            spaces[space].anchors = []
            shell.workspaceStore.replaceProfiles(spaces, activeProfileID: lead.space)
            shell.startWaitingTask(restored)
            XCTAssertTrue(restored.waitingStart?.failure?.contains("left the space") == true)
            shell.sweepMergeWaits(now: Date().timeIntervalSince1970 + MergeWait.deliveryLifetime)
            XCTAssertTrue(restored.isWaitingTask)
            XCTAssertNil(restored.missionID)
            XCTAssertEqual(count, harness.agentLaunches.count)
        }
    }

    func testFailedDependencyCanBeRepointedOrStartedManually() throws {
        try UIFlowHarness.run { harness in
            let shell = harness.shell
            let lead = try harness.makeLead()
            let upstream = try upstreamTask("Prepare schema", lead: lead, in: harness)
            let task = try start("Update schema", after: upstream.title, lead: lead, in: harness)
            let downstream = try start("Ship schema", after: task.title, lead: lead, in: harness)
            let change = { (args: [String: Any]) in try harness.callLeadTool(LeadTools.setTaskAfter, args, lead: lead) }
            XCTAssertTrue(try change(["task": task.title, "after": downstream.title]).isError)
            XCTAssertTrue(try change(["task": task.title, "after": task.title]).isError)
            XCTAssertTrue(try change(["task": task.title, "after": 123]).isError)
            XCTAssertEqual(task.waitingStart?.awaited.workspaceID, upstream.id)
            shell.followMergeWaits(awaiting: upstream, read: pullRequest("CLOSED"), now: 100)
            let failed = try XCTUnwrap(shell.sidebar.lastInfos.first { $0.id == task.id })
            XCTAssertEqual(failed.rowSummary.status.tone, .needsYou)
            XCTAssertTrue(failed.rowSummary.status.text.contains("#42"))
            XCTAssertFalse(shell.awaitedWorkspaceIDs.contains(upstream.id))
            XCTAssertTrue(shell.pendingLeadNotices.contains { $0.text.contains("#42") && $0.text.contains(task.title) })
            let other = try start("Prepare API", after: upstream.title, lead: lead, in: harness)
            XCTAssertFalse(try change(["task": task.title, "after": other.title]).isError)
            XCTAssertNil(task.waitingStart?.failure)
            XCTAssertEqual(task.waitingStart?.awaited.workspaceID, other.id)
            let close = try harness.callLeadTool(LeadTools.closeTask, ["task": other.title], lead: lead)
            XCTAssertFalse(close.isError, close.text)
            XCTAssertTrue(task.waitingStart?.failure?.contains("without a merged pull request") == true)

            // A cached remote branch exists, but fetching its new tip fails.
            _ = try UIFlowHarness.git(["remote", "add", "origin", harness.root + "/missing-remote"], at: harness.repo)
            _ = try UIFlowHarness.git(["update-ref", "refs/remotes/origin/main", "HEAD"], at: harness.repo)
            let launches = harness.agentLaunches.count
            XCTAssertFalse(try change(["task": task.title]).isError)
            harness.waitUntil("fetch failure", timeout: 30) { task.waitingStart?.failure?.contains("fetch") == true }
            XCTAssertEqual(launches, harness.agentLaunches.count)
            XCTAssertEqual(try UIFlowHarness.git(["branch", "--list", "feat/update-schema"], at: harness.repo), "")
            _ = try UIFlowHarness.git(["remote", "set-url", "origin", harness.repo], at: harness.repo)
            let column = try XCTUnwrap(task.columns.first?.waitingTask)
            let occupied = harness.repo + ".feat-update-schema"
            try FileManager.default.createDirectory(atPath: occupied, withIntermediateDirectories: true)
            column.startButton.performClick(nil)
            harness.waitUntil("the occupied worktree path", timeout: 30) { task.waitingStart?.failure?.contains(occupied) == true }
            XCTAssertEqual(harness.agentLaunches.count, launches)
            try FileManager.default.removeItem(atPath: occupied)
            column.startButton.performClick(nil)
            harness.waitUntil("Start Now makes its worktree", timeout: 30) { !task.isWaitingTask }
            XCTAssertEqual(harness.agentLaunches.count, launches + 1)
            XCTAssertEqual(downstream.waitingStart?.awaited.workspaceID, task.id)
            XCTAssertFalse(try harness.callLeadTool(LeadTools.closeTask, ["task": downstream.title], lead: lead).isError)
            XCTAssertTrue(downstream.isClosing || !shell.workspaces.contains { $0 === downstream })

            shell.setLeadStartsTasks(false, spaceID: lead.space)
            let refused = try harness.callLeadTool(LeadTools.startTask, ["description": "Later", "after": task.title], lead: lead)
            XCTAssertTrue(refused.isError)
            XCTAssertNil(shell.newTaskPanel)
        }
    }
}
