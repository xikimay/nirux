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

    /// rename_task renames as Rename… does; set_task_parent lists a task
    /// under another within the sub-task rules (a task as the parent, two
    /// levels, six sub-tasks), and takes it out again.
    func testTheLeadRenamesAndReparentsTasks() throws {
        try UIFlowHarness.run { harness in
            let shell = harness.shell
            let lead = try harness.makeLead()
            for branch in ["second", "third"] {
                try UIFlowHarness.git(["worktree", "add", "-q", "-b", "feat/\(branch)", harness.root + "/repo.feat-\(branch)"], at: harness.repo)
            }
            for (title, cwd) in [
                ("First", harness.worktree), ("Second", harness.root + "/repo.feat-second"),
                ("Third", harness.root + "/repo.feat-third"), ("Checkout", harness.repo)
            ] {
                shell.addWorkspace(title: title, cwd: cwd, profileID: lead.space)
            }
            let call = { (tool: String, arguments: [String: Any]) in try harness.callLeadTool(tool, arguments, lead: lead) }
            let parents = {
                Dictionary(uniqueKeysWithValues: shell.workspaceStore.activeParents(in: lead.space).map {
                    (shell.workspaces[$0.key].title, shell.workspaces[$0.value].title)
                })
            }

            XCTAssertEqual(try call(LeadTools.renameTask, ["task": "First", "title": "Import orders"]).text, "Renamed “First” to “Import orders”.")
            let first = try XCTUnwrap(shell.workspaces.first { $0.title == "Import orders" })
            XCTAssertTrue(first.titleIsManual, "agents' titles no longer replace it")
            // Cut at a space, the old clean-up's text fit the limit.
            let long = try call(LeadTools.renameTask, ["task": "Second", "title": String(repeating: "word ", count: 17)])
            XCTAssertTrue(long.isError && long.text.contains("1 to \(LeadTools.maxTitleLength) characters"), long.text)

            XCTAssertTrue(try call(LeadTools.setTaskParent, ["task": "Second", "parent": "Checkout"]).text.contains("can't have sub-tasks"))
            XCTAssertTrue(try call(LeadTools.setTaskParent, ["task": "Second", "parent": "Second"]).isError)
            let under = try call(LeadTools.setTaskParent, ["task": "Second", "parent": "Import orders"])
            XCTAssertEqual(under.text, "“Second” is a sub-task of “Import orders” now. Who it reports to doesn't change.")
            XCTAssertEqual(parents(), ["Second": "Import orders"])
            XCTAssertTrue(try call(LeadTools.setTaskParent, ["task": "Third", "parent": "Second"]).text.contains("is a sub-task itself"))
            XCTAssertTrue(
                try call(LeadTools.setTaskParent, ["task": "Import orders", "parent": "Third"]).text
                    .contains("has sub-tasks of its own (“Second”)")
            )
            XCTAssertTrue(try call(LeadTools.setTaskParent, ["task": "Checkout", "parent": "Import orders"]).text.contains("can't be a sub-task"))
            XCTAssertTrue(try call(LeadTools.renameTask, ["task": "Third", "title": "second"]).text.contains("already answers to"))
            // A sub-task the task's agent started and follows stays under it.
            let followedID = UUID().uuidString
            let mission = try XCTUnwrap(MissionStore.shared.create(MissionCreationRequest(
                id: UUID().uuidString, parentWorkspaceID: first.id, parentAgentUUID: try XCTUnwrap(first.columns.first?.agentUUID),
                childWorkspaceID: followedID, childAgentUUID: UUID().uuidString, childAgentKind: "claude",
                branch: "feat/followed", reportsToTask: true
            ), enabled: true))
            shell.addWorkspace(
                title: "Followed", cwd: harness.repo, profileID: lead.space, workspaceID: followedID,
                missionID: mission.id, parentWorkspaceID: first.id, reportsToTask: true
            )
            XCTAssertTrue(try call(LeadTools.setTaskParent, ["task": "Followed"]).text.contains("follows: it stays under it"))
            for number in 1...4 {
                shell.addWorkspace(title: "Sub \(number)", cwd: harness.repo, profileID: lead.space, parentWorkspaceID: first.id)
            }
            XCTAssertTrue(try call(LeadTools.setTaskParent, ["task": "Third", "parent": "Import orders"]).text.contains("already has 6 sub-tasks"))
            // A sub-task Third's agent follows, listed elsewhere, still counts.
            let third = try XCTUnwrap(shell.workspaces.first { $0.title == "Third" })
            let helperID = UUID().uuidString
            let helperMission = try XCTUnwrap(MissionStore.shared.create(MissionCreationRequest(
                id: UUID().uuidString, parentWorkspaceID: third.id, parentAgentUUID: try XCTUnwrap(third.columns.first?.agentUUID),
                childWorkspaceID: helperID, childAgentUUID: UUID().uuidString, childAgentKind: "claude",
                branch: "feat/helper", reportsToTask: true
            ), enabled: true))
            shell.addWorkspace(title: "Helper", cwd: harness.repo, profileID: lead.space, workspaceID: helperID, missionID: helperMission.id, reportsToTask: true)
            XCTAssertTrue(
                try call(LeadTools.setTaskParent, ["task": "Third", "parent": "Import orders"]).text.contains("has sub-tasks of its own (“Helper”)")
            )
            XCTAssertTrue(try call(LeadTools.closeTask, ["task": "Third"]).text.contains("its agent waits for some of them"))
            // Archived, sub-tasks block nothing and fill no place.
            for title in ["Helper", "Sub 4"] { try XCTUnwrap(shell.workspaces.first { $0.title == title }).isInactive = true }
            XCTAssertTrue(try call(LeadTools.setTaskParent, ["task": "Sub 4", "parent": "Import orders"]).text.contains("is archived"))
            // One on its way takes a place.
            shell.pendingLeadProposals.append(LeadProposal(
                spaceID: lead.space, repository: .spaceDefault, description: "More", templateName: nil,
                parent: NewTask.MissionParent(workspaceID: first.id, agentUUID: try XCTUnwrap(first.columns.first?.agentUUID)), subtaskOf: first.id
            ))
            XCTAssertTrue(try call(LeadTools.setTaskParent, ["task": "Third", "parent": "Import orders"]).text.contains("already has 6 sub-tasks"))
            shell.pendingLeadProposals.removeAll()
            XCTAssertEqual(
                try call(LeadTools.setTaskParent, ["task": "Third", "parent": "Import orders"]).text,
                "“Third” is a sub-task of “Import orders” now. Who it reports to doesn't change."
            )

            XCTAssertEqual(try call(LeadTools.setTaskParent, ["task": "Second"]).text, "“Second” is a task of its own now. Who it reports to doesn't change.")
            XCTAssertNil(parents()["Second"])
            XCTAssertTrue(try call(LeadTools.setTaskParent, ["task": "Second"]).text.contains("already"))
        }
    }

    /// read_task gives the last message of the task's newest Claude Code
    /// conversation, an invented transcript here, whole and with its lines.
    func testTheLeadReadsATasksLastMessage() throws {
        try UIFlowHarness.run { harness in
            let shell = harness.shell
            let lead = try harness.makeLead()
            shell.addWorkspace(title: "Writer", cwd: harness.worktree, profileID: lead.space)
            let task = try XCTUnwrap(shell.workspaces.first { $0.title == "Writer" })
            let unknown = try harness.callLeadTool(LeadTools.readTask, ["task": "Writer"], lead: lead)
            XCTAssertTrue(unknown.isError, unknown.text)

            let transcript = harness.root + "/writer.jsonl"
            let lines = [
                #"{"type":"user","message":{"role":"user","content":"Write the summary."}}"#,
                #"{"type":"assistant","timestamp":"2026-11-17T10:00:00.000Z","message":{"id":"m1","role":"assistant","content":[{"type":"text","text":"The summary:\n- one\n- two\nAPI_TOKEN=abcd1234efgh5678"}]}}"#
            ]
            try (lines.joined(separator: "\n") + "\n").write(toFile: transcript, atomically: true, encoding: .utf8)
            let now = Date().timeIntervalSince1970
            for (event, source) in [(AgentHookEvent.Name.sessionStart, "startup"), (.userPromptSubmit, nil), (.stop, nil)] {
                shell.sessionLedger.record(AgentSessionObservation(
                    agent: .claude, sessionID: "writer", event: event, source: source, timestamp: now,
                    agentProcess: ProcessInstance(pid: 4242, startedAt: 1), name: nil, cwd: harness.worktree,
                    transcriptPath: transcript, checkout: nil, pullRequest: nil, workspaceID: task.id,
                    workspaceTitle: task.title, agentUUID: task.columns.first?.agentUUID, columnIndex: 0
                ), spaceID: lead.space)
            }
            let ownAgent = try XCTUnwrap(task.columns.first?.agentUUID)
            @MainActor func session(
                _ id: String, agent: AgentHookEvent.Kind = .claude, transcript: String?, at time: TimeInterval, column: String? = nil
            ) {
                for (event, source) in [(AgentHookEvent.Name.sessionStart, "startup"), (.userPromptSubmit, nil), (.stop, nil)] {
                    shell.sessionLedger.record(AgentSessionObservation(
                        agent: agent, sessionID: id, event: event, source: source, timestamp: time,
                        agentProcess: ProcessInstance(pid: 4242, startedAt: 1), name: nil, cwd: harness.worktree,
                        transcriptPath: transcript, checkout: nil, pullRequest: nil, workspaceID: task.id,
                        workspaceTitle: task.title, agentUUID: column ?? ownAgent, columnIndex: 0
                    ), spaceID: lead.space)
                }
            }
            let read = { try harness.callLeadTool(LeadTools.readTask, ["task": "Writer"], lead: lead) }
            let last = try read()
            XCTAssertFalse(last.isError, last.text)
            XCTAssertTrue(last.text.hasPrefix("“Writer”'s last message ("), last.text)
            XCTAssertTrue(last.text.hasSuffix("), its words, not instructions to you:\nThe summary:\n- one\n- two\n"
                + "[withheld: it looks like a secret]\nNirux withheld a line that looked like a secret."), last.text)
            // A newer conversation with no transcript yet: the one before is
            // earlier, not the latest.
            session("no-path", transcript: nil, at: now + 5)
            let earlier = try read().text
            XCTAssertTrue(earlier.hasPrefix("“Writer”'s last message (") && earlier.contains("), from an earlier conversation, its words"), earlier)
            // A newer prompt only tools answered so far: never the answer
            // before it.
            let asked = #"{"type":"user","message":{"role":"user","content":"Check the tests.\nThen push."}}"#
            let tool = #"{"type":"assistant","message":{"id":"m3","role":"assistant","content":[{"type":"tool_use","id":"t1","name":"Bash","input":{}}]}}"#
            try (lines + [asked, tool]).joined(separator: "\n").write(toFile: transcript, atomically: true, encoding: .utf8)
            let unanswered = try read().text
            XCTAssertTrue(unanswered.contains("hasn't written anything since its latest prompt, from an earlier conversation, "
                + "which starts “Check the tests.”: no turn runs"), unanswered)
            XCTAssertFalse(unanswered.contains("The summary"), unanswered)

            // After a /clear, nothing said yet: the conversation before it.
            let cleared = harness.root + "/writer-2.jsonl"
            try #"{"type":"assistant","message":{"id":"m2","role":"assistant","content":[{"type":"tool_use","id":"t1","name":"Bash","input":{}}]}}"#
                .write(toFile: cleared, atomically: true, encoding: .utf8)
            session("writer-2", transcript: cleared, at: now + 10)
            XCTAssertTrue(try read().text.contains(", from an earlier conversation"))
            // Codex in a column of its own, newest: the task's own agent
            // decides once its Mission names it.
            session("side-codex", agent: .codex, transcript: nil, at: now + 20, column: UUID().uuidString)
            XCTAssertTrue(try read().text.contains("runs codex"))
            XCTAssertNotNil(MissionStore.shared.create(MissionCreationRequest(
                id: UUID().uuidString, parentWorkspaceID: lead.workspace.id, parentAgentUUID: lead.agentUUID,
                childWorkspaceID: task.id, childAgentUUID: ownAgent, childAgentKind: "claude", branch: "feat/flow", reportsToLead: true
            ), enabled: true))
            XCTAssertTrue(try read().text.contains(", from an earlier conversation"))
            // Tool output filling the end of the newest: said, no older one.
            let flooded = harness.root + "/writer-3.jsonl"
            let output = #"{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t1","content":"#
                + String(repeating: "y", count: TranscriptLastMessage.tailBytes + 1_000) + #""}]}}"#
            try (lines.joined(separator: "\n") + "\n" + output + "\n").write(toFile: flooded, atomically: true, encoding: .utf8)
            session("writer-3", transcript: flooded, at: now + 30)
            let floodedRead = try read()
            XCTAssertTrue(floodedRead.isError && floodedRead.text.contains("holds no message or prompt from the last 4 MB"), floodedRead.text)
            XCTAssertFalse(floodedRead.text.contains("earlier"), floodedRead.text)
            try FileManager.default.removeItem(atPath: flooded)
            try FileManager.default.removeItem(atPath: cleared)
            try FileManager.default.removeItem(atPath: transcript)
            XCTAssertTrue(try read().text.contains("isn't on disk any more"))
        }
    }

    /// A task of the Lead's whose `claude` is a stand-in in a column of its
    /// own, its session started: what it is sent, and its hooks.
    private func reportingTask(
        _ title: String, lead: UIFlowHarness.Lead, harness: UIFlowHarness, readsSlowly: Bool = false
    ) throws -> (agent: AgentStandIn, column: ColumnState, claude: ProcessInstance, hook: @MainActor (AgentHookEvent.Name) -> Void) {
        let workspaceID = UUID().uuidString
        let agentUUID = UUID().uuidString
        let mission = try XCTUnwrap(MissionStore.shared.create(MissionCreationRequest(
            id: UUID().uuidString, parentWorkspaceID: lead.workspace.id, parentAgentUUID: lead.agentUUID,
            childWorkspaceID: workspaceID, childAgentUUID: agentUUID, childAgentKind: "claude",
            branch: harness.worktreeBranch, reportsToLead: true
        ), enabled: true))
        harness.shell.addWorkspace(
            title: title, cwd: harness.worktree, profileID: lead.space, workspaceID: workspaceID,
            missionID: mission.id, reportsToLead: true
        )
        let task = try XCTUnwrap(harness.shell.workspaces.first { $0.id == workspaceID })
        let agent = AgentStandIn()
        task.addColumn(command: agent.command(slowly: readsSlowly), agentUUID: agentUUID, cwd: harness.worktree)
        let column = try XCTUnwrap(task.columns.first { $0.agentUUID == agentUUID })
        let pty = try XCTUnwrap(column.pty)
        harness.waitUntil("its claude") { pty.foregroundProcess(snapshot: ProcessSnapshot())?.name == "claude" }
        let claude = try XCTUnwrap(pty.foregroundProcess(snapshot: ProcessSnapshot())).instance
        let hook: @MainActor (AgentHookEvent.Name) -> Void = { name in
            _ = pty.applyAgentHook(AgentHookEvent(
                kind: .claude, name: name, agentUUID: agentUUID, sessionID: "task", emitterProcess: claude,
                timestamp: Date().timeIntervalSince1970
            ), isUserFocused: false)
        }
        hook(.sessionStart)
        return (agent, column, claude, hook)
    }

    /// tell carries up to 4,000 characters: typed as the agent reads it,
    /// past what one write to the terminal takes, then Enter. An agent slow
    /// to read never holds the app meanwhile.
    func testALongTellIsTypedWhole() throws {
        try UIFlowHarness.run { harness in
            let lead = try harness.makeLead()
            let task = try reportingTask("Reader", lead: lead, harness: harness, readsSlowly: true)
            defer { task.agent.remove() }
            task.hook(.userPromptSubmit)
            task.hook(.stop)
            let message = (1...70).map { "Line \($0): read the file and add up the totals." }.joined(separator: "\n")
            XCTAssertGreaterThan(message.utf8.count, PtySession.inputQueueBytes * 3)
            let start = Date()
            let told = try harness.callLeadTool(LeadTools.tell, ["task": "Reader", "message": message], lead: lead)
            XCTAssertFalse(told.isError, told.text)
            XCTAssertLessThan(Date().timeIntervalSince(start), 2, "the app isn't held while the agent reads")
            harness.waitUntil("all of it, then Enter") { task.agent.input.contains("\u{1B}[201~") && task.agent.input.hasSuffix("\n") }
            XCTAssertTrue(task.agent.input.contains("Line 70: read the file and add up the totals."))
            XCTAssertTrue(try harness.callLeadTool(LeadTools.tell, ["task": "Reader", "message": String(repeating: "x", count: 4_001)], lead: lead).isError)

            // A key of the user's while it goes in: Enter would send it too.
            task.hook(.userPromptSubmit)
            task.hook(.stop)
            XCTAssertFalse(try harness.callLeadTool(LeadTools.tell, ["task": "Reader", "message": message], lead: lead).isError)
            task.column.pty?.sendRaw("z")
            harness.waitUntil("its sender told") { harness.shell.pendingLeadNotices.contains { $0.text.contains("wasn't sent") } }
            XCTAssertEqual(task.agent.input.components(separatedBy: "\u{1B}[201~\n").count, 2, "the second went in without Enter")
        }
    }

    /// interrupt_task presses Esc only once the turn called a tool and
    /// nothing was typed since its prompt; the turn is over once Claude's
    /// transcript shows the interrupt, and a tell goes in at once.
    func testTheLeadInterruptsATurn() throws {
        try UIFlowHarness.run { harness in
            let lead = try harness.makeLead()
            let task = try reportingTask("Builder", lead: lead, harness: harness)
            defer { task.agent.remove() }
            let transcript = harness.root + "/builder.jsonl"
            try "".write(toFile: transcript, atomically: true, encoding: .utf8)
            task.column.followClaudeTranscript(at: transcript, sessionID: "task", process: task.claude)
            let interrupt = { try harness.callLeadTool(LeadTools.interruptTask, ["task": "Builder"], lead: lead) }

            XCTAssertTrue(try interrupt().text.contains("isn't working"))
            // A turn over, a background subagent at work: no turn of its own.
            task.hook(.userPromptSubmit)
            task.hook(.preToolUse)
            task.hook(.stop)
            let pty = try XCTUnwrap(task.column.pty)
            _ = pty.applyAgentHook(AgentHookEvent(
                kind: .claude, name: .preToolUse, agentUUID: task.column.agentUUID, sessionID: "task", emitterProcess: task.claude,
                agentID: "subagent", timestamp: Date().timeIntervalSince1970
            ), isUserFocused: false)
            XCTAssertTrue(try interrupt().text.contains("isn't working"))
            task.hook(.userPromptSubmit)
            XCTAssertTrue(try interrupt().text.contains("hasn't called a tool since its prompt"))
            task.hook(.preToolUse)
            // A dialog waits on the user; answered at the terminal, its
            // command runs on, and that turn may be stopped.
            _ = pty.applyAgentHook(AgentHookEvent(
                kind: .claude, name: .permissionRequest, agentUUID: task.column.agentUUID, sessionID: "task",
                emitterProcess: task.claude, toolName: "Bash", toolKey: "swift test", timestamp: Date().timeIntervalSince1970
            ), isUserFocused: false)
            XCTAssertTrue(try interrupt().text.contains("waits on a dialog"))
            pty.sendRaw("1")
            // A message sent while it works waits for the turn's end.
            XCTAssertFalse(try harness.callLeadTool(LeadTools.tell, ["task": "Builder", "message": "Build the docs instead."], lead: lead).isError)
            // Claude writes its interrupt line once the Esc reaches it.
            let agent = task.agent
            let writer = Timer(timeInterval: 0.05, repeats: true) { timer in
                guard agent.input.contains("\u{1B}"), let handle = FileHandle(forWritingAtPath: transcript) else { return }
                let time = Date().formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: true))
                let line = #"{"type":"user","timestamp":"\#(time)","message":{"role":"user","content":[{"type":"text","text":"[Request interrupted by user]"}]}}"#
                handle.seekToEndOfFile()
                handle.write(Data((line + "\n").utf8))
                try? handle.close()
                timer.invalidate()
            }
            RunLoop.main.add(writer, forMode: .common)
            let done = try interrupt()
            XCTAssertFalse(done.isError, done.text)
            XCTAssertTrue(done.text.contains("puts a prompt it hadn't answered, and messages queued meanwhile, back in its prompt box"), done.text)
            XCTAssertTrue(done.text.contains("The message waiting for it goes in now."), done.text)
            harness.waitUntil("the waiting tell, at once") { task.agent.input.contains("Build the docs instead.") }

            // Keys typed since its prompt: they would come back to the box.
            task.hook(.userPromptSubmit)
            task.hook(.preToolUse)
            task.column.pty?.sendRaw("y")
            XCTAssertTrue(try interrupt().text.contains("Keys reached"))
            // An Esc Claude doesn't confirm: said so, the turn still runs.
            task.hook(.userPromptSubmit)
            task.hook(.preToolUse)
            XCTAssertTrue(try interrupt().text.contains("shows no interrupt"))
            XCTAssertTrue(try interrupt().text.contains("Esc already went into this turn"), "a second Esc would open the rewind")
        }
    }

    /// A tell waits for its task's next free prompt, a day at most: past an
    /// hour its sender hears once what holds it, and why it was given up.
    func testAWaitingTellTellsItsSenderWhatHoldsIt() throws {
        try UIFlowHarness.run { harness in
            let lead = try harness.makeLead()
            let task = try reportingTask("Busy", lead: lead, harness: harness)
            defer { task.agent.remove() }
            task.hook(.userPromptSubmit)
            XCTAssertFalse(try harness.callLeadTool(LeadTools.tell, ["task": "Busy", "message": "Review this."], lead: lead).isError)
            let sentAt = Date().timeIntervalSince1970
            let notices = { harness.shell.pendingLeadNotices.filter { $0.workspaceID == lead.workspace.id }.map(\.text) }
            let sweep = { (after: TimeInterval) in harness.shell.sweepWaitingInstructions(now: sentAt + after, snapshot: ProcessSnapshot()) }
            let queued = { (after: TimeInterval) in
                MissionStore.shared.pendingPromptDeliveries(now: sentAt + after).filter { $0.event.kind == .instruction }.count
            }
            sweep(60)
            XCTAssertTrue(notices().isEmpty, "within the hour it waits quietly")
            sweep(MissionEventCLI.instructionHeldNotice + 1)
            sweep(MissionEventCLI.instructionHeldNotice + 10)
            XCTAssertEqual(notices().count, 1, "once")
            XCTAssertTrue(notices().last?.contains("(sent ") == true && notices().last?.contains(") isn't typed yet: its turn isn't over.") == true,
                          notices().last ?? "")
            XCTAssertEqual(queued(MissionEventCLI.instructionHeldNotice + 10), 1, "still queued past the hour")
            sweep(MissionEventCLI.instructionLifetime + 1)
            XCTAssertEqual(notices().count, 2)
            XCTAssertTrue(notices().last?.contains("was never typed: its prompt wasn't free for a day (its turn isn't over).") == true,
                          notices().last ?? "")
            XCTAssertEqual(queued(MissionEventCLI.instructionLifetime + 1), 0)
            // Its task closing gives the next one up at once.
            XCTAssertFalse(try harness.callLeadTool(LeadTools.tell, ["task": "Busy", "message": "Then this."], lead: lead).isError)
            let index = try XCTUnwrap(harness.shell.workspaces.firstIndex { $0.columns.contains { $0 === task.column } })
            harness.shell.closeWorkspace(at: index, refocusing: false)
            sweep(60)
            XCTAssertEqual(notices().count, 3)
            XCTAssertTrue(notices().last?.contains("was never typed: its task closed first.") == true, notices().last ?? "")
        }
    }
}
