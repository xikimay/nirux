import Foundation

/// What a space sets for the workspaces started in it (docs/design/projects.md,
/// section 5): the agent preselected for its tasks, the agent
/// launch modes, and environment variables for new shells. Edited in Space
/// Settings › Defaults, kept in the space's `defaults.json`
/// (SpaceDefaultsStore).
///
/// Precedence: Nirux computes one value per launch, an explicit choice for
/// that launch first, then the space's, then Settings'.
struct SpaceDefaults: Equatable, Sendable {
    /// Preselected for a task (New Task…, ⌘N). Nil: Claude Code. A plain
    /// workspace stays a shell whatever it says.
    var agent: CodingAgent?
    var leadAgent: CodingAgent?
    var preferredLeadAgent: CodingAgent { leadAgent ?? .claude }

    /// Nil: Settings' mode.
    var claudeLaunchMode: ClaudeLaunchMode?
    var codexLaunchMode: CodexLaunchMode?
    var agyLaunchMode: AgyLaunchMode?
    /// As listed in Space Settings. `effectiveEnvironment` is what shells
    /// get.
    var environment: [EnvironmentVariable] = []
    /// Space Settings › Lead, "Starts tasks without asking". Nil: on. Off,
    /// the Lead's `start_task` opens the New sheet for the user to start.
    var leadStartsTasks: Bool?
    var leadStartsMergeQueue: Bool?
    var leadCanStartMergeQueue: Bool { leadStartsMergeQueue ?? false }
    var leadStartsMergeQueueWithoutLocalReview: Bool?
    var leadCanStartMergeQueueWithoutLocalReview: Bool { leadStartsMergeQueueWithoutLocalReview ?? false }
    /// Space Settings › Lead, "Fresh start when idle with a heavy context".
    /// Nil: on.
    var leadFreshStart: Bool?
    /// Space Settings › Lead, "Daily pass" (docs/design/daily-pass.md). Nil:
    /// on, after `DailyPass.defaultHour`.
    var leadDailyPass: Bool?
    /// Space Settings › Lead, "Group task results" (`MissionResultBatch`).
    /// Nil: on.
    var leadGroupsResults: Bool?
    /// 0 to 23, local time.
    var leadDailyPassHour: Int?
    /// Space Settings › Defaults, "Follow up on pull requests"
    /// (docs/design/pr-follow-up.md). Nil: on; only false turns it off.
    var prFollowUp: Bool?
    /// Space Settings › Defaults, "Resume work after a relaunch"
    /// (`RelaunchResume`). Nil: on; only false turns it off.
    var resumeWorkOnRelaunch: Bool?
    /// Space Settings › Defaults, "Lead on Fable, subagents on Opus". Nil:
    /// on.
    var claudeModelSplit: Bool?
    /// Space Settings › Defaults, "Task budget": weighted tokens
    /// (`TokenCounts.weighted`) a task may spend over 7 days before its row
    /// warns and its pull request's follow-ups wait. Nil: the default; 0: off.
    var taskBudget: Int?
    /// Space Settings › Defaults, "Tasks can manage spaces": its tasks'
    /// agents get the Lead's space tools (SpaceToolCaller). Nil: on in
    /// General, off elsewhere (`tasksCanManageSpaces`).
    var tasksManageSpaces: Bool?
    /// The day plan (docs/design/plan.md), while it is built: on, the space's agents get the plan's tools
    /// (PlanTools). Nil: off.
    var dayPlan: Bool?
    /// Space Settings › Safety, one per `ClaudeSpaceSettings.Part`. Nil:
    /// its default.
    var claudeTrustsRepositories: Bool?
    var claudeDeniesIrreversible: Bool?
    var claudeSandbox: Bool?
    /// Lines the user added from the recap (`ClaudeSpaceSettings.Line`).
    var claudeAllow: [String] = []
    var claudeEnvironment: [String] = []

    /// Whether the space's Lead starts its tasks itself.
    var leadStartsTasksWithoutAsking: Bool { leadStartsTasks ?? true }

    var dailyPassIsOn: Bool { leadDailyPass ?? true }
    var groupsResults: Bool { leadGroupsResults ?? true }
    /// Whether a cold Lead with a heavy context starts a new conversation
    /// (`ContextOffer.restartsLead`).
    var leadStartsFreshWhenCold: Bool { leadFreshStart ?? true }
    var dailyPassHour: Int { leadDailyPassHour ?? DailyPass.defaultHour }
    /// Whether Nirux types the rounds its tasks' pull requests need.
    var followsUpPullRequests: Bool { prFollowUp ?? true }
    var resumesWorkOnRelaunch: Bool { resumeWorkOnRelaunch ?? true }
    var splitsClaudeModels: Bool { claudeModelSplit ?? true }
    var plansTheDay: Bool { dayPlan ?? false }

    /// About the 90th percentile of what a Nirux task spent in 7 days
    /// (the 2026-11-23 scan).
    static let defaultTaskBudget = 25_000_000
    static let taskBudgetChoices = [0, 10_000_000, defaultTaskBudget, 50_000_000, 100_000_000]

    /// Nil: no budget.
    var weeklyTaskBudget: Int? {
        let budget = taskBudget ?? Self.defaultTaskBudget
        return budget > 0 ? budget : nil
    }

    /// What the switch sets in a new terminal (Claude Code reads it as it
    /// starts): every subagent on Opus, whatever its call or agent file
    /// asks. A subagent starts its own context: a resumed session switches
    /// at no cache cost.
    var claudeModelEnvironment: [String: String] {
        splitsClaudeModels ? ["CLAUDE_CODE_SUBAGENT_MODEL": "opus", "CLAUDE_CODE_SUBAGENT_MODEL_FORCE": "1"] : [:]
    }

    /// The model of a new Lead conversation, on its launch line only: a
    /// resumed one keeps the model it ran (Claude Code restores it), and the
    /// rest of the Lead's terminal never inherits it.
    func leadModel(for agent: CodingAgent) -> String? {
        agent == .claude && splitsClaudeModels ? "fable" : nil
    }

    /// The space's variables, then the model switch's: a variable the user
    /// set for the space wins.
    var shellEnvironment: [String: String] {
        effectiveEnvironment.merging(claudeModelEnvironment) { space, _ in space }
    }

    func tasksCanManageSpaces(inSpace spaceID: String) -> Bool {
        tasksManageSpaces ?? Self.tasksManageSpacesByDefault(inSpace: spaceID)
    }

    static func tasksManageSpacesByDefault(inSpace spaceID: String) -> Bool {
        spaceID == WorkspaceProfile.defaultID
    }

    /// Nothing is written for the space's default.
    mutating func setTasksManageSpaces(_ on: Bool, inSpace spaceID: String) {
        tasksManageSpaces = on == Self.tasksManageSpacesByDefault(inSpace: spaceID) ? nil : on
    }

    func isOn(_ part: ClaudeSpaceSettings.Part) -> Bool { self[keyPath: part.key] ?? part.isOnByDefault }

    /// Nothing is written for a part set to its default.
    mutating func set(_ part: ClaudeSpaceSettings.Part, on: Bool) {
        self[keyPath: part.key] = on == part.isOnByDefault ? nil : on
    }

    var addedLines: [ClaudeSpaceSettings.Line] {
        claudeAllow.map(ClaudeSpaceSettings.Line.allow) + claudeEnvironment.map(ClaudeSpaceSettings.Line.environment)
    }

    mutating func add(_ line: ClaudeSpaceSettings.Line) {
        guard !addedLines.contains(line) else { return }
        switch line {
        case .allow(let rule): claudeAllow.append(rule)
        case .environment(let entry): claudeEnvironment.append(entry)
        }
    }

    mutating func remove(_ line: ClaudeSpaceSettings.Line) {
        switch line {
        case .allow(let rule): claudeAllow.removeAll { $0 == rule }
        case .environment(let entry): claudeEnvironment.removeAll { $0 == entry }
        }
    }

    /// Each on/off switch the file holds, with its value when Nirux can't
    /// read it: the safe side (SpaceDefaultsStore).
    static var switches: [(key: WritableKeyPath<SpaceDefaults, Bool?>, name: CodingKeys, safe: Bool)] {
        [
            (\.leadStartsTasks, .leadStartsTasks, false),
            (\.leadStartsMergeQueue, .leadStartsMergeQueue, false),
            (\.leadStartsMergeQueueWithoutLocalReview, .leadStartsMergeQueueWithoutLocalReview, false),
            (\.leadDailyPass, .leadDailyPass, false),
            (\.leadGroupsResults, .leadGroupsResults, false),
            (\.leadFreshStart, .leadFreshStart, false),
            (\.prFollowUp, .prFollowUp, false),
            (\.resumeWorkOnRelaunch, .resumeWorkOnRelaunch, false),
            (\.claudeModelSplit, .claudeModelSplit, false),
            (\.tasksManageSpaces, .tasksManageSpaces, false),
            (\.dayPlan, .dayPlan, false),
            (\.claudeTrustsRepositories, .claudeTrustsRepositories, false),
            (\.claudeDeniesIrreversible, .claudeDeniesIrreversible, true),
            (\.claudeSandbox, .claudeSandbox, true)
        ]
    }

    struct EnvironmentVariable: Equatable, Sendable {
        var name: String
        var value: String
    }

    /// The preselected agent, Claude Code when the space sets none.
    var taskAgent: CodingAgent { agent ?? .claude }

    func claudeMode(settings: ClaudeLaunchMode) -> ClaudeLaunchMode { claudeLaunchMode ?? settings }

    func codexMode(settings: CodexLaunchMode) -> CodexLaunchMode { codexLaunchMode ?? settings }
    func agyMode(settings: AgyLaunchMode) -> AgyLaunchMode { agyLaunchMode ?? settings }

    // MARK: - Environment

    /// Hook routing, Missions and launch authorization read these: a space
    /// can't set or replace them.
    static let reservedPrefix = "NIRUX_"

    /// What new shells get: each valid name once (the first wins), never a
    /// reserved one. A file edited by hand may hold others; they are listed
    /// but never applied. Values are literal: nothing expands `$PATH`.
    var effectiveEnvironment: [String: String] {
        var result: [String: String] = [:]
        for variable in environment where Self.problem(name: variable.name, value: variable.value) == nil {
            if result[variable.name] == nil { result[variable.name] = variable.value }
        }
        return result
    }

    /// Why a variable can't apply, or nil. Names are what a shell accepts
    /// (letters, digits, underscores, not starting with a digit).
    static func problem(name: String, value: String) -> String? {
        guard isValidName(name) else {
            return name.isEmpty
                ? "A variable needs a name."
                : "“\(name)” isn’t a variable name: use letters, digits and underscores, not starting with a digit."
        }
        if name.uppercased().hasPrefix(reservedPrefix) {
            return "\(name) is reserved: Nirux sets the NIRUX_ variables itself."
        }
        if value.contains("\0") { return "\(name)’s value holds a NUL character." }
        return nil
    }

    static func isValidName(_ name: String) -> Bool {
        guard let first = name.unicodeScalars.first, name.utf8.count <= 255 else { return false }
        let letters = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ_")
        let rest = letters.union(CharacterSet(charactersIn: "0123456789"))
        return letters.contains(first) && name.unicodeScalars.allSatisfy(rest.contains)
    }

    /// What may surprise about a variable that applies, or nil: it is
    /// written all the same.
    static func warning(name: String, value: String) -> String? {
        let upper = name.uppercased()
        if ["PATH", "HOME", "SHELL", "ZDOTDIR", "TMPDIR", "USER", "LANG"].contains(upper) || upper.hasPrefix("TERM") {
            return "\(name) replaces the shell’s own: agents and tools may not start, or not find their settings."
        }
        if ["CLAUDE_", "ANTHROPIC_", "OPENAI_", "CODEX_"].contains(where: upper.hasPrefix) {
            return "\(name) reaches every agent of the space: its account, settings folder or keys."
        }
        if value.contains("$") {
            return "\(name)’s value is literal: “$” stays as typed, nothing is expanded."
        }
        return nil
    }

    /// The warnings of the variables that apply, one line each.
    var environmentWarnings: [String] {
        var seen = Set<String>()
        return environment.compactMap { variable in
            guard Self.problem(name: variable.name, value: variable.value) == nil, seen.insert(variable.name).inserted else { return nil }
            return Self.warning(name: variable.name, value: variable.value)
        }
    }

    /// What the list can't apply, one line per variable, for Space Settings.
    var environmentProblems: [String] {
        var seen = Set<String>()
        var problems: [String] = []
        for variable in environment {
            if let problem = Self.problem(name: variable.name, value: variable.value) {
                problems.append(problem)
            } else if !seen.insert(variable.name).inserted {
                problems.append("\(variable.name) is set twice: the first one applies.")
            }
        }
        return problems
    }
}

// MARK: - Storage

/// `{"schemaVersion": 1, "agent": "codex", "claudeLaunchMode": "plan",
/// "codexLaunchMode": "readOnly", "environment": [{"name": …, "value": …}],
/// "leadStartsTasks": false, "leadDailyPass": false, "leadDailyPassHour": 7,
/// "prFollowUp": false, "tasksManageSpaces": true, "claudeTrustsRepositories": false,
/// "claudeDeniesIrreversible": false, "claudeSandbox": true,
/// "claudeAllow": ["Bash(swift build:*)"], "claudeEnvironment": […]}`,
/// every key optional, nothing written for what isn't set. Unknown keys and
/// values are read-only reasons (see SpaceDefaultsStore), not decoding
/// errors.
extension SpaceDefaults: Codable {
    enum CodingKeys: String, CodingKey, CaseIterable {
        case schemaVersion, agent, leadAgent, claudeLaunchMode, codexLaunchMode, agyLaunchMode, environment
        case leadStartsTasks, leadStartsMergeQueue, leadStartsMergeQueueWithoutLocalReview, leadDailyPass, leadDailyPassHour, prFollowUp, resumeWorkOnRelaunch
        case leadGroupsResults
        case leadFreshStart, tasksManageSpaces, dayPlan
        case claudeModelSplit, taskBudget
        case claudeTrustsRepositories, claudeDeniesIrreversible, claudeSandbox, claudeAllow, claudeEnvironment
    }

    private struct StoredVariable: Codable {
        let name: String
        let value: String
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        agent = (try? container.decodeIfPresent(String.self, forKey: .agent)).flatMap(CodingAgent.init(launchable:))
        leadAgent = (try? container.decodeIfPresent(String.self, forKey: .leadAgent)).flatMap(CodingAgent.init(launchable:))
        claudeLaunchMode = (try? container.decodeIfPresent(String.self, forKey: .claudeLaunchMode))
            .flatMap(ClaudeLaunchMode.init(rawValue:))
        codexLaunchMode = (try? container.decodeIfPresent(String.self, forKey: .codexLaunchMode))
            .flatMap(CodexLaunchMode.init(rawValue:))
        agyLaunchMode = try? container.decode(AgyLaunchMode.self, forKey: .agyLaunchMode)
        environment = ((try? container.decodeIfPresent([StoredVariable].self, forKey: .environment)) ?? nil)?
            .map { EnvironmentVariable(name: $0.name, value: $0.value) } ?? []
        leadStartsTasks = (try? container.decodeIfPresent(Bool.self, forKey: .leadStartsTasks)) ?? nil
        leadStartsMergeQueue = try? container.decodeIfPresent(Bool.self, forKey: .leadStartsMergeQueue)
        leadStartsMergeQueueWithoutLocalReview = try? container.decodeIfPresent(Bool.self, forKey: .leadStartsMergeQueueWithoutLocalReview)
        leadDailyPass = (try? container.decodeIfPresent(Bool.self, forKey: .leadDailyPass)) ?? nil
        leadGroupsResults = (try? container.decodeIfPresent(Bool.self, forKey: .leadGroupsResults)) ?? nil
        leadDailyPassHour = ((try? container.decodeIfPresent(Int.self, forKey: .leadDailyPassHour)) ?? nil).flatMap { (0...23).contains($0) ? $0 : nil }
        prFollowUp = (try? container.decodeIfPresent(Bool.self, forKey: .prFollowUp)) ?? nil
        leadFreshStart = (try? container.decodeIfPresent(Bool.self, forKey: .leadFreshStart)) ?? nil
        resumeWorkOnRelaunch = (try? container.decodeIfPresent(Bool.self, forKey: .resumeWorkOnRelaunch)) ?? nil
        claudeModelSplit = (try? container.decodeIfPresent(Bool.self, forKey: .claudeModelSplit)) ?? nil
        taskBudget = ((try? container.decodeIfPresent(Int.self, forKey: .taskBudget)) ?? nil).flatMap { $0 >= 0 ? $0 : nil }
        tasksManageSpaces = (try? container.decodeIfPresent(Bool.self, forKey: .tasksManageSpaces)) ?? nil
        dayPlan = (try? container.decodeIfPresent(Bool.self, forKey: .dayPlan)) ?? nil
        claudeTrustsRepositories = (try? container.decodeIfPresent(Bool.self, forKey: .claudeTrustsRepositories)) ?? nil
        claudeDeniesIrreversible = (try? container.decodeIfPresent(Bool.self, forKey: .claudeDeniesIrreversible)) ?? nil
        claudeSandbox = (try? container.decodeIfPresent(Bool.self, forKey: .claudeSandbox)) ?? nil
        claudeAllow = ((try? container.decodeIfPresent([String].self, forKey: .claudeAllow)) ?? nil) ?? []
        claudeEnvironment = ((try? container.decodeIfPresent([String].self, forKey: .claudeEnvironment)) ?? nil) ?? []
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(SpaceDefaultsStore.schemaVersion, forKey: .schemaVersion)
        try container.encodeIfPresent(agent?.rawValue, forKey: .agent)
        try container.encodeIfPresent(leadAgent?.rawValue, forKey: .leadAgent)
        try container.encodeIfPresent(claudeLaunchMode?.rawValue, forKey: .claudeLaunchMode)
        try container.encodeIfPresent(codexLaunchMode?.rawValue, forKey: .codexLaunchMode)
        try container.encodeIfPresent(agyLaunchMode?.rawValue, forKey: .agyLaunchMode)
        if !environment.isEmpty {
            try container.encode(environment.map { StoredVariable(name: $0.name, value: $0.value) }, forKey: .environment)
        }
        try container.encodeIfPresent(leadStartsTasks, forKey: .leadStartsTasks)
        if leadCanStartMergeQueue { try container.encode(true, forKey: .leadStartsMergeQueue) }
        if leadCanStartMergeQueueWithoutLocalReview {
            try container.encode(true, forKey: .leadStartsMergeQueueWithoutLocalReview)
        }
        try container.encodeIfPresent(leadDailyPass, forKey: .leadDailyPass)
        try container.encodeIfPresent(leadGroupsResults, forKey: .leadGroupsResults)
        try container.encodeIfPresent(leadDailyPassHour, forKey: .leadDailyPassHour)
        try container.encodeIfPresent(prFollowUp, forKey: .prFollowUp)
        try container.encodeIfPresent(leadFreshStart, forKey: .leadFreshStart)
        try container.encodeIfPresent(resumeWorkOnRelaunch, forKey: .resumeWorkOnRelaunch)
        try container.encodeIfPresent(claudeModelSplit, forKey: .claudeModelSplit)
        try container.encodeIfPresent(taskBudget, forKey: .taskBudget)
        try container.encodeIfPresent(tasksManageSpaces, forKey: .tasksManageSpaces)
        try container.encodeIfPresent(dayPlan, forKey: .dayPlan)
        try container.encodeIfPresent(claudeTrustsRepositories, forKey: .claudeTrustsRepositories)
        try container.encodeIfPresent(claudeDeniesIrreversible, forKey: .claudeDeniesIrreversible)
        try container.encodeIfPresent(claudeSandbox, forKey: .claudeSandbox)
        if !claudeAllow.isEmpty { try container.encode(claudeAllow, forKey: .claudeAllow) }
        if !claudeEnvironment.isEmpty { try container.encode(claudeEnvironment, forKey: .claudeEnvironment) }
    }
}
