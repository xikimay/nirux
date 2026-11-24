import Foundation

extension MergeQueue {
    static func leadStatus(
        repository: GitHubRepository, saved: SavedQueue?, runsElsewhere: Bool, selection: [Int],
        openPRs: Set<Int>?, leadEnabled: Bool, allowWithoutLocalReview: Bool = false,
        build: String, settingsProblem: String?, journal: JournalSnapshot
    ) -> String {
        var lines = ["Repository: " + repository.ownerAndName]
        if let saved {
            let phase = runsElsewhere ? "running elsewhere" : phaseDescription(saved.status)
            lines.append("Phase: " + phase)
            lines.append("Status: " + journal.status)
            let current = saved.current.flatMap { saved.entries[safe: $0] }
            if let current { lines.append("Current PR: #\(current.number)") }
            if let train = saved.train {
                lines.append("Train: \(train.name) on \(train.branch), at \(MergeQueue.Engine.short(train.head))")
            }
            if saved.isRunning {
                lines.append("Cadence: " + saved.effectiveCadence.title)
                lines.append("Started by: " + (saved.startedByLead.map { $0 ? "Lead" : "user" } ?? "unknown"))
                let remaining = saved.entries.filter { $0.step == .waiting && $0.number != current?.number }
                lines.append("Remaining PRs: " + list(remaining.map { "#\($0.number)" }))
            }
        } else {
            lines.append("Phase: idle")
        }
        let selected = selection.map { number in
            "#\(number)" + (openPRs?.contains(number) == false ? " (closed or stale)" : "")
        }
        lines.append("Board selection: " + list(selected) + (openPRs == nil && !selected.isEmpty ? " (open status unknown)" : ""))
        if let settingsProblem { lines.append("Board Settings: " + settingsProblem) }
        let autoStart = !leadEnabled ? "disabled"
            : allowWithoutLocalReview ? "enabled (without local review required)" : "enabled"
        lines.append("Lead auto-start: " + autoStart)
        lines.append("Build: " + build)
        lines.append("Recent journal entries:\n" + (journal.entriesText.isEmpty ? "none" : journal.entriesText))
        return lines.joined(separator: "\n")
    }

    /// What the Lead hears when a queue it started ends: a stop nobody
    /// asked for (a person's, the Lead's or the user's, is theirs to tell),
    /// or its list done. Nil for anything else. Its own words only: a
    /// stop's message can carry GitHub's.
    /// `current`: the pull request it stopped on; `merged`: those that
    /// landed before; `left`: those that left it (an agent stayed busy). A
    /// stop that waiting can't fix (an agent busy, GitHub not answering) asks
    /// for no new queue.
    static func leadEndNotice(
        repository: String, phase: Phase, isLeads: Bool, merged: [Int], left: [Int] = [], current: Int?
    ) -> String? {
        guard isLeads else { return nil }
        switch phase {
        case .stopped(let reason) where reason.kind != .user:
            let next = switch reason.kind {
            case .agentBusy: " Its agent stayed busy: queue it again only once that agent is back at its prompt."
            case .github: " GitHub didn't answer: nothing to fix, merge_queue_status has the journal."
            default: " Read merge_queue_status, fix what stopped it, then queue_merge again."
            }
            let landed = merged.isEmpty ? "" : " " + merged.map { "#\($0)" }.joined(separator: ", ")
                + " landed: close their tasks with close_task."
            return "The merge queue of \(repository) stopped" + (current.map { " on #\($0)" } ?? "")
                + " (\(reason.kind.rawValue))." + next + landed
        case .finished:
            let leftIt = left.isEmpty ? "" : " " + left.map { "#\($0)" }.joined(separator: ", ")
                + " left it, an agent still busy: queue it again once that agent is back at its prompt."
            return "The merge queue of \(repository) finished: \(merged.count) merged." + leftIt + " Close the merged tasks with close_task."
        default:
            return nil
        }
    }

    private static func phaseDescription(_ status: SavedQueue.Status) -> String {
        switch status {
        case .running: "running"
        case .stopping: "stopping"
        case .stopped, .finished: "ended"
        }
    }

    private static func list(_ items: [String]) -> String {
        items.isEmpty ? "none" : items.joined(separator: ", ")
    }
}
