import Foundation

/// `Nirux --hook claude --mcp`: the Model Context Protocol server Nirux
/// gives the Claude agents it launches (`claudeArguments`), over stdin and
/// stdout, one JSON-RPC message per line. Its tools are read-only views of
/// the project: `history_search` (see HistorySearch) for now, room for
/// more. Spelled as a hook, like the status line, so that an older build at
/// the same path (a rollback) takes the messages for a hook payload instead
/// of launching its UI: it waits for the end of stdin, records nothing, and
/// Claude reports the server as failed. See "Agent history search" in
/// docs/projects.md.
enum NiruxMCPServer {
    static let serverName = "nirux"
    /// Newest first: a client asking for another gets the first.
    static let protocolVersions = ["2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"]
    static let maxLineBytes = 1_000_000
    /// What Claude adds to the system prompt for this server.
    static let instructions = """
        Nirux keeps this project's past Claude conversations, across all its worktrees and sessions. \
        Before starting a task, and before asking the user about a past decision, search them with \
        history_search: a feature or branch name, a PR number, a distinctive word.
        """

    /// The Lead's role (docs/spaces.md, "The Lead"), for the Claude of a
    /// space's Lead workspace: what it may do, and what it hands to the
    /// user.
    static let leadInstructions = """
        You are the Lead of this Nirux space. The user talks to you: turn what they ask into tasks, start \
        them, follow them, and bring the user only what needs them. Start tasks only with start_task (not \
        the nirux-worktree skill, not git worktree), one repository per task: a feature across two \
        repositories is two tasks. Read list_tasks first: give a running task more work with tell instead of \
        starting another, and group small related fixes into one task. Don't edit files, commit or switch \
        branches in this checkout. Each task's questions and result are typed into your prompt as [Nirux \
        Mission] messages, only while you are idle: after starting or telling tasks, end your turn; don't \
        poll or sleep. Answer a question with reply when the space brief, the code or this conversation \
        settles it; otherwise hand it over with ask_user and say why. When tasks are ready to merge, propose \
        them with queue_merge: the user starts the queue. Never merge a pull request, remove a worktree or a \
        branch, or act on another space: leave those to the user. After a /clear, list_tasks shows where \
        things stand.
        """

    /// The instructions for whoever launched the server: the Lead's role
    /// comes first in its workspace (`NIRUX_LEAD=1`).
    static func instructions(for context: Context) -> String {
        context.isLead ? leadInstructions + "\n\n" + instructions : instructions
    }

    /// `--mcp-config=<this server>` and `--allowedTools=<its tools>` for
    /// `claude`, unquoted. The config goes inline, not in a file: Claude
    /// refuses to start when a config file is missing, and a column
    /// replays its launch line on restart. The `=` forms keep the variadic
    /// options from taking the next argument (a handover prompt). The
    /// tools don't ask: history_search only reads the project, and the
    /// Lead's act through the app, within the Lead's space only.
    static func claudeArguments(executable: String) -> [String] {
        let server: [String: Any] = ["type": "stdio", "command": executable, "args": ["--hook", "claude", "--mcp"]]
        let config = json(["mcpServers": [serverName: server]]).flatMap { String(bytes: $0, encoding: .utf8) } ?? "{}"
        let allowed = toolNames.map { "mcp__\(serverName)__\($0)" }.joined(separator: ",")
        return ["--mcp-config=" + config, "--allowedTools=" + allowed]
    }

    /// Every tool, pre-allowed for every Claude Nirux launches; the Lead's
    /// are listed to a Lead only (and the app checks each call).
    static let toolNames = [HistorySearchTool.name] + LeadTools.names

    /// Who runs the server, and where.
    struct Context: Sendable {
        var workingDirectory: String
        var environment: [String: String]
        var stateDirectory: URL
        /// `~/.claude/projects`, or under `CLAUDE_CONFIG_DIR`.
        var claudeProjects: URL
        var timeZone = TimeZone.current
        var gitPath = "/usr/bin/git"

        /// The space (`NIRUX_PROFILE_ID`) of the column that launched the
        /// agent; nil outside Nirux.
        var spaceID: String? { nonEmpty("NIRUX_PROFILE_ID") }
        /// Claude's session: the one that started the server. Claude sets
        /// it once, so after `/clear` or `/resume` it names the previous one.
        var sessionID: String? { nonEmpty("CLAUDE_CODE_SESSION_ID") }
        /// Launched in a space's Lead workspace (see `WorkspaceState.isLead`).
        var isLead: Bool { environment[WorkspaceState.leadEnvironmentKey] == "1" }
        /// Tests shorten the Lead's calls' wait for the app.
        var leadTimeout: TimeInterval?

        func nonEmpty(_ key: String) -> String? {
            environment[key].flatMap { $0.isEmpty ? nil : $0 }
        }

        static func current() -> Context {
            let environment = ProcessInfo.processInfo.environment
            let configDirectory = environment["CLAUDE_CONFIG_DIR"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
                ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude")
            return Context(
                workingDirectory: FileManager.default.currentDirectoryPath,
                environment: environment,
                stateDirectory: Persistence.stateDirectory,
                claudeProjects: configDirectory.appendingPathComponent("projects")
            )
        }
    }

    struct ToolResult: Equatable {
        let text: String
        let isError: Bool
    }

    /// Answers each line of stdin until it closes, or Claude stops
    /// reading: a closed pipe ends the server rather than killing it.
    static func run(context: Context = .current()) -> Int32 {
        signal(SIGPIPE, SIG_IGN)
        let output = ServerOutput()
        // A Lead's call can wait minutes for the app: it answers on its
        // own, so pings and other calls are read and answered meanwhile.
        let slowCalls = DispatchQueue(label: "nirux.mcp.lead-calls", attributes: .concurrent)
        while let line = readLine(strippingNewline: true), !output.isClosed {
            let data = Data(line.utf8)
            if isLeadToolCall(data, context: context) {
                slowCalls.async { output.write(reply(to: data, context: context)) }
            } else {
                output.write(reply(to: data, context: context))
            }
        }
        return 0
    }

    /// A `tools/call` of one of the Lead's tools, from a Lead.
    static func isLeadToolCall(_ line: Data, context: Context) -> Bool {
        guard context.isLead, line.count <= maxLineBytes,
              let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
              object["method"] as? String == "tools/call",
              let name = (object["params"] as? [String: Any])?["name"] as? String
        else { return false }
        return LeadTools.names.contains(name)
    }

    /// The answer to one message, without its newline; nil for a
    /// notification, or a response.
    static func reply(to line: Data, context: Context) -> Data? {
        guard line.count <= maxLineBytes, let message = try? JSONSerialization.jsonObject(with: line) else {
            return response(id: NSNull(), error: (-32700, "Parse error"))
        }
        // Batches went away in 2025-06-18; no client sends them.
        guard let object = message as? [String: Any] else {
            return response(id: NSNull(), error: (-32600, "Invalid request"))
        }
        guard let method = object["method"] as? String, let id = object["id"], isRequestID(id) else { return nil }
        let params = object["params"] as? [String: Any] ?? [:]
        switch method {
        case "initialize":
            let asked = params["protocolVersion"] as? String
            let version = asked.flatMap { protocolVersions.contains($0) ? $0 : nil } ?? protocolVersions[0]
            return response(id: id, result: [
                "protocolVersion": version,
                "capabilities": ["tools": ["listChanged": false]],
                "serverInfo": [
                    "name": serverName, "title": "Nirux",
                    "version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
                ],
                "instructions": instructions(for: context)
            ])
        case "ping":
            return response(id: id, result: [:])
        case "tools/list":
            let lead = context.isLead ? LeadTools.definitions : []
            return response(id: id, result: ["tools": [HistorySearchTool.definition] + lead])
        case "tools/call":
            let name = params["name"] as? String
            guard let name, name == HistorySearchTool.name || (context.isLead && LeadTools.names.contains(name)) else {
                return response(id: id, error: (-32602, "Unknown tool: \(name ?? "none")"))
            }
            guard let arguments = params["arguments"] as? [String: Any] ?? (params["arguments"] == nil ? [:] : nil) else {
                return response(id: id, error: (-32602, "The arguments must be an object."))
            }
            let result = name == HistorySearchTool.name
                ? HistorySearchTool.call(arguments, context: context)
                : callLeadTool(name, arguments: arguments, context: context)
            return response(id: id, result: [
                "content": [["type": "text", "text": result.text]],
                "isError": result.isError
            ])
        default:
            return response(id: id, error: (-32601, "Method not found: \(method)"))
        }
    }

    /// A Lead's tool: checked here, then sent to the running app, which
    /// acts and answers (see LeadChannel).
    static func callLeadTool(_ name: String, arguments: [String: Any], context: Context) -> ToolResult {
        if let problem = LeadTools.problem(tool: name, arguments: arguments) {
            return ToolResult(text: problem, isError: true)
        }
        guard let workspaceID = context.nonEmpty("NIRUX_WORKSPACE_ID"), let agentUUID = context.nonEmpty("NIRUX_AGENT_UUID"),
              let data = try? JSONSerialization.data(withJSONObject: arguments), let json = String(data: data, encoding: .utf8)
        else { return ToolResult(text: "This terminal isn't a Nirux Lead's.", isError: true) }
        let request = LeadChannel.Request(
            id: UUID().uuidString, tool: name, arguments: json,
            workspaceID: workspaceID, agentUUID: agentUUID, createdAt: Date().timeIntervalSince1970
        )
        let take = context.leadTimeout ?? LeadTools.takeTimeout
        let work = context.leadTimeout ?? LeadTools.workTimeout(for: name)
        switch LeadChannel.send(request, stateDirectory: context.stateDirectory, takeTimeout: take, workTimeout: work) {
        case .answered(let response):
            return ToolResult(text: response.text, isError: response.isError)
        case .notTaken:
            return ToolResult(
                text: "Nirux didn't take the call within \(Int(take)) seconds: it may be closed or busy. Nothing was done: "
                    + "try again later, or tell the user.",
                isError: true
            )
        case .stillWorking:
            return ToolResult(
                text: "Nirux took the call but hasn't finished: it may still be doing it. Don't call again; "
                    + "list_tasks shows the result in a moment.",
                isError: true
            )
        }
    }

    /// A string or a finite number: not a boolean, which JSONSerialization
    /// also reads as an NSNumber, nor null, nor `1e400`, which it reads as
    /// infinity and can't write back.
    private static func isRequestID(_ id: Any) -> Bool {
        if id is String { return true }
        guard let number = id as? NSNumber else { return false }
        return CFGetTypeID(number) != CFBooleanGetTypeID() && number.doubleValue.isFinite
    }

    private static func response(id: Any, result: [String: Any]) -> Data? {
        json(["jsonrpc": "2.0", "id": id, "result": result])
    }

    private static func response(id: Any, error: (code: Int, message: String)) -> Data? {
        json(["jsonrpc": "2.0", "id": id, "error": ["code": error.code, "message": error.message]])
    }

    /// One line: JSONSerialization escapes line breaks inside strings. Nil
    /// for what it can't write, rather than its exception.
    private static func json(_ object: [String: Any]) -> Data? {
        guard JSONSerialization.isValidJSONObject(object) else { return nil }
        return try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
    }
}

/// `history_search`: the tool's definition and its call.
enum HistorySearchTool {
    static let name = "history_search"

    static var definition: [String: Any] {
        [
            "name": name,
            "title": "Search the project's history",
            "description": """
                Search this project's past Claude conversations (what the user typed and Claude answered, \
                not tool output), across all its worktrees and sessions. Every term must appear in the same \
                message; case and accents are ignored; "double quotes" make a phrase one term. The \
                conversations may be in another language than yours: use their words. Returns dated \
                excerpts, newest first, with the branch and session.
                """,
            "inputSchema": [
                "type": "object",
                "properties": [
                    "query": ["type": "string", "description": "Words or \"phrases\" a matching message holds."],
                    "before": [
                        "type": "string",
                        "description": "Only messages written before this ISO 8601 date or date and time, to see older matches."
                    ],
                    "limit": [
                        "type": "integer", "minimum": 1, "maximum": HistorySearch.maxLimit,
                        "description": "How many messages to show (default \(HistorySearch.defaultLimit))."
                    ]
                ],
                "required": ["query"],
                "additionalProperties": false
            ],
            "annotations": ["readOnlyHint": true, "destructiveHint": false, "idempotentHint": true, "openWorldHint": false]
        ]
    }

    static func call(_ arguments: [String: Any], context: NiruxMCPServer.Context) -> NiruxMCPServer.ToolResult {
        guard let text = arguments["query"] as? String else { return invalid("query must be a string.") }
        var before: Date?
        if let value = arguments["before"], !(value is NSNull) {
            guard let string = value as? String, let date = HistorySearch.parseDate(string, timeZone: context.timeZone) else {
                return invalid("before must be an ISO 8601 date (2026-10-03) or date and time (2026-10-03T15:45:00Z).")
            }
            before = date
        }
        var limit = HistorySearch.defaultLimit
        if let value = arguments["limit"], !(value is NSNull) {
            guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
                  let whole = Int(exactly: number.doubleValue) else { return invalid("limit must be a whole number.") }
            limit = whole
        }
        let query: HistorySearch.Query
        do {
            query = try HistorySearch.Query(text, before: before, limit: limit)
        } catch {
            return invalid((error as? HistorySearch.InvalidQuery)?.reason ?? "The query can't be read.")
        }
        let started = ProcessInfo.processInfo.systemUptime
        var budget = TranscriptSearch.Budget.standard(now: started)
        let scope = HistorySearch.scope(
            workingDirectory: context.workingDirectory, spaceID: context.spaceID,
            stateDirectory: context.stateDirectory, gitPath: context.gitPath
        )
        let transcripts = HistorySearch.transcripts(in: scope, claudeProjects: context.claudeProjects, budget: &budget)
        let outcome = HistorySearch.search(query, in: transcripts, budget: &budget)
        let answer = HistorySearch.render(
            outcome, of: query, transcripts: transcripts, currentSession: context.sessionID, timeZone: context.timeZone
        )
        if let spaceID = context.spaceID {
            HistorySearchUsage.append(
                HistorySearchUsage.Entry(
                    at: Date().timeIntervalSince1970, session: context.sessionID,
                    agent: context.nonEmpty("NIRUX_AGENT_UUID"), workspace: context.nonEmpty("NIRUX_WORKSPACE_ID"),
                    query: text, before: before.map(HistorySearch.isoTimestamp), limit: query.limit,
                    found: outcome.total, shown: outcome.hits.count, searched: outcome.searched, isCut: outcome.isCut,
                    milliseconds: Int((ProcessInfo.processInfo.systemUptime - started) * 1000)
                ),
                spaceID: spaceID, stateDirectory: context.stateDirectory
            )
        }
        return NiruxMCPServer.ToolResult(text: answer, isError: false)
    }

    private static func invalid(_ reason: String) -> NiruxMCPServer.ToolResult {
        NiruxMCPServer.ToolResult(text: reason, isError: true)
    }
}

/// One line per `history_search` call, to judge whether agents use it:
/// `<state dir>/projects/<space id>/history-search.jsonl`, 0600. Past
/// `maxFileBytes` the file moves to `history-search.1.jsonl`, replacing
/// the previous one. A failed write is dropped: counting never fails a
/// search.
enum HistorySearchUsage {
    static let fileName = "history-search.jsonl"
    static let previousFileName = "history-search.1.jsonl"
    static let maxFileBytes = 2_000_000

    struct Entry: Codable, Equatable {
        var schemaVersion = 1
        /// Epoch seconds.
        var at: TimeInterval
        /// Claude's session.
        var session: String?
        /// The column (`NIRUX_AGENT_UUID`) and workspace.
        var agent: String?
        var workspace: String?
        var query: String
        var before: String?
        var limit: Int
        /// Matching messages; those shown.
        var found: Int
        var shown: Int
        /// Conversations read.
        var searched: Int
        var isCut: Bool
        var milliseconds: Int

        enum CodingKeys: String, CodingKey {
            case schemaVersion = "v"
            case at, session, agent, workspace, query, before, limit, found, shown, searched, isCut, milliseconds
        }
    }

    static func fileURL(spaceID: String, stateDirectory: URL) -> URL? {
        SpaceBrief.directory(spaceID: spaceID, stateDirectory: stateDirectory)?.appendingPathComponent(fileName)
    }

    static func append(_ entry: Entry, spaceID: String, stateDirectory: URL) {
        guard let url = fileURL(spaceID: spaceID, stateDirectory: stateDirectory),
              var line = try? JSONEncoder().encode(entry) else { return }
        line.append(0x0A)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var info = stat()
        if lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG, Int(info.st_size) + line.count > maxFileBytes {
            _ = rename(url.path, url.deletingLastPathComponent().appendingPathComponent(previousFileName).path)
        }
        let descriptor = open(url.path, O_WRONLY | O_APPEND | O_CREAT | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK, 0o600)
        guard descriptor >= 0 else { return }
        defer { close(descriptor) }
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { return }
        _ = line.withUnsafeBytes { write(descriptor, $0.baseAddress, line.count) }
    }
}

/// The server's stdout, one message per line, from any thread. A closed
/// pipe (Claude stopped reading) ends the server.
private final class ServerOutput: @unchecked Sendable {
    private let lock = NSLock()
    private var closed = false

    var isClosed: Bool {
        lock.lock()
        defer { lock.unlock() }
        return closed
    }

    func write(_ reply: Data?) {
        guard var reply else { return }
        reply.append(0x0A)
        lock.lock()
        defer { lock.unlock() }
        guard !closed else { return }
        do {
            try FileHandle.standardOutput.write(contentsOf: reply)
        } catch {
            closed = true
        }
    }
}
