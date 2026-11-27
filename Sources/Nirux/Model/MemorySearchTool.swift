import Foundation

enum MemorySearchTool {
    static let name = "memory_search"
    static let maxResponseBytes = 16_000
    static let maxExcerptBytes = 1_200
    private static let defaultLimit = 8
    private static let maxLimit = 20

    static var definition: [String: Any] {
        [
            "name": name,
            "title": "Search project memory",
            "description": "Search the space brief, team rules, saved notes and the space's bricks (facts the user validated). "
                + "Each excerpt names its scope and source file.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "query": [
                        "type": "string", "maxLength": HistorySearch.Query.maxCharacters,
                        "description": "Match every word, ignoring case and accents. Omit for a summary."
                    ],
                    "scope": ["type": "string", "enum": ["all", "always", "team", "when_relevant"], "default": "all"],
                    "limit": ["type": "integer", "minimum": 1, "maximum": maxLimit, "default": defaultLimit]
                ],
                "additionalProperties": false
            ],
            "annotations": ["readOnlyHint": true, "destructiveHint": false, "idempotentHint": true, "openWorldHint": false]
        ]
    }

    static func call(_ arguments: [String: Any], context: NiruxMCPServer.Context) -> NiruxMCPServer.ToolResult {
        func invalid(_ message: String) -> NiruxMCPServer.ToolResult { .init(text: message, isError: true) }
        guard arguments.keys.allSatisfy({ ["query", "scope", "limit"].contains($0) }) else {
            return invalid("Only query, scope, and limit are accepted.")
        }
        guard let query = (arguments["query"] ?? "") as? String else { return invalid("query must be a string.") }
        guard query.count <= HistorySearch.Query.maxCharacters else {
            return invalid("The query is longer than \(HistorySearch.Query.maxCharacters) characters.")
        }
        let scope: ProjectMemory.Scope?
        switch (arguments["scope"] ?? "all") as? String {
        case "all": scope = nil
        case "always": scope = .always
        case "team": scope = .team
        case "when_relevant": scope = .whenRelevant
        default: return invalid("scope must be all, always, team, or when_relevant.")
        }
        guard let number = (arguments["limit"] ?? defaultLimit) as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID(), let whole = Int(exactly: number.doubleValue)
        else { return invalid("limit must be a whole number.") }
        let limit = min(max(1, whole), maxLimit)
        let brief = context.spaceID.flatMap { SpaceBrief.briefURL(spaceID: $0, stateDirectory: context.stateDirectory) }
        let location = ProjectMemory.locate(
            folder: context.workingDirectory, home: context.nonEmpty("HOME") ?? NSHomeDirectory(),
            environment: context.environment, followingSymlinks: false
        )
        let bricks = context.spaceID.flatMap { spaceID in
            SpaceKnowledge.store(spaceID: spaceID, stateDirectory: context.stateDirectory).flatMap {
                ProjectMemory.Bricks.read($0, serves: SpaceDefaultsStore.defaults(forSpace: spaceID, stateDirectory: context.stateDirectory).servesKnowledge)
            }
        }
        let knowledge = ProjectMemory.knowledge(
            folder: context.workingDirectory, brief: brief, location: location, bricks: bricks, followingSymlinks: false
        )
        return render(knowledge, query: query, scope: scope, limit: limit, notice: location.notice)
    }

    private static func render(
        _ knowledge: ProjectMemory.Knowledge, query: String, scope: ProjectMemory.Scope?, limit: Int, notice: String?
    ) -> NiruxMCPServer.ToolResult {
        let matches = ProjectMemory.entries(in: knowledge, text: query, scope: scope).lazy
            .map { knowledge.entries[$0] }.filter { scope == nil || $0.scope == scope }
        let terms = query.split(whereSeparator: \.isWhitespace).map(String.init)
        var lines = notice.map { [bounded(BranchReview.visible($0), bytes: 512)] } ?? []
        if knowledge.memory?.isTruncated == true { lines.append("The auto-memory scan was truncated.") }
        if let memory = knowledge.memory,
           memory.memories.contains(where: { $0.indexLine.map { !memory.isRead($0) } == true })
            || memory.missingFiles.contains(where: { !memory.isRead($0) }) {
            lines.append("Some MEMORY.md entries fall beyond Claude Code’s startup limit.")
        }
        let cut = "Results truncated. Narrow the query or scope for more detail."
        var shown = 0
        for entry in matches {
            guard shown < limit else { lines.append(cut); break }
            guard let row = excerpt(for: entry, in: knowledge, terms: terms) else { continue }
            // Count JSON escapes and keep room for the truncation notice.
            let candidate = (lines + [row, cut]).joined(separator: "\n")
            guard let encoded = try? JSONSerialization.data(withJSONObject: candidate, options: [.fragmentsAllowed, .withoutEscapingSlashes]),
                  encoded.count <= maxResponseBytes - 128 else { lines.append(cut); break }
            lines.append(row)
            shown += 1
        }
        if shown == 0 {
            lines.append(knowledge.entries.isEmpty ? "No project memory found for this space or repository." : "No matching project memory.")
        }
        return .init(text: lines.joined(separator: "\n"), isError: false)
    }

    private static func excerpt(
        for entry: ProjectMemory.Entry, in knowledge: ProjectMemory.Knowledge, terms: [String]
    ) -> String? {
        let source: String
        let text: String
        switch entry.source {
        case .rule:
            guard let (ruleFile, rule) = knowledge.rule(of: entry) else { return nil }
            source = (entry.scope == .team ? ruleFile.label : ruleFile.url.lastPathComponent) + ":\(rule.lines.lowerBound)"
            text = rule.text
        case .memory:
            guard let memory = knowledge.memory(of: entry) else { return nil }
            source = memory.fileName
            text = [entry.title, memory.description, memory.body].filter { !$0.isEmpty }.joined(separator: "\n")
        case .missingFile(let line):
            source = ProjectMemory.indexFileName + ":\(line.number)"
            text = "\(entry.title) — \(entry.detail). \(line.target) \(line.hook)"
        case .brick(let id):
            // Only what agents may get now: a closed, expired or suspect brick isn't.
            guard let bricks = knowledge.bricks, bricks.serves, bricks.status(of: id) == .open, let brick = bricks.loaded.bricks[id] else { return nil }
            source = "brick \(id), " + brick.scope.paths.joined(separator: ", ")
            text = "\(brick.sentence) (proof: \(brick.proofs.map(\.label).joined(separator: " · ")))"
        case .proposal, .flag:
            return nil
        }
        let excerpt = HistorySearch.excerpt(of: text, terms: terms) ?? "[Excerpt withheld.]"
        // It rests on a brick agents no longer get: said, so it isn't taken as is.
        let flagged = knowledge.bricks?.flaggedBase(in: entry.cites).map { bounded(BranchReview.visible(" [Flagged: it rests on \($0.id), \($0.why)]"), bytes: 300) } ?? ""
        return "[\(entry.scope.title) · \(BranchReview.visible(source))] " + bounded(excerpt, bytes: maxExcerptBytes - flagged.utf8.count) + flagged
    }

    private static func bounded(_ text: String, bytes: Int) -> String {
        guard text.utf8.count > bytes else { return text }
        var result = ""
        for character in text {
            guard result.utf8.count + character.utf8.count <= bytes - "…".utf8.count else { break }
            result.append(character)
        }
        return result + "…"
    }
}
