import Foundation

// Every change follows the same rules: an addition goes at the end of its place,
// so never above a session's current step; only the user moves or removes a
// line; each author checks only its own kind of line. A refused change leaves
// the plan as it was.
extension Plan {
    public enum Change: String, Sendable {
        case add, move, check, link, remove, propose, take
    }

    public enum Refusal: Error, Equatable, Sendable, CustomStringConvertible {
        case noLine(String)
        case noProposal(String)
        case takenID(String)
        case noTitle
        /// Under a line of that kind, or outside any line for nil.
        case misplaced(Line.Kind, under: Line.Kind?)
        case notAllowed(Change)
        case isFeature(String)
        case fieldsDontFitKind
        /// The workspace already has its line.
        case linked(String)

        public var description: String {
            switch self {
            case .noLine(let id): "No line \(id) in the plan."
            case .noProposal(let id): "No proposal \(id)."
            case .takenID(let id): "The plan already has a line \(id)."
            case .noTitle: "A line needs a title."
            case .misplaced(let kind, let parent):
                "A \(kind.rawValue) can't go " + (parent.map { "under a \($0.rawValue)." } ?? "outside a line.")
            case .notAllowed(.add): "An agent adds only steps, under a session."
            case .notAllowed(.check): "An agent checks only its own steps: a step for the user is the user's."
            case .notAllowed(.link): "Only the user, the Lead or Nirux starts a session."
            case .notAllowed(.move): "Only the user moves a line."
            case .notAllowed(.remove): "Only the user removes a line."
            case .notAllowed(.propose): "Only the Lead proposes lines."
            case .notAllowed(.take): "Only the user, or the Lead on their word, takes or drops a proposal."
            case .isFeature(let id): "\(id) is a feature: check or start its lines instead."
            case .fieldsDontFitKind: "Only a session has a workspace, only a planned one waits for a line, and only a step is for the user."
            case .linked(let workspaceID): "Workspace \(workspaceID) already has its line in the plan."
            }
        }
    }

    /// Adds a new line at the end of `place`, by its origin's author.
    public mutating func add(_ line: Line, to place: Place) throws {
        try validate(line)
        var line = line
        line.isUnseen = line.origin.by != .user
        try update { try $0.put(line, in: place, by: line.origin.by, at: line.origin.at, change: .add) }
    }

    /// Moves a line to `index` among the lines of `place`, counted once it left its own place.
    public mutating func move(_ id: String, to place: Place, index: Int, by author: Author, at time: TimeInterval) throws {
        guard author == .user else { throw Refusal.notAllowed(.move) }
        try update { plan in
            guard let path = plan.lines.path(to: id) else { throw Refusal.noLine(id) }
            let line = plan.lines.remove(at: path)
            try plan.put(line, in: place, index: index, by: author, at: time, change: .move)
        }
    }

    /// Checking again keeps the first time.
    public mutating func check(_ id: String, _ isChecked: Bool = true, by author: Author, at time: TimeInterval) throws {
        guard let path = lines.path(to: id) else { throw Refusal.noLine(id) }
        let line = lines[path: path]
        guard line.kind != .feature else { throw Refusal.isFeature(id) }
        guard Self.may(author, .check, line, under: parent(at: path)) else { throw Refusal.notAllowed(.check) }
        lines[path: path].checkedAt = isChecked ? line.checkedAt ?? time : nil
    }

    /// Turns a to-do, a Lead line, a step or a planned session into the session of `workspaceID`, in its place.
    public mutating func link(_ id: String, toWorkspace workspaceID: String, by author: Author) throws {
        guard let path = lines.path(to: id) else { throw Refusal.noLine(id) }
        var line = lines[path: path]
        let parent = parent(at: path)
        guard line.kind != .feature else { throw Refusal.isFeature(id) }
        guard Self.fits(line.kind, under: parent?.kind) else { throw Refusal.misplaced(line.kind, under: parent?.kind) }
        guard Self.may(author, .link, line, under: parent) else { throw Refusal.notAllowed(.link) }
        if let linked = line.workspaceID { throw Refusal.linked(linked) }
        guard !carries(workspaceID) else { throw Refusal.linked(workspaceID) }
        line.kind = .session
        line.workspaceID = workspaceID
        line.isForUser = false
        line.after = nil
        line.checkedAt = nil
        lines[path: path] = line
    }

    /// Removes a line with what it holds and the proposals placed under them; what waited for them waits for the
    /// user's go instead.
    public mutating func remove(_ id: String, by author: Author) throws {
        guard author == .user else { throw Refusal.notAllowed(.remove) }
        guard let path = lines.path(to: id) else { throw Refusal.noLine(id) }
        let gone = Set([lines.remove(at: path)].flattened.map(\.id))
        let stopWaiting = { (line: inout Line) in if let after = line.after, gone.contains(after) { line.after = nil } }
        lines.updateEach(stopWaiting)
        proposals.removeAll { if case .under(let parent) = $0.place { gone.contains(parent) } else { false } }
        proposals.indices.forEach { stopWaiting(&proposals[$0].line) }
    }

    /// The user looked at the line: its dot and those of the lines under it go.
    public mutating func markSeen(_ id: String) {
        guard let path = lines.path(to: id) else { return }
        lines[path: path].isUnseen = false
        lines[path: path].children.indices.forEach { lines[path: path].children[$0].isUnseen = false }
    }

    public mutating func propose(_ line: Line, to place: Place) throws {
        guard line.origin.by == .lead else { throw Refusal.notAllowed(.propose) }
        try validate(line)
        var trial = self
        try trial.put(line, in: place, by: .lead, at: line.origin.at, change: .add)
        proposals.append(Proposal(line: line, place: place))
    }

    /// Adds the proposal's line at the end of its place, still the Lead's and with its source.
    public mutating func take(_ id: String, by author: Author) throws {
        let proposal = try dropping(id, by: author)
        try update {
            $0.proposals.removeAll { $0.id == id }
            try $0.add(proposal.line, to: proposal.place)
        }
    }

    public mutating func drop(_ id: String, by author: Author) throws {
        _ = try dropping(id, by: author)
        proposals.removeAll { $0.id == id }
    }

    private func dropping(_ id: String, by author: Author) throws -> Proposal {
        guard author == .user || author == .lead else { throw Refusal.notAllowed(.take) }
        guard let proposal = proposals.first(where: { $0.id == id }) else { throw Refusal.noProposal(id) }
        return proposal
    }

    private mutating func update(_ body: (inout Plan) throws -> Void) throws {
        var next = self
        try body(&next)
        self = next
    }

    private func validate(_ line: Line) throws {
        guard !line.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw Refusal.noTitle }
        guard line.workspaceID == nil || line.kind == .session, line.after == nil || line.isPlanned, !line.isForUser || line.kind == .step
        else { throw Refusal.fieldsDontFitKind }
        guard self.line(line.id) == nil, !proposals.contains(where: { $0.id == line.id }) else { throw Refusal.takenID(line.id) }
        if let workspaceID = line.workspaceID, carries(workspaceID) { throw Refusal.linked(workspaceID) }
        if let after = line.after {
            guard let awaited = self.line(after) else { throw Refusal.noLine(after) }
            guard awaited.kind != .feature else { throw Refusal.isFeature(after) }
        }
    }

    /// Matched without case or surrounding spaces.
    func feature(titled title: String) -> Line? {
        lines.first { $0.kind == .feature && $0.title.matches(title) }
    }

    /// A line or a proposal has this workspace already.
    private func carries(_ workspaceID: String) -> Bool {
        line(ofWorkspace: workspaceID) != nil || proposals.contains { $0.line.workspaceID == workspaceID }
    }

    private func parent(at path: [Int]) -> Line? {
        path.count > 1 ? lines[path: Array(path.dropLast())] : nil
    }

    /// Puts a line in `place`, at its end unless the user gives an index; a feature it makes is dated `time`.
    private mutating func put(
        _ line: Line, in place: Place, index: Int? = nil, by author: Author, at time: TimeInterval, change: Change
    ) throws {
        switch place {
        case .top:
            try Self.allow(author, change, line, under: nil)
            lines.insert(line, at: Self.clamp(index, lines.count))
        case .under(let id):
            guard let path = lines.path(to: id) else { throw Refusal.noLine(id) }
            try Self.allow(author, change, line, under: lines[path: path])
            lines[path: path].children.insert(line, at: Self.clamp(index, lines[path: path].children.count))
        case .feature(let title, let id):
            if let found = feature(titled: title) {
                return try put(line, in: .under(found.id), index: index, by: author, at: time, change: change)
            }
            var feature = Line(id: id, kind: .feature, title: title, by: author, at: time)
            try validate(feature)
            guard ![line].flattened.contains(where: { $0.id == id }) else { throw Refusal.takenID(id) }
            try Self.allow(author, change, feature, under: nil)
            try Self.allow(author, change, line, under: feature)
            feature.isUnseen = author != .user
            feature.children = [line]
            lines.append(feature)
        }
    }

    private static func clamp(_ index: Int?, _ count: Int) -> Int {
        min(max(index ?? count, 0), count)
    }

    private static func allow(_ author: Author, _ change: Change, _ line: Line, under parent: Line?) throws {
        guard fits(line.kind, under: parent?.kind) else { throw Refusal.misplaced(line.kind, under: parent?.kind) }
        guard may(author, change, line, under: parent) else { throw Refusal.notAllowed(change) }
    }

    private static let holds: [Line.Kind?: Set<Line.Kind>] = [
        nil: [.feature, .todo, .lead, .session],
        .feature: [.todo, .lead, .session],
        .todo: [.step, .session], .lead: [.step, .session], .session: [.step, .session]
    ]

    private static func fits(_ kind: Line.Kind, under parent: Line.Kind?) -> Bool {
        holds[parent]?.contains(kind) == true
    }

    /// An agent's tool reaches its own session's line only.
    private static func may(_ author: Author, _ change: Change, _ line: Line, under parent: Line?) -> Bool {
        if author == .user || author == .lead || author == .nirux { return true }
        guard author == .agent || author == .parentTask, change == .add || change == .check else { return false }
        return line.kind == .step && parent?.kind == .session && !(change == .check && line.isForUser)
    }
}

private extension String {
    func matches(_ other: String) -> Bool {
        trimmingCharacters(in: .whitespacesAndNewlines)
            .caseInsensitiveCompare(other.trimmingCharacters(in: .whitespacesAndNewlines)) == .orderedSame
    }
}
