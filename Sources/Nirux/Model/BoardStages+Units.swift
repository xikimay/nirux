import Foundation

// MARK: - Lines that stay together, by repository (docs/design/board-stages.md, section 4)

extension BoardStages {
    /// Lines that never part, each keeping its own state.
    enum Unit: Equatable, Sendable {
        /// A task, then the tasks listed under it in the sidebar, depth
        /// first: each joined to it by an elbow.
        case task(Line, subtasks: [Line])
        /// A straight stack of pull requests on a numbered rail, in merge
        /// order, under its title.
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
        /// Its task's line, while that task is open here: a click opens it.
        var lineID: String?
        /// The task's title, else the pull request's.
        var title: String
        var number: Int
        var mergedAt: TimeInterval
        /// An agent of its task waits for the user: amber is never hidden.
        var needsYou = false
        /// Its worktree is still there.
        var cleanUp: CleanUp?
    }

    /// One repository of the space, or its tasks without one.
    struct Section: Equatable, Sendable {
        let id: String
        var units: [Unit]
        /// "Pull requests without a task": no workspace here. Folded,
        /// closing the section.
        var withoutTask: [Unit]
        /// "Merged today", the newest first.
        var merged: [Merged]
        /// "Other worktrees": folded, after the pull requests without a task.
        var otherWorktrees: [OtherWorktree] = []
    }

    /// A linked worktree of the repository with no workspace and no open
    /// pull request (a task closed since, a branch left): listed folded
    /// under "Other worktrees", with what the table offered it.
    struct OtherWorktree: Equatable, Sendable {
        /// Its top level, as git lists it.
        let path: String
        /// Its branch, "detached HEAD (1a2b3c4)", or its folder's name.
        var title: String
        /// Its merged pull request, as the table says it: "#41 merged".
        var pullRequest: String?
        /// That pull request's address, for its tooltip.
        var url: String?
        /// Open, then Clean Up….
        var menu: [MenuItem]
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
        /// without a task (oldest first, a stack in its order), one line
        /// per pull request, each `id` its own. A task's merged pull
        /// request is on its facts where the queue's own branch update
        /// left its worktree a commit behind (`BoardStages.sectionFacts`).
        var lines: [Facts]
        /// The line each sub-task is listed under in the sidebar
        /// (`WorkspaceStore.activeParents`), by their facts' `id`.
        var parents: [String: String] = [:]
        var merged: [MergedFacts] = []
        /// By title.
        var otherWorktrees: [OtherWorktree] = []
    }

    enum Order: String, Sendable {
        /// The sidebar's.
        case sidebar
        /// The closest to its base branch first.
        case progress
    }

    /// One section's units, in `order`.
    /// - A pull request merged today leaves the list for "Merged today"
    ///   once the queue is through with it, whatever its agent does next:
    ///   a line doesn't come and go with each turn. It stays while a
    ///   sub-task of it is listed. One merged before today, whose task is
    ///   still open, stays a line.
    /// - A task and its sub-tasks are a family, wherever their pull
    ///   requests are, listed as the sidebar lists them.
    /// - A straight stack is a unit of its own only when none of its
    ///   lines is in a family; else, as in a fork, the lines stay where
    ///   they are, and their pull request cells and phrases say the stack.
    /// - A stack with a task stays whole in the list; one without any goes
    ///   to the pull requests without a task.
    /// `now` is the wall clock, in seconds since 1970 as `mergedAt` is:
    /// "today" starts at midnight in `timeZone`.
    static func section(
        _ facts: SectionFacts, order: Order = .sidebar, rules: Rules = Rules(), now: TimeInterval, timeZone: TimeZone = .current
    ) -> Section {
        let lines = facts.lines.map { line($0, rules: rules) }
        let tree = Tree(ids: facts.lines.map(\.id), parents: facts.parents)

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let midnight = calendar.startOfDay(for: Date(timeIntervalSince1970: now)).timeIntervalSince1970
        let today = facts.merged.filter { $0.mergedAt >= midnight }.sorted { $0.mergedAt > $1.mergedAt }
        let mergedToday = Set(today.map(\.number))
        // Merged today, and nothing of its rail is current (which only a
        // merged line's is): the queue is through with it.
        let isThrough = facts.lines.indices.map { index -> Bool in
            guard let number = facts.lines[index].pullRequest?.number, mergedToday.contains(number) else { return false }
            return lines[index].rail?.marks.contains(.current) == false
        }
        // In the tree's order, sub-tasks before their task: one that is
        // through leaves, unless a sub-task of it stays.
        var stays = Array(repeating: true, count: lines.count)
        for index in tree.order.reversed() where isThrough[index] {
            stays[index] = tree.children[index, default: []].contains { stays[$0] }
        }

        let placed = units(facts.lines, lines: lines, tree: tree, stays: stays)
        let arranged = { (units: [Placed]) -> [Unit] in
            let sorted = order == .sidebar ? units : units.enumerated().sorted { lhs, rhs in
                (lhs.element.rank, rhs.offset) > (rhs.element.rank, lhs.offset)
            }.map(\.element)
            return sorted.map(\.unit)
        }
        // Where each merged pull request's lines went.
        var left: [Int: [Int]] = [:]
        var listed = Set<Int>()
        for index in lines.indices {
            guard let number = facts.lines[index].pullRequest?.number else { continue }
            if stays[index] { listed.insert(number) } else { left[number, default: []].append(index) }
        }
        return Section(
            id: facts.id,
            units: arranged(placed.filter(\.hasTask)),
            withoutTask: arranged(placed.filter { !$0.hasTask }),
            merged: today.compactMap { pullRequest in
                let gone = left[pullRequest.number] ?? []
                // One place per pull request: not here while its line is listed.
                guard !gone.isEmpty || !listed.contains(pullRequest.number) else { return nil }
                let task = gone.first { facts.lines[$0].hasTask }
                return Merged(
                    lineID: task.map { facts.lines[$0].id },
                    title: task.map { facts.lines[$0].title } ?? text(pullRequest.title) ?? "#\(pullRequest.number)",
                    number: pullRequest.number,
                    mergedAt: pullRequest.mergedAt,
                    needsYou: gone.contains { lines[$0].state == .needsYou },
                    cleanUp: task.flatMap { facts.lines[$0].cleanUp }
                )
            },
            otherWorktrees: facts.otherWorktrees
        )
    }

    /// The lines as the sidebar's tree lists them
    /// (`WorkspaceStore.treeOrder`): the roots in order, each followed by
    /// its sub-tasks, depth first; then what a loop of parents (a
    /// hand-edited state) left out, the same way.
    private struct Tree {
        /// The lines no other is listed above.
        let roots: [Int]
        /// Each line's sub-tasks, by index.
        let children: [Int: [Int]]
        /// Every line once, a task before its sub-tasks.
        let order: [Int]

        init(ids: [String], parents links: [String: String]) {
            let indexByID = Dictionary(ids.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
            var named: [Int: [Int]] = [:]
            var hasParent = Set<Int>()
            for index in ids.indices {
                // A parent listed here, and not the line itself.
                guard let parent = links[ids[index]].flatMap({ indexByID[$0] }), parent != index else { continue }
                named[parent, default: []].append(index)
                hasParent.insert(index)
            }
            var roots: [Int] = []
            var children: [Int: [Int]] = [:]
            var order: [Int] = []
            var visited = Set<Int>()
            func visit(_ index: Int) {
                order.append(index)
                for child in named[index, default: []] where visited.insert(child).inserted {
                    children[index, default: []].append(child)
                    visit(child)
                }
            }
            // The roots first, then what a loop of parents left out.
            for index in ids.indices where !hasParent.contains(index) && visited.insert(index).inserted {
                roots.append(index)
                visit(index)
            }
            for index in ids.indices where visited.insert(index).inserted {
                roots.append(index)
                visit(index)
            }
            (self.roots, self.children, self.order) = (roots, children, order)
        }
    }

    /// A unit, and where it goes.
    private struct Placed {
        let unit: Unit
        /// A task is in it, or in its stack: it is in the list. (Its lines
        /// agree: a family's are tasks, a stack's share the stack.)
        let hasTask: Bool
        /// Its furthest line's rank, for "By progress".
        let rank: Rank
    }

    /// How close a line is to its base branch: its score, then, among the
    /// lines of the queue's list, the first to land.
    private struct Rank: Comparable {
        let score: Int
        /// After every place when it is in no list.
        let queueOrder: Int

        static func < (lhs: Rank, rhs: Rank) -> Bool {
            (lhs.score, rhs.queueOrder) < (rhs.score, lhs.queueOrder)
        }
    }

    /// The units of the lines that stay, in the order of their first line.
    private static func units(_ facts: [Facts], lines: [Line], tree: Tree, stays: [Bool]) -> [Placed] {
        // Each root that stays, then its sub-tasks that do: a line that
        // leaves has none left under it.
        func family(from index: Int) -> [Int] {
            stays[index] ? [index] + tree.children[index, default: []].flatMap(family(from:)) : []
        }
        let families = tree.roots.map(family(from:)).filter { !$0.isEmpty }
        let inFamily = Set(families.filter { $0.count > 1 }.joined())

        // Straight stacks of several pull requests, none of whose lines is
        // in a family. Only an open pull request has a place in a stack.
        var byStack: [Int: [Int]] = [:]
        for index in facts.indices where stays[index] {
            guard let place = facts[index].pullRequest?.stack, place.chain.count > 1 else { continue }
            byStack[place.root, default: []].append(index)
        }
        let number = { (index: Int) in facts[index].pullRequest?.number }
        let stacks = byStack.filter { Set($0.value.map(number)).count > 1 && $0.value.allSatisfy { !inFamily.contains($0) } }
        // A stack with a task stays whole in the list, even where a
        // family keeps its lines apart.
        let stacksWithTask = Set(byStack.filter { $0.value.contains { facts[$0].hasTask } }.keys)
        let isInList = { (index: Int) in
            facts[index].hasTask || (facts[index].pullRequest?.stack).map { stacksWithTask.contains($0.root) } ?? false
        }

        func place(_ unit: Unit, _ members: [Int]) -> Placed {
            Placed(
                unit: unit, hasTask: isInList(members[0]),
                rank: members.map { rank(facts[$0], lines[$0]) }.max() ?? Rank(score: 0, queueOrder: .max)
            )
        }
        var placed: [(first: Int, unit: Placed)] = []
        var inStack = Set<Int>()
        for members in stacks.values {
            let inOrder = members.sorted { (facts[$0].pullRequest?.stack?.order ?? 0) < (facts[$1].pullRequest?.stack?.order ?? 0) }
            let base = branch(facts[inOrder[0]].pullRequest?.stack?.base ?? "")
            let title = "Stack · \(Set(inOrder.map(number)).count) pull requests on \(base)"
            inStack.formUnion(members)
            placed.append((members.min() ?? 0, place(.stack(title: title, inOrder.map { lines[$0] }), inOrder)))
        }
        for members in families where !inStack.contains(members[0]) {
            placed.append((members[0], place(.task(lines[members[0]], subtasks: members.dropFirst().map { lines[$0] }), members)))
        }
        return placed.sorted { $0.first < $1.first }.map(\.unit)
    }

    /// How close a line is to its base branch, for "By progress", by what
    /// doesn't change with each turn of its agent:
    /// - the pull request the queue works on first;
    /// - then the queue's list, in its order, whatever station each is at;
    /// - then by station, a line with a blocker below Code;
    /// - then what nothing is left to follow for: a pull request merged
    ///   and through the queue, then an archived task.
    private static func rank(_ facts: Facts, _ line: Line) -> Rank {
        let queueOrder = line.rail?.queueOrder
        var score = queueOrder == nil ? line.station.rawValue : Station.merge.rawValue
        if facts.queue.step != nil {
            score = Station.merge.rawValue + 1
        } else if facts.isArchived {
            score = -3
        } else if line.rail?.marks.contains(.current) == false {
            score = -2
        } else if text(facts.blocker) != nil {
            score = -1
        }
        return Rank(score: score, queueOrder: queueOrder ?? .max)
    }
}
