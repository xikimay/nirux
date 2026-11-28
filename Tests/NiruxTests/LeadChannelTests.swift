import XCTest
@testable import Nirux

/// The files between the Lead's MCP server and the app (see LeadChannel),
/// and the server's side of the Lead's tools.
final class LeadChannelTests: XCTestCase {
    private var stateDirectory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        stateDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("nirux-lead-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: stateDirectory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: stateDirectory)
        super.tearDown()
    }

    private func request(tool: String = LeadTools.listTasks, createdAt: TimeInterval = Date().timeIntervalSince1970) -> LeadChannel.Request {
        LeadChannel.Request(
            id: UUID().uuidString, tool: tool, arguments: "{}",
            workspaceID: UUID().uuidString, agentUUID: UUID().uuidString, createdAt: createdAt
        )
    }

    /// A stand-in for the app: answers each request it finds, `answers`
    /// times, from another thread.
    private func answerRequests(_ answers: Int, with text: String) -> Thread {
        let directory = stateDirectory!
        let respond: @Sendable () -> Void = {
            var answered = 0
            let deadline = Date().addingTimeInterval(10)
            while answered < answers, Date() < deadline {
                for request in LeadChannel.takeRequests(stateDirectory: directory) {
                    LeadChannel.respond(LeadChannel.Response(id: request.id, text: "\(text) \(request.tool)", isError: false), stateDirectory: directory)
                    answered += 1
                }
                Thread.sleep(forTimeInterval: 0.02)
            }
        }
        let thread = Thread(block: respond)
        thread.start()
        return thread
    }

    func testARequestGetsItsAnswerAndLeavesNoFile() throws {
        _ = answerRequests(1, with: "done")
        let outcome = LeadChannel.send(request(), stateDirectory: stateDirectory, takeTimeout: 5, workTimeout: 5)
        guard case .answered(let response) = outcome else { return XCTFail("no answer: \(outcome)") }
        XCTAssertEqual(response.text, "done list_tasks")
        for folder in [LeadChannel.requestsFolder(stateDirectory: stateDirectory), LeadChannel.responsesFolder(stateDirectory: stateDirectory)] {
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path), [])
        }
        let attributes = try FileManager.default.attributesOfItem(atPath: LeadChannel.requestsFolder(stateDirectory: stateDirectory).path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o700)
    }

    /// Nobody takes it: the caller takes its request back, so a late app
    /// never acts on it. Taken but not answered: the caller says it may
    /// still happen.
    func testAnUntakenRequestIsTakenBackAndATakenOneMayStillHappen() {
        XCTAssertEqual(LeadChannel.send(request(), stateDirectory: stateDirectory, takeTimeout: 0.2, workTimeout: 0.2), .notTaken)
        XCTAssertEqual(LeadChannel.takeRequests(stateDirectory: stateDirectory), [])

        let directory = stateDirectory!
        let take: @Sendable () -> Void = {
            let deadline = Date().addingTimeInterval(5)
            while Date() < deadline, LeadChannel.takeRequests(stateDirectory: directory).isEmpty {
                Thread.sleep(forTimeInterval: 0.02)
            }
        }
        Thread(block: take).start()
        XCTAssertEqual(LeadChannel.send(request(), stateDirectory: stateDirectory, takeTimeout: 2, workTimeout: 0.3), .stillWorking)
    }

    /// Another Nirux on the same state directory leaves a request it
    /// doesn't own alone; one claim only wins.
    func testARequestIsClaimedOnce() throws {
        let item = request()
        XCTAssertTrue(LeadChannel.write(item, id: item.id, in: LeadChannel.requestsFolder(stateDirectory: stateDirectory)))
        XCTAssertEqual(LeadChannel.waitingRequests(stateDirectory: stateDirectory).map(\.id), [item.id])
        XCTAssertEqual(LeadChannel.waitingRequests(stateDirectory: stateDirectory).map(\.id), [item.id], "looking takes nothing")
        XCTAssertTrue(LeadChannel.claim(item, stateDirectory: stateDirectory))
        XCTAssertFalse(LeadChannel.claim(item, stateDirectory: stateDirectory))
    }

    func testOldAndForeignRequestsAreDropped() {
        let folder = LeadChannel.requestsFolder(stateDirectory: stateDirectory)
        let current = request()
        var foreign = request()
        foreign.v = LeadChannel.protocolVersion + 1
        let old = request(createdAt: Date().timeIntervalSince1970 - LeadChannel.requestLifetime - 1)
        for item in [current, foreign, old] { XCTAssertTrue(LeadChannel.write(item, id: item.id, in: folder)) }
        XCTAssertEqual(LeadChannel.takeRequests(stateDirectory: stateDirectory).map(\.id), [current.id])
        XCTAssertEqual(LeadChannel.takeRequests(stateDirectory: stateDirectory), [], "each is read once")
    }

    /// The app takes only requests from its own workspaces, and none an
    /// earlier launch's terminals left.
    @MainActor
    func testTheAppTakesOnlyItsOwnFreshRequests() {
        let folder = LeadChannel.requestsFolder(stateDirectory: stateDirectory)
        let left = request(createdAt: Date().timeIntervalSince1970 - 5)
        XCTAssertTrue(LeadChannel.write(left, id: left.id, in: folder))
        let center = LeadRequestCenter()
        var handled: [String] = []
        center.handler = { request, answer in
            handled.append(request.id)
            answer("ok", false)
        }
        let foreign = request()
        center.owns = { $0.id != foreign.id }
        center.start(stateDirectory: stateDirectory)
        defer { center.stop() }
        XCTAssertEqual(handled, [], "an earlier launch's request")
        XCTAssertEqual(
            LeadChannel.take(LeadChannel.Response.self, id: left.id, from: LeadChannel.responsesFolder(stateDirectory: stateDirectory))?.isError,
            true, "refused, not left waiting"
        )
        let mine = request(createdAt: Date().timeIntervalSince1970 + 1)
        for item in [mine, foreign] { XCTAssertTrue(LeadChannel.write(item, id: item.id, in: folder)) }
        center.drain()
        XCTAssertEqual(handled, [mine.id])
        XCTAssertEqual(LeadChannel.waitingRequests(stateDirectory: stateDirectory).map(\.id), [foreign.id], "left to its Nirux")
        XCTAssertEqual(LeadChannel.take(LeadChannel.Response.self, id: mine.id, from: LeadChannel.responsesFolder(stateDirectory: stateDirectory))?.text, "ok")
    }

    // MARK: - The MCP server

    private func context(lead: Bool, inWorkspace: Bool = true, launchID: String = "launch") -> NiruxMCPServer.Context {
        var environment = ["NIRUX_AGENT_UUID": UUID().uuidString, "NIRUX_LAUNCH_ID": launchID]
        if inWorkspace { environment["NIRUX_WORKSPACE_ID"] = UUID().uuidString }
        if lead { environment["NIRUX_LEAD"] = "1" }
        var context = NiruxMCPServer.Context(
            workingDirectory: stateDirectory.path, environment: environment, stateDirectory: stateDirectory,
            claudeProjects: stateDirectory.appendingPathComponent("projects")
        )
        context.leadTimeout = 5
        return context
    }

    private func send(_ message: [String: Any], context: NiruxMCPServer.Context) throws -> [String: Any] {
        let line = try JSONSerialization.data(withJSONObject: message)
        let reply = try XCTUnwrap(NiruxMCPServer.reply(to: line, context: context))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: reply) as? [String: Any])
    }

    private func call(_ tool: String, _ arguments: [String: Any], context: NiruxMCPServer.Context) throws -> [String: Any] {
        try send(["jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": ["name": tool, "arguments": arguments]], context: context)
    }

    /// A Lead sees and calls the Lead's tools; another workspace's agent a
    /// task's, the same names scoped to its sub-tasks; an agent that can't
    /// name its workspace neither. Every agent has them pre-allowed, so a
    /// call never asks.
    func testEachAgentHasItsRolesTools() throws {
        let list = ["jsonrpc": "2.0", "id": 0, "method": "tools/list"] as [String: Any]
        let names = { (context: NiruxMCPServer.Context) in
            ((try self.send(list, context: context)["result"] as? [String: Any])?["tools"] as? [[String: Any]])?.compactMap { $0["name"] as? String }
        }
        XCTAssertEqual(try names(context(lead: true)), [HistorySearchTool.name, MemorySearchTool.name, FlagKnowledgeTool.name] + LeadTools.names)
        XCTAssertEqual(try names(context(lead: false)), [HistorySearchTool.name, MemorySearchTool.name, FlagKnowledgeTool.name] + TaskTools.names)
        XCTAssertEqual(try names(context(lead: false, inWorkspace: false)), [HistorySearchTool.name, MemorySearchTool.name])
        // A workspace opened by a link from outside Nirux has no launch id.
        XCTAssertEqual(try names(context(lead: false, launchID: "")), [HistorySearchTool.name, MemorySearchTool.name])
        XCTAssertNotNil(try call(LeadTools.readThread, ["task": "sample"], context: context(lead: false))["error"])
        XCTAssertNotNil(LeadTools.problem(tool: LeadTools.readThread, arguments: [:]))
        // Both roles expose the same start options.
        for lead in [true, false] {
            let tools = (try send(list, context: context(lead: lead))["result"] as? [String: Any])?["tools"] as? [[String: Any]]
            let start = tools?.first { $0["name"] as? String == LeadTools.startTask }
            let properties = (start?["inputSchema"] as? [String: Any])?["properties"] as? [String: Any]
            XCTAssertEqual(properties.map { Set($0.keys).isSuperset(of: ["description", "title", "branch", "goal"]) }, true, "lead: \(lead)")
        }
        XCTAssertNotNil(try call(LeadTools.queueMerge, ["prs": [1]], context: context(lead: false))["error"], "the Lead's only")
        XCTAssertNotNil(try call(LeadTools.listTasks, [:], context: context(lead: false, inWorkspace: false))["error"], "unknown outside")
        let allowed = NiruxMCPServer.claudeArguments(executable: "/x/Nirux").first { $0.hasPrefix("--allowedTools=") }
        for name in LeadTools.names + [FlagKnowledgeTool.name] { XCTAssertEqual(allowed?.contains("mcp__nirux__\(name)"), true) }
    }

    func testThePlansToolsAreListedOnlyWhereTheDayPlanIsOn() throws {
        let list = ["jsonrpc": "2.0", "id": 0, "method": "tools/list"] as [String: Any]
        let names = { (context: NiruxMCPServer.Context) in
            ((try self.send(list, context: context)["result"] as? [String: Any])?["tools"] as? [[String: Any]])?.compactMap { $0["name"] as? String }
        }
        var lead = context(lead: true)
        var task = context(lead: false)
        lead.environment["NIRUX_PROFILE_ID"] = "plans"
        task.environment["NIRUX_PROFILE_ID"] = "plans"
        XCTAssertEqual(try names(lead), [HistorySearchTool.name, MemorySearchTool.name, FlagKnowledgeTool.name] + LeadTools.names)
        let defaults = stateDirectory.appendingPathComponent("projects/plans/defaults.json")
        try FileManager.default.createDirectory(at: defaults.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"schemaVersion": 1, "dayPlan": true}"#.utf8).write(to: defaults)
        XCTAssertEqual(try names(lead), [HistorySearchTool.name, MemorySearchTool.name, FlagKnowledgeTool.name] + LeadTools.names + PlanTools.leadNames)
        XCTAssertEqual(try names(task), [HistorySearchTool.name, MemorySearchTool.name, FlagKnowledgeTool.name] + TaskTools.names + PlanTools.taskNames)
        let allowed = NiruxMCPServer.claudeArguments(executable: "/x/Nirux").first { $0.hasPrefix("--allowedTools=") }
        for name in PlanTools.names {
            XCTAssertEqual(allowed?.contains("mcp__nirux__\(name)"), true)
            XCTAssertNil(LeadTools.problem(tool: name, arguments: [:]), "the app parses its arguments")
        }
    }

    func testQueueControlsAreScopedToLeadsAndValidateArguments() throws {
        for tool in [LeadTools.mergeQueueStatus, LeadTools.stopMergeQueue] {
            let definition = try XCTUnwrap(LeadTools.definitions.first { $0["name"] as? String == tool })
            let hints = try XCTUnwrap(definition["annotations"] as? [String: Bool])
            XCTAssertEqual(hints["readOnlyHint"], tool == LeadTools.mergeQueueStatus)
            XCTAssertFalse(TaskTools.names.contains(tool))
            XCTAssertNil(LeadTools.problem(tool: tool, arguments: [:]))
            XCTAssertNotNil(LeadTools.problem(tool: tool, arguments: ["repo": 1]))
        }
        for invalid: Any in [1, "true", NSNull()] {
            XCTAssertNotNil(LeadTools.problem(tool: LeadTools.queueMerge, arguments: ["prs": [12], "replace": invalid]))
        }
    }

    func testOnlyTheLeadCanSetATasksDependency() throws {
        let start = try XCTUnwrap(LeadTools.definitions.first { $0["name"] as? String == LeadTools.startTask })
        let schema = try XCTUnwrap(start["inputSchema"] as? [String: Any])
        XCTAssertNotNil((schema["properties"] as? [String: Any])?["after"])
        XCTAssertEqual(schema["required"] as? [String], ["description"])
        XCTAssertTrue(LeadTools.names.contains(LeadTools.setTaskAfter))
        XCTAssertFalse(TaskTools.names.contains(LeadTools.setTaskAfter))
        XCTAssertNil(LeadTools.problem(tool: LeadTools.setTaskAfter, arguments: ["task": "Docs"]))
        XCTAssertNotNil(LeadTools.problem(tool: LeadTools.setTaskAfter, arguments: ["task": "Docs", "after": " "]))
        XCTAssertNotNil(LeadTools.problem(tool: LeadTools.startTask, arguments: ["description": "Docs", "after": false]))
    }

    /// set_task_context needs one field at least, a string within the
    /// limit; "" clears one, null leaves it out. One line on the row.
    func testTaskContextArgumentsAreCheckedBeforeTheApp() {
        let problem = { (arguments: [String: Any]) in LeadTools.problem(tool: LeadTools.setTaskContext, arguments: arguments) }
        let longest = String(repeating: "x", count: LeadTools.maxContextLength)
        XCTAssertNil(problem(["task": "a", "blocker": ""]), "an empty string clears it")
        XCTAssertNil(problem(["task": "a", "next_step": longest, "blocker": NSNull()]))
        XCTAssertNotNil(problem(["task": "a", "next_step": longest + "x"]))
        XCTAssertNotNil(problem(["task": "a"]))
        XCTAssertNotNil(problem(["task": "a", "blocker": NSNull()]), "null is left out")
        XCTAssertNotNil(problem(["task": "a", "next_step": 3]))
        XCTAssertNotNil(problem(["next_step": "x"]))
        XCTAssertEqual(LeadTools.contextText(["next_step": " write\n\tthe import\u{202E} side "], "next_step"), .some("write the import side"))
    }

    /// start_task needs a description; a title its row shows whole (a
    /// sub-task's is shorter), a goal of one short line and a valid branch
    /// name when given, null being left out.
    func testStartTaskArgumentsAreCheckedBeforeTheApp() {
        let problem = { (arguments: [String: Any]) in LeadTools.problem(tool: LeadTools.startTask, arguments: arguments) }
        let longest = String(repeating: "t", count: LeadTools.maxTaskTitleLength)
        let subtaskLongest = ["description": "x", "title": String(repeating: "t", count: LeadTools.maxSubtaskTitleLength)]
        XCTAssertNil(LeadTools.problem(tool: LeadTools.startTask, arguments: subtaskLongest, subtask: true))
        XCTAssertNotNil(LeadTools.problem(tool: LeadTools.startTask, arguments: ["description": "x", "title": longest], subtask: true))
        let goal = String(repeating: "g", count: LeadTools.maxGoalLength)
        XCTAssertNil(problem(["description": "x", "goal": goal]))
        XCTAssertNotNil(problem(["description": "x", "goal": goal + "g"]))
        XCTAssertNotNil(problem(["description": "x", "goal": 3]))
        XCTAssertNotNil(problem(["description": "x", "goal": " \n\t "]))
        XCTAssertNil(problem(["description": "x", "goal": NSNull()]))
        XCTAssertNil(problem(["description": "x", "title": longest, "branch": "fix/stale-labels"]))
        XCTAssertNil(problem(["description": "x", "title": NSNull(), "branch": NSNull()]))
        XCTAssertNotNil(problem(["title": "CSV export"]))
        XCTAssertNotNil(problem(["description": "x", "title": longest + "t"]))
        XCTAssertNotNil(problem(["description": "x", "title": " \n "]))
        XCTAssertNotNil(problem(["description": "x", "branch": "feat/a..b"]))
        XCTAssertNotNil(problem(["description": "x", "branch": "origin/main"]), "it would hide origin's")
        XCTAssertNotNil(problem(["description": "x", "branch": 3]))
        XCTAssertEqual(
            LeadTools.startOptions(["title": " CSV\n export ", "branch": "fix/x", "goal": "Export\n orders"]),
            NewTask.StartOptions(title: "CSV export", branch: "fix/x", goal: "Export orders")
        )
    }

    /// reply takes a message, or accept: true (a JSON boolean) in its place.
    func testReplyArgumentsAreCheckedBeforeTheApp() {
        let problem = { (arguments: [String: Any]) in LeadTools.problem(tool: LeadTools.reply, arguments: arguments) }
        XCTAssertNil(problem(["question": "q", "message": "Yes"]))
        XCTAssertNil(problem(["question": "q", "accept": true]))
        XCTAssertNil(problem(["question": "q", "accept": false, "message": "Yes"]))
        XCTAssertNotNil(problem(["question": "q", "accept": true, "message": "Yes"]), "one or the other")
        XCTAssertNil(problem(["question": "q", "accept": true, "message": NSNull()]), "a null message is left out")
        XCTAssertNotNil(problem(["question": "q", "accept": false]))
        XCTAssertNotNil(problem(["question": "q", "accept": 1]), "a number isn't true")
        XCTAssertNotNil(problem(["accept": true]))
    }

    /// propose_rule needs a rule of one or two lines and where the defect
    /// showed up; nothing that would hide part of the brief.
    func testProposedRuleArgumentsAreCheckedBeforeTheApp() {
        let problem = { (arguments: [String: Any]) in LeadTools.problem(tool: LeadTools.proposeRule, arguments: arguments) }
        let longest = String(repeating: "x", count: LearnedRules.maxRuleLength)
        XCTAssertNil(problem(["rule": " Tests wait\non state. ", "evidence": "#395, #417"]))
        XCTAssertNil(problem(["rule": longest, "evidence": "#1"]))
        XCTAssertNotNil(problem(["rule": longest + "x", "evidence": "#1"]))
        XCTAssertNotNil(problem(["rule": " \n ", "evidence": "#1"]))
        XCTAssertNotNil(problem(["rule": "Wait on state.", "evidence": " "]))
        XCTAssertNotNil(problem(["rule": "Wait on state."]))
        XCTAssertNotNil(problem(["rule": 3, "evidence": "#1"]))
        XCTAssertNotNil(problem(["rule": "Wait <!-- on state", "evidence": "#1"]))
    }

    /// A call is checked here first, then carried to the app and back.
    func testALeadsCallReachesTheAppAndComesBack() throws {
        let missing = try XCTUnwrap(try call(LeadTools.startTask, [:], context: context(lead: true))["result"] as? [String: Any])
        XCTAssertEqual(missing["isError"] as? Bool, true)
        XCTAssertEqual(LeadChannel.takeRequests(stateDirectory: stateDirectory), [], "a bad call never reaches the app")

        _ = answerRequests(1, with: "answered")
        let result = try XCTUnwrap(try call(LeadTools.listTasks, [:], context: context(lead: true))["result"] as? [String: Any])
        XCTAssertEqual(result["isError"] as? Bool, false)
        XCTAssertEqual((result["content"] as? [[String: Any]])?.first?["text"] as? String, "answered list_tasks")
    }

    func testSpaceToolsAreTheLeadsAndCheckTheirArguments() throws {
        let spaceTools = [
            LeadTools.listSpaces, LeadTools.createSpace, LeadTools.editSpace,
            LeadTools.deleteSpace, LeadTools.moveTaskToSpace
        ]
        for tool in spaceTools {
            let definition = try XCTUnwrap(LeadTools.definitions.first { $0["name"] as? String == tool }, tool)
            let schema = try XCTUnwrap(definition["inputSchema"] as? [String: Any])
            XCTAssertEqual(schema["additionalProperties"] as? Bool, false, tool)
            let hints = try XCTUnwrap(definition["annotations"] as? [String: Bool])
            XCTAssertEqual(hints["readOnlyHint"], tool == LeadTools.listSpaces, tool)
            XCTAssertEqual(hints["destructiveHint"], tool == LeadTools.deleteSpace, tool)
            XCTAssertFalse(TaskTools.names.contains(tool), tool)
        }

        let leadListTasks = try XCTUnwrap(LeadTools.definitions.first { $0["name"] as? String == LeadTools.listTasks })
        let leadListProps = try XCTUnwrap((leadListTasks["inputSchema"] as? [String: Any])?["properties"] as? [String: Any])
        XCTAssertNotNil(leadListProps["space"])
        let taskListTasks = try XCTUnwrap(TaskTools.definitions.first { $0["name"] as? String == LeadTools.listTasks })
        let taskListProps = try XCTUnwrap((taskListTasks["inputSchema"] as? [String: Any])?["properties"] as? [String: Any])
        XCTAssertNil(taskListProps["space"])

        XCTAssertNil(LeadTools.problem(tool: LeadTools.listSpaces, arguments: [:]))
        XCTAssertNil(LeadTools.problem(tool: LeadTools.listTasks, arguments: ["space": "General"]))
        XCTAssertNotNil(LeadTools.problem(tool: LeadTools.listTasks, arguments: ["space": "  "]))

        XCTAssertNil(LeadTools.problem(tool: LeadTools.createSpace, arguments: ["name": "Ops", "color": "#aabbcc", "anchors": ["/tmp"]]))
        XCTAssertNotNil(LeadTools.problem(tool: LeadTools.createSpace, arguments: ["name": "   "]))
        XCTAssertNotNil(LeadTools.problem(tool: LeadTools.createSpace, arguments: ["name": "A\nB"]))
        XCTAssertNotNil(LeadTools.problem(tool: LeadTools.createSpace, arguments: ["name": "Ops", "color": "7AA2F7"]))
        XCTAssertNotNil(LeadTools.problem(tool: LeadTools.createSpace, arguments: ["name": "Ops", "color": "#GGGGGG"]))
        XCTAssertNotNil(LeadTools.problem(tool: LeadTools.createSpace, arguments: ["name": "Ops", "anchors": [""]]))
        XCTAssertNil(LeadTools.problem(tool: LeadTools.createSpace, arguments: ["name": "Ops", "anchors": ["~/Projects/ops"]]))
        XCTAssertNotNil(LeadTools.problem(tool: LeadTools.createSpace, arguments: ["name": "Ops", "anchors": ["Projects/ops"]]))
        XCTAssertNotNil(LeadTools.problem(tool: LeadTools.createSpace, arguments: ["name": "Ops", "move_anchors": "yes"]))

        XCTAssertNil(LeadTools.problem(tool: LeadTools.editSpace, arguments: ["space": "Ops", "color": "#9ECE6A"]))
        XCTAssertNotNil(LeadTools.problem(tool: LeadTools.editSpace, arguments: ["space": "Ops"]), "needs at least one change")
        XCTAssertNotNil(LeadTools.problem(tool: LeadTools.editSpace, arguments: ["space": "Ops", "name": "  "]))
        XCTAssertNotNil(LeadTools.problem(tool: LeadTools.editSpace, arguments: ["space": "Ops", "color": "#12345"]))
        XCTAssertNotNil(LeadTools.problem(tool: LeadTools.editSpace, arguments: ["space": "Ops", "add_anchors": [1]]))
        XCTAssertNotNil(LeadTools.problem(tool: LeadTools.editSpace, arguments: ["space": "Ops", "add_anchors": ["."]]))
        XCTAssertNil(LeadTools.problem(tool: LeadTools.editSpace, arguments: ["space": "Ops", "remove_anchors": ["api"]]))

        XCTAssertNil(LeadTools.problem(tool: LeadTools.deleteSpace, arguments: ["space": "Ops"]))
        XCTAssertNil(LeadTools.problem(tool: LeadTools.deleteSpace, arguments: ["space": "Ops", "move_tasks_to": "General"]))
        XCTAssertNotNil(LeadTools.problem(tool: LeadTools.deleteSpace, arguments: [:]))
        XCTAssertNotNil(LeadTools.problem(tool: LeadTools.deleteSpace, arguments: ["space": "Ops", "move_tasks_to": "  "]))

        XCTAssertNil(LeadTools.problem(tool: LeadTools.moveTaskToSpace, arguments: ["task": "Fix", "to_space": "General"]))
        XCTAssertNil(LeadTools.problem(tool: LeadTools.moveTaskToSpace, arguments: [
            "task": "Fix", "to_space": "General", "from_space": "Ops"
        ]))
        XCTAssertNotNil(LeadTools.problem(tool: LeadTools.moveTaskToSpace, arguments: ["task": "Fix"]))
        XCTAssertNotNil(LeadTools.problem(tool: LeadTools.moveTaskToSpace, arguments: ["to_space": "General"]))
        XCTAssertNotNil(LeadTools.problem(tool: LeadTools.moveTaskToSpace, arguments: [
            "task": "Fix", "to_space": "General", "from_space": " "
        ]))

    }
}
