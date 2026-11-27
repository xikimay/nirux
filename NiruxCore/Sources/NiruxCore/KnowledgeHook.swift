import Foundation

/// One line of `knowledge/uses.jsonl`: a brick reached an agent's session,
/// or the user then wrote about its subject (a correction). The hook
/// receiver appends them; the app counts them per brick, and makes a brick
/// a correction followed suspect.
public struct KnowledgeUse: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable { case got, corrected }

    public var time: TimeInterval
    public var brick: String
    public var kind: Kind
    /// The workspace of the terminal the agent runs in: its task.
    public var task: String?
    public var agent: String

    public init(time: TimeInterval, brick: String, kind: Kind, task: String?, agent: String) {
        self.time = time
        self.brick = brick
        self.kind = kind
        self.task = task
        self.agent = agent
    }

    enum CodingKeys: String, CodingKey { case time = "t", brick, kind, task, agent }

    public static let fileName = "uses.jsonl"
    public static let keptDays = 90
    static let maxFileBytes = 2_000_000

    /// Appends `uses`, unless the file is full, under the lock a trim
    /// takes: a line appended while the file is rewritten would be lost.
    public static func append(_ uses: [KnowledgeUse], in store: KnowledgeStore) {
        let url = store.folder.appendingPathComponent(fileName)
        let lines = uses.compactMap { try? JSONEncoder().encode($0) }.map { $0 + Data("\n".utf8) }.reduce(Data(), +)
        locked(store, attempts: 100) {
            var info = stat()
            if stat(url.path, &info) == 0, info.st_size >= maxFileBytes { return }
            let descriptor = open(url.path, O_WRONLY | O_CREAT | O_APPEND | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard descriptor >= 0 else { return }
            defer { close(descriptor) }
            _ = lines.withUnsafeBytes { write(descriptor, $0.baseAddress, $0.count) }
        }
    }

    /// Runs `body` holding `uses.lock`, or not at all once `attempts`
    /// tries 10 ms apart fail.
    private static func locked(_ store: KnowledgeStore, attempts: Int, _ body: () -> Void) {
        let descriptor = open(store.folder.appendingPathComponent("uses.lock").path, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { return }
        defer { close(descriptor) }
        for _ in 0..<attempts {
            if flock(descriptor, LOCK_EX | LOCK_NB) == 0 {
                body()
                flock(descriptor, LOCK_UN)
                return
            }
            usleep(10_000)
        }
    }

    public static func load(in store: KnowledgeStore) -> [KnowledgeUse] {
        guard let data = RegularFileRead.read(store.folder.appendingPathComponent(fileName), maxBytes: maxFileBytes + 65_536).contents
        else { return [] }
        let decoder = JSONDecoder()
        return data.split(separator: UInt8(ascii: "\n")).compactMap { try? decoder.decode(KnowledgeUse.self, from: $0) }
    }

    /// Lines kept at most by a trim, the newest: well under the file's limit,
    /// past which nothing more is recorded.
    static let maxKeptLines = 10_000

    /// Rewrites the file without the lines past `keptDays`, and without the
    /// oldest past `maxKeptLines`, when it has some.
    public static func trim(in store: KnowledgeStore, now: TimeInterval) {
        locked(store, attempts: 300) {
            let uses = load(in: store)
            let kept = uses.filter { now - $0.time < Double(keptDays) * 86_400 }.suffix(maxKeptLines)
            guard kept.count < uses.count else { return }
            let lines = kept.compactMap { try? JSONEncoder().encode($0) }.map { $0 + Data("\n".utf8) }
            try? KnowledgeStore.writePrivately(lines.reduce(Data(), +), to: store.folder.appendingPathComponent(fileName))
        }
    }

    /// Per brick: the tasks it reached, and those where a correction followed.
    public static func reach(_ uses: [KnowledgeUse]) -> [String: (tasks: Int, corrections: Int)] {
        var tasks: [String: Set<String>] = [:]
        var corrected: [String: Set<String>] = [:]
        for use in uses {
            let task = use.task ?? "?"
            switch use.kind {
            case .got: tasks[use.brick, default: []].insert(task)
            case .corrected: corrected[use.brick, default: []].insert(task)
            }
        }
        return Dictionary(uniqueKeysWithValues: Set(tasks.keys).union(corrected.keys).map {
            ($0, (tasks[$0]?.count ?? 0, corrected[$0]?.count ?? 0))
        })
    }
}

/// What the hook receiver does with a space's served bricks for one hook
/// call. Claude's PostToolUse after it read or edited a file gets the
/// bricks about that file as additional context. agy's PostToolUse sets
/// them aside, and its next model call's PreInvocation injects them. A
/// prompt the user typed (Claude's UserPromptSubmit, agy's first model call
/// of a turn) that names the subject of a brick the session got is a
/// correction. Nothing is read past `served.json` when it is absent.
public enum KnowledgeHook {
    public enum Agent: String, Sendable { case claude, agy }

    public struct Answer: Equatable {
        /// What the hook prints.
        public var output: Data?
        public var uses: [KnowledgeUse] = []

        public init(output: Data? = nil, uses: [KnowledgeUse] = []) {
            self.output = output
            self.uses = uses
        }
    }

    static let handled: [Agent: Set<String>] = [.claude: ["PostToolUse", "UserPromptSubmit"], .agy: ["PostToolUse", "PreInvocation"]]

    /// Claude's file tools, and the input naming their file.
    static let claudeFileTools = ["Read": "file_path", "Edit": "file_path", "MultiEdit": "file_path", "Write": "file_path",
                                  "NotebookEdit": "notebook_path"]
    /// What agy's file tools name their file with (probed on agy 1.5.18:
    /// read_file and edit_file take `Path`).
    static let agyPathArguments = ["Path", "AbsolutePath", "TargetFile", "FilePath", "File"]

    /// `typedByNirux`: a prompt Nirux typed (a Mission's, a pull request
    /// round's), never the user's correction.
    public static func answer(
        agent: Agent, payload: [String: Any], store: KnowledgeStore, task: String?, now: TimeInterval, macOS: Int,
        typedByNirux: (String) -> Bool = { $0.hasPrefix("[Nirux") }
    ) -> Answer {
        let event = payload["hook_event_name"] as? String ?? payload["hookEventName"] as? String
        func isTypedByUser(_ prompt: String) -> Bool { !typedByNirux(prompt.trimmingCharacters(in: .whitespacesAndNewlines)) }
        // A compacted conversation lost what it got: it may get it again.
        if agent == .claude, event == "SessionStart", payload["source"] as? String == "compact", let session = payload["session_id"] as? String {
            let url = KnowledgeSession.url(in: store.sessionsFolder, agent: agent.rawValue, session: session, subagent: nil)
            if FileManager.default.fileExists(atPath: url.path) { _ = KnowledgeSession.update(url) { $0 = KnowledgeSession() } }
            return Answer()
        }
        // Most hook calls are none of these: they read nothing.
        guard let event, handled[agent]?.contains(event) == true,
              let served = ServedKnowledge.read(store.servedURL), !served.bricks.isEmpty
        else { return Answer() }
        func uses(_ ids: [String], _ kind: KnowledgeUse.Kind) -> [KnowledgeUse] {
            ids.map { KnowledgeUse(time: now, brick: $0, kind: kind, task: task, agent: agent.rawValue) }
        }
        switch (agent, event) {
        case (.claude, "PostToolUse"):
            guard let session = payload["session_id"] as? String, let tool = payload["tool_name"] as? String,
                  let key = claudeFileTools[tool], let named = (payload["tool_input"] as? [String: Any])?[key] as? String,
                  let file = location(of: absolute(named, cwd: payload["cwd"] as? String), in: served)
            else { return Answer() }
            let url = KnowledgeSession.url(in: store.sessionsFolder, agent: agent.rawValue, session: session, subagent: payload["agent_id"] as? String)
            guard let (picked, text) = KnowledgeSession.update(url, { session -> ([ServedKnowledge.Brick], String)? in
                let picked = KnowledgeDelivery.pick(served, anchor: file.anchor, path: file.path, session: session, now: now, macOS: macOS)
                guard !picked.isEmpty else { return nil }
                let text = KnowledgeDelivery.text(picked, about: KnowledgeDelivery.about(picked[0].name, path: file.path))
                session.bytes += KnowledgeDelivery.cost(text)
                for brick in picked { session.delivered[brick.id] = now }
                return (picked, text)
            }) ?? nil else { return Answer() }
            let output = try? JSONSerialization.data(withJSONObject: [
                "hookSpecificOutput": ["hookEventName": "PostToolUse", "additionalContext": text]
            ])
            return Answer(output: output, uses: uses(picked.map(\.id), .got))
        case (.claude, "UserPromptSubmit"):
            guard let session = payload["session_id"] as? String, payload["source"] as? String != "poll_event",
                  let prompt = payload["prompt"] as? String, isTypedByUser(prompt)
            else { return Answer() }
            let url = KnowledgeSession.url(in: store.sessionsFolder, agent: agent.rawValue, session: session, subagent: nil)
            return Answer(uses: uses(corrections(prompt, served: served, session: url), .corrected))
        case (.agy, "PostToolUse"):
            guard let session = payload["conversationId"] as? String, let call = payload["toolCall"] as? [String: Any],
                  (payload["error"] as? String ?? "").isEmpty,
                  let name = call["name"] as? String, name.lowercased().contains("file"),
                  let arguments = call["args"] as? [String: Any],
                  let named = agyPathArguments.lazy.compactMap({ arguments[$0] as? String }).first,
                  let file = location(of: absolute(named, cwd: payload["cwd"] as? String), in: served)
            else { return Answer() }
            let url = KnowledgeSession.url(in: store.sessionsFolder, agent: agent.rawValue, session: session, subagent: nil)
            _ = KnowledgeSession.update(url) { session in
                let picked = KnowledgeDelivery.pick(served, anchor: file.anchor, path: file.path, session: session, now: now, macOS: macOS)
                guard !picked.isEmpty else { return }
                // Kept for the model call: its lines count now, the one header
                // when it is sent.
                session.bytes += picked.map { KnowledgeDelivery.cost($0.line) + 1 }.reduce(0, +)
                session.pending += picked.map(\.id)
            }
            return Answer()
        case (.agy, "PreInvocation"):
            guard let session = payload["conversationId"] as? String else { return Answer() }
            let url = KnowledgeSession.url(in: store.sessionsFolder, agent: agent.rawValue, session: session, subagent: nil)
            var corrected: [String] = []
            if payload["invocationNum"] as? Int == 0, let prompt = payload["lastUserInput"] as? String, isTypedByUser(prompt) {
                corrected = corrections(prompt, served: served, session: url)
            }
            let pending = KnowledgeSession.update(url) { session -> [ServedKnowledge.Brick] in
                let bricks = served.bricks.filter { session.pending.contains($0.id) && $0.isServed(now: now, macOS: macOS) }
                session.pending = []
                for brick in bricks { session.delivered[brick.id] = now }
                if !bricks.isEmpty { session.bytes += KnowledgeDelivery.cost(KnowledgeDelivery.text([], about: KnowledgeDelivery.openedFiles)) }
                return bricks
            } ?? []
            guard !pending.isEmpty else { return Answer(uses: uses(corrected, .corrected)) }
            let output = try? JSONSerialization.data(withJSONObject: [
                "injectSteps": [["systemMessage": ["systemMessage": KnowledgeDelivery.text(pending, about: KnowledgeDelivery.openedFiles)]]]
            ])
            return Answer(output: output, uses: uses(pending.map(\.id), .got) + uses(corrected, .corrected))
        default:
            return Answer()
        }
    }

    /// The bricks the session got and no correction followed yet whose
    /// subject `prompt` names, recorded as corrected.
    private static func corrections(_ prompt: String, served: ServedKnowledge, session url: URL) -> [String] {
        KnowledgeSession.update(url) { session -> [String] in
            let got = served.bricks.filter { session.delivered[$0.id] != nil && !session.corrected.contains($0.id) }
            let named = KnowledgeCorrection.named(in: prompt, among: got)
            session.corrected += named
            return named
        } ?? []
    }

    static func absolute(_ path: String, cwd: String?) -> String {
        path.hasPrefix("/") || cwd == nil ? path : (cwd! as NSString).appendingPathComponent(path)
    }

    /// The anchor of a served brick `path` is in, and its path there.
    static func location(of path: String, in served: ServedKnowledge) -> (anchor: String, path: String)? {
        guard path.hasPrefix("/") else { return nil }
        let anchors = Set(served.bricks.map(\.anchor))
        if anchors.contains(where: { $0.hasPrefix("git:") }), let found = KnowledgeLocation.repository(of: path), anchors.contains(found.anchor) {
            return found
        }
        return KnowledgeLocation.folder(of: path, among: Array(anchors))
    }
}
