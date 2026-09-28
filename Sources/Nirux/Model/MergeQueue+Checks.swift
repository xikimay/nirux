import Foundation

// MARK: - Checks (section 3.2)

extension MergeQueue {
    /// Check run conclusions that make a check red. NEUTRAL and SKIPPED
    /// are neither green nor red: CodeQL adds a NEUTRAL check to every PR.
    static let redConclusions: Set<String> = [
        "FAILURE", "CANCELLED", "TIMED_OUT", "ACTION_REQUIRED", "STARTUP_FAILURE", "STALE"
    ]

    /// The checks of one head, judged by section 3.2's rules.
    struct ChecksVerdict: Equatable, Sendable {
        /// Required check runs that concluded red.
        var failed: [CommitChecks.CheckRun] = []
        /// Required commit statuses in ERROR or FAILURE.
        var failedStatuses: [String] = []
        /// Required checks that completed neither green nor red: "test (skipped)".
        var notGreen: [String] = []
        /// Required names still running, or with no run yet.
        var pending: [String] = []
        /// Checks that aren't required and are red.
        var otherFailures: [String] = []

        var allRequiredGreen: Bool {
            failed.isEmpty && failedStatuses.isEmpty && notGreen.isEmpty && pending.isEmpty
        }
    }

    /// Only the latest run of each check counts (the highest id, per
    /// workflow, or app, and name): a rerun replaces the run it reran.
    static func latestRuns(_ runs: [CommitChecks.CheckRun]) -> [CommitChecks.CheckRun] {
        var latest: [String: CommitChecks.CheckRun] = [:]
        var order: [String] = []
        for run in runs {
            let key = "\(run.workflow ?? run.app ?? "")\u{0}\(run.name)"
            guard let known = latest[key] else {
                latest[key] = run
                order.append(key)
                continue
            }
            if run.id > known.id { latest[key] = run }
        }
        return order.compactMap { latest[$0] }
    }

    /// `name`, or `Workflow / name` as board.json may spell it.
    static func matches(_ run: CommitChecks.CheckRun, required: String) -> Bool {
        run.name == required || run.workflow.map { "\($0) / \(run.name)" } == required
    }

    /// Each required name must have a check run or a commit status, and
    /// every one matching it must be green: several workflows' jobs may
    /// share a name. `replaced` holds the ids of failed runs a rerun
    /// replaces: until the new run shows, the check is pending.
    static func judge(_ checks: CommitChecks, required: [String], replaced: Set<Int> = []) -> ChecksVerdict {
        let latest = latestRuns(checks.runs)
        var verdict = ChecksVerdict()
        for name in required {
            let runs = latest.filter { matches($0, required: name) }
            let statuses = checks.statuses.filter { $0.context == name }
            guard !runs.isEmpty || !statuses.isEmpty else {
                verdict.pending.append("\(name) (not started)")
                continue
            }
            var failed: [CommitChecks.CheckRun] = []
            var failedStatus = false
            var pending = false
            var notGreen: String?
            for run in runs {
                let conclusion = run.conclusion?.uppercased() ?? ""
                if replaced.contains(run.id) || run.status.uppercased() != "COMPLETED" {
                    pending = true
                } else if conclusion == "SUCCESS" {
                    continue
                } else if redConclusions.contains(conclusion) {
                    failed.append(run)
                } else {
                    notGreen = conclusion.isEmpty ? "no conclusion" : conclusion.lowercased()
                }
            }
            for status in statuses {
                switch status.state.uppercased() {
                case "SUCCESS": continue
                case "FAILURE", "ERROR": failedStatus = true
                default: pending = true
                }
            }
            if !failed.isEmpty || failedStatus {
                verdict.failed += failed
                if failedStatus { verdict.failedStatuses.append(name) }
            } else if pending {
                verdict.pending.append(name)
            } else if let notGreen {
                verdict.notGreen.append("\(name) (\(notGreen))")
            }
        }
        for run in latest where !replaced.contains(run.id) && !required.contains(where: { matches(run, required: $0) })
            && run.status.uppercased() == "COMPLETED" && redConclusions.contains(run.conclusion?.uppercased() ?? "") {
            verdict.otherFailures.append(run.workflow.map { "\($0) / \(run.name)" } ?? run.name)
        }
        for status in checks.statuses where !required.contains(status.context)
            && ["FAILURE", "ERROR"].contains(status.state.uppercased()) {
            verdict.otherFailures.append(status.context)
        }
        return verdict
    }

    /// The red runs a rerun of `runID` replaces: every failed job of that
    /// workflow run, required or not.
    static func runsReplaced(byRerunOf runID: Int, in checks: CommitChecks) -> Set<Int> {
        Set(latestRuns(checks.runs).filter { run in
            run.workflowRunID == runID && run.status.uppercased() == "COMPLETED"
                && redConclusions.contains(run.conclusion?.uppercased() ?? "")
        }.map(\.id))
    }

    /// Whether the post-merge workflow's run failed: a cancelled, skipped
    /// or neutral one didn't.
    static func runFailed(_ run: Run) -> Bool {
        ["failure", "timed_out", "startup_failure", "action_required"].contains(run.conclusion?.lowercased() ?? "")
    }
}
