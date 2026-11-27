import Foundation

/// The day plan's tools (docs/design/plan.md), listed to a space's agents while its day plan is on
/// (`SpaceDefaults.plansTheDay`). The plan's rules go in their descriptions: the Lead's instructions are full.
enum PlanTools {
    static let readPlan = "read_plan"
    static let addToPlan = "add_to_plan"
    static let checkPlanLine = "check_plan_line"
    static let taskSteps = "task_steps"
    static let leadNames = [readPlan, addToPlan, checkPlanLine]
    static let taskNames = [taskSteps]
    static let names = leadNames + taskNames

    static var leadDefinitions: [[String: Any]] {
        [
            LeadTools.definition(
                readPlan, title: "Read the day plan",
                description: """
                    The space's day plan as Nirux keeps it: features, to-dos for the user, your own lines, sessions \
                    (planned, or a task's) with their steps, each with its id, then what you proposed that the user \
                    hasn't taken. Read it after a restart or a /clear rather than rebuilding the plan.
                    """,
                properties: [:], required: [], readOnly: true
            ),
            LeadTools.definition(
                addToPlan, title: "Add to the day plan",
                description: """
                    Add a line at the end of its place in the day plan the user sees, as you plan the day together. \
                    Nothing moves or goes by itself: only the user reorders or removes lines. With propose, it waits \
                    in the morning triage for the user to take or drop: use that for what you read in GitHub, Linear, \
                    Slack, mail or Figma, with source, url and why.
                    """,
                properties: [
                    "kind": ["type": "string", "enum": ["todo", "lead", "session", "step"], "description": """
                        todo: the user does it. lead: you do it yourself. session: work for a task, planned until \
                        it starts, or with task a running task's line. step: one action under a line.
                        """],
                    "title": ["type": "string", "description": "At most \(Plan.maxTitleLength) characters; a task's title for a session with task."],
                    "feature": ["type": "string", "description": "The feature it goes in, by name: a new name makes one at the end."],
                    "under": ["type": "string", "description": "A line's id from read_plan: for a step, or a sub-session in a step's place."],
                    "task": ["type": "string", "description": LeadTools.taskDescription
                        + " With session, that task's line; with step, a step under it (its line is made if missing)."],
                    "for_user": ["type": "boolean", "description": "A step the user does: it stops the task's agent until checked."],
                    "after": ["type": "string", "description": "A line's id: this planned session starts once that line is checked."],
                    "detail": ["type": "string", "description": "What a planned session will do, as you would tell its agent."],
                    "source": ["type": "string", "description": "Where you read it: GitHub, Linear, Slack, Mail, Figma."],
                    "url": ["type": "string", "description": "A link to it, http or https."],
                    "why": ["type": "string", "description": "Why it belongs on the plan, in a few words."],
                    "propose": ["type": "boolean", "description": "true: the user takes or drops it in the triage."]
                ],
                required: ["kind"]
            ),
            LeadTools.definition(
                checkPlanLine, title: "Check a line of the day plan",
                description: """
                    Check a line of the day plan, or uncheck it with done false: your own lines once done, a to-do or \
                    a step for the user when they say it's done. A feature is done when its lines are. A checked line \
                    stays until the next morning.
                    """,
                properties: [
                    "line": ["type": "string", "description": "The line's id, as read_plan shows it."],
                    "done": ["type": "boolean", "description": "false unchecks it. Defaults to true."]
                ],
                required: ["line"]
            )
        ]
    }

    static var taskDefinitions: [[String: Any]] {
        [
            LeadTools.definition(
                taskSteps, title: "Your task's steps",
                description: """
                    Your task's steps in the space's day plan, which the user sees under your row. Add the steps you \
                    discover: they go at the end, and only the user reorders. Work them in order and check each one \
                    once done. A step for the user stops you: end your turn until they check it. Call it with nothing \
                    to read your steps back after a /clear.
                    """,
                properties: [
                    "add": ["type": "array", "items": ["type": "string"], "description": "Steps to add, in order, at most \(Plan.maxTitleLength) characters each."],
                    "for_user": ["type": "boolean", "description": "The steps added are the user's to do, such as a choice only they can make."],
                    "check": ["type": "array", "items": ["type": "string"], "description": "The ids of your steps that are done."]
                ],
                required: []
            )
        ]
    }
}

extension Plan.Store {
    /// Nil for a space id that isn't a plain name (see `SpaceBrief.directory`).
    init?(spaceID: String, stateDirectory: URL = Persistence.stateDirectory) {
        guard let folder = SpaceBrief.directory(spaceID: spaceID, stateDirectory: stateDirectory) else { return nil }
        self.init(fileURL: folder.appendingPathComponent(Self.fileName))
    }
}

/// The day plans the sidebar shows, read again only once their files changed: the sidebar refreshes several times a
/// second.
@MainActor
final class DayPlanFiles {
    private var spaces: [String: (isOn: FileBackedValue<Bool>, plan: FileBackedValue<Plan>)] = [:]

    /// Nil while the space's day plan is off.
    func plan(ofSpace spaceID: String) -> Plan? {
        guard let files = files(ofSpace: spaceID), files.isOn.value else { return nil }
        return files.plan.value
    }

    private func files(ofSpace spaceID: String) -> (isOn: FileBackedValue<Bool>, plan: FileBackedValue<Plan>)? {
        if let files = spaces[spaceID] { return files }
        guard let defaults = SpaceDefaultsStore(spaceID: spaceID), let store = Plan.Store(spaceID: spaceID) else { return nil }
        let files = (
            isOn: FileBackedValue(url: defaults.fileURL, read: { _ in defaults.load().defaults.plansTheDay }, write: { _, _ in }),
            plan: FileBackedValue(url: store.fileURL, read: { Plan.Store(fileURL: $0).load().plan }, write: { _, _ in })
        )
        spaces[spaceID] = files
        return files
    }
}
