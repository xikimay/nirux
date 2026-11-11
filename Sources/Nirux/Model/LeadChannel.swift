import Foundation

/// How the Lead's tools reach the running app (docs/design/spaces.md, "The
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
    /// A request nobody took within this long is dropped: its caller takes
    /// it back after `LeadTools.takeTimeout`, so one this old was left by a
    /// caller that died (a `claude` that quit while Nirux was closed).
    static let requestLifetime: TimeInterval = 60

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

    enum Outcome: Equatable {
        case answered(Response)
        /// No Nirux took the request within the wait: it was taken back,
        /// nothing was done.
        case notTaken
        /// A Nirux took it but hasn't answered yet: it may still act.
        case stillWorking
    }

    /// Sends `request`, waits up to `takeTimeout` for a Nirux to take it
    /// (else takes it back: nothing happens), then up to `workTimeout` for
    /// the answer.
    static func send(
        _ request: Request, stateDirectory: URL, takeTimeout: TimeInterval, workTimeout: TimeInterval,
        pollInterval: TimeInterval = 0.05
    ) -> Outcome {
        let requests = requestsFolder(stateDirectory: stateDirectory)
        let responses = responsesFolder(stateDirectory: stateDirectory)
        let requestFile = requests.appendingPathComponent(request.id + ".json")
        guard write(request, id: request.id, in: requests) else { return .notTaken }
        let start = Date()
        var interval = max(0.01, pollInterval)
        while true {
            if let response = take(Response.self, id: request.id, from: responses) { return .answered(response) }
            let taken = !FileManager.default.fileExists(atPath: requestFile.path)
            let elapsed = Date().timeIntervalSince(start)
            if !taken, elapsed >= takeTimeout {
                // Taken back only if nobody claimed it meanwhile.
                if unlink(requestFile.path) == 0 { return .notTaken }
            } else if taken, elapsed >= takeTimeout + workTimeout {
                return take(Response.self, id: request.id, from: responses).map { .answered($0) } ?? .stillWorking
            }
            Thread.sleep(forTimeInterval: interval)
            interval = min(0.5, interval * 1.5)
        }
    }

    // MARK: - The app's side

    /// The requests waiting, oldest first, without taking them: `claim`
    /// takes one. Ones of another protocol, too old, or unreadable are
    /// removed.
    static func waitingRequests(stateDirectory: URL, now: TimeInterval = Date().timeIntervalSince1970) -> [Request] {
        let folder = requestsFolder(stateDirectory: stateDirectory)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        var requests: [Request] = []
        for name in names where name.hasSuffix(".json") && !name.hasPrefix(".") {
            let url = folder.appendingPathComponent(name)
            guard isIdentifier(String(name.dropLast(5))), let data = FileManager.default.contents(atPath: url.path) else { continue }
            guard let request = try? JSONDecoder().decode(Request.self, from: data),
                  request.v == protocolVersion, now - request.createdAt < requestLifetime, request.id + ".json" == name
            else {
                try? FileManager.default.removeItem(at: url)
                continue
            }
            requests.append(request)
        }
        return requests.sorted { $0.createdAt < $1.createdAt }
    }

    /// Takes `request` for this process: false when another Nirux, or its
    /// caller giving up, took it first.
    static func claim(_ request: Request, stateDirectory: URL) -> Bool {
        let folder = requestsFolder(stateDirectory: stateDirectory)
        let claimed = folder.appendingPathComponent(".\(request.id).claimed-\(getpid())")
        guard rename(folder.appendingPathComponent(request.id + ".json").path, claimed.path) == 0 else { return false }
        try? FileManager.default.removeItem(at: claimed)
        return true
    }

    /// Every request waiting, each claimed: tests, and a Nirux that takes
    /// them all.
    static func takeRequests(stateDirectory: URL, now: TimeInterval = Date().timeIntervalSince1970) -> [Request] {
        waitingRequests(stateDirectory: stateDirectory, now: now).filter { claim($0, stateDirectory: stateDirectory) }
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
                if modified.map({ now.timeIntervalSince($0) > 600 }) ?? true {
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
