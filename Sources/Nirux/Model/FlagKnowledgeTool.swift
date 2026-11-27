import Foundation

/// `flag_knowledge`, for every agent Nirux starts: a signal about the
/// space's knowledge (docs/design/knowledge-bricks.md, "Flags"), written by
/// the MCP server itself to `knowledge/flags.jsonl`. It changes no brick:
/// the user reads it in Space Memory, and an error or contradiction on a
/// brick from two tasks makes it suspect.
enum FlagKnowledgeTool {
    static let name = "flag_knowledge"
    /// The same flag from the same task within this time is refused.
    static let repeatWindow: TimeInterval = 86_400

    static var definition: [String: Any] {
        [
            "name": name,
            "title": "Flag the space's knowledge",
            "description": """
                Flag, for the user, what the space's knowledge (its bricks, the Nirux space knowledge you may get when you \
                open a file, or memory_search's) got wrong or lacks: "error" when a brick proved wrong (a test, CI, the \
                code says otherwise), "contradiction" when two bricks, or a brick and the code, disagree, "gap" when you \
                needed a fact it didn't have and found it the hard way. Name the brick (b-…) when one is concerned. It \
                changes nothing: the user sees it in Space Memory and decides. Not for bugs in your task's code, nor for \
                the user's instructions. One line each, no secrets, keys or personal details. Then go on with your task.
                """,
            "inputSchema": [
                "type": "object",
                "properties": [
                    "kind": ["type": "string", "enum": KnowledgeFlag.Kind.allCases.map(\.rawValue)],
                    "about": ["type": "string", "maxLength": KnowledgeFlag.maxAbout, "description": "What it is about, in a few words."],
                    "text": ["type": "string", "maxLength": KnowledgeFlag.maxText, "description": "What is wrong or missing, in one line."],
                    "brick": ["type": "string", "description": "The brick concerned (b-…), if one is."],
                    "evidence": ["type": "string", "maxLength": KnowledgeFlag.maxEvidence, "description": "Where it showed: a test, a PR, a file and line."]
                ],
                "required": ["kind", "about", "text"],
                "additionalProperties": false
            ],
            "annotations": ["readOnlyHint": false, "destructiveHint": false, "idempotentHint": false, "openWorldHint": false]
        ]
    }

    static func call(_ arguments: [String: Any], context: NiruxMCPServer.Context, now: TimeInterval = Date().timeIntervalSince1970) -> NiruxMCPServer.ToolResult {
        func refused(_ text: String) -> NiruxMCPServer.ToolResult { .init(text: text, isError: true) }
        guard arguments.keys.allSatisfy({ ["kind", "about", "text", "brick", "evidence"].contains($0) }) else {
            return refused("Only kind, about, text, brick and evidence are accepted.")
        }
        guard let kind = (arguments["kind"] as? String).flatMap(KnowledgeFlag.Kind.init(rawValue:)) else {
            return refused("kind must be gap, error or contradiction.")
        }
        func text(_ key: String) -> String? { (arguments[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard let about = text("about"), let said = text("text") else { return refused("about and text must be strings.") }
        let evidence = text("evidence").flatMap { $0.isEmpty ? nil : $0 }
        if let problem = KnowledgeFlag.problem(about: about, text: said, evidence: evidence) { return refused(problem) }
        guard context.isLead || context.isWorkspaceAgent, let spaceID = context.workspaceSpaceID ?? context.spaceID,
              let store = SpaceKnowledge.store(spaceID: spaceID, stateDirectory: context.stateDirectory)
        else { return refused("Only an agent Nirux started in a space can flag its knowledge.") }
        let brick = text("brick").flatMap { $0.isEmpty ? nil : $0 }
        if let brick {
            guard KnowledgeLinks.isBrickID(brick), store.load().bricks[brick] != nil else { return refused("This space holds no brick \(brick).") }
        }
        let task = context.nonEmpty("NIRUX_WORKSPACE_ID")
        let again = KnowledgeFlag.load(in: store).contains { flag in
            flag.task == task && flag.kind == kind && flag.brick == brick && now - flag.time < repeatWindow
                && ProjectMemory.folded(flag.about) == ProjectMemory.folded(about)
        }
        guard !again else { return refused("You flagged this already today: the user has it.") }
        do {
            try KnowledgeFlag.append(KnowledgeFlag(time: now, kind: kind, brick: brick, about: about, text: said, evidence: evidence, task: task), in: store)
        } catch {
            return refused("Nirux couldn't record the flag: \(error.localizedDescription)")
        }
        return .init(text: "Flagged for the user, who sees it in Space Memory. It changes no brick: go on with your task.", isError: false)
    }
}
