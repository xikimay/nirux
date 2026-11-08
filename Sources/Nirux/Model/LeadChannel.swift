import Foundation

/// How the Lead's tools reach the running app (docs/spaces.md, "The
/// Lead"): the MCP server Claude runs for a space's Lead (`Nirux --hook
/// claude --mcp`, see NiruxMCPServer) writes one request per tool call
/// into `<state dir>/lead/requests/`, and the app answers into
/// `<state dir>/lead/responses/` under the same id. Each file is written
/// whole under a temporary name, then renamed, 0600 in 0700 folders.
///
/// A request names the terminal it comes from (its workspace and column):
/// that proves nothing, so the app checks it against its own state (see
/// `NiruxShellView.handleLeadRequest`) before acting.
enum LeadChannel {
    static let protocolVersion = 1
    /// A request nobody took within this long is dropped: its caller gave up.
    static let requestLifetime: TimeInterval = 600

    struct Request: Codable, Equatable, Sendable {
        var v = LeadChannel.protocolVersion
        let id: String
        let tool: String
        /// The tool's arguments, a JSON object.
        let arguments: String
        let workspaceID: String
        let agentUUID: String
        /// Epoch seconds.
        let createdAt: TimeInterval

        /// The arguments as an object; empty when they aren't one.
        var argumentObject: [String: Any] {
            (try? JSONSerialization.jsonObject(with: Data(arguments.utf8))) as? [String: Any] ?? [:]
        }
    }

    struct Response: Codable, Equatable, Sendable {
        let id: String
        let text: String
        let isError: Bool
    }

    static func folder(_ name: String, stateDirectory: URL) -> URL {
        stateDirectory.appendingPathComponent("lead", isDirectory: true).appendingPathComponent(name, isDirectory: true)
    }

    static func requestsFolder(stateDirectory: URL) -> URL { folder("requests", stateDirectory: stateDirectory) }

    static func responsesFolder(stateDirectory: URL) -> URL { folder("responses", stateDirectory: stateDirectory) }

    // MARK: - Writing

    /// `value` as `<id>.json` in `folder`, whole or not at all.
    @discardableResult
    static func write<Value: Encodable>(_ value: Value, id: String, in folder: URL) -> Bool {
        guard isIdentifier(id), let data = try? JSONEncoder().encode(value) else { return false }
        let fileManager = FileManager.default
        do {
            try fileManager.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let staging = folder.appendingPathComponent(".\(id).\(UUID().uuidString).tmp")
            guard fileManager.createFile(atPath: staging.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
                return false
            }
            if rename(staging.path, folder.appendingPathComponent(id + ".json").path) != 0 {
                try? fileManager.removeItem(at: staging)
                return false
            }
            return true
        } catch {
            return false
        }
    }

    /// Reads `<id>.json` from `folder` and removes it: each file is read
    /// once. Nil when it isn't there, or doesn't decode.
    static func take<Value: Decodable>(_ type: Value.Type, id: String, from folder: URL) -> Value? {
        let url = folder.appendingPathComponent(id + ".json")
        guard isIdentifier(id), let data = FileManager.default.contents(atPath: url.path) else { return nil }
        try? FileManager.default.removeItem(at: url)
        return try? JSONDecoder().decode(Value.self, from: data)
    }

    // MARK: - The server's side

    /// Sends `request` and waits for the app's answer, at most `timeout`.
    /// Nil when none came: the request is taken back, so a late app never
    /// acts on a call its caller gave up on.
    static func send(
        _ request: Request, stateDirectory: URL, timeout: TimeInterval, pollInterval: TimeInterval = 0.05
    ) -> Response? {
        let requests = requestsFolder(stateDirectory: stateDirectory)
        let responses = responsesFolder(stateDirectory: stateDirectory)
        guard write(request, id: request.id, in: requests) else { return nil }
        let deadline = Date().addingTimeInterval(timeout)
        var interval = max(0.01, pollInterval)
        while true {
            if let response = take(Response.self, id: request.id, from: responses) { return response }
            guard Date() < deadline else { break }
            Thread.sleep(forTimeInterval: min(interval, max(0, deadline.timeIntervalSinceNow)))
            interval = min(0.5, interval * 1.5)
        }
        try? FileManager.default.removeItem(at: requests.appendingPathComponent(request.id + ".json"))
        // Taken meanwhile: its answer may still come, too late to wait for.
        return take(Response.self, id: request.id, from: responses)
    }

    // MARK: - The app's side

    /// Every request waiting, oldest first, each removed as it is read.
    /// Ones of another protocol, too old, or unreadable are dropped.
    static func takeRequests(stateDirectory: URL, now: TimeInterval = Date().timeIntervalSince1970) -> [Request] {
        let folder = requestsFolder(stateDirectory: stateDirectory)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        let requests = names.compactMap { name -> Request? in
            guard name.hasSuffix(".json"), !name.hasPrefix(".") else { return nil }
            return take(Request.self, id: String(name.dropLast(5)), from: folder)
        }
        return requests
            .filter { $0.v == protocolVersion && now - $0.createdAt < requestLifetime }
            .sorted { $0.createdAt < $1.createdAt }
    }

    @discardableResult
    static func respond(_ response: Response, stateDirectory: URL) -> Bool {
        write(response, id: response.id, in: responsesFolder(stateDirectory: stateDirectory))
    }

    /// Answers left behind by callers that gave up (and stray staging
    /// files): removed at launch.
    static func sweep(stateDirectory: URL, now: Date = Date()) {
        for folder in [requestsFolder(stateDirectory: stateDirectory), responsesFolder(stateDirectory: stateDirectory)] {
            let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
            for name in names {
                let url = folder.appendingPathComponent(name)
                let modified = (try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate]) as? Date
                if modified.map({ now.timeIntervalSince($0) > requestLifetime }) ?? true {
                    try? FileManager.default.removeItem(at: url)
                }
            }
        }
    }

    /// Names a file: no path separators or dots.
    static func isIdentifier(_ id: String) -> Bool {
        UUID(uuidString: id) != nil
    }
}
