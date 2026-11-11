import Foundation

// MARK: - Lines that stay together, by repository (docs/design/board-stages.md, section 4)

extension BoardStages {
    /// Lines that never part, each keeping its own state.
    enum Unit: Equatable, Sendable {
        /// A task, then the tasks listed under it in the sidebar, depth
        /// first: each joined to it by an elbow.
        case task(Line, subtasks: [Line])
        /// A stack of pull requests on a numbered rail, in merge order.
        case stack(title: String, [Line])

        var lines: [Line] {
            switch self {
            case .task(let task, let subtasks): return [task] + subtasks
            case .stack(_, let lines): return lines
            }
        }
    }

    /// A pull request merged today, on the line closing its section.
    struct Merged: Equatable, Sendable {
        /// The line of its task, while one is open here: a click opens it.
        var lineID: String?
        var title: String
        var number: Int
        /// "14:02".
        var time: String
    }

    /// One repository of the space, or its tasks without one.
    struct Section: Equatable, Sendable {
        let id: String
        var units: [Unit]
        /// "Pull requests without a task": no worktree here. Folded,
        /// closing the section.
        var withoutTask: [Unit]
        /// "Merged today", the newest first.
        var merged: [Merged]
    }

    /// A pull request of the merged batch.
    struct MergedFacts: Equatable, Sendable {
        var number: Int
        var title: String
        var mergedAt: TimeInterval
    }

    struct SectionFacts: Equatable, Sendable {
        var id: String
        /// Its tasks in the sidebar's order, then its pull requests
        /// without a task.
        var lines: [Facts]
        /// The line each sub-task is listed under in the sidebar, by
        /// their facts' `id`.
        var parents: [String: String] = [:]
        var merged: [MergedFacts] = []
    }

    enum Order: String, Sendable {
        /// The sidebar's.
        case sidebar
        /// The closest to its base branch first.
        case progress
    }

    /// One section's units, in `order`.
    /// - A pull request merged today leaves the list for "Merged today",
    ///   once its line has nothing else to say (an agent that needs the
    ///   user, the queue waiting for its post-merge run); one merged
    ///   before, whose task is still open, stays a line.
    /// - A task and its sub-tasks are a family, wherever their pull
    ///   requests are. A stack is a unit of its own only when none of its
    ///   lines is in a family; else the lines stay where their family has
    ///   them, and their pull request cells and phrases say the stack.
    /// - A stack with a task stays whole in the list; one without any goes
    ///   to the pull requests without a task.
    static func section(
        _ facts: SectionFacts, order: Order = .sidebar, rules: Rules = Rules(), now: TimeInterval, timeZone: TimeZone = .current
    ) -> Section {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let midnight = calendar.startOfDay(for: Date(timeIntervalSince1970: now)).timeIntervalSince1970
        let today = facts.merged.filter { $0.mergedAt >= midnight }.sorted { $0.mergedAt > $1.mergedAt }
        let mergedToday = Set(today.map(\.number))
        let isMergedToday = { (facts: Facts) in
            guard let number = facts.pullRequest?.number, mergedToday.contains(number) else { return false }
            return line(facts, rules: rules).state == .merged
        }
        let listed = facts.lines.filter { !isMergedToday($0) }

        let placed = units(listed, parents: facts.parents, rules: rules)
        let hasTask = { (unit: Placed) in unit.members.contains { listed[$0].hasTask } }
        let arranged = { (units: [Placed]) -> [Unit] in
            let sorted = order == .sidebar ? units : units.enumerated().sorted { lhs, rhs in
                (lhs.element.score, rhs.offset) > (rhs.element.score, lhs.offset)
            }.map(\.element)
            return sorted.map(\.unit)
        }
        return Section(
            id: facts.id,
            units: arranged(placed.filter(hasTask)),
            withoutTask: arranged(placed.filter { !hasTask($0) }),
            // One place per pull request: not here while its line is listed.
            merged: today.compactMap { pullRequest in
                guard !listed.contains(where: { $0.pullRequest?.number == pullRequest.number }) else { return nil }
                let task = facts.lines.first { $0.pullRequest?.number == pullRequest.number }
                return Merged(
                    lineID: task?.id, title: task?.title ?? pullRequest.title, number: pullRequest.number,
                    time: clockTime(pullRequest.mergedAt, calendar: calendar)
                )
            }
        )
    }

    /// A unit, the indices of its lines' facts, and how far it got.
    private struct Placed {
        let unit: Unit
        let members: [Int]
        let score: Int
    }

    /// The units in the order of their first line.
    private static func units(_ facts: [Facts], parents links: [String: String], rules: Rules) -> [Placed] {
        let lines = facts.map { line($0, rules: rules) }
        let indexByID = Dictionary(facts.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { first, _ in first })
        // Each line's parent, when it is listed here too. A loop of
        // parents (a hand-edited state) has no root: its lines list flat,
        // as in the sidebar.
        let named = facts.map { links[$0.id].flatMap { indexByID[$0] } }
        let parents = named.indices.map { isRooted($0, parents: named) ? named[$0] : nil }
        var children: [Int: [Int]] = [:]
        for (index, parent) in parents.enumerated() { if let parent { children[parent, default: []].append(index) } }
        let inFamily = Set(children.keys).union(parents.indices.filter { parents[$0] != nil })

        var byStack: [Int: [Int]] = [:]
        for (index, fact) in facts.enumerated() {
            // Only an open pull request has a place in a stack.
            guard let root = fact.pullRequest?.stack?.root else { continue }
            byStack[root, default: []].append(index)
        }
        let stacks = byStack.filter { $0.value.count > 1 && $0.value.allSatisfy { !inFamily.contains($0) } }
        let stackOf = { (index: Int) in facts[index].pullRequest?.stack.flatMap { stacks[$0.root] } }

        var placed: [Placed] = []
        var seen = Set<Int>()
        func score(_ members: [Int]) -> Int { members.map { progress(lines[$0]) }.max() ?? 0 }
        func family(from root: Int) -> [Int] {
            guard seen.insert(root).inserted else { return [] }
            return [root] + (children[root] ?? []).flatMap(family(from:))
        }
        for index in facts.indices where !seen.contains(index) {
            if let members = stackOf(index) {
                seen.formUnion(members)
                let inOrder = members.sorted { (facts[$0].pullRequest?.stack?.order ?? 0) < (facts[$1].pullRequest?.stack?.order ?? 0) }
                let title = stackTitle(inOrder.compactMap { facts[$0].pullRequest })
                placed.append(Placed(unit: .stack(title: title, inOrder.map { lines[$0] }), members: inOrder, score: score(inOrder)))
            } else if parents[index] == nil {
                let members = family(from: index)
                let unit = Unit.task(lines[index], subtasks: members.dropFirst().map { lines[$0] })
                placed.append(Placed(unit: unit, members: members, score: score(members)))
            }
        }
        return placed
    }

    /// Whether following `index`'s parents ends at a line without one.
    private static func isRooted(_ index: Int, parents: [Int?]) -> Bool {
        var current = index
        var steps = 0
        while let parent = parents[current] {
            current = parent
            steps += 1
            if steps > parents.count { return false }
        }
        return true
    }

    /// "Stack · 3 pull requests on main".
    private static func stackTitle(_ pullRequests: [PullRequest]) -> String {
        let base = pullRequests.first?.stack.map { place in
            place.mergedBase.map { "\(place.rootBase) (#\($0.number) merged)" } ?? place.rootBase
        } ?? ""
        return "Stack · \(pullRequests.count) pull requests on \(base)"
    }

    /// How close a line is to its base branch, for "By progress": its
    /// station; a blocked one below Code; one already merged last, since
    /// nothing is left to follow.
    private static func progress(_ line: Line) -> Int {
        switch line.state {
        case .merged: return -2
        case .blocked: return -1
        default: return line.station.rawValue
        }
    }

    /// "14:02", in the calendar's time zone.
    private static func clockTime(_ time: TimeInterval, calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.hour, .minute], from: Date(timeIntervalSince1970: time))
        return String(format: "%02d:%02d", parts.hour ?? 0, parts.minute ?? 0)
    }
}
