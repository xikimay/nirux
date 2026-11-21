import Foundation

extension BoardStages {
    struct CheckTimeout: Equatable {
        enum Reading: Equatable {
            case unavailable, changed, pending, failed, passed
        }

        let number: Int
        let status: String
        let reading: Reading
        let canRetry: Bool

        var hasCurrentReading: Bool { reading != .unavailable }
    }

    static func checkTimeout(
        in state: ProjectBoard.QueueState?, rows: [ProjectBoard.Row], required: [String], baseBranch: String?,
        currentRead: @autoclosure () -> Date?, now: Date
    ) -> CheckTimeout? {
        guard let state, state.run == .ended, let entry = state.entries.first(where: {
            if case .stopped(let reason) = $0.step { return reason.isChecksTimeout }
            return false
        }) else { return nil }
        let time = state.stoppedAt.map { " at " + ProjectBoard.clockTime($0, now: now) } ?? ""
        let history = "#\(entry.number) queue timed out\(time)"
        func report(_ reading: CheckTimeout.Reading, _ current: String, canRetry: Bool = false) -> CheckTimeout {
            CheckTimeout(number: entry.number, status: history + " · " + current, reading: reading, canRetry: canRetry)
        }
        guard let stopped = state.stoppedAt, let currentRead = currentRead(), currentRead >= stopped,
              let head = GitHub.objectID(entry.heads.last),
              let row = rows.first(where: { $0.pullRequest?.number == entry.number }),
              let pr = row.pullRequest, pr.isOpen, pr.isFromConfiguredRepository,
              let currentHead = GitHub.objectID(pr.headOid)
        else { return report(.unavailable, "Current checks unknown") }
        let sha = WorktreeCleanup.short(currentHead)
        guard currentHead == head else { return report(.changed, "Head changed to \(sha)") }
        guard !required.isEmpty, !pr.checks.isEmpty else { return report(.unavailable, "Current checks unknown") }
        let latest = GitHub.latest(pr.checks)
        switch checks(latest: latest, required: required) {
        case .failed(let names):
            return report(.failed, "\(names.joined(separator: ", ")) now failing on \(sha)")
        case .pending(_, let missing):
            if !missing.isEmpty { return report(.pending, "No run reported for \(missing.joined(separator: ", ")) on \(sha)") }
            let pending = required.filter { name in latest.contains { $0.matches(name) && $0.result == .pending } }
            return report(.pending, "\(pending.joined(separator: ", ")) still pending on \(sha)")
        case .passed:
            // A green commit status alone cannot satisfy a required check run.
            guard required.allSatisfy({ name in latest.contains { $0.matches(name) && $0.conclusion == "SUCCESS" } })
            else { return report(.unavailable, "Required check runs unconfirmed on \(sha)") }
            let eligible = pr.mergeable == "MERGEABLE" && pr.baseRefName == baseBranch
                && !pr.mergeIsBlocked && !pr.autoMerges && pr.reviewDecision != "CHANGES_REQUESTED" && pr.reviewDecision != "REVIEW_REQUIRED"
                && ProjectBoard.queueRefusal(row, baseBranch: baseBranch) == nil
            return report(.passed, "\(required.joined(separator: ", ")) passed on \(sha)", canRetry: eligible)
        case .absent:
            return report(.unavailable, "Current checks unknown")
        }
    }
}
