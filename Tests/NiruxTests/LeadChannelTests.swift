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
        let thread = Thread {
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
        let taker = Thread {
            let deadline = Date().addingTimeInterval(5)
            while Date() < deadline, LeadChannel.takeRequests(stateDirectory: directory).isEmpty {
                Thread.sleep(forTimeInterval: 0.02)
            }
        }
        taker.start()
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

    // MARK: - The MCP server

    private func context(lead: Bool) -> NiruxMCPServer.Context {
        var environment = ["NIRUX_WORKSPACE_ID": UUID().uuidString, "NIRUX_AGENT_UUID": UUID().uuidString]
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

    /// Only a Lead sees and calls the Lead's tools; every agent has them
    /// pre-allowed, so a Lead's calls never ask.
    func testOnlyTheLeadHasItsTools() throws {
        let list = ["jsonrpc": "2.0", "id": 0, "method": "tools/list"] as [String: Any]
        let names = { (context: NiruxMCPServer.Context) in
            ((try self.send(list, context: context)["result"] as? [String: Any])?["tools"] as? [[String: Any]])?.compactMap { $0["name"] as? String }
        }
        XCTAssertEqual(try names(context(lead: false)), [HistorySearchTool.name])
        XCTAssertEqual(try names(context(lead: true)), [HistorySearchTool.name] + LeadTools.names)
        XCTAssertNotNil(try call(LeadTools.listTasks, [:], context: context(lead: false))["error"], "unknown elsewhere")
        let allowed = NiruxMCPServer.claudeArguments(executable: "/x/Nirux").first { $0.hasPrefix("--allowedTools=") }
        for name in LeadTools.names { XCTAssertEqual(allowed?.contains("mcp__nirux__\(name)"), true) }
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
}
