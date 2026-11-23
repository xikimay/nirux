import Foundation

/// The Nirux spaces and tasks usage is attributed to: plain values the app
/// builds from its stores.
public struct UsageCatalog: Equatable, Sendable {
    public struct Space: Equatable, Sendable {
        public var id: String
        /// Main checkouts of its repositories: their worktrees sit beside
        /// them (`<checkout>.<name>`).
        public var repositories: [String]
        public var folders: [String]

        public init(id: String, repositories: [String] = [], folders: [String] = []) {
            self.id = id
            self.repositories = repositories
            self.folders = folders
        }
    }

    public struct Task: Equatable, Sendable {
        public var id: String
        public var spaceID: String
        /// Its worktree or folder.
        public var folder: String?

        public init(id: String, spaceID: String, folder: String? = nil) {
            self.id = id
            self.spaceID = spaceID
            self.folder = folder
        }
    }

    public var spaces: [Space]
    /// The first of two tasks in one folder wins it: list open tasks first.
    public var tasks: [Task]
    /// The task each recorded agent session ran in.
    public var sessionTasks: [UsageSessionKey: String]

    public init(spaces: [Space] = [], tasks: [Task] = [], sessionTasks: [UsageSessionKey: String] = [:]) {
        self.spaces = spaces
        self.tasks = tasks
        self.sessionTasks = sessionTasks
    }
}

public struct UsageAttribution: Hashable, Sendable {
    /// Nil outside Nirux's spaces.
    public var spaceID: String?
    public var taskID: String?

    public init(spaceID: String? = nil, taskID: String? = nil) {
        self.spaceID = spaceID
        self.taskID = taskID
    }
}

/// Attributes a session to the task it was recorded in, else to the
/// innermost task folder or space anchor holding its working directory.
struct UsageAttributor: Sendable {
    private let tasksByID: [String: UsageCatalog.Task]
    private let sessionTasks: [UsageSessionKey: String]
    private let tasksByFolder: [String: UsageCatalog.Task]
    private let spacesByFolder: [String: String]
    private let repositories: [(checkout: String, spaceID: String)]

    init(_ catalog: UsageCatalog) {
        tasksByID = Dictionary(catalog.tasks.map { ($0.id, $0) }) { first, _ in first }
        sessionTasks = catalog.sessionTasks
        tasksByFolder = Dictionary(catalog.tasks.compactMap { task in task.folder.map { ($0.comparablePath, task) } }) { first, _ in first }
        repositories = catalog.spaces.flatMap { space in space.repositories.map { ($0.comparablePath, space.id) } }
        let folders = catalog.spaces.flatMap { space in space.folders.map { ($0.comparablePath, space.id) } }
        spacesByFolder = Dictionary(repositories + folders) { first, _ in first }
    }

    func attribution(_ key: UsageSessionKey, cwd: String?) -> UsageAttribution {
        if let task = sessionTasks[key].flatMap({ tasksByID[$0] }) {
            return UsageAttribution(spaceID: task.spaceID, taskID: task.id)
        }
        var path = cwd?.comparablePath
        while let folder = path, folder.count > 1 {
            if let task = tasksByFolder[folder] { return UsageAttribution(spaceID: task.spaceID, taskID: task.id) }
            if let spaceID = spacesByFolder[folder] ?? worktreeSpace(folder) { return UsageAttribution(spaceID: spaceID) }
            path = (folder as NSString).deletingLastPathComponent
        }
        return UsageAttribution()
    }

    private func worktreeSpace(_ folder: String) -> String? {
        repositories.first { folder.hasPrefix($0.checkout + ".") && !folder.dropFirst($0.checkout.count).contains("/") }?.spaceID
    }
}

/// One agent session's usage, attributed to its Nirux space and task.
public struct UsageSession: Equatable, Sendable {
    public var key: UsageSessionKey
    public var cwd: String?
    public var attribution = UsageAttribution()
    public var model: String?
    /// Context of its latest response; for Claude, nil right after a
    /// compaction.
    public var contextTokens: Int?
    public var contextWindow: Int?
    public var subagents = 0
    public var rateLimits: CodexRateLimits?
    /// Its responses, then each subagent's, each in time order.
    public var events: [UsageEvent]
}

/// Usage summed over responses.
public struct UsageSummary: Equatable, Sendable {
    public var calls = 0
    public var totals = TokenCounts()
    public var weightedTokens = 0.0
    /// The part of `weightedTokens` subagents spent.
    public var subagentWeightedTokens = 0.0
    public var peakContextTokens = 0
    /// Responses that rewrote a cold cache, and what they cost.
    public var coldRewrites = 0
    public var coldRewriteWeightedTokens = 0.0
    public var lastActivity: TimeInterval = 0
    public private(set) var sessions: Set<UsageSessionKey> = []
    /// As `<session ID>/<subagent ID>`.
    public private(set) var subagents: Set<String> = []

    public init() {}

    /// A response after this long idle finds the cache expired (Claude
    /// keeps it 5 minutes).
    public static let coldIdle: TimeInterval = 5 * 60
    /// From this many tokens rewritten: cache writes for Claude, uncached
    /// input for Codex and agy.
    public static let coldRewriteTokens = 20_000

    mutating func add(_ event: UsageEvent, of session: UsageSessionKey, idle: TimeInterval?) {
        let weighted = event.counts.weighted(model: event.model)
        calls += 1
        totals += event.counts
        weightedTokens += weighted
        peakContextTokens = max(peakContextTokens, event.contextTokens)
        lastActivity = max(lastActivity, event.timestamp)
        sessions.insert(session)
        if let subagentID = event.subagentID {
            subagentWeightedTokens += weighted
            subagents.insert(session.id + "/" + subagentID)
        }
        let rewrite = session.agent == .claude
            ? TokenCounts(cacheWrite: event.counts.cacheWrite)
            : TokenCounts(input: event.counts.input)
        if let idle, idle >= Self.coldIdle, rewrite.context >= Self.coldRewriteTokens {
            coldRewrites += 1
            coldRewriteWeightedTokens += rewrite.weighted(model: event.model)
        }
    }
}

extension Sequence where Element == UsageSession {
    /// The responses made since `since`, summed by `key`; a nil key leaves
    /// a response out.
    public func summaries<Key: Hashable>(
        since: TimeInterval = 0,
        by key: (UsageSession, UsageEvent) -> Key?
    ) -> [Key: UsageSummary] {
        var summaries: [Key: UsageSummary] = [:]
        for session in self {
            // Idle gaps run across the whole history, per stream: a
            // subagent's pause says nothing of the session's cache.
            var lastTimes: [String?: TimeInterval] = [:]
            for event in session.events {
                let idle = lastTimes[event.subagentID].map { event.timestamp - $0 }
                if event.timestamp > 0 { lastTimes[event.subagentID] = event.timestamp }
                guard event.timestamp >= since, let group = key(session, event) else { continue }
                summaries[group, default: UsageSummary()].add(event, of: session.key, idle: idle)
            }
        }
        return summaries
    }

    public func summary(since: TimeInterval = 0) -> UsageSummary {
        summaries(since: since) { _, _ in true }[true] ?? UsageSummary()
    }
}

/// Where the agents keep their transcripts, under a home folder.
public struct UsageSources: Equatable, Sendable {
    public var claudeProjects: String
    public var codexSessions: String
    public var agyBrain: String

    public init(home: String = NSHomeDirectory()) {
        claudeProjects = home + "/.claude/projects"
        codexSessions = home + "/.codex/sessions"
        agyBrain = home + "/.gemini/antigravity-cli/brain"
    }
}

/// Every agent session's token usage, read incrementally from the agents'
/// own transcripts (numbers only, never text), attributed to Nirux spaces
/// and tasks.
public struct UsageLedger: Sendable {
    public let sources: UsageSources
    public var catalog: UsageCatalog {
        didSet { attributor = UsageAttributor(catalog) }
    }
    private var attributor: UsageAttributor
    private var claude: [String: ClaudeSessionReader] = [:]
    private var codex: [String: TranscriptLineReader<CodexRolloutUsageParser>] = [:]
    private var agy: [String: TranscriptLineReader<AgyTranscriptUsageParser>] = [:]

    public init(sources: UsageSources = UsageSources(), catalog: UsageCatalog = UsageCatalog()) {
        self.sources = sources
        self.catalog = catalog
        attributor = UsageAttributor(catalog)
    }

    /// Follows the transcripts written since `since`, forgetting the
    /// others, then reads what each gained: at most `budget` bytes a file.
    /// Returns false when more is left to read.
    public mutating func refresh(since: TimeInterval, budget: Int = TranscriptLineReader<AgyTranscriptUsageParser>.defaultReadBudget) -> Bool {
        let claudeFiles = Self.entries(of: sources.claudeProjects).flatMap(Self.entries(of:)).filter { $0.hasSuffix(".jsonl") }
        let codexFiles = (FileManager.default.subpaths(atPath: sources.codexSessions) ?? [])
            .filter { ($0 as NSString).lastPathComponent.hasPrefix("rollout-") && $0.hasSuffix(".jsonl") }
            .map { sources.codexSessions + "/" + $0 }
        let agyFiles = Self.entries(of: sources.agyBrain).map { $0 + "/.system_generated/logs/transcript_full.jsonl" }
        let isRecent = { (path: String) in FileStatus(path).map { $0.isFile && $0.modifiedAt >= since } ?? false }

        claude = Self.follow(claudeFiles.filter(isRecent), readers: claude, make: ClaudeSessionReader.init(path:))
        codex = Self.follow(codexFiles.filter(isRecent), readers: codex) { TranscriptLineReader(path: $0) }
        agy = Self.follow(agyFiles.filter(isRecent), readers: agy) { TranscriptLineReader(path: $0) }
        let caughtUp = [
            Self.read(&claude) { $0.readAppended(budget: budget) },
            Self.read(&codex) { $0.readAppended(budget: budget) },
            Self.read(&agy) { $0.readAppended(budget: budget) }
        ]
        return !caughtUp.contains(false)
    }

    /// Sessions with one response at least.
    public var sessions: [UsageSession] {
        let claudeSessions = claude.values.map { reader in
            let usage = reader.main.parser.usage
            return session(
                UsageSessionKey(.claude, reader.sessionID), cwd: reader.main.parser.cwd, events: reader.events,
                model: usage.model, contextTokens: usage.contextTokens, contextWindow: usage.contextWindow,
                subagents: reader.subagents.values.filter { !$0.parser.events.isEmpty }.count
            )
        }
        let codexSessions = codex.values.map { reader in
            let parser = reader.parser
            let id = parser.sessionID ?? URL(fileURLWithPath: reader.path).deletingPathExtension().lastPathComponent
            return session(
                UsageSessionKey(.codex, id), cwd: parser.cwd, events: parser.events, model: parser.model,
                contextTokens: parser.events.last?.contextTokens, contextWindow: parser.contextWindow,
                rateLimits: parser.rateLimits
            )
        }
        let agySessions = agy.values.map { reader in
            // brain/<conversation>/.system_generated/logs/transcript_full.jsonl
            let id = (reader.path as NSString).pathComponents.dropLast(3).last ?? reader.path
            let events = reader.parser.events
            return session(
                UsageSessionKey(.agy, id), cwd: nil, events: events,
                model: events.last?.model, contextTokens: events.last?.contextTokens
            )
        }
        return (claudeSessions + codexSessions + agySessions).filter { !$0.events.isEmpty }
    }

    private func session(
        _ key: UsageSessionKey,
        cwd: String?,
        events: [UsageEvent],
        model: String?,
        contextTokens: Int?,
        contextWindow: Int? = nil,
        subagents: Int = 0,
        rateLimits: CodexRateLimits? = nil
    ) -> UsageSession {
        UsageSession(
            key: key, cwd: cwd, attribution: attributor.attribution(key, cwd: cwd), model: model,
            contextTokens: contextTokens, contextWindow: contextWindow, subagents: subagents,
            rateLimits: rateLimits, events: events
        )
    }

    private static func entries(of folder: String) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? []).map { folder + "/" + $0 }
    }

    private static func follow<Reader>(_ paths: [String], readers: [String: Reader], make: (String) -> Reader) -> [String: Reader] {
        Dictionary(paths.map { ($0, readers[$0] ?? make($0)) }) { first, _ in first }
    }

    /// Keys copied: a view of them would keep the old storage, and each read
    /// would copy its reader's events.
    private static func read<Reader>(_ readers: inout [String: Reader], _ read: (inout Reader) -> Bool) -> Bool {
        var caughtUp = true
        for path in Array(readers.keys) {
            caughtUp = read(&readers[path]!) && caughtUp
        }
        return caughtUp
    }
}

/// lstat(2): a link is never followed.
struct FileStatus {
    let type: mode_t
    let modifiedAt: TimeInterval

    init?(_ path: String) {
        var info = stat()
        guard lstat(path, &info) == 0 else { return nil }
        type = info.st_mode & S_IFMT
        modifiedAt = TimeInterval(info.st_mtimespec.tv_sec) + TimeInterval(info.st_mtimespec.tv_nsec) / 1e9
    }

    var isFile: Bool { type == S_IFREG }
    var isFolder: Bool { type == S_IFDIR }
}
