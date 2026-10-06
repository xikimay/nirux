import XCTest
@testable import Nirux

/// The tools server Claude runs for the agents Nirux launches (see
/// NiruxMCPServer): the protocol, the history_search call and its usage
/// log, and the arguments that start it.
final class NiruxMCPServerTests: XCTestCase {
    private var folder = ""

    override func setUpWithError() throws {
        try super.setUpWithError()
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("nirux-mcp-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        folder = try XCTUnwrap(temporary.path.realPath)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: folder)
        super.tearDown()
    }

    private var context: NiruxMCPServer.Context {
        NiruxMCPServer.Context(
            workingDirectory: folder + "/repo",
            environment: ["NIRUX_PROFILE_ID": "space", "CLAUDE_CODE_SESSION_ID": "current", "NIRUX_AGENT_UUID": "column"],
            stateDirectory: URL(fileURLWithPath: folder + "/state"),
            claudeProjects: URL(fileURLWithPath: folder + "/projects"),
            timeZone: TimeZone(identifier: "UTC") ?? .current
        )
    }

    private func send(_ message: Any, context: NiruxMCPServer.Context? = nil) throws -> [String: Any]? {
        let line = try JSONSerialization.data(withJSONObject: message)
        guard let reply = NiruxMCPServer.reply(to: line, context: context ?? self.context) else { return nil }
        XCTAssertFalse(reply.contains(0x0A), "one message per line")
        return try XCTUnwrap(JSONSerialization.jsonObject(with: reply) as? [String: Any])
    }

    private func error(_ reply: [String: Any]?) -> Int? {
        (reply?["error"] as? [String: Any])?["code"] as? Int
    }

    private func result(_ reply: [String: Any]?) -> [String: Any]? {
        reply?["result"] as? [String: Any]
    }

    // MARK: - Protocol

    func testHandshakeListsTheReadOnlyTool() throws {
        // Claude probes a newer protocol first and falls back on this error.
        let probe = try send(["jsonrpc": "2.0", "id": "probe", "method": "server/discover"])
        XCTAssertEqual(error(probe), -32601)
        XCTAssertEqual(probe?["id"] as? String, "probe")

        let initialize = result(try send(["jsonrpc": "2.0", "id": 0, "method": "initialize", "params": ["protocolVersion": "2025-06-18"]]))
        XCTAssertEqual(initialize?["protocolVersion"] as? String, "2025-06-18")
        XCTAssertEqual((initialize?["serverInfo"] as? [String: Any])?["name"] as? String, "nirux")
        XCTAssertTrue((initialize?["instructions"] as? String)?.contains("Before starting a task") == true)
        let future = result(try send(["jsonrpc": "2.0", "id": 1, "method": "initialize", "params": ["protocolVersion": "2099-01-01"]]))
        XCTAssertEqual(future?["protocolVersion"] as? String, NiruxMCPServer.protocolVersions[0])

        XCTAssertNil(try send(["jsonrpc": "2.0", "method": "notifications/initialized"]))
        XCTAssertEqual(result(try send(["jsonrpc": "2.0", "id": 2, "method": "ping"]))?.count, 0)

        let tools = try XCTUnwrap(result(try send(["jsonrpc": "2.0", "id": 3, "method": "tools/list"]))?["tools"] as? [[String: Any]])
        XCTAssertEqual(tools.map { $0["name"] as? String }, ["history_search"])
        XCTAssertEqual((tools[0]["inputSchema"] as? [String: Any])?["required"] as? [String], ["query"])
        XCTAssertEqual((tools[0]["annotations"] as? [String: Any])?["readOnlyHint"] as? Bool, true)
    }

    func testBrokenMessagesGetErrorsAndResponsesNone() throws {
        let garbage = try XCTUnwrap(NiruxMCPServer.reply(to: Data("{oops".utf8), context: context))
        let parsed = try XCTUnwrap(JSONSerialization.jsonObject(with: garbage) as? [String: Any])
        XCTAssertEqual(error(parsed), -32700)
        XCTAssertTrue(parsed["id"] is NSNull)
        XCTAssertEqual(error(try send([["jsonrpc": "2.0", "id": 1, "method": "ping"]])), -32600)
        XCTAssertNil(try send(["jsonrpc": "2.0", "id": 4, "result": [:]]), "a response to the server")
        XCTAssertNil(try send(["jsonrpc": "2.0", "id": true, "method": "ping"]), "a boolean is no id")
        // Read as infinity, which can't be written back: no answer, no crash.
        XCTAssertNil(NiruxMCPServer.reply(to: Data(#"{"jsonrpc":"2.0","id":-1e400,"method":"ping"}"#.utf8), context: context))
        XCTAssertEqual(error(try send(["jsonrpc": "2.0", "id": 5, "method": "tools/call", "params": ["name": "rm"]])), -32602)
        XCTAssertEqual(error(try send([
            "jsonrpc": "2.0", "id": 6, "method": "tools/call", "params": ["name": "history_search", "arguments": "B3b"]
        ])), -32602)
    }

    // MARK: - history_search

    private func call(_ arguments: [String: Any]) throws -> (text: String, isError: Bool) {
        let reply = result(try send(["jsonrpc": "2.0", "id": 7, "method": "tools/call", "params": [
            "name": "history_search", "arguments": arguments
        ]]))
        let content = try XCTUnwrap(reply?["content"] as? [[String: Any]])
        return (try XCTUnwrap(content.first?["text"] as? String), try XCTUnwrap(reply?["isError"] as? Bool))
    }

    func testSearchAnswersAndEachCallIsCounted() throws {
        try FileManager.default.createDirectory(atPath: folder + "/repo", withIntermediateDirectories: true)
        try HistorySearchTests.git(["init", "-q"], at: folder + "/repo")
        let transcript = folder + "/projects/" + HistorySearch.claudeFolderName(folder + "/repo") + "/past.jsonl"
        try FileManager.default.createDirectory(
            atPath: (transcript as NSString).deletingLastPathComponent, withIntermediateDirectories: true
        )
        try [
            try HistorySearchTests.prompt("Freeze Telegram for now.", at: "2026-10-01T08:00:00Z", cwd: folder + "/repo"),
            try HistorySearchTests.answer("Telegram is frozen.", at: "2026-10-01T08:01:00Z")
        ].joined(separator: "\n").write(toFile: transcript, atomically: true, encoding: .utf8)

        let found = try call(["query": "telegram frozen", "limit": 5])
        XCTAssertFalse(found.isError)
        XCTAssertTrue(
            found.text.contains("[1] 2026-10-01 08:01 +00:00 · Claude · branch main · in repo · session past\n> Telegram is frozen."),
            found.text
        )
        XCTAssertTrue(try call(["query": "telegram", "before": "2026-10-01T08:00:30Z"]).text.contains("1 found in 1 conversation"))

        for (arguments, reason) in [
            (["limit": 3], "query must be a string"),
            (["query": "x", "limit": "3"], "limit must be a whole number"),
            (["query": "x", "limit": 2.5], "limit must be a whole number"),
            (["query": "x", "before": "last week"], "before must be an ISO 8601 date"),
            (["query": " "], "The query is empty")
        ] as [([String: Any], String)] {
            let answer = try call(arguments)
            XCTAssertTrue(answer.isError, reason)
            XCTAssertTrue(answer.text.hasPrefix(reason), answer.text)
        }

        let log = try XCTUnwrap(HistorySearchUsage.fileURL(spaceID: "space", stateDirectory: context.stateDirectory))
        let lines = try String(contentsOf: log, encoding: .utf8).split(separator: "\n")
        XCTAssertEqual(lines.count, 2, "only searches are counted")
        let first = try JSONDecoder().decode(HistorySearchUsage.Entry.self, from: Data(lines[0].utf8))
        XCTAssertEqual(first.session, "current")
        XCTAssertEqual(first.agent, "column")
        XCTAssertEqual(first.query, "telegram frozen")
        XCTAssertEqual([first.limit, first.found, first.shown, first.searched], [5, 1, 1, 1])
        let second = try JSONDecoder().decode(HistorySearchUsage.Entry.self, from: Data(lines[1].utf8))
        XCTAssertEqual(second.before, "2026-10-01T08:00:30.000Z")
        let mode = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: log.path)[.posixPermissions] as? Int)
        XCTAssertEqual(mode, 0o600)

        // Outside Nirux there is no space to count in.
        var outside = context
        outside.environment = [:]
        XCTAssertNotNil(try send(["jsonrpc": "2.0", "id": 8, "method": "tools/call", "params": [
            "name": "history_search", "arguments": ["query": "telegram"]
        ]], context: outside))
        XCTAssertEqual(try String(contentsOf: log, encoding: .utf8).split(separator: "\n").count, 2)
    }

    func testTheUsageLogStaysBoundedAndFollowsNoLink() throws {
        let state = URL(fileURLWithPath: folder + "/state")
        let log = try XCTUnwrap(HistorySearchUsage.fileURL(spaceID: "space", stateDirectory: state))
        let entry = HistorySearchUsage.Entry(
            at: 0, query: String(repeating: "q", count: 1_000), limit: 8, found: 0, shown: 0, searched: 0, isCut: false,
            milliseconds: 1
        )
        for _ in 0..<(HistorySearchUsage.maxFileBytes / 1_000 + 10) {
            HistorySearchUsage.append(entry, spaceID: "space", stateDirectory: state)
        }
        let previous = log.deletingLastPathComponent().appendingPathComponent(HistorySearchUsage.previousFileName)
        XCTAssertLessThanOrEqual(try Data(contentsOf: log).count, HistorySearchUsage.maxFileBytes)
        XCTAssertGreaterThan(try Data(contentsOf: previous).count, HistorySearchUsage.maxFileBytes - 2_000)

        let target = folder + "/elsewhere.txt"
        try "kept\n".write(toFile: target, atomically: true, encoding: .utf8)
        try FileManager.default.removeItem(at: log)
        try FileManager.default.createSymbolicLink(atPath: log.path, withDestinationPath: target)
        HistorySearchUsage.append(entry, spaceID: "space", stateDirectory: state)
        XCTAssertEqual(try String(contentsOfFile: target, encoding: .utf8), "kept\n")
    }

    // MARK: - Launch

    /// The arguments survive the shell as one word each, the config parses,
    /// and the handover prompt stays a prompt.
    @MainActor
    func testClaudeLaunchLineStartsTheServer() throws {
        let executable = "/Applications/It's Nirux.app/Contents/MacOS/Nirux"
        let command = NiruxShellView.claudeCommand(mode: .default, niruxExecutable: executable, handoverPrompt: "Go")
        XCTAssertTrue(command.hasPrefix("command claude '--mcp-config="), command)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "printf '%s\\n' " + command.dropFirst("command claude ".count)]
        let output = Pipe()
        process.standardOutput = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let words = try XCTUnwrap(String(bytes: data, encoding: .utf8)).split(separator: "\n").map(String.init)
        XCTAssertEqual(words.count, 3, words.joined(separator: "\n"))
        XCTAssertEqual(words.last, "Go")
        XCTAssertEqual(words[1], "--allowedTools=mcp__nirux__history_search")
        let config = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(words[0].dropFirst("--mcp-config=".count).utf8)) as? [String: Any])
        let server = try XCTUnwrap((config["mcpServers"] as? [String: Any])?["nirux"] as? [String: Any])
        XCTAssertEqual(server["command"] as? String, executable)
        XCTAssertEqual(server["args"] as? [String], ["--hook", "claude", "--mcp"])

        XCTAssertEqual(NiruxShellView.claudeCommand(mode: .default), "command claude")
    }
}
