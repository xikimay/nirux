import Foundation

// The tools' side of the plan: a call's arguments in, one answer out. The Lead's read_plan, add_to_plan and
// check_plan_line, and task_steps for a task's agent, which reaches its own session's line only.
extension Plan {
    public struct Problem: Error, Equatable, Sendable, CustomStringConvertible {
        public let description: String

        public init(_ description: String) {
            self.description = description
        }
    }

    /// A task of the space, as the app found it from a tool's words.
    public struct Task: Equatable, Sendable {
        public let workspaceID: String
        public let title: String

        public init(workspaceID: String, title: String) {
            self.workspaceID = workspaceID
            self.title = title
        }
    }

    public static let maxTitleLength = 120
    public static let maxDetailLength = 2_000
    public static let maxTextLength = 6_000

    /// add_to_plan. A step for `task` goes under its line, made at the end of the plan if it has none.
    public mutating func add(_ arguments: [String: Any], task: Task?, newID: () -> String, at now: TimeInterval) throws -> String {
        let kind = Line.Kind(rawValue: Self.string(arguments, "kind") ?? "")
        guard [Line.Kind.todo, .lead, .session, .step].contains(kind) else { throw Problem("kind must be todo, lead, session or step.") }
        guard task == nil || kind == .session || kind == .step else { throw Problem("task goes with a session or a step.") }
        let proposes = try Self.flag(arguments, "propose")
        guard !proposes || kind != .session || task == nil else {
            throw Problem("Propose new work only: put a running task's line in the plan without propose.")
        }
        if kind == .session, let task, let line = line(ofWorkspace: task.workspaceID) {
            throw Problem("\(task.title) is in the plan already, as \(line.id): only the user moves lines.")
        }
        guard let title = try Self.text(arguments, "title", limit: Self.maxTitleLength) ?? (kind == .session ? task?.title : nil) else {
            throw Problem("title must say what the line is, in at most \(Self.maxTitleLength) characters.")
        }
        let under = try Self.lineID(arguments, "under")
        let feature = try Self.text(arguments, "feature", limit: Self.maxTitleLength)
        guard under == nil || feature == nil else { throw Problem("Pass under or feature, not both.") }
        var next = self
        let id = next.unusedID(newID)
        var place = under.map(Place.under)
            ?? feature.map { .feature(title: $0, id: next.feature(titled: $0)?.id ?? next.unusedID(newID, besides: [id])) } ?? .top
        if kind == .step, under == nil, feature == nil, let task {
            if proposes, next.line(ofWorkspace: task.workspaceID) == nil {
                throw Problem("\(task.title) has no line in the plan yet: add it first, as a session with task.")
            }
            place = .under(try next.lineID(of: task, at: now, newID: newID, besides: [id]))
        }
        let line = Line(
            id: id, kind: kind, title: title, by: .lead, at: now, source: try Self.source(arguments),
            detail: try Self.lines(arguments, "detail", limit: Self.maxDetailLength), isForUser: try Self.flag(arguments, "for_user"),
            workspaceID: kind == .session ? task?.workspaceID : nil, after: try Self.lineID(arguments, "after")
        )
        if proposes { try next.propose(line, to: place) } else { try next.add(line, to: place) }
        self = next
        return proposes
            ? "Proposed \(id) for \(name(of: place)): the user takes or drops it."
            : "Added \(id) at the end of \(name(of: place))."
    }

    /// check_plan_line.
    public mutating func check(_ arguments: [String: Any], by author: Author, at now: TimeInterval) throws -> String {
        guard let id = Self.string(arguments, "line") else { throw Problem("line must be a line's id, as read_plan shows it.") }
        let done = try Self.flag(arguments, "done", default: true)
        try check(id, done, by: author, at: now)
        return (done ? "Checked" : "Unchecked") + " “\(line(id)?.title ?? id)”."
    }

    /// task_steps: checks, then adds, then answers the task's steps. `tasks` as for read_plan.
    public mutating func steps(
        _ arguments: [String: Any], of task: Task, tasks: (String) -> String?, newID: () -> String, at now: TimeInterval
    ) throws -> String {
        let adds = try Self.texts(arguments, "add", limit: Self.maxTitleLength)
        let checks = try Self.texts(arguments, "check", limit: Self.maxTitleLength)
        let forUser = try Self.flag(arguments, "for_user")
        var next = self
        if !adds.isEmpty || !checks.isEmpty {
            let lineID = try next.lineID(of: task, at: now, newID: newID)
            for id in checks {
                guard next.line(lineID)?.children.contains(where: { $0.id == id }) == true else { throw Problem("\(id) isn't one of your steps.") }
                try next.check(id, by: .agent, at: now)
            }
            for title in adds {
                let step = Line(id: next.unusedID(newID), kind: .step, title: title, by: .agent, at: now, isForUser: forUser)
                try next.add(step, to: .under(lineID))
            }
        }
        self = next
        guard let line = line(ofWorkspace: task.workspaceID), !line.children.isEmpty else { return "You have no steps yet." }
        return Self.cut(["Your steps, in order:"] + line.children.flatMap { describe($0, under: line, depth: 0, tasks: tasks) })
    }

    /// read_plan. `tasks` names a workspace's task and its state; nil for one that closed.
    public func text(tasks: (String) -> String?) -> String {
        var rows = lines.flatMap { describe($0, under: nil, depth: 0, tasks: tasks) }
        if rows.isEmpty { rows = ["The plan is empty."] }
        if !proposals.isEmpty {
            rows.append("Proposed, for the user to take or drop:")
            rows += proposals.map { "- " + row($0.line, under: nil, tasks: tasks, extra: ["for " + name(of: $0.place)]) }
        }
        return Self.cut(rows)
    }

    private func describe(_ line: Line, under parent: Line?, depth: Int, tasks: (String) -> String?) -> [String] {
        [String(repeating: "  ", count: depth) + "- " + row(line, under: parent, tasks: tasks)]
            + line.children.flatMap { describe($0, under: line, depth: depth + 1, tasks: tasks) }
    }

    private func row(_ line: Line, under parent: Line?, tasks: (String) -> String?, extra: [String] = []) -> String {
        let progress = "\(line.progress.done)/\(line.progress.total)"
        var facts: [String]
        switch line.kind {
        case .feature: facts = ["feature \(line.id)", progress + " done"]
        case .todo: facts = ["to-do \(line.id)"]
        case .lead: facts = ["Lead line \(line.id)"]
        case .session where line.isPlanned: facts = ["planned session \(line.id)"] + (line.after.map { ["starts once \($0) is checked"] } ?? [])
        case .session:
            facts = ["session \(line.id): " + (line.workspaceID.flatMap(tasks) ?? "its task closed")]
                + (line.children.isEmpty ? [] : [progress + " steps"])
        case .step:
            facts = ["step \(line.id)"] + (line.isForUser ? ["for the user"] : [])
                + (parent?.kind == .session && parent?.current?.id == line.id ? ["current"] : [])
        default: facts = ["\(line.kind.rawValue) \(line.id)"]
        }
        if let source = line.origin.source { facts.append([source.name, source.url, source.why].compactMap { $0 }.joined(separator: " ")) }
        if let detail = line.detail { facts.append("“" + detail.replacingOccurrences(of: "\n", with: " / ") + "”") }
        let box = line.kind == .feature ? "" : line.isChecked ? "[x] " : "[ ] "
        return box + line.title + " (" + (facts + extra).joined(separator: ", ") + ")"
    }

    private func name(of place: Place) -> String {
        switch place {
        case .top: "the plan"
        case .under(let id): line(id).map { "“\($0.title)”" } ?? id
        case .feature(let title, _): "feature “\(feature(titled: title)?.title ?? title)”"
        }
    }

    /// The task's line, made at the end of the plan by Nirux if it has none.
    private mutating func lineID(of task: Task, at now: TimeInterval, newID: () -> String, besides taken: Set<String> = []) throws -> String {
        if let line = line(ofWorkspace: task.workspaceID) { return line.id }
        let id = unusedID(newID, besides: taken)
        try add(Line(id: id, kind: .session, title: task.title, by: .nirux, at: now, workspaceID: task.workspaceID), to: .top)
        return id
    }

    private func unusedID(_ newID: () -> String, besides taken: Set<String> = []) -> String {
        let proposed = Set(proposals.flatMap { proposal -> [String] in
            if case .feature(_, let id) = proposal.place { return [proposal.id, id] }
            return [proposal.id]
        })
        while true {
            let id = newID()
            if !id.isEmpty, !taken.contains(id), !proposed.contains(id), line(id) == nil { return id }
        }
    }

    private static func cut(_ rows: [String]) -> String {
        var text = ""
        for (index, row) in rows.enumerated() {
            guard text.count + row.count < maxTextLength else { return text + "\n… and \(rows.count - index) more lines." }
            text += (text.isEmpty ? "" : "\n") + row
        }
        return text
    }

    // MARK: - Arguments

    private static func string(_ arguments: [String: Any], _ key: String) -> String? {
        (arguments[key] as? String).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.flatMap { $0.isEmpty ? nil : $0 }
    }

    /// Nil when left out or blank.
    private static func text(_ arguments: [String: Any], _ key: String, limit: Int) throws -> String? {
        guard let value = arguments[key], !(value is NSNull) else { return nil }
        return try text(value, key, limit: limit)
    }

    private static func text(_ value: Any, _ key: String, limit: Int) throws -> String? {
        guard let raw = value as? String else { throw Problem("\(key) must be a string.") }
        guard let text = AgentText.clean(raw, maxLength: limit * 4) else { return nil }
        guard text.count <= limit else { throw Problem("\(key) must hold at most \(limit) characters.") }
        return text
    }

    /// Text kept on its lines, each cleaned: what a planned session's agent starts with.
    private static func lines(_ arguments: [String: Any], _ key: String, limit: Int) throws -> String? {
        guard let value = arguments[key], !(value is NSNull) else { return nil }
        guard let raw = value as? String else { throw Problem("\(key) must be a string.") }
        let text = raw.components(separatedBy: .newlines).map { AgentText.clean($0, maxLength: limit * 4) ?? "" }
            .joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count <= limit else { throw Problem("\(key) must hold at most \(limit) characters.") }
        return text.isEmpty ? nil : text
    }

    /// A line's id; nil when left out or blank.
    private static func lineID(_ arguments: [String: Any], _ key: String) throws -> String? {
        guard let value = arguments[key], !(value is NSNull) else { return nil }
        guard value is String else { throw Problem("\(key) must be a line's id, as read_plan shows it.") }
        return string(arguments, key)
    }

    private static func texts(_ arguments: [String: Any], _ key: String, limit: Int) throws -> [String] {
        guard let value = arguments[key], !(value is NSNull) else { return [] }
        guard let items = value as? [Any] else { throw Problem("\(key) must list strings.") }
        return try items.map { item in
            guard let text = try Self.text(item as Any, key, limit: limit) else { throw Problem("\(key) must list strings, none blank.") }
            return text
        }
    }

    private static func flag(_ arguments: [String: Any], _ key: String, default fallback: Bool = false) throws -> Bool {
        guard let value = arguments[key], !(value is NSNull) else { return fallback }
        guard let flag = value as? Bool else { throw Problem("\(key) must be true or false.") }
        return flag
    }

    private static func source(_ arguments: [String: Any]) throws -> Source? {
        let url = try text(arguments, "url", limit: 500)
        let why = try text(arguments, "why", limit: maxTitleLength)
        guard let name = try text(arguments, "source", limit: 40) else {
            guard url == nil, why == nil else { throw Problem("source must name where you read it (GitHub, Linear, Slack, Mail, Figma).") }
            return nil
        }
        if let url, !["http", "https"].contains(URL(string: url)?.scheme?.lowercased()) { throw Problem("url must be an http or https link.") }
        return Source(name: name, url: url, why: why)
    }
}
