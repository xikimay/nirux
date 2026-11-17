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
        let stubbed = tools
        harness.shell.worktreeCleanupTools = { stubbed }
        return trash
    }

    /// A `claude` stand-in that `command` starts in a new column of
    /// `workspace`, its session begun: its terminal, and its hooks.
    private func startAgent(
        _ command: String, in workspace: WorkspaceState, harness: UIFlowHarness
    ) throws -> (pty: PtySession, hook: @MainActor (AgentHookEvent.Name) -> Void) {
        let agentUUID = UUID().uuidString
        workspace.addColumn(command: command, agentUUID: agentUUID, cwd: workspace.cwd)
        let pty = try XCTUnwrap(workspace.columns.first { $0.agentUUID == agentUUID }?.pty)
        harness.waitUntil("its claude") { pty.runningAgentName(snapshot: ProcessSnapshot()) == "claude" }
        let hook: @MainActor (AgentHookEvent.Name) -> Void = { name in
            _ = pty.applyAgentHook(AgentHookEvent(
                kind: .claude, name: name, agentUUID: agentUUID, sessionID: agentUUID,
                toolName: name == .permissionRequest ? "Bash" : nil, timestamp: Date().timeIntervalSince1970
            ), isUserFocused: false)
        }
        hook(.sessionStart)
        return (pty, hook)
    }

    /// Pushed to GitHub as gh sees it: a worktree of the harness's
    /// repository on `branch` in `folder`, one commit ahead, with a merged
    /// pull request holding its tip.
    private func mergedWorktree(_ branch: String, in folder: String, number: Int, harness: UIFlowHarness) throws {
        try UIFlowHarness.git(["worktree", "add", "-q", "-b", branch, folder], at: harness.repo)
        try UIFlowHarness.git(
            ["-c", "user.name=Test", "-c", "user.email=test@example.com", "commit", "-q", "--allow-empty", "-m", "work"], at: folder
        )
        try UIFlowHarness.git(["config", "branch.\(branch).pushRemote", "acme"], at: harness.repo)
        let tip = try UIFlowHarness.git(["rev-parse", "HEAD"], at: folder).trimmingCharacters(in: .whitespacesAndNewlines)
        let pullRequest: [String: Any] = [
            "number": number, "state": "MERGED", "headRefOid": tip, "url": "https://github.com/acme/widgets/pull/\(number)",
            "headRepositoryOwner": ["login": "acme"], "headRepository": ["name": "widgets"]
        ]
        try JSONSerialization.data(withJSONObject: [pullRequest])
            .write(to: URL(fileURLWithPath: harness.root + "/prs/" + branch.replacingOccurrences(of: "/", with: "-") + ".json"))
    }

    /// close_task never closes the Lead, another space's workspace, a main
    /// checkout, a task with sub-tasks, a name two workspaces answer, nor
    /// one whose terminals still work: a program, its agent's turn, an
    /// agent paused since a relaunch that was last seen working.
    func testCloseTaskRefusesWhatTheUserStillNeeds() throws {
        try UIFlowHarness.run { harness in
            let shell = harness.shell
            let lead = try harness.makeLead()
            let subFolder = harness.root + "/repo.feat-sub"
            try UIFlowHarness.git(["worktree", "add", "-q", "-b", "feat/sub", subFolder], at: harness.repo)
            for (title, cwd) in [
                ("Work", harness.worktree), ("Checkout", harness.repo), ("Peek", harness.worktree), ("Later", harness.worktree),
                ("Typed", harness.worktree), ("Wrapped", harness.worktree)
            ] {
                shell.addWorkspace(title: title, cwd: cwd, profileID: lead.space)
            }
            let named = { (title: String) in try XCTUnwrap(shell.workspaces.first { $0.title == title }) }
            let work = try named("Work")
            shell.addWorkspace(title: "Sub", cwd: subFolder, profileID: lead.space, parentWorkspaceID: work.id)
            let sub = try named("Sub")
            let refusal: (String, String) throws -> Void = { task, words in
                let answer = try harness.callLeadTool(LeadTools.closeTask, ["task": task], lead: lead)
                XCTAssertTrue(answer.isError, answer.text)
                XCTAssertTrue(answer.text.contains(words), answer.text)
            }

            // On screen, Nirux in front: the user may be typing in it.
            shell.sideEffects.appIsActive = { true }
            shell.workspaceStore.selectWorkspace(id: work.id)
            try refusal("Work", "The user has “Work” on screen")
            shell.sideEffects.appIsActive = { false }

            try refusal("Lead", "No task in Tools is named “Lead”")
            try refusal("repo", "No task in Tools is named “repo”")
            try refusal("Checkout", "isn't a task")
            try refusal("Work", "still has sub-tasks (“Sub”)")
            // The user's own workspace in that worktree shows its branch too.
            let peek = try named("Peek")
            shell.refreshGitContextNow(for: work)
            shell.refreshGitContextNow(for: peek)
            harness.waitUntil("their branch") { work.gitBranch == harness.worktreeBranch && peek.gitBranch == harness.worktreeBranch }
            try refusal(harness.worktreeBranch, "several share that name")

            peek.addColumn(command: "sleep 60", cwd: harness.worktree)
            let sleeper = try XCTUnwrap(peek.columns.last?.pty)
            harness.waitUntil("the program") { sleeper.foregroundProcess(snapshot: ProcessSnapshot())?.name == "sleep" }
            try refusal("Peek", "runs sleep in a terminal")

            let agent = AgentStandIn()
            defer { agent.remove() }
            let agentUUID = UUID().uuidString
            sub.addColumn(command: agent.command(), agentUUID: agentUUID, cwd: subFolder)
            let pty = try XCTUnwrap(sub.columns.first { $0.agentUUID == agentUUID }?.pty)
            harness.waitUntil("its claude") { pty.foregroundProcess(snapshot: ProcessSnapshot())?.name == "claude" }
            let claude = try XCTUnwrap(pty.foregroundProcess(snapshot: ProcessSnapshot())).instance
            for name in [AgentHookEvent.Name.sessionStart, .userPromptSubmit] {
                _ = pty.applyAgentHook(AgentHookEvent(
                    kind: .claude, name: name, agentUUID: agentUUID, sessionID: "sub", emitterProcess: claude,
                    timestamp: Date().timeIntervalSince1970
                ), isUserFocused: false)
            }
            try refusal("Sub", "agent is working")

            // Not on screen: its agent stays paused.
            let later = try named("Later")
            shell.workspaceStore.selectWorkspace(id: lead.workspace.id)
            later.addColumn(
                deferredAgent: DeferredAgentLaunch(agent: .claude(resume: .session("s1"), mode: .default), title: nil, lastStatus: .working),
                agentUUID: UUID().uuidString, cwd: harness.worktree
            )
            try refusal("Later", "hasn't resumed since Nirux restarted, last seen working")

            // Text typed at its prompt and not sent would be lost.
            let typedAgent = AgentStandIn()
            defer { typedAgent.remove() }
            let typed = try startAgent(typedAgent.command(), in: try named("Typed"), harness: harness)
            typed.hook(.userPromptSubmit)
            typed.hook(.stop)
            typed.pty.sendRaw("half a prompt")
            try refusal("Typed", "text typed into its prompt and not sent")
            // Under a launcher, waiting on a permission: its hooks say so,
            // no screen read does.
            let wrappedAgent = AgentStandIn()
            defer { wrappedAgent.remove() }
            let launcher = "stty -icanon min 1 time 0; exec -a node /bin/sh -c '(exec -a claude /bin/cat > \"\(wrappedAgent.received.path)\"); true'"
            let wrapped = try startAgent(launcher, in: try named("Wrapped"), harness: harness)
            XCTAssertEqual(wrapped.pty.foregroundProcess(snapshot: ProcessSnapshot())?.name, "node", "a launcher in front")
            wrapped.hook(.userPromptSubmit)
            wrapped.hook(.permissionRequest)
            try refusal("Wrapped", "waits for the user")
            XCTAssertEqual(shell.workspaces.filter { $0.profileID == lead.space && !$0.isClosing }.count, 8, "nothing closed")
        }
    }

    /// A merged task's worktree and branch go with it, as Clean Up
    /// Worktree… does once confirmed; an unmerged one's stay, and so do
    /// those of a folder named for another branch (a base reused across
    /// branches): the answer says why.
    func testCloseTaskCleansUpOnlyMergedTaskWorktrees() throws {
        try UIFlowHarness.run { harness in
            let shell = harness.shell
            let lead = try harness.makeLead()
            _ = try stubCleanupTools(harness)
            try UIFlowHarness.git(["remote", "add", "acme", "https://github.com/acme/widgets.git"], at: harness.repo)
            let merged = harness.root + "/repo.feat-merged"
            let base = harness.root + "/repo-base"
            try mergedWorktree("feat/merged", in: merged, number: 7, harness: harness)
            try mergedWorktree("feat/base", in: base, number: 8, harness: harness)
            for (title, cwd) in [("Merged work", merged), ("Base work", base), ("Flow work", harness.worktree)] {
                shell.addWorkspace(title: title, cwd: cwd, profileID: lead.space)
            }
            // GitHub and git answer first: a cold CI runner's first git
            // calls take seconds each (the tool itself waits 300 s).
            let close = { (task: String) in try harness.callLeadTool(LeadTools.closeTask, ["task": task], lead: lead, timeout: 180) }
            let closed = { (title: String) in
                harness.waitUntil("“\(title)” to close") { !shell.workspaces.contains { $0.title == title } }
            }

            let unmerged = try close("Flow work")
            XCTAssertFalse(unmerged.isError, unmerged.text)
            XCTAssertTrue(unmerged.text.hasPrefix("Closed “Flow work”. Its worktree and branch stay: feat/flow isn't pushed"), unmerged.text)
            closed("Flow work")
            XCTAssertTrue(FileManager.default.fileExists(atPath: harness.worktree))

            let reused = try close("Base work")
            XCTAssertFalse(reused.isError, reused.text)
            XCTAssertTrue(reused.text.contains("Its worktree and branch stay: Its folder isn't named for its branch"), reused.text)
            closed("Base work")
            XCTAssertTrue(FileManager.default.fileExists(atPath: base))

            let cleaned = try close("Merged work")
            XCTAssertFalse(cleaned.isError, cleaned.text)
            XCTAssertTrue(cleaned.text.hasPrefix("Closed “Merged work” and cleaned it up (pull request #7 merged)"), cleaned.text)
            closed("Merged work")
            XCTAssertFalse(FileManager.default.fileExists(atPath: merged))
            XCTAssertEqual(try UIFlowHarness.git(["branch", "--list", "feat/merged"], at: harness.repo), "")
            XCTAssertNotEqual(try UIFlowHarness.git(["branch", "--list", "feat/base"], at: harness.repo), "")
        }
    }

    /// A task without a repository: it closes, and its folder goes to the
    /// Trash once its processes ended, where Put Back restores it; unless
    /// another workspace is open in it, a process outlives the task, or it
    /// holds git work no remote has.
    func testClosingATaskWithoutARepositoryTrashesItsFolder() throws {
        try UIFlowHarness.run { harness in
            let shell = harness.shell
            let lead = try harness.makeLead()
            let trash = try stubCleanupTools(harness)
            for description in ["Compare two parsers", "Draft the notes", "Keep it busy", "Start a repo"] {
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
            XCTAssertTrue(trashed.text.hasSuffix("moved its folder to the Trash (\(trash)/Compare two parsers): Finder's Put Back restores it to \(folder)."), trashed.text)
            harness.waitUntil("its folder to go to the Trash") { !FileManager.default.fileExists(atPath: folder) }
            XCTAssertTrue(FileManager.default.fileExists(atPath: trash + "/Compare two parsers/.claude-handover.md"))
            harness.waitUntil("the task to close") { !shell.workspaces.contains { $0 === parsers } }

            let kept = try harness.callLeadTool(LeadTools.closeTask, ["task": "Draft the notes"], lead: lead)
            XCTAssertFalse(kept.isError, kept.text)
            XCTAssertEqual(kept.text, "Closed “Draft the notes”. Its folder stays (\(notesFolder)): Other workspaces are open in it: “Peek”.")
            harness.waitUntil("the second task to close") { !shell.workspaces.contains { $0 === notes } }
            XCTAssertTrue(FileManager.default.fileExists(atPath: notesFolder))

            // A job its shell left running past the close.
            let busy = try XCTUnwrap(shell.workspaces.first { $0.title == "Keep it busy" })
            let busyFolder = try XCTUnwrap(busy.taskFolder)
            let shellPID = try XCTUnwrap(busy.columns.first?.pty?.shellPID)
            busy.columns.first?.pty?.sendRaw("nohup sleep 60 >/dev/null 2>&1 &\r")
            harness.waitUntil("the job") { ProcessSnapshot().tree(of: shellPID).contains { $0.name == "sleep" } }
            let job = try XCTUnwrap(ProcessSnapshot().tree(of: shellPID).first { $0.name == "sleep" }).process
            defer { kill(job.pid, SIGKILL) }
            let waited = try harness.callLeadTool(LeadTools.closeTask, ["task": "Keep it busy"], lead: lead, timeout: 60)
            XCTAssertEqual(waited.text, "Closed “Keep it busy”. Its folder stays (\(busyFolder)): Its processes (sleep) still ran 10 s after it closed.")
            XCTAssertTrue(FileManager.default.fileExists(atPath: busyFolder))

            // An agent's git repository with work no remote has.
            let repo = try XCTUnwrap(shell.workspaces.first { $0.title == "Start a repo" })
            let repoFolder = try XCTUnwrap(repo.taskFolder)
            try UIFlowHarness.git(["init", "-q"], at: repoFolder)
            let gitKept = try harness.callLeadTool(LeadTools.closeTask, ["task": "Start a repo"], lead: lead)
            XCTAssertEqual(gitKept.text, "Closed “Start a repo”. Its folder stays (\(repoFolder)): It holds a git repository with uncommitted changes.")
            XCTAssertTrue(FileManager.default.fileExists(atPath: repoFolder))
        }
    }

    /// Closing the task the user had selected (Nirux in the background)
    /// selects the next one, but gives no terminal the keyboard: the user
    /// comes back to no agent's prompt.
    func testClosingTheSelectedTaskGivesNoTerminalTheKeyboard() throws {
        try UIFlowHarness.run { harness in
            let shell = harness.shell
            let lead = try harness.makeLead()
            shell.addWorkspace(title: "Selected", cwd: harness.worktree, profileID: lead.space)
            shell.addWorkspace(title: "Next", cwd: harness.repo, profileID: lead.space)
            let selected = try XCTUnwrap(shell.workspaces.first { $0.title == "Selected" })
            shell.workspaceStore.selectWorkspace(id: selected.id)
            shell.refreshAfterWorkspaceSelection(animated: false)
            let typing = { (harness.window.firstResponder as? NSView).flatMap { responder in
                shell.workspaces.first { responder.isDescendant(of: $0.containerView) }
            } }
            XCTAssertTrue(typing() === selected, "its terminal has the keyboard")
            let closed = try harness.callLeadTool(LeadTools.closeTask, ["task": "Selected"], lead: lead)
            XCTAssertFalse(closed.isError, closed.text)
            XCTAssertFalse(shell.activeWorkspace === selected)
            XCTAssertNil(typing(), "no terminal took the keyboard")
            harness.waitUntil("it closes") { !shell.workspaces.contains { $0 === selected } }
            XCTAssertNil(typing())
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
            // A branch names before a title does.
            shell.addWorkspace(title: harness.worktreeBranch, cwd: harness.repo, profileID: lead.space)
            shell.workspaceStore.selectWorkspace(id: elsewhere.id)
            shell.refreshGitContextNow(for: one)
            harness.waitUntil("its branch") { one.gitBranch == harness.worktreeBranch }
            XCTAssertEqual(try move(harness.worktreeBranch, 1).text, "“One” is 1 of 4 among the tasks of Tools.")
            XCTAssertEqual(titles(), ["Lead", "One", "Sub", "Three", "Two", harness.worktreeBranch])
            XCTAssertTrue(shell.activeWorkspace === elsewhere, "the user stays where they are")
        }
    }
}
