import Foundation

/// The Lead's tools (docs/spaces.md, "The Lead"), listed by the Nirux MCP
/// server to a space's Lead only (`NIRUX_LEAD=1`). Each call goes to the
/// running app through `LeadChannel`, which acts within the Lead's space:
/// no tool merges, removes a worktree or a branch, or reaches another space.
enum LeadTools {
    static let startTask = "start_task"
    static let listTasks = "list_tasks"
    static let tell = "tell"
    static let reply = "reply"
    static let askUser = "ask_user"
    static let queueMerge = "queue_merge"
    static let setTaskContext = "set_task_context"
    static let names = [startTask, listTasks, tell, reply, askUser, queueMerge, setTaskContext]

    /// `start_task`'s `repo` for a task without a repository: a new folder
    /// of its own (unless a repository of the space has that name).
    static let noRepository = "none"

    /// How a tool names one of the Lead's tasks.
    static let taskDescription = "The task's branch (its folder, as list_tasks shows it, or the folder's name, "
        + "for a task without a repository), or its title."

    /// A next step or blocker: one line on the task's row.
    static let maxContextLength = 200

    /// How long a call waits for a Nirux to take it: a running app takes
    /// it at once.
    static let takeTimeout: TimeInterval = 15

    /// How long a call then waits for the answer: a task fetches origin
    /// and makes its worktree first.
    static func workTimeout(for tool: String) -> TimeInterval {
        tool == startTask ? 300 : 30
    }

    static var definitions: [[String: Any]] {
        [
            definition(
                startTask, title: "Start a task",
                description: """
                    Start a task in a new worktree of this space, from origin's base branch, fetched: Nirux writes \
                    the description into its handover, launches the space's agent and links the task to you (its \
                    questions and result are typed into your prompt). One repository per task. Work that needs no \
                    repository (research, writing, a one-off script) starts in a new folder of its own instead, \
                    with no git, branch or pull request: repo "\(noRepository)", or any task in a space without a \
                    repository. Never "\(noRepository)" for work that reads or changes a repository of this space: \
                    start it in that repository. When the user turned "Starts tasks without asking" off, it opens \
                    the New sheet filled in for the user to start instead.
                    """,
                properties: [
                    "description": ["type": "string", "description": "What the task must do, as you would tell the agent. Its first line names the task and its branch or folder."],
                    "repo": ["type": "string", "description": "The repository's name in this space (see list_tasks); its default one when left out. \"\(noRepository)\": a new folder, no repository."],
                    "template": ["type": "string", "description": "A task template's name (Space Settings › Templates), if one fits."]
                ],
                required: ["description"]
            ),
            definition(
                listTasks, title: "List the space's tasks",
                description: """
                    The space's tasks and repositories: each task's title, branch, repository, agent state (working, \
                    needs the user, asking you, idle, done), pull request and checks, and the question or result it \
                    sent you, its next step and blocker. Read it again after a /clear: Nirux keeps the state, your \
                    conversation doesn't.
                    """,
                properties: [:], required: [], readOnly: true
            ),
            definition(
                tell, title: "Tell a task",
                description: """
                    Type a message into a task's prompt once its agent's turn is over (a follow-up, an answer it \
                    didn't ask for, a slash command). Claude Code tasks only.
                    """,
                properties: [
                    "task": ["type": "string", "description": taskDescription],
                    "message": ["type": "string", "description": "At most \(MissionEventCLI.maxMessageLength) characters."]
                ],
                required: ["task", "message"]
            ),
            definition(
                reply, title: "Answer a task's question",
                description: "Answer the question a task asked you, by its id (in the [Nirux Mission] message and list_tasks).",
                properties: [
                    "question": ["type": "string", "description": "The question's id."],
                    "message": ["type": "string", "description": "Your answer, at most \(MissionEventCLI.maxMessageLength) characters."]
                ],
                required: ["question", "message"]
            ),
            definition(
                askUser, title: "Hand a task's question to the user",
                description: """
                    Hand the question a task is waiting on to the user, when neither the brief, the code nor the \
                    conversation settles it: its row turns amber and shows your reason. Their answer goes to the \
                    task, and a line comes to you.
                    """,
                properties: [
                    "task": ["type": "string", "description": taskDescription],
                    "why": ["type": "string", "description": "Why you can't answer it yourself, in one sentence."]
                ],
                required: ["task", "why"]
            ),
            definition(
                queueMerge, title: "Propose a merge queue",
                description: """
                    Open the merge queue's confirmation sheet for these pull requests of one repository, in this order. \
                    It never starts the queue: the user reviews it and clicks Start.
                    """,
                properties: [
                    "prs": ["type": "array", "items": ["type": "integer", "minimum": 1], "minItems": 1, "description": "Pull request numbers, in merge order."],
                    "repo": ["type": "string", "description": "The repository's name in this space, or owner/name; needed when the space has several."]
                ],
                required: ["prs"]
            ),
            definition(
                setTaskContext, title: "Set a task's next step and blocker",
                description: """
                    Keep a task's next step and blocker current: the user reads them on its row in the sidebar. \
                    Pass only what changed; an empty string clears one. A field the user wrote by hand stays \
                    theirs: Nirux says so, and leaves it.
                    """,
                properties: [
                    "task": ["type": "string", "description": taskDescription],
                    // The limit in words, not maxLength: Nirux counts after
                    // folding whitespace, a schema check before it.
                    "next_step": [
                        "type": "string",
                        "description": "What happens next, and who does it, in a few words, at most \(maxContextLength) characters "
                            + "(\"user reviews #39\", \"write the import side\")."
                    ],
                    "blocker": [
                        "type": "string",
                        "description": "What keeps the task from going on, at most \(maxContextLength) characters "
                            + "(\"waits for #212 to merge\"); empty once it is gone."
                    ]
                ],
                required: ["task"]
            )
        ]
    }

    private static func definition(
        _ name: String, title: String, description: String, properties: [String: Any], required: [String], readOnly: Bool = false
    ) -> [String: Any] {
        [
            "name": name,
            "title": title,
            "description": description,
            "inputSchema": ["type": "object", "properties": properties, "required": required, "additionalProperties": false],
            "annotations": ["readOnlyHint": readOnly, "destructiveHint": false, "openWorldHint": false]
        ]
    }

    // MARK: - Arguments

    /// A string argument, trimmed; nil when missing or blank.
    static func string(_ arguments: [String: Any], _ key: String) -> String? {
        (arguments[key] as? String).flatMap { value in
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
    }

    /// A next step or blocker as given: nil when left out (or null), ""
    /// to clear it; whitespace runs folded to one space, invisible
    /// characters dropped. `.some(nil)` when it isn't a string.
    static func contextText(_ arguments: [String: Any], _ key: String) -> String?? {
        guard let value = arguments[key], !(value is NSNull) else { return nil }
        guard let text = value as? String else { return .some(nil) }
        // Past the limit either way: cut, so a huge one isn't copied whole.
        return .some(AgentText.clean(text, maxLength: maxContextLength * 4) ?? "")
    }

    /// Whole positive numbers, as JSON gives them; nil for anything else.
    static func pullRequestNumbers(_ arguments: [String: Any]) -> [Int]? {
        guard let values = arguments["prs"] as? [Any], !values.isEmpty else { return nil }
        var numbers: [Int] = []
        for value in values {
            guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
                  let whole = Int(exactly: number.doubleValue), whole > 0 else { return nil }
            if !numbers.contains(whole) { numbers.append(whole) }
        }
        return numbers
    }

    /// What's wrong with a call's arguments before it reaches the app, or nil.
    static func problem(tool: String, arguments: [String: Any]) -> String? {
        let messageLimit = MissionEventCLI.maxMessageLength
        switch tool {
        case startTask:
            return string(arguments, "description") == nil ? "description must say what the task must do." : nil
        case listTasks:
            return nil
        case tell, reply:
            let target = tool == tell ? "task" : "question"
            guard string(arguments, target) != nil else { return "\(target) is missing." }
            guard let message = string(arguments, "message"), message.count <= messageLimit else {
                return "message must hold 1 to \(messageLimit) characters."
            }
            return nil
        case askUser:
            guard string(arguments, "task") != nil else { return "task is missing." }
            return string(arguments, "why") == nil ? "why must say why you can't answer it yourself." : nil
        case queueMerge:
            return pullRequestNumbers(arguments) == nil ? "prs must list pull request numbers." : nil
        case setTaskContext:
            guard string(arguments, "task") != nil else { return "task is missing." }
            let fields = ["next_step", "blocker"].map { ($0, contextText(arguments, $0)) }
            guard fields.contains(where: { $0.1 != nil }) else { return "Pass next_step, blocker or both (an empty string clears one)." }
            for (key, value) in fields {
                guard let value else { continue }
                guard let text = value else { return "\(key) must be a string." }
                guard text.count <= maxContextLength else { return "\(key) must hold at most \(maxContextLength) characters." }
            }
            return nil
        default:
            return "Unknown tool: \(tool)"
        }
    }
}
