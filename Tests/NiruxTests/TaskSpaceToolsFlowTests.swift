import AppKit
import XCTest
@testable import Nirux

/// A task's agent managing spaces through its Nirux MCP server, as Claude
/// runs it, to the app's request center and back (SpaceToolCaller): on
/// by default in General, off elsewhere, as the space's "Tasks can manage
/// spaces" says.
@MainActor
final class TaskSpaceToolsFlowTests: XCTestCase {
    private final class Reply: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: Data?
        var data: Data? {
            get { lock.withLock { stored } }
            set { lock.withLock { stored = newValue } }
        }
    }

    /// The app's side of the channel, as NiruxApp starts it.
    private func startRequestCenter(_ shell: NiruxShellView) -> LeadRequestCenter {
        let center = LeadRequestCenter()
        center.handler = { [weak shell] request, answer in
            guard let shell else { return answer("Nirux is closing.", true) }
            shell.handleLeadRequest(request, answer: answer)
        }
        center.start(stateDirectory: Persistence.stateDirectory)
        return center
    }

    /// The server of `task`'s agent, launched while the task was in `spaceID`.
    private func agentServer(of task: WorkspaceState, launchedIn spaceID: String) throws -> NiruxMCPServer.Context {
        var context = NiruxMCPServer.Context(
            workingDirectory: task.cwd,
            environment: [
                "NIRUX_WORKSPACE_ID": task.id, "NIRUX_AGENT_UUID": try XCTUnwrap(task.columns.first?.agentUUID),
                NiruxLaunchAuthorization.environmentKey: "launch", "NIRUX_PROFILE_ID": spaceID
            ],
            stateDirectory: Persistence.stateDirectory,
            claudeProjects: Persistence.stateDirectory.appendingPathComponent("projects")
        )
        context.leadTimeout = 30
        return context
    }

    /// One message, answered off the main thread as the server answers
    /// Claude, while the app takes the call on it.
    private func send(
        _ method: String, _ params: [String: Any] = [:], to server: NiruxMCPServer.Context, in harness: UIFlowHarness
    ) throws -> [String: Any] {
        let line = try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": 1, "method": method, "params": params])
        let reply = Reply()
        // Typed first, so that it stays nonisolated (ThreadClosureGuardTests).
        let answer: @Sendable () -> Void = { reply.data = NiruxMCPServer.reply(to: line, context: server) ?? Data() }
        Thread(block: answer).start()
        harness.waitUntil("the server's answer to \(method)", timeout: 60) { reply.data != nil }
        return try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(reply.data)) as? [String: Any])
    }

    private func toolNames(_ server: NiruxMCPServer.Context, in harness: UIFlowHarness) throws -> [String] {
        let tools = (try send("tools/list", to: server, in: harness)["result"] as? [String: Any])?["tools"] as? [[String: Any]]
        return try XCTUnwrap(tools).compactMap { $0["name"] as? String }
    }

    private func instructions(_ server: NiruxMCPServer.Context, in harness: UIFlowHarness) throws -> String {
        try XCTUnwrap((try send("initialize", to: server, in: harness)["result"] as? [String: Any])?["instructions"] as? String)
    }

    /// The tool's answer; nil when the server itself refused the call.
    private func call(
        _ tool: String, _ arguments: [String: Any] = [:], on server: NiruxMCPServer.Context, in harness: UIFlowHarness
    ) throws -> (text: String, isError: Bool)? {
        let message = try send("tools/call", ["name": tool, "arguments": arguments], to: server, in: harness)
        guard let result = message["result"] as? [String: Any] else { return nil }
        let text = (result["content"] as? [[String: Any]])?.first?["text"] as? String
        return (try XCTUnwrap(text), try XCTUnwrap(result["isError"] as? Bool))
    }

    private let searchTools = [HistorySearchTool.name, MemorySearchTool.name]

    /// `shell`'s first workspace in General, on screen: the tools never
    /// move what the user looks at.
    private func lookAtGeneral(_ shell: NiruxShellView) throws {
        let general = try XCTUnwrap(shell.workspaces.first { $0.profileID == WorkspaceProfile.defaultID && $0.title == "repo" })
        XCTAssertTrue(shell.workspaceStore.selectWorkspace(id: general.id))
    }

    func testATaskInGeneralManagesSpacesUntilItMovesOut() throws {
        try UIFlowHarness.run { harness in
            let shell = harness.shell
            let center = startRequestCenter(shell)
            defer { center.stop() }
            shell.addWorkspace(title: "Organize", cwd: harness.worktree, profileID: WorkspaceProfile.defaultID)
            let task = try XCTUnwrap(shell.workspaces.first { $0.title == "Organize" })
            try lookAtGeneral(shell)
            let server = try agentServer(of: task, launchedIn: WorkspaceProfile.defaultID)

            XCTAssertEqual(try toolNames(server, in: harness), searchTools + TaskTools.names + LeadTools.spaceNames)
            let text = try instructions(server, in: harness)
            XCTAssertTrue(text.contains(NiruxMCPServer.taskSpaceInstructions), text)
            XCTAssertLessThanOrEqual(text.count, 2048, "Claude Code cuts server instructions at 2,048 characters")

            let created = try XCTUnwrap(try call(LeadTools.createSpace, ["name": "Ops"], on: server, in: harness))
            XCTAssertFalse(created.isError, created.text)
            let ops = try XCTUnwrap(shell.profiles.first { $0.name == "Ops" })
            XCTAssertEqual(shell.activeProfileID, WorkspaceProfile.defaultID, "nothing comes to the front")

            let spaces = try XCTUnwrap(try call(LeadTools.listSpaces, on: server, in: harness))
            let general = try XCTUnwrap(spaces.text.components(separatedBy: "\n").first { $0.contains("space:default") })
            XCTAssertTrue(general.contains("current space"), spaces.text)

            let own = try XCTUnwrap(try call(LeadTools.listTasks, ["space": "General"], on: server, in: harness))
            XCTAssertFalse(own.isError, own.text)
            XCTAssertTrue(own.text.hasPrefix("“General” has no Lead. Your tell and reply reach your sub-tasks only."), own.text)
            XCTAssertTrue(own.text.contains("“Organize”"), own.text)

            // It moves itself, and hears what that does: Ops keeps its tasks out of space management.
            let moved = try XCTUnwrap(try call(LeadTools.moveTaskToSpace, ["task": task.leadTaskReference, "to_space": "Ops"], on: server, in: harness))
            XCTAssertFalse(moved.isError, moved.text)
            XCTAssertEqual(task.profileID, ops.id)
            XCTAssertTrue(moved.text.contains("You moved too: you are in “Ops” (space:\(ops.id)) now, whose tasks can't manage spaces"), moved.text)

            // Its server still lists the tools; the app answers for where the task is now.
            let refused = try XCTUnwrap(try call(LeadTools.listSpaces, on: server, in: harness))
            XCTAssertTrue(refused.isError, refused.text)
            XCTAssertTrue(refused.text.contains("“Ops” doesn't let its tasks manage spaces"), refused.text)
            // Restarted in the same shell, which still says General, it lists Ops' tools.
            let restarted = try agentServer(of: task, launchedIn: WorkspaceProfile.defaultID)
            XCTAssertEqual(try toolNames(restarted, in: harness), searchTools + TaskTools.names)
            XCTAssertFalse(try instructions(restarted, in: harness).contains(NiruxMCPServer.taskSpaceInstructions))
        }
    }

    func testGeneralWithTheSettingOffGivesItsTasksNoSpaceTools() throws {
        try UIFlowHarness.run { harness in
            let shell = harness.shell
            let center = startRequestCenter(shell)
            defer { center.stop() }
            shell.changeSpaceDefaults(spaceID: WorkspaceProfile.defaultID) { $0.setTasksManageSpaces(false, inSpace: WorkspaceProfile.defaultID) }
            shell.addWorkspace(title: "Organize", cwd: harness.worktree, profileID: WorkspaceProfile.defaultID)
            let task = try XCTUnwrap(shell.workspaces.first { $0.title == "Organize" })
            try lookAtGeneral(shell)
            let server = try agentServer(of: task, launchedIn: WorkspaceProfile.defaultID)

            XCTAssertEqual(try toolNames(server, in: harness), searchTools + TaskTools.names)
            XCTAssertFalse(try instructions(server, in: harness).contains(NiruxMCPServer.taskSpaceInstructions))
            for (tool, arguments) in [(LeadTools.createSpace, ["name": "Ops"]), (LeadTools.listTasks, ["space": "General"])] {
                let refused = try XCTUnwrap(try call(tool, arguments, on: server, in: harness))
                XCTAssertTrue(refused.isError, refused.text)
                XCTAssertTrue(refused.text.contains("“General” doesn't let its tasks manage spaces"), refused.text)
            }
            XCTAssertEqual(shell.profiles.map(\.name), ["General"])
        }
    }

    /// Another space's tasks get the tools once its setting is on. A task
    /// never leaves its task or its repository behind, nor moves where its
    /// repository isn't.
    func testATaskInAnotherSpaceManagesSpacesOnceTheSettingIsOn() throws {
        try UIFlowHarness.run { harness in
            let shell = harness.shell
            let center = startRequestCenter(shell)
            defer { center.stop() }
            let repository = SpaceAnchor(kind: .gitRepository(commonDir: harness.repo + "/.git"), name: "repo", isDefault: true)
            let ops = shell.workspaceStore.createProfile(named: "Ops", anchors: [repository], select: false)
            shell.addWorkspace(title: "Fix", cwd: harness.worktree, profileID: ops.id)
            let task = try XCTUnwrap(shell.workspaces.first { $0.title == "Fix" })
            shell.addWorkspace(title: "Fix child", cwd: harness.worktree, profileID: ops.id, parentWorkspaceID: task.id)
            let child = try XCTUnwrap(shell.workspaces.first { $0.title == "Fix child" })
            try lookAtGeneral(shell)
            let server = try agentServer(of: task, launchedIn: ops.id)

            XCTAssertEqual(try toolNames(server, in: harness), searchTools + TaskTools.names, "off outside General")
            let off = try XCTUnwrap(try call(LeadTools.listSpaces, on: server, in: harness))
            XCTAssertTrue(off.isError, off.text)
            XCTAssertTrue(off.text.contains("“Ops” doesn't let its tasks manage spaces"), off.text)

            shell.changeSpaceDefaults(spaceID: ops.id) { $0.setTasksManageSpaces(true, inSpace: ops.id) }
            XCTAssertEqual(try toolNames(server, in: harness), searchTools + TaskTools.names + LeadTools.spaceNames)

            let alone = try XCTUnwrap(try call(
                LeadTools.moveTaskToSpace, ["task": child.leadTaskReference, "to_space": "General"],
                on: try agentServer(of: child, launchedIn: ops.id), in: harness
            ))
            XCTAssertTrue(alone.isError, alone.text)
            XCTAssertTrue(alone.text.contains("You are a sub-task"), alone.text)
            for (tool, arguments) in [
                (LeadTools.editSpace, ["space": "Ops", "remove_anchors": ["repo"]] as [String: Any]),
                (LeadTools.createSpace, ["name": "Elsewhere", "anchors": [harness.repo], "move_anchors": true])
            ] {
                let lost = try XCTUnwrap(try call(tool, arguments, on: server, in: harness))
                XCTAssertTrue(lost.isError, lost.text)
                XCTAssertTrue(lost.text.contains("You work in “repo”"), lost.text)
            }
            XCTAssertEqual(shell.profiles.first { $0.id == ops.id }?.anchors.map(\.name), ["repo"])
            XCTAssertNil(shell.profiles.first { $0.name == "Elsewhere" })

            // A space with a Lead stays that Lead's to organize, for its own tasks too.
            let led = shell.workspaceStore.createProfile(named: "Led", select: false)
            shell.startLead(spaceID: led.id)
            shell.changeSpaceDefaults(spaceID: led.id) { $0.setTasksManageSpaces(true, inSpace: led.id) }
            shell.addWorkspace(title: "Led task", cwd: harness.worktree, profileID: led.id)
            let ledTask = try XCTUnwrap(shell.workspaces.first { $0.title == "Led task" })
            try lookAtGeneral(shell)
            let organized = try XCTUnwrap(try call(
                LeadTools.moveTaskToSpace, ["task": ledTask.leadTaskReference, "to_space": "General"],
                on: try agentServer(of: ledTask, launchedIn: led.id), in: harness
            ))
            XCTAssertTrue(organized.isError, organized.text)
            XCTAssertTrue(organized.text.contains("has a Lead of its own"), organized.text)
            XCTAssertEqual(ledTask.profileID, led.id)

            // General has no repository: moved there, Fix would work outside its space's.
            let stranding = try XCTUnwrap(try call(
                LeadTools.deleteSpace, ["space": "Ops", "move_tasks_to": "General"], on: server, in: harness
            ))
            XCTAssertTrue(stranding.isError, stranding.text)
            XCTAssertTrue(stranding.text.contains("You work in a repository of your space that “General” doesn't have"), stranding.text)
            XCTAssertEqual(harness.alerts, [], "refused before asking the user")
            XCTAssertEqual([task.profileID, child.profileID], [ops.id, ops.id])
        }
    }

    /// A task without a repository there deletes its own space: it moves
    /// out with the others, and keeps the tools its new space gives, in this
    /// agent and once it restarts.
    func testATaskThatDeletesItsSpaceManagesSpacesFromItsNewOne() throws {
        try UIFlowHarness.run { harness in
            let shell = harness.shell
            let center = startRequestCenter(shell)
            defer { center.stop() }
            let scratch = shell.workspaceStore.createProfile(named: "Scratch", select: false)
            shell.changeSpaceDefaults(spaceID: scratch.id) { $0.setTasksManageSpaces(true, inSpace: scratch.id) }
            shell.addWorkspace(title: "Notes", cwd: harness.worktree, profileID: scratch.id)
            let task = try XCTUnwrap(shell.workspaces.first { $0.title == "Notes" })
            shell.addWorkspace(title: "Draft", cwd: harness.worktree, profileID: scratch.id, parentWorkspaceID: task.id)
            let child = try XCTUnwrap(shell.workspaces.first { $0.title == "Draft" })
            try lookAtGeneral(shell)
            let server = try agentServer(of: task, launchedIn: scratch.id)

            harness.alertResponses = [.alertSecondButtonReturn]
            let deleted = try XCTUnwrap(try call(
                LeadTools.deleteSpace, ["space": "Scratch", "move_tasks_to": "General"], on: server, in: harness
            ))
            XCTAssertFalse(deleted.isError, deleted.text)
            XCTAssertEqual(harness.alerts, ["The task “Notes” asks to delete the space \"Scratch\""])
            XCTAssertNil(shell.profiles.first { $0.id == scratch.id })
            XCTAssertTrue(deleted.text.hasSuffix("You moved too: you are in “General” (space:default) now."), deleted.text)
            XCTAssertEqual([task.profileID, child.profileID], [WorkspaceProfile.defaultID, WorkspaceProfile.defaultID])
            XCTAssertEqual(child.parentWorkspaceID, task.id)

            // Its shell still names the deleted space.
            let spaces = try XCTUnwrap(try call(LeadTools.listSpaces, on: server, in: harness))
            XCTAssertFalse(spaces.isError, spaces.text)
            let restarted = try agentServer(of: task, launchedIn: scratch.id)
            XCTAssertEqual(try toolNames(restarted, in: harness), searchTools + TaskTools.names + LeadTools.spaceNames)
        }
    }
}
