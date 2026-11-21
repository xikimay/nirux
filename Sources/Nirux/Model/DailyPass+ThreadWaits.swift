import Foundation

extension DailyPass {
    /// All pages measure the same interval. Workspace IDs break ties between concurrent waits.
    struct WaitPage: Codable, Equatable, Sendable {
        static let more = "Call daily_pass again for the remaining tasks in this wait window."
        let window: Window
        var afterID: String?

        func remaining(in waits: [ThreadWaits]) -> [ThreadWaits] {
            waits.filter { $0.workspaceID > (afterID ?? "") }.sorted { $0.workspaceID < $1.workspaceID }
        }

        func next(afterShowing count: Int, of waits: [ThreadWaits]) -> Self? {
            let rows = remaining(in: waits)
            guard count < rows.count else { return nil }
            return Self(window: window, afterID: rows.prefix(count).last?.workspaceID ?? afterID)
        }

        func read(_ waits: [ThreadWaits]) -> (text: String, next: Self?) {
            let rows = remaining(in: waits)
            let shown = rows.prefix(DailyPass.maxItems)
            let next = next(afterShowing: shown.count, of: waits)
            let header = "Task waits · " + DailyPass.clock(window.start) + " to " + DailyPass.clock(window.end)
            let lines = shown.isEmpty ? ["No remaining waits in this space."] : shown.map(\.line)
            return (([header] + lines + (next == nil ? [] : [Self.more])).joined(separator: "\n"), next)
        }
    }

    struct ThreadWaits: Sendable {
        let task: String
        let workspaceID: String
        let firstPR: TimeInterval?
        let questions: Int
        let reviewRounds: Int
        let followUps: Int
        let user: TimeInterval
        let lead: TimeInterval
        let parent: TimeInterval
        let ci: TimeInterval

        var line: String {
            var parts = [quote(task), "id " + quote(workspaceID), "\(questions) questions", "\(reviewRounds) review rounds", "\(followUps) follow-up rounds"]
            if let firstPR { parts.append("first recorded PR in " + duration(firstPR)) }
            for (label, seconds) in [("user", user), ("Lead", lead), ("parent task", parent), ("CI running", ci)] where seconds > 0 {
                parts.append(label + " " + duration(seconds))
            }
            return "- " + parts.joined(separator: " · ")
        }
    }

    static func threadWaits(
        in ordered: [TaskThread.Event], task: String, workspaceID: String, window: Window
    ) -> ThreadWaits? {
        func inWindow(_ at: TimeInterval) -> Bool { at > window.start && at <= window.end }
        enum Wait { case user, lead, parent, ci }
        var intervals: [Wait: [Range<TimeInterval>]] = [:]
        func count(_ owner: Wait?, from start: TimeInterval, until end: TimeInterval) {
            let lower = max(start, window.start)
            let upper = min(end, window.end)
            guard let owner, upper > lower else { return }
            intervals[owner, default: []].append(lower..<upper)
        }
        var questions = 0
        for question in TaskThread.questions(in: ordered) {
            if inWindow(question.asked.time) {
                questions += 1
            }
            let end = min(question.answer?.time ?? window.end, question.retiredAt ?? window.end)
            let owner = question.asked.recipient ?? question.handoff?.by
                ?? (question.answer?.by == .user ? nil : question.answer?.by)
            let waitingOn: Wait? = switch owner {
            case .lead: .lead
            case .parentTask: .parent
            case .user: .user
            default: nil
            }
            count(waitingOn, from: question.asked.time, until: min(question.handoff?.time ?? end, end))
            if let handoff = question.handoff { count(.user, from: handoff.time, until: end) }
        }
        let close = ordered.first { $0.kind == .closed }?.time
        var firstPR: TimeInterval?
        if let born = ordered.first(where: { $0.kind == .request })?.time,
           let opened = ordered.first(where: { $0.kind == .pullRequest })?.time, opened >= born, inWindow(opened) {
            firstPR = opened - born
        }
        var rounds = 0
        var reviews = 0
        for event in ordered {
            if inWindow(event.time) {
                if event.kind == .findings {
                    reviews += 1
                }
                if event.kind == .followUp {
                    rounds += 1
                }
            }
            if event.kind == .checkRun, let end = event.until ?? close {
                count(.ci, from: event.time, until: min(end, close ?? end))
            }
        }
        guard !intervals.isEmpty || firstPR != nil || questions + rounds + reviews > 0 else { return nil }
        func seconds(_ owner: Wait) -> TimeInterval {
            var total: TimeInterval = 0
            var until = window.start
            for range in (intervals[owner] ?? []).sorted(by: { $0.lowerBound < $1.lowerBound }) {
                total += max(0, range.upperBound - max(until, range.lowerBound))
                until = max(until, range.upperBound)
            }
            return total
        }
        return ThreadWaits(task: task, workspaceID: workspaceID, firstPR: firstPR, questions: questions, reviewRounds: reviews, followUps: rounds,
                           user: seconds(.user), lead: seconds(.lead), parent: seconds(.parent), ci: seconds(.ci))
    }

    struct LiveThread: Sendable {
        let id: String
        let title: String
        let context: TaskThread.Context
    }

    /// A frozen thread supplies its own Mission and PR history. Only open threads need the changing sources.
    static func readThreadWaits(
        spaceID: String, live: [LiveThread], excluding: Set<String>, missions: [Mission], findings: [ReviewFindings.Entry], window: Window, directory: URL
    ) -> [ThreadWaits] {
        let liveByID = Dictionary(uniqueKeysWithValues: live.map { ($0.id, $0) })
        let byWorkspace = Dictionary(grouping: findings, by: \.workspace)
        let byChild = Dictionary(grouping: missions, by: \.childWorkspaceID)
        let followUps = PRFollowUpStore.load(from: directory.appendingPathComponent(PRFollowUpStore.fileName)).pullRequests
        let folder = TaskThread.Store.folder(spaceID: spaceID, stateDirectory: directory)
        let names = folder.flatMap { try? FileManager.default.contentsOfDirectory(atPath: $0.path) } ?? []
        let archivedIDs = names.filter { $0.hasSuffix(".jsonl") }.map { String($0.dropLast(6)) }
        return Set(archivedIDs).union(liveByID.keys).subtracting(excluding).sorted().compactMap { id in
            guard let url = TaskThread.Store.fileURL(workspaceID: id, spaceID: spaceID, stateDirectory: directory) else { return nil }
            let current = liveByID[id]
            let recorded = current == nil ? TaskThread.Store.load(from: url) : TaskThread.Store.load(workspaceID: id, stateDirectory: directory)
            guard current != nil || TaskThread.canReadArchive(recorded) else { return nil }
            let events: [TaskThread.Event]
            let frozen = recorded.contains { $0.kind == .closed }
            if frozen {
                events = TaskThread.ordered(recorded)
            } else {
                let urls = current?.context.urls ?? []
                let sources = TaskThread.Sources(missions: byChild[id] ?? [], findings: byWorkspace[id] ?? [], followUps: followUps.filter { urls.contains($0.key) })
                events = TaskThread.thread(recorded: recorded + (current?.context.pullRequestEvents ?? []), joining: sources)
            }
            var measured = window
            if current == nil && !frozen {
                // A failed freeze left no close time. Only dated evidence bounds this archive’s waits.
                measured.end = min(window.end, events.last?.time ?? window.start)
            }
            return threadWaits(in: events, task: current?.title ?? byChild[id]?.first?.branch ?? id, workspaceID: id, window: measured)
        }
    }
}
