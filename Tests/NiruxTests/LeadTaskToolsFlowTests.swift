import AppKit
import XCTest
@testable import Nirux

/// The Lead tidies its space (NiruxShellView+LeadTaskTools), in a real
/// window on throwaway state (see UIFlowHarness): close_task closes any
/// task of the space and cleans up a merged one with Clean Up Worktree…'s
/// checks; move_task moves one among its siblings.
@MainActor
final class LeadTaskToolsFlowTests: XCTestCase {
    /// A stub gh answering each branch's pull requests from
    /// `<root>/prs/<branch, "/" as "-">.json`, and a Trash of the test's
    /// own, returned.
    private func stubCleanupTools(_ harness: UIFlowHarness) throws -> String {
        let gh = harness.root + "/gh"
        try """
        #!/bin/sh
        for arg in "$@"; do case "$arg" in --head=*) branch="${arg#--head=}";; esac; done
        file="$(dirname "$0")/prs/$(printf '%s' "$branch" | tr '/' '-').json"
        if [ -f "$file" ]; then cat "$file"; else echo '[]'; fi
        """.write(toFile: gh, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: gh)
        try FileManager.default.createDirectory(atPath: harness.root + "/prs", withIntermediateDirectories: true)
        var tools = WorktreeCleanup.Tools(ghPath: gh, timeout: 30)
        let trash = harness.root + "/Trash"
        tools.trash = { url in
            try FileManager.default.createDirectory(atPath: trash, withIntermediateDirectories: true)
            let target = URL(fileURLWithPath: trash).appendingPathComponent(url.lastPathComponent)
            try FileManager.default.moveItem(at: url, to: target)
            return target
        }
        harness.shell.worktreeCleanupTools = tools
        return trash
    }

    /// close_task closes the Lead's tasks and the user's: a merged one's
    /// worktree and branch go, as Clean Up Worktree… does once confirmed;
    /// an unmerged one's stay, and the answer says why. Never a main
    /// checkout, a task with sub-tasks, or another space's workspace.
    func testTheLeadClosesTasksAndCleansUpMergedOnes() throws {
        try UIFlowHarness.run { harness in
            let shell = harness.shell
            let lead = try harness.makeLead()
            _ = try stubCleanupTools(harness)
            // Pushed to GitHub as gh sees it, its pull request merged.
            let merged = harness.root + "/repo.feat-merged"
            try UIFlowHarness.git(["worktree", "add", "-q", "-b", "feat/merged", merged], at: harness.repo)
            try UIFlowHarness.git(
                ["-c", "user.name=Test", "-c", "user.email=test@example.com", "commit", "-q", "--allow-empty", "-m", "work"], at: merged
            )
            try UIFlowHarness.git(["remote", "add", "acme", "https://github.com/acme/widgets.git"], at: harness.repo)
            try UIFlowHarness.git(["config", "branch.feat/merged.pushRemote", "acme"], at: harness.repo)
            let tip = try UIFlowHarness.git(["rev-parse", "HEAD"], at: merged).trimmingCharacters(in: .whitespacesAndNewlines)
            let pullRequest: [String: Any] = [
                "number": 7, "state": "MERGED", "headRefOid": tip, "url": "https://github.com/acme/widgets/pull/7",
                "headRepositoryOwner": ["login": "acme"], "headRepository": ["name": "widgets"]
            ]
            try JSONSerialization.data(withJSONObject: [pullRequest])
                .write(to: URL(fileURLWithPath: harness.root + "/prs/feat-merged.json"))

            shell.addWorkspace(title: "Merged work", cwd: merged, profileID: lead.space)
            let mergedTask = try XCTUnwrap(shell.workspaces.first { $0.title == "Merged work" })
            shell.addWorkspace(title: "Flow work", cwd: harness.worktree, profileID: lead.space, parentWorkspaceID: mergedTask.id)
            let flowTask = try XCTUnwrap(shell.workspaces.first { $0.title == "Flow work" })
            shell.addWorkspace(title: "Checkout", cwd: harness.repo, profileID: lead.space)
            let close = { (task: String) in try harness.callLeadTool(LeadTools.closeTask, ["task": task], lead: lead) }

            let itself = try close("Lead")
            XCTAssertTrue(itself.isError, itself.text)
            let elsewhere = try close("repo")
            XCTAssertTrue(elsewhere.text.hasPrefix("No task in Tools is named “repo”"), elsewhere.text)
            let checkout = try close("Checkout")
            XCTAssertTrue(checkout.isError)
            XCTAssertTrue(checkout.text.contains("isn't a task"), checkout.text)
            let parent = try close("Merged work")
            XCTAssertTrue(parent.isError)
            XCTAssertTrue(parent.text.contains("still has sub-tasks (“Flow work”)"), parent.text)
            XCTAssertEqual(shell.workspaces.filter { $0.profileID == lead.space && !$0.isClosing }.count, 4, "nothing closed")

            // Not merged (not even pushed): it closes, its worktree and branch stay.
            let unmerged = try close("Flow work")
            XCTAssertFalse(unmerged.isError, unmerged.text)
            XCTAssertTrue(unmerged.text.hasPrefix("Closed “Flow work”. Its worktree and branch stay: feat/flow isn't pushed"), unmerged.text)
            harness.waitUntil("the unmerged task to close") { !shell.workspaces.contains { $0 === flowTask } }
            XCTAssertTrue(FileManager.default.fileExists(atPath: harness.worktree))

            // Its agent's turn runs: never closed under it; once over, it may be.
            let agent = AgentStandIn()
            defer { agent.remove() }
            let agentUUID = UUID().uuidString
            mergedTask.addColumn(command: agent.command(), agentUUID: agentUUID, cwd: merged)
            let pty = try XCTUnwrap(mergedTask.columns.first { $0.agentUUID == agentUUID }?.pty)
            harness.waitUntil("its claude") { pty.foregroundProcess(snapshot: ProcessSnapshot())?.name == "claude" }
            let claude = try XCTUnwrap(pty.foregroundProcess(snapshot: ProcessSnapshot())).instance
            @MainActor func hook(_ name: AgentHookEvent.Name) {
                _ = pty.applyAgentHook(AgentHookEvent(
                    kind: .claude, name: name, agentUUID: agentUUID, sessionID: "task", emitterProcess: claude,
                    timestamp: Date().timeIntervalSince1970
                ), isUserFocused: false)
            }
            hook(.sessionStart)
            hook(.userPromptSubmit)
            let working = try close("Merged work")
            XCTAssertTrue(working.isError)
            XCTAssertTrue(working.text.contains("agent is working"), working.text)
            hook(.stop)

            // Merged: its worktree and branch go with it.
            let cleaned = try close("Merged work")
            XCTAssertFalse(cleaned.isError, cleaned.text)
            XCTAssertTrue(cleaned.text.hasPrefix("Closed “Merged work” and cleaned it up (pull request #7 merged)"), cleaned.text)
            harness.waitUntil("the merged task to close") { !shell.workspaces.contains { $0 === mergedTask } }
            XCTAssertFalse(FileManager.default.fileExists(atPath: merged))
            XCTAssertEqual(try UIFlowHarness.git(["branch", "--list", "feat/merged"], at: harness.repo), "")
            XCTAssertNotEqual(try UIFlowHarness.git(["branch", "--list", "feat/flow"], at: harness.repo), "")
        }
    }

    /// A task without a repository: it closes, and its folder goes to the
    /// Trash, where the user can put it back, unless another workspace is
    /// open in it.
    func testClosingATaskWithoutARepositoryTrashesItsFolder() throws {
        try UIFlowHarness.run { harness in
            let shell = harness.shell
            let lead = try harness.makeLead()
            let trash = try stubCleanupTools(harness)
            for description in ["Compare two parsers", "Draft the notes"] {
                let started = try harness.callLeadTool(LeadTools.startTask, ["description": description, "repo": "none"], lead: lead)
                XCTAssertFalse(started.isError, started.text)
            }
            let parsers = try XCTUnwrap(shell.workspaces.first { $0.title == "Compare two parsers" })
            let folder = try XCTUnwrap(parsers.taskFolder)
            let notes = try XCTUnwrap(shell.workspaces.first { $0.title == "Draft the notes" })
            let notesFolder = try XCTUnwrap(notes.taskFolder)
            shell.addWorkspace(title: "Peek", cwd: notesFolder, profileID: lead.space)

            let trashed = try harness.callLeadTool(LeadTools.closeTask, ["task": "Compare two parsers"], lead: lead)
            XCTAssertFalse(trashed.isError, trashed.text)
            XCTAssertTrue(trashed.text.contains("moved its folder to the Trash"), trashed.text)
            harness.waitUntil("its folder to go to the Trash") { !FileManager.default.fileExists(atPath: folder) }
            XCTAssertTrue(FileManager.default.fileExists(atPath: trash + "/Compare two parsers/.claude-handover.md"))
            harness.waitUntil("the task to close") { !shell.workspaces.contains { $0 === parsers } }

            let kept = try harness.callLeadTool(LeadTools.closeTask, ["task": "Draft the notes"], lead: lead)
            XCTAssertFalse(kept.isError, kept.text)
            XCTAssertEqual(kept.text, "Closed “Draft the notes”. Its folder stays (\(notesFolder)): Other workspaces are open in it: “Peek”.")
            harness.waitUntil("the second task to close") { !shell.workspaces.contains { $0 === notes } }
            XCTAssertTrue(FileManager.default.fileExists(atPath: notesFolder))
        }
    }

    /// move_task moves a task among its siblings in the Lead's space while
    /// the user is in another one: the Lead stays first, a sub-task under
    /// its task, and a task's sub-tasks follow it.
    func testTheLeadMovesTasksAmongTheirSiblings() throws {
        try UIFlowHarness.run { harness in
            let shell = harness.shell
            let lead = try harness.makeLead()
            // A task (a worktree) can have sub-tasks.
            shell.addWorkspace(title: "One", cwd: harness.worktree, profileID: lead.space)
            for title in ["Two", "Three"] { shell.addWorkspace(title: title, cwd: harness.repo, profileID: lead.space) }
            let one = try XCTUnwrap(shell.workspaces.first { $0.title == "One" })
            shell.addWorkspace(title: "Sub", cwd: harness.repo, profileID: lead.space, parentWorkspaceID: one.id)
            let titles = { shell.workspaceStore.visibleWorkspaceIndices(in: lead.space).map { shell.workspaces[$0].title } }
            XCTAssertEqual(titles(), ["Lead", "One", "Sub", "Two", "Three"])
            let elsewhere = try XCTUnwrap(shell.workspaces.first { $0.profileID != lead.space })
            shell.workspaceStore.selectWorkspace(id: elsewhere.id)
            let move = { (task: String, position: Int) in
                try harness.callLeadTool(LeadTools.moveTask, ["task": task, "position": position], lead: lead)
            }

            XCTAssertEqual(try move("Three", 1).text, "“Three” is 1 of 3 among the tasks of Tools.")
            XCTAssertEqual(titles(), ["Lead", "Three", "One", "Sub", "Two"])
            XCTAssertEqual(try move("One", 9).text, "“One” is 3 of 3 among the tasks of Tools.")
            XCTAssertEqual(titles(), ["Lead", "Three", "Two", "One", "Sub"], "its sub-task follows it")
            XCTAssertEqual(try move("Sub", 1).text, "“Sub” is 1 of 1 among the sub-tasks of “One”, as it was.")
            XCTAssertTrue(try move("Lead", 1).isError)
            XCTAssertTrue(try move("Two", 0).isError)
            XCTAssertEqual(titles(), ["Lead", "Three", "Two", "One", "Sub"])
            XCTAssertTrue(shell.activeWorkspace === elsewhere, "the user stays where they are")
        }
    }
}
