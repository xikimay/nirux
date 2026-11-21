import Foundation

extension DailyPass {
    struct ThreadWaits: Sendable {
        let task: String
        let workspaceID: String
        let at: TimeInterval
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
        var firstFact: TimeInterval?
        func note(_ at: TimeInterval) { firstFact = min(firstFact ?? at, at) }
        enum Wait { case user, lead, parent, ci }
        var intervals: [Wait: [Range<TimeInterval>]] = [:]
        func count(_ owner: Wait?, from start: TimeInterval, until end: TimeInterval) {
            let lower = max(start, window.start)
            let upper = min(end, window.end)
            guard let owner, upper > lower else { return }
            intervals[owner, default: []].append(lower..<upper)
            note(upper)
        }
        var questions = 0
        for question in TaskThread.questions(in: ordered) {
            if window.contains(question.asked.time) {
                questions += 1
                note(question.asked.time)
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
           let opened = ordered.first(where: { $0.kind == .pullRequest })?.time, opened >= born, window.contains(opened) {
            firstPR = opened - born
            note(opened)
        }
        var rounds = 0
        var reviews = 0
        for event in ordered {
            if window.contains(event.time) {
                if event.kind == .findings {
                    reviews += 1
                    note(event.time)
                }
                if event.kind == .followUp {
                    rounds += 1
                    note(event.time)
                }
            }
            if event.kind == .checkRun, let end = event.until ?? close {
                count(.ci, from: event.time, until: min(end, close ?? end))
            }
        }
        guard let at = firstFact else { return nil }
        func seconds(_ owner: Wait) -> TimeInterval {
            var total: TimeInterval = 0
            var until = window.start
            for range in (intervals[owner] ?? []).sorted(by: { $0.lowerBound < $1.lowerBound }) {
                total += max(0, range.upperBound - max(until, range.lowerBound))
                until = max(until, range.upperBound)
            }
            return total
        }
        return ThreadWaits(task: task, workspaceID: workspaceID, at: at, firstPR: firstPR, questions: questions, reviewRounds: reviews, followUps: rounds,
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
