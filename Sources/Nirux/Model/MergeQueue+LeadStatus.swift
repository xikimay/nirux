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
