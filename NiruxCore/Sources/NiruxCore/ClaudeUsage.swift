import Foundation

/// One Claude session's token usage, as read from its transcript.
public struct ClaudeSessionUsage: Equatable, Sendable {
    /// Context of the latest main-thread response. Nil before the first
    /// response, and after a compaction until the next one: the boundary's
    /// `postTokens` leaves out the system prompt and tools.
    public var contextTokens: Int?
    /// Largest context a response of the current model carried: switching
    /// models (`/model`) may switch windows, so it starts over.
    public var peakContextTokens = 0
    /// API model ID of the latest response (`claude-opus-5-5`).
    public var model: String?
    /// Sum over the transcript's responses, each counted once. Subagents
    /// log to files of their own and are not included.
    public var totals = TokenCounts()
    public var responses = 0

    public init() {}

    /// Claude Code runs a 200k window unless it enables the 1M one, and
    /// which it picks depends on the model variant, the account and the
    /// provider — none of which the transcript records (`message.model` is
    /// the plain API ID, without the `[1m]` suffix).
    public static let standardWindow = 200_000
    public static let extendedWindow = 1_000_000

    /// The context window, only when the transcript shows it: a context
    /// past the standard window means the session runs the extended one.
    /// Nil otherwise — then only token counts are shown.
    public var contextWindow: Int? {
        guard peakContextTokens > Self.standardWindow, !Self.mayHaveCustomWindow(model) else { return nil }
        return Self.extendedWindow
    }

    /// Models Claude Code may give another window: one between the two for
    /// `claude-sonnet-4-6` (remote configuration), any for IDs outside its
    /// model table (`CLAUDE_CODE_MAX_CONTEXT_TOKENS`). A context past 200k
    /// proves nothing about them.
    public static func mayHaveCustomWindow(_ model: String?) -> Bool {
        guard let model, model.hasPrefix("claude-") else { return true }
        return model.hasPrefix("claude-sonnet-4-6")
    }

    /// Share of the context window in use, 0…1 (can exceed 1 only on a
    /// malformed transcript).
    public var contextFraction: Double? {
        guard let contextTokens, let contextWindow else { return nil }
        return Double(contextTokens) / Double(contextWindow)
    }
}

/// Folds a Claude transcript's lines into the session's usage and its
/// responses.
///
/// Claude Code writes one assistant line per content block of a response,
/// each repeating the response's usage (an early block may carry a partial
/// output count), so the lines of one `message.id` count once, the latest
/// winning. Synthetic and API-error messages, and lines of any other shape
/// are skipped, never errors. A session's transcript skips its subagent
/// lines (`isSidechain`): each subagent logs to a file of its own, all
/// sidechain lines, read with `subagentID` set. Only counts, the model ID,
/// times and the working directory are kept — never message content.
public struct ClaudeTranscriptUsageParser: TranscriptLineParser, Sendable {
    public private(set) var usage = ClaudeSessionUsage()
    public private(set) var events: [UsageEvent] = []
    /// The working directory the session started in.
    public private(set) var cwd: String?
    public let subagentID: String?
    private var eventIndexByID: [String: Int] = [:]

    /// Keys a line must contain to matter; others skip JSON parsing.
    private static let usageMarker = Data("\"usage\"".utf8)
    private static let compactMarker = Data("compact_boundary".utf8)
    private static let cwdMarker = Data("\"cwd\"".utf8)

    public init() {
        subagentID = nil
    }

    public init(subagentID: String) {
        self.subagentID = subagentID
    }

    public mutating func consume(line: Data) {
        guard line.contains(Self.usageMarker) || line.contains(Self.compactMarker)
            || (cwd == nil && line.contains(Self.cwdMarker)),
            let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else { return }
        if cwd == nil, let value = object["cwd"] as? String, !value.isEmpty { cwd = value }
        guard subagentID != nil || object["isSidechain"] as? Bool != true else { return }
        switch object["type"] as? String {
        case "assistant":
            consumeResponse(object)
        case "system" where object["subtype"] as? String == "compact_boundary":
            usage.contextTokens = nil
        default:
            return
        }
    }

    private mutating func consumeResponse(_ object: [String: Any]) {
        guard object["isApiErrorMessage"] as? Bool != true,
              let message = object["message"] as? [String: Any],
              let rawUsage = message["usage"] as? [String: Any],
              let counts = TokenCounts(claudeUsage: rawUsage) else { return }
        let model = (message["model"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        // Error placeholders Claude Code writes itself carry this model
        // and zero counts: no request was made.
        guard model != "<synthetic>", counts.context > 0 else { return }
        let context = Self.contextCounts(usage: rawUsage, response: counts).context
        let event = UsageEvent(
            timestamp: UsageEvent.time(object["timestamp"]),
            model: model,
            counts: counts,
            contextTokens: context,
            subagentID: subagentID
        )

        let id = (message["id"] as? String) ?? (object["requestId"] as? String)
        if let id, let index = eventIndexByID[id] {
            // A later block of the latest response, or a stray repeat of an
            // earlier one, already counted.
            guard index == events.count - 1 else { return }
            usage.totals += counts - events[index].counts
            events[index] = event
        } else {
            if let id { eventIndexByID[id] = events.count }
            events.append(event)
            usage.totals += counts
            usage.responses += 1
        }
        if let model, let previous = usage.model, model != previous { usage.peakContextTokens = 0 }
        usage.contextTokens = context
        usage.peakContextTokens = max(usage.peakContextTokens, context)
        if let model { usage.model = model }
    }

    /// What Claude Code measures the context from (its statusline's
    /// `used_percentage`): when a response ran several iterations (a
    /// server-side compaction, an advisor, a model fallback), the last one
    /// that isn't an advisor or compaction step — if it is a well-formed
    /// `message` or `fallback_message` — else the response's own counts.
    static func contextCounts(usage: [String: Any], response: TokenCounts) -> TokenCounts {
        guard response.context > 0, let iterations = usage["iterations"] as? [Any] else { return response }
        let last = iterations.last { iteration in
            let type = (iteration as? [String: Any])?["type"] as? String
            return type != "advisor_message" && type != "compaction"
        }
        guard let last = last as? [String: Any],
              ["message", "fallback_message"].contains(last["type"] as? String),
              TokenCounts.claudeKeys.allSatisfy({ ((last[$0] as? NSNumber)?.doubleValue ?? -1) >= 0 }),
              let counts = TokenCounts(claudeUsage: last), counts.context > 0 else { return response }
        return counts
    }
}

extension TokenCounts {
    static let claudeKeys = ["input_tokens", "output_tokens", "cache_creation_input_tokens", "cache_read_input_tokens"]

    /// Nil unless the object carries at least one known count.
    init?(claudeUsage usage: [String: Any]) {
        let fields = Self.claudeKeys.map { Self.count(usage[$0]) }
        guard fields.contains(where: { $0 != nil }) else { return nil }
        self.init(input: fields[0] ?? 0, output: fields[1] ?? 0, cacheWrite: fields[2] ?? 0, cacheRead: fields[3] ?? 0)
    }
}

/// A Claude session's transcript and its subagents'
/// (`<session>/subagents/<agent>.jsonl`), read incrementally.
public struct ClaudeSessionReader: Sendable {
    public private(set) var main: TranscriptLineReader<ClaudeTranscriptUsageParser>
    public private(set) var subagents: [String: TranscriptLineReader<ClaudeTranscriptUsageParser>] = [:]
    /// Modification time of the subagents folder when last listed.
    private var listedSubagentsAt: TimeInterval?

    public init(path: String) {
        main = TranscriptLineReader(path: path)
    }

    public var sessionID: String { URL(fileURLWithPath: main.path).deletingPathExtension().lastPathComponent }

    /// The session's responses, then each subagent's.
    public var events: [UsageEvent] {
        main.parser.events + subagents.sorted { $0.key < $1.key }.flatMap(\.value.parser.events)
    }

    /// Returns false when more is left to read.
    public mutating func readAppended(budget: Int = TranscriptLineReader<ClaudeTranscriptUsageParser>.defaultReadBudget) -> Bool {
        var budget = budget
        return readAppended(budget: &budget)
    }

    /// Takes the bytes it reads off `budget`.
    public mutating func readAppended(budget: inout Int) -> Bool {
        listSubagents()
        var caughtUp = main.readAppended(budget: &budget)
        // Keys copied: a view of them would keep the old storage, and each
        // read would copy its reader's events.
        for id in Array(subagents.keys) {
            caughtUp = subagents[id]!.readAppended(budget: &budget) && caughtUp
        }
        return caughtUp
    }

    private mutating func listSubagents() {
        let folder = String(main.path.dropLast(".jsonl".count)) + "/subagents"
        guard let status = FileStatus(folder), status.isFolder, status.modifiedAt != listedSubagentsAt else { return }
        listedSubagentsAt = status.modifiedAt
        for name in (try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? [] where name.hasSuffix(".jsonl") {
            let id = String(name.dropLast(".jsonl".count))
            if subagents[id] == nil {
                subagents[id] = TranscriptLineReader(
                    path: folder + "/" + name, parser: ClaudeTranscriptUsageParser(subagentID: id)
                )
            }
        }
    }
}
