import Foundation

/// The Lead's tools (docs/design/spaces.md, "The Lead"), listed by the Nirux MCP
/// server to a space's Lead only (`NIRUX_LEAD=1`). Each call goes to the
/// running app through `LeadChannel`, which acts within the Lead's space:
/// no tool merges or reaches another space, and only `close_task` removes
/// a worktree and a branch, once its pull request is merged.
enum LeadTools {
    static let startTask = "start_task"
    static let setTaskAfter = "set_task_after"
    static let listTasks = "list_tasks"
    static let tell = "tell"
    static let reply = "reply"
    static let askUser = "ask_user"
    static let mergeQueueStatus = "merge_queue_status"
    static let stopMergeQueue = "stop_merge_queue"
    static let queueMerge = "queue_merge"
    static let setTaskContext = "set_task_context"
    static let proposeRule = "propose_rule"
    static let closeTask = "close_task"
    static let moveTask = "move_task"
    static let renameTask = "rename_task"
    static let setTaskParent = "set_task_parent"
    static let readThread = "read_thread"
    static let readTask = "read_task"
    static let resumeTask = "resume_task"
    static let interruptTask = "interrupt_task"
    static let recordReview = "record_review"
    static let dailyPass = "daily_pass"
    static let listSpaces = "list_spaces"
    static let createSpace = "create_space"
    static let editSpace = "edit_space"
    static let deleteSpace = "delete_space"
    static let moveTaskToSpace = "move_task_to_space"
    static let names = [
        startTask, setTaskAfter, listTasks, tell, reply, askUser, mergeQueueStatus, stopMergeQueue, queueMerge, setTaskContext, proposeRule, recordReview, dailyPass,
        closeTask, moveTask, renameTask, setTaskParent, readThread, readTask, resumeTask, interruptTask,
        listSpaces, createSpace, editSpace, deleteSpace, moveTaskToSpace
    ]

    /// `start_task`'s `repo` for a task without a repository: a new folder
    /// of its own (unless a repository of the space has that name).
    static let noRepository = "none"

    static let queueRepoArgument = ["type": "string", "description": "The repository's name in this space, or owner/name; needed when the space has several."]

    static let taskIDPrefix = "task:"
    static let spaceIDPrefix = "space:"
    static let maxSpaceNameLength = 80

    /// How a tool names a space.
    static let spaceDescription = "The stable space:<id> from list_spaces, or the space's name."

    /// How a tool names one of the Lead's tasks.
    static let taskDescription = "The stable task:<id> from list_tasks, the task’s branch, its folder or folder name, or its title. "
        + "Use the ID when a waiting task shares a name. For other shared names, a single task reporting to you takes precedence."

    /// tell's `after`.
    static let afterDescription = "Another task of this space, named the same way: the message is held until that task's "
        + "pull request merges, then typed as a tell then would be (\"merge origin/main\" once the pull request it builds on "
        + "lands). Held across relaunches. If that pull request closes without merging, or its task closes first, the message "
        + "isn't typed and you hear it."

    /// What reply's description adds about a question's kind and recommendation.
    static let replyKindsDescription = "A question may say its kind (decision, access, spec-mismatch) and what the task "
        + "recommends; for access, what it needs, which only the user can give: hand it over with ask_user unless "
        + "you can say what to do instead. Accept a recommendation only when the brief, the code or the user's words "
        + "back it: a spec-mismatch one changes what the user asked for."

    /// reply's arguments, for the Lead's tasks and a task's sub-tasks.
    static var replyProperties: [String: Any] {
        [
        "question": ["type": "string", "description": "The question's id."],
        "message": ["type": "string", "description": "Your answer, at most \(MissionEventCLI.maxInstructionLength) characters."],
        "accept": [
            "type": "boolean",
            "description": "true, in place of message: send the task's recommended answer as yours (not for an access question)."
        ]
        ]
    }

    /// start_task's arguments: `own`, then `title` and `branch`, for the
    /// Lead's tasks and a task's sub-tasks.
    static func startTaskProperties(_ own: [String: Any]) -> [String: Any] {
        own.merging(nameProperties) { first, _ in first }.merging(agentProperties) { first, _ in first }
    }

    private static var nameProperties: [String: Any] {
        [
            "title": [
                "type": "string",
                "description": "Its name on its row: English, the distinctive word first, at most \(maxTaskTitleLength) characters "
                    + "(\(maxSubtaskTitleLength) for a sub-task), no branch, slug or PR number (\"Clearer task rows\"). "
                    + "Left out: the description's first line."
            ],
            "goal": [
                "type": "string",
                "description": "What it delivers, on its row under the title: one line in English starting with a verb, at most "
                    + "\(maxGoalLength) characters (\"Show a goal line on task rows\")."
            ],
            "branch": [
                "type": "string",
                "description": "Its new branch, type/kebab-words (fix/stale-labels). Left out: made from the title. "
                    + "Taken: -2, -3… is added. A task without a repository has none."
            ]
        ]
    }

    /// A next step or blocker: one line on the task's row.
    static let maxContextLength = 200

    /// A task's title, as the rename panel takes it.
    static let maxTitleLength = 80
    /// start_task's title: what a task's row shows whole; a sub-task's row
    /// is indented.
    static let maxTaskTitleLength = 22
    static let maxSubtaskTitleLength = 20
    /// start_task's goal: what the task delivers, a line under its title.
    static let maxGoalLength = 34

    /// What read_task returns of a message, its start and its end.
    static let maxReadLength = 6_000

    /// How long a call waits for a Nirux to take it: a running app takes
    /// it at once.
    static let takeTimeout: TimeInterval = 15

    /// How long a call then waits for the answer: a task fetches origin
    /// and makes its worktree first; a clean-up asks GitHub, then git
    /// deletes; the daily pass asks GitHub about each repository.
    static func workTimeout(for tool: String) -> TimeInterval {
        if tool == dailyPass { return 150 }
        return [startTask, closeTask, queueMerge].contains(tool) ? 300 : 30
    }

    static var agentProperties: [String: Any] {
        [
            "agent": ["type": "string", "enum": CodingAgent.launchable.map(\.rawValue),
                      "description": "Agent to launch. Defaults to the space's task agent."],
            "model": ["type": "string", "description": "Optional --model for that agent: an agy models slug, a codex debug models slug, or a Claude alias or full ID. Omit for its default. Preselected in the New sheet when approval is required."]
        ]
    }

    static var definitions: [[String: Any]] {
        [
            definition(
                startTask, title: "Start a task",
                description: """
                    Start a task in a new worktree of this space, from origin's base branch, fetched: Nirux writes \
                    the description into its handover, launches the chosen agent and links the task to you (its \
                    questions and result are typed into your prompt). One repository per task. Work that needs no \
                    repository (research, writing, a one-off script) starts in a new folder of its own instead, \
                    with no git, branch or pull request: repo "\(noRepository)", or any task in a space without a \
                    repository. Never "\(noRepository)" for work that reads or changes a repository of this space: \
                    start it in that repository. When the user turned "Starts tasks without asking" off, it opens \
                    the New sheet filled in for the user to start instead.
                    """,
                properties: startTaskProperties([
                    "description": ["type": "string", "description": "What the task must do, as you would tell the agent."],
                    "repo": ["type": "string", "description": "The repository's name in this space (see list_tasks); its default one when left out. \"\(noRepository)\": a new folder, no repository."],
                    "after": ["type": "string", "description": "Create a waiting task. Once the named task’s pull request merges, fetch the base and start the agent. Requires a repository and Starts tasks without asking."],
                    "template": ["type": "string", "description": "A task template's name (Space Settings › Templates), if one fits."]
                ]),
                required: ["description"]
            ),
            definition(
                setTaskAfter, title: "Change a waiting task’s dependency",
                description: "Point a waiting task at another task, or omit after to start it now.",
                properties: [
                    "task": ["type": "string", "description": taskDescription],
                    "after": ["type": "string", "description": "The task whose pull request must merge before this one starts."]
                ],
                required: ["task"]
            ),
            definition(
                listTasks, title: "List a space's tasks",
                description: """
                    A space's tasks and repositories: each task's title, branch, repository, agent state (working, \
                    needs the user, asking you, stopped on an API error, silent, exited mid-turn, idle, done), pull request and checks, the \
                    last questions it got answered, and the question or result it sent you, its next step and blocker. Defaults to your \
                    space; pass space to inspect another space. Read it again after a /clear: Nirux keeps the state, your \
                    conversation doesn't.
                    """,
                properties: [
                    "space": ["type": "string", "description": "Optional: another space to inspect. \(spaceDescription) Omit for your own space."]
                ],
                required: [], readOnly: true
            ),
            definition(
                tell, title: "Tell a task",
                description: """
                    Type a message into a task's prompt once its agent's turn is over (a follow-up, an answer it \
                    didn't ask for, a slash command). Any task of this space: one that doesn't report to you (a \
                    sub-task, a task the user started) gets it under a line saying it comes from you (so no \
                    slash command); its questions and result still go to whoever started it. Claude Code, \
                    Codex and Antigravity tasks only; slash commands are Claude Code's (Codex gets the text through its queue).
                    """,
                properties: [
                    "task": ["type": "string", "description": taskDescription],
                    "message": ["type": "string", "description": "At most \(MissionEventCLI.maxInstructionLength) characters."],
                    "after": ["type": "string", "description": afterDescription]
                ],
                required: ["task", "message"]
            ),
            definition(
                reply, title: "Answer a task's question",
                description: "Answer the question a task asked you, by its id (in the [Nirux Mission] message and list_tasks). "
                    + replyKindsDescription,
                properties: replyProperties, required: ["question"]
            ),
            definition(
                askUser, title: "Hand a task's question to the user",
                description: """
                    Hand the question a task is waiting on to the user, when neither the brief, the code nor the \
                    conversation settles it: its row turns amber and shows your reason, and the task's \
                    recommendation, if it gave one, which the user can accept (for access, what it needs, with \
                    nothing to accept). Their answer goes to the task, and a line comes to you.
                    """,
                properties: [
                    "task": ["type": "string", "description": taskDescription],
                    "why": ["type": "string", "description": "Why you can't answer it yourself, in one sentence."]
                ],
                required: ["task", "why"]
            ),
            definition(
                mergeQueueStatus, title: "Inspect the merge queue",
                description: "Read the queue phase, progress, selection, Lead settings and the last ten journal entries, even with the Board closed.",
                properties: ["repo": queueRepoArgument], required: [], readOnly: true
            ),
            definition(
                stopMergeQueue, title: "Stop the merge queue",
                description: "With Lead auto-start enabled, stop this instance’s queue before its next command. An in-flight command finishes.",
                properties: ["repo": queueRepoArgument], required: [], destructive: true
            ),
            definition(
                queueMerge, title: "Queue pull requests",
                description: """
                    Queue these pull requests of one repository in the given order. By default the user confirms in a sheet. \
                    If this space allows the Lead to start the queue, it starts directly when every safety check passes.
                    """,
                properties: [
                    "cadence": ["type": "string", "enum": MergeQueue.Cadence.allCases.map(\.toolArgument), "default": "standard"],
                    "prs": ["type": "array", "items": ["type": "integer", "minimum": 1], "minItems": 1, "description": "Pull request numbers, in merge order."],
                    "replace": ["type": "boolean", "default": false, "description": "Replace the idle Board selection only when the user asks. Requires Lead auto-start."],
                    "repo": queueRepoArgument
                ],
                required: ["prs"]
            ),
            definition(
                setTaskContext, title: "Set a task's next step and blocker",
                description: """
                    Keep a task's next step and blocker current, any task of this space: the user reads them on \
                    its row in the sidebar. Pass only what changed; an empty string clears one. A field the user \
                    wrote by hand stays theirs: Nirux says so, and leaves it.
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
            ),
            definition(
                proposeRule, title: "Propose a rule for the space brief",
                description: """
                    When a second, different task gets the same kind of finding (the same defect class in two tasks, \
                    not two review rounds of one), propose a rule that would have prevented it: an instruction every \
                    later task follows, in one or two lines; name the repository when it holds for one only. Never on \
                    a first finding. The user sees it on your row and adds, edits or dismisses it; nothing reaches the \
                    brief without them. An added rule reaches only sessions started from then on: until you hear it \
                    was added, keep telling tasks yourself.
                    """,
                properties: [
                    "rule": [
                        "type": "string",
                        "description": "The rule, at most \(LearnedRules.maxRuleLength) characters "
                            + "(\"Tests wait on state, never on a fixed sleep or the wall clock.\")."
                    ],
                    "evidence": [
                        "type": "string",
                        "description": "Where the defect showed up, at most \(LearnedRules.maxEvidenceLength) characters "
                            + "(\"#395, #417\", or the tasks' branches)."
                    ]
                ],
                required: ["rule", "evidence"]
            ),
            definition(
                recordReview, title: "Record a review's findings",
                description: """
                    Record what your review of a task found, once you send it: one call per review, with all its \
                    findings, each with its kind, a short class name you reuse whenever a finding is of the same class, \
                    in any task ("animation-end-deadline", "test-waits-on-sleep"). Pass an empty findings list ([]) for \
                    a clean review: Nirux marks the local code review pass on the task's current HEAD and branch. Any \
                    task of this space. Nirux keeps them 30 days: the answer lists the kinds the space uses, and says \
                    when one shows up in a second task, where propose_rule comes in. The daily pass reads them.
                    """,
                properties: [
                    "task": ["type": "string", "description": taskDescription],
                    "findings": [
                        "type": "array", "minItems": 0, "maxItems": ReviewFindings.maxFindings,
                        "items": [
                            "type": "object",
                            "properties": [
                                "kind": [
                                    "type": "string",
                                    "description": "A kebab-case class name, at most \(ReviewFindings.maxKindLength) characters."
                                ],
                                "text": ["type": "string", "description": "The finding, at most \(ReviewFindings.maxTextLength) characters."]
                            ],
                            "required": ["kind", "text"], "additionalProperties": false
                        ]
                    ]
                ],
                required: ["task", "findings"]
            ),
            definition(
                dailyPass, title: "Read the space's day for the daily pass",
                description: """
                    What happened in this space since the last daily pass (the last day, for the first): your recorded \
                    findings by kind, the pull requests merged with their review rounds, CI failures, flaky tests and \
                    reruns, task wait times, Mission messages held, given up or crossed, the questions the user answered, the rules \
                    decided, waiting or in the brief, and the tasks you may have forgotten. Nirux asks for it once a \
                    day; the user may ask too. Its text says what to propose.
                    """,
                properties: [:], required: []
            ),
            definition(
                closeTask, title: "Close a task",
                description: """
                    Close a task's workspace once it is merged or abandoned: its agent's session ends. When its pull \
                    request is merged (Nirux asks GitHub, as Clean Up Worktree… does), Nirux also deletes its worktree \
                    and local branch; a task without a repository has its folder moved to the Trash. Otherwise they \
                    stay, and the answer says why. Any task of this space, the user's too, but never while the user has \
                    it on screen, its agent works or waits on the user, a program runs in its terminals, with unsaved \
                    editor changes, or with sub-tasks open.
                    """,
                properties: ["task": ["type": "string", "description": taskDescription]],
                required: ["task"], destructive: true
            ),
            definition(
                moveTask, title: "Move a task in the sidebar",
                description: """
                    Move a task up or down the sidebar, among its siblings: the space's tasks, a task's sub-tasks, or \
                    the archived tasks. Its sub-tasks move with it; your own row stays first.
                    """,
                properties: [
                    "task": ["type": "string", "description": taskDescription],
                    "position": [
                        "type": "integer", "minimum": 1,
                        "description": "Its place among its siblings, 1 for the top, in list_tasks' order; past the end, last."
                    ]
                ],
                required: ["task", "position"]
            ),
            definition(
                renameTask, title: "Rename a task",
                description: "Give a task of this space the title its row shows, as Rename… does: agents' titles no longer replace it.",
                properties: [
                    "task": ["type": "string", "description": taskDescription],
                    "title": ["type": "string", "description": "The new title, one line, at most \(maxTitleLength) characters."]
                ],
                required: ["task", "title"]
            ),
            definition(
                setTaskParent, title: "Put a task under another, or take it out",
                description: """
                    List a task under another task of this space as its sub-task, or at the top level when parent is \
                    left out. Two levels at most: the parent can't be a sub-task, nor the task have sub-tasks; a task \
                    holds at most \(TaskTools.maxRunningSubtasks) sub-tasks. Who a task reports to doesn't change.
                    """,
                properties: [
                    "task": ["type": "string", "description": taskDescription],
                    "parent": ["type": "string", "description": "The task to list it under, named the same way; left out, the top level."]
                ],
                required: ["task"]
            ),
            definition(
                readThread, title: "Read a task’s thread",
                description: "Read a task’s request, decisions, open questions, latest status, PRs and next step in up to 6,000 characters. Use after restarting the Lead.",
                properties: ["task": ["type": "string", "description": taskDescription + " A retained thread also accepts its workspace ID."]],
                required: ["task"], readOnly: true
            ),
            definition(
                readTask, title: "Read a task's last message",
                description: """
                    The last message a task's Claude Code agent wrote, in full up to \(maxReadLength) characters (its \
                    start and end past that): what list_tasks sums up in a line. Any task of this space.
                    """,
                properties: ["task": ["type": "string", "description": taskDescription]],
                required: ["task"], readOnly: true
            ),
            definition(
                resumeTask, title: "Resume a task with another CLI",
                description: "End the worker of one of your tasks and start a fresh session with the selected CLI in its existing terminal and worktree.",
                properties: [
                    "task": ["type": "string", "description": taskDescription],
                    "agent": ["type": "string", "enum": CodingAgent.launchable.map(\.rawValue)],
                    "model": ["type": "string", "description": "The provider’s model ID. Omit to use the CLI’s configured default."]
                ],
                required: ["task", "agent"], destructive: true
            ),
            definition(
                interruptTask, title: "Interrupt a task's turn",
                description: """
                    Stop the turn a task's Claude Code agent is working on, as Esc does, without closing anything; \
                    then tell it what to do instead. Only once the turn has called a tool and nothing was typed into \
                    its prompt since: Claude Code puts a prompt it hasn't answered, and messages queued meanwhile, \
                    back in its prompt box, where your next message would join them.
                    """,
                properties: ["task": ["type": "string", "description": taskDescription]],
                required: ["task"], destructive: true
            ),
            definition(
                listSpaces, title: "List all spaces",
                description: """
                    List every Nirux space in sidebar order: name, space:<id>, color hex, default flag, repositories and \
                    folders, open and archived task counts, whether a Lead is active, and whether a merge queue is running.
                    """,
                properties: [:], required: [], readOnly: true
            ),
            definition(
                createSpace, title: "Create a space",
                description: """
                    Create a space without switching the user to it. anchors: absolute paths; a path in a git repository \
                    anchors that repository. One that belongs to another space moves only with move_anchors, never from a \
                    space with a Lead or a running merge queue.
                    """,
                properties: [
                    "name": ["type": "string", "description": "Unique space name (trimmed, case-insensitively unique)."],
                    "color": ["type": "string", "description": "Optional #RRGGBB hex color. Omit for Nirux's next palette color."],
                    "anchors": [
                        "type": "array", "items": ["type": "string"],
                        "description": "Optional absolute paths of git repositories or folders to anchor to the space."
                    ],
                    "move_anchors": [
                        "type": "boolean", "default": false,
                        "description": "true moves an anchor that belongs to another space, when the user asked to."
                    ]
                ],
                required: ["name"]
            ),
            definition(
                editSpace, title: "Edit a space",
                description: """
                    Rename a space, change its color, or add and remove its repositories and folders. Pass only what \
                    changes. Anchors move from another space as with create_space; a space with a Lead or a running \
                    merge queue keeps its own.
                    """,
                properties: [
                    "space": ["type": "string", "description": spaceDescription],
                    "name": ["type": "string", "description": "Optional new space name (unique, non-empty)."],
                    "color": ["type": "string", "description": "Optional new #RRGGBB hex color."],
                    "add_anchors": [
                        "type": "array", "items": ["type": "string"],
                        "description": "Optional absolute paths of git repositories or folders to add."
                    ],
                    "remove_anchors": [
                        "type": "array", "items": ["type": "string"],
                        "description": "Optional anchor names or paths to remove from the space."
                    ],
                    "move_anchors": [
                        "type": "boolean", "default": false,
                        "description": "true moves an anchor of add_anchors that belongs to another space, when the user asked to."
                    ]
                ],
                required: ["space"]
            ),
            definition(
                deleteSpace, title: "Delete a space",
                description: """
                    Delete a space: its tasks move to move_tasks_to first; its defaults, setup scripts and rule proposals \
                    are deleted, its brief stays. Refused for General, your space, the space on screen, and a space with a \
                    Lead or a running merge queue.
                    """,
                properties: [
                    "space": ["type": "string", "description": spaceDescription],
                    "move_tasks_to": [
                        "type": "string",
                        "description": "Optional destination space (name or space:<id>) to move remaining tasks into before deleting."
                    ]
                ],
                required: ["space"], destructive: true
            ),
            definition(
                moveTaskToSpace, title: "Move a task to another space",
                description: """
                    Move a task and its sub-tasks to another space. The task is found in your space, or in from_space. \
                    Refused for the task on screen, a task waiting for a merge, and one with an open Mission (it reports \
                    to a Lead or task that stays).
                    """,
                properties: [
                    "task": ["type": "string", "description": taskDescription],
                    "to_space": ["type": "string", "description": "Destination space. \(spaceDescription)"],
                    "from_space": ["type": "string", "description": "Optional source space. \(spaceDescription) Defaults to your space."]
                ],
                required: ["task", "to_space"]
            )
        ]
    }

    static func definition(
        _ name: String, title: String, description: String, properties: [String: Any], required: [String],
        readOnly: Bool = false, destructive: Bool = false
    ) -> [String: Any] {
        [
            "name": name,
            "title": title,
            "description": description,
            "inputSchema": ["type": "object", "properties": properties, "required": required, "additionalProperties": false],
            "annotations": ["readOnlyHint": readOnly, "destructiveHint": destructive, "openWorldHint": false]
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

    /// reply's `accept`: false when left out, nil when not a JSON boolean.
    static func accepts(_ arguments: [String: Any]) -> Bool? {
        arguments["accept"] is NSNull ? false : optionalFlag(arguments, "accept")
    }

    static func optionalFlag(_ arguments: [String: Any], _ key: String) -> Bool? {
        guard let value = arguments[key] else { return false }
        guard let flag = value as? NSNumber, CFGetTypeID(flag) == CFBooleanGetTypeID() else { return nil }
        return flag.boolValue
    }

    static func queueCadence(_ arguments: [String: Any]) -> MergeQueue.Cadence? {
        guard let value = arguments["cadence"] else { return .standard }
        return MergeQueue.Cadence.allCases.first { $0.toolArgument == value as? String }
    }

    /// Whole positive numbers, as JSON gives them; nil for anything else.
    static func pullRequestNumbers(_ arguments: [String: Any]) -> [Int]? {
        guard let values = arguments["prs"] as? [Any], !values.isEmpty else { return nil }
        var numbers: [Int] = []
        for value in values {
            guard let whole = positiveInteger(value) else { return nil }
            if !numbers.contains(whole) { numbers.append(whole) }
        }
        return numbers
    }

    /// rename_task's and start_task's title on one line, whitespace folded.
    /// A huge one is cut past twice the limit, so a cut one is still refused
    /// as too long.
    static func title(_ arguments: [String: Any]) -> String? {
        (arguments["title"] as? String).flatMap { AgentText.clean($0, maxLength: maxTitleLength * 2) }
    }

    /// start_task's `title`, `branch` and `goal`, checked by `problem` first.
    static func startOptions(_ arguments: [String: Any]) -> NewTask.StartOptions {
        NewTask.StartOptions(
            title: title(arguments), branch: string(arguments, "branch"),
            goal: (arguments["goal"] as? String).flatMap { AgentText.clean($0, maxLength: maxGoalLength * 2) }
        )
    }

    /// `key` is there, and not null.
    static func isGiven(_ arguments: [String: Any], _ key: String) -> Bool {
        guard let value = arguments[key] else { return false }
        return !(value is NSNull)
    }

    /// A whole positive number, as JSON gives it (not a boolean).
    static func positiveInteger(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              let whole = Int(exactly: number.doubleValue), whole > 0 else { return nil }
        return whole
    }

    /// Validates a `#RRGGBB` hex color and returns its normalized uppercase form, or nil.
    static func normalizedColorHex(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count == 7, trimmed.hasPrefix("#") else { return nil }
        let hex = trimmed.dropFirst()
        guard hex.allSatisfy(\.isHexDigit) else { return nil }
        return "#" + hex.uppercased()
    }

    /// An array of non-empty strings, trimmed; nil when left out or not one.
    static func stringArray(_ arguments: [String: Any], _ key: String) -> [String]? {
        guard let items = arguments[key] as? [Any] else { return nil }
        let strings = items.compactMap { ($0 as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        return strings.count == items.count ? strings : nil
    }

    /// What's wrong with a call's arguments before it reaches the app, or nil.
    /// `subtask`: a task's agent calls, for a sub-task.
    static func problem(tool: String, arguments: [String: Any], subtask: Bool = false) -> String? {
        let messageLimit = MissionEventCLI.maxInstructionLength
        if [startTask, setTaskAfter].contains(tool), arguments["after"] != nil, string(arguments, "after") == nil {
            return "after must name a task of this space."
        }
        if [queueMerge, mergeQueueStatus, stopMergeQueue].contains(tool), arguments["repo"] != nil, string(arguments, "repo") == nil {
            return "repo must name a repository in this space."
        }
        switch tool {
        case startTask:
            if arguments["agent"] != nil, string(arguments, "agent").flatMap(CodingAgent.init(launchable:)) == nil {
                return "Unknown agent “\(string(arguments, "agent") ?? "")”. Choices: \(CodingAgent.launchable.map(\.rawValue).joined(separator: ", "))."
            }
            if arguments["model"] != nil, string(arguments, "model") == nil { return "model must be a nonempty string." }
            guard string(arguments, "description") != nil else { return "description must say what the task must do." }
            let options = startOptions(arguments)
            let titleLength = subtask ? maxSubtaskTitleLength : maxTaskTitleLength
            if isGiven(arguments, "title"), options.title.map({ $0.count <= titleLength }) != true {
                return "title must hold 1 to \(titleLength) characters\(subtask ? " for a sub-task" : ""): its row shows no more."
            }
            if isGiven(arguments, "goal"), options.goal.map({ $0.count <= maxGoalLength }) != true {
                return "goal must hold 1 to \(maxGoalLength) characters: what the task delivers, starting with a verb."
            }
            if isGiven(arguments, "branch"), string(arguments, "branch").map(NewTask.isTaskBranchName) != true {
                return "branch must be a valid git branch name of its own, such as fix/stale-labels (not origin/…)."
            }
            return nil
        case listTasks:
            if isGiven(arguments, "space") {
                if subtask { return "Only the space's Lead can inspect another space." }
                if string(arguments, "space") == nil { return "space must name a space (or omit it for your own space)." }
            }
            return nil
        case tell, reply:
            let target = tool == tell ? "task" : "question"
            guard string(arguments, target) != nil else { return "\(target) is missing." }
            if tool == tell, let after = arguments["after"], !(after is NSNull), !(after is String) {
                return "after must name a task of this space."
            }
            if tool == reply {
                guard let accepts = accepts(arguments) else { return "accept must be true or false." }
                if accepts { return string(arguments, "message") == nil ? nil : "Pass message or accept, not both." }
            }
            guard let message = string(arguments, "message") else { return "message must hold 1 to \(messageLimit) characters." }
            return MissionEventCLI.problem(with: message, limit: messageLimit)
        case askUser:
            guard string(arguments, "task") != nil else { return "task is missing." }
            return string(arguments, "why") == nil ? "why must say why you can't answer it yourself." : nil
        case closeTask:
            return string(arguments, "task") == nil ? "task is missing." : nil
        case moveTask:
            guard string(arguments, "task") != nil else { return "task is missing." }
            return positiveInteger(arguments["position"]) == nil ? "position must be a whole number, 1 for the top." : nil
        case renameTask:
            guard string(arguments, "task") != nil else { return "task is missing." }
            guard let title = title(arguments), title.count <= maxTitleLength else {
                return "title must hold 1 to \(maxTitleLength) characters."
            }
            return nil
        case resumeTask:
            guard string(arguments, "task") != nil else { return "task is missing." }
            if case .failure(let problem) = TaskAgentChoice.parse(arguments) { return problem.localizedDescription }
            return nil
        case setTaskAfter, setTaskParent, readThread, readTask, interruptTask:
            return string(arguments, "task") == nil ? "task is missing." : nil
        case recordReview:
            guard string(arguments, "task") != nil else { return "task is missing." }
            if case .failure(let refusal) = ReviewFindings.findings(arguments["findings"]) { return refusal.reason }
            return nil
        case dailyPass, mergeQueueStatus, stopMergeQueue:
            return nil
        case queueMerge:
            guard optionalFlag(arguments, "replace") != nil else { return "replace must be true or false." }
            guard pullRequestNumbers(arguments) != nil else { return "prs must list pull request numbers." }
            return queueCadence(arguments) == nil ? "cadence must be standard, batch_post_merge or express_disjoint." : nil
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
        case proposeRule:
            guard let rule = arguments["rule"] as? String, let evidence = arguments["evidence"] as? String else {
                return "rule and evidence must be strings."
            }
            return LearnedRules.proposalProblem(
                rule: LearnedRules.cleaned(rule, limit: LearnedRules.maxRuleLength),
                evidence: LearnedRules.cleaned(evidence, limit: LearnedRules.maxEvidenceLength)
            )
        case listSpaces, createSpace, editSpace, deleteSpace, moveTaskToSpace:
            return spaceToolProblem(tool: tool, arguments: arguments)
        default:
            return "Unknown tool: \(tool)"
        }
    }

    private static func spaceToolProblem(tool: String, arguments: [String: Any]) -> String? {
        switch tool {
        case listSpaces:
            return nil
        case createSpace:
            return spaceNameProblem(arguments, required: true) ?? spaceChangeProblem(arguments, anchors: "anchors")
        case editSpace:
            guard string(arguments, "space") != nil else { return "space is missing." }
            if let problem = spaceNameProblem(arguments, required: false) ?? spaceChangeProblem(arguments, anchors: "add_anchors")
                ?? listProblem(arguments, "remove_anchors", paths: false) {
                return problem
            }
            let changes = isGiven(arguments, "name") || isGiven(arguments, "color")
                || !(stringArray(arguments, "add_anchors") ?? []).isEmpty || !(stringArray(arguments, "remove_anchors") ?? []).isEmpty
            return changes ? nil : "Pass at least one change: name, color, add_anchors or remove_anchors."
        case deleteSpace:
            guard string(arguments, "space") != nil else { return "space is missing." }
            if isGiven(arguments, "move_tasks_to"), string(arguments, "move_tasks_to") == nil {
                return "move_tasks_to must name a destination space."
            }
            return nil
        case moveTaskToSpace:
            guard string(arguments, "task") != nil else { return "task is missing." }
            guard string(arguments, "to_space") != nil else { return "to_space is missing." }
            if isGiven(arguments, "from_space"), string(arguments, "from_space") == nil {
                return "from_space must name a source space."
            }
            return nil
        default:
            return "Unknown tool: \(tool)"
        }
    }

    private static func spaceNameProblem(_ arguments: [String: Any], required: Bool) -> String? {
        guard required || isGiven(arguments, "name") else { return nil }
        guard let name = string(arguments, "name"), !name.contains(where: \.isNewline), name.count <= maxSpaceNameLength else {
            return "name must be a single line holding 1 to \(maxSpaceNameLength) characters."
        }
        return nil
    }

    /// create_space's and edit_space's color, move_anchors and anchors to add.
    private static func spaceChangeProblem(_ arguments: [String: Any], anchors key: String) -> String? {
        if isGiven(arguments, "color"), (arguments["color"] as? String).flatMap(normalizedColorHex) == nil {
            return "color must be a valid #RRGGBB hex color."
        }
        if isGiven(arguments, "move_anchors"), optionalFlag(arguments, "move_anchors") == nil {
            return "move_anchors must be true or false."
        }
        return listProblem(arguments, key, paths: true)
    }

    /// An optional array of strings; `paths`: absolute ones, as a relative
    /// one would be read from Nirux's own folder.
    private static func listProblem(_ arguments: [String: Any], _ key: String, paths: Bool) -> String? {
        guard isGiven(arguments, key) else { return nil }
        guard let items = stringArray(arguments, key) else { return "\(key) must be an array of non-empty strings." }
        if paths, let relative = items.first(where: { !$0.hasPrefix("/") && !$0.hasPrefix("~") }) {
            return "\(key) takes absolute paths: \(relative) isn't one."
        }
        return nil
    }
}
