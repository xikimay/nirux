import Foundation

/// The tools of a task's agent: any Claude agent Nirux launches in a
/// workspace that isn't a space's Lead. The Nirux MCP server lists them
/// with the Lead's names, scoped to the caller's own sub-tasks. Each call
/// goes to the running app through `LeadChannel`, which checks it against
/// its own state: the caller must be a task, and it reaches only its own
/// sub-tasks. A sub-task can't start sub-tasks (two levels), and a task
/// runs at most `maxRunningSubtasks` at once. Nothing here merges, removes
/// a worktree or a branch, or reaches another task or space.
enum TaskTools {
    static let names = [LeadTools.startTask, LeadTools.listTasks, LeadTools.reply]

    /// Sub-tasks of one task at once, not counting archived ones nor those
    /// that completed.
    static let maxRunningSubtasks = 6

    static var definitions: [[String: Any]] {
        [
            LeadTools.definition(
                LeadTools.startTask, title: "Start a sub-task",
                description: """
                    Start a sub-task of your task: another agent does part of the work in a new worktree of the same \
                    repository, from origin's base branch, fetched (for a task without a repository, in a folder \
                    inside your task's folder). Nirux writes the description into its handover, launches the space's \
                    agent, lists it under your task and links it to you: its questions and its result are typed into \
                    your prompt once your turn is over. A sub-task can't start sub-tasks, and a task runs at most \
                    \(maxRunningSubtasks) at once. When the user turned "Starts tasks without asking" off for the \
                    space, it opens the New Sub-task sheet filled in for them to start instead.
                    """,
                properties: [
                    "description": [
                        "type": "string",
                        "description": "What the sub-task must do, as you would tell the agent. Its first line names it and its branch or folder."
                    ],
                    "template": ["type": "string", "description": "A task template's name (Space Settings › Templates), if one fits."]
                ],
                required: ["description"]
            ),
            LeadTools.definition(
                LeadTools.listTasks, title: "List your sub-tasks",
                description: """
                    Your task's sub-tasks: each one's title, branch or folder, agent state (working, needs the user, \
                    idle), pull request and checks, and the question or result it sent you. Read it again after a \
                    /clear: Nirux keeps the state, your conversation doesn't.
                    """,
                properties: [:], required: [], readOnly: true
            ),
            LeadTools.definition(
                LeadTools.reply, title: "Answer a sub-task's question",
                description: "Answer the question one of your sub-tasks asked you, by its id (in the [Nirux Mission] message and list_tasks).",
                properties: [
                    "question": ["type": "string", "description": "The question's id."],
                    "message": ["type": "string", "description": "Your answer, at most \(MissionEventCLI.maxMessageLength) characters."]
                ],
                required: ["question", "message"]
            )
        ]
    }
}
