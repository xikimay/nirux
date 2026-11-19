import Foundation

extension GitHub {
    /// A check run's or a commit status's outcome, in the order the board
    /// shows the worst of several: a skipped or neutral check doesn't hide
    /// a success. (The merge queue has its own rules: neither is green.)
    enum CheckResult: Int, Comparable, Sendable {
        case skipped
        case neutral
        case success
        case pending
        case failure

        static func < (lhs: CheckResult, rhs: CheckResult) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    /// One entry of a pull request's `statusCheckRollup`: a check run, or a
    /// commit status (`context`). For display only: the rollup carries no
    /// commit, so the merge queue reads checks by commit instead.
    struct Check: Hashable, Sendable {
        /// The job's name, or a commit status's context.
        let name: String
        /// The check run's workflow. Nil (or empty) for a commit status, or
        /// a check run no workflow made (CodeQL's summary check).
        let workflowName: String?
        let result: CheckResult
        /// ISO 8601. Of two runs of one check, the later one counts.
        let startedAt: String?
        /// The check run's `detailsUrl`, or the commit status's `targetUrl`.
        /// Set by whoever posted the check: untrusted.
        let url: String?

        /// `Workflow / job`, as board.json may name it.
        var qualifiedName: String? { GitHub.qualifiedName(name: name, workflow: workflowName) }

        func matches(_ required: String) -> Bool {
            name == required || qualifiedName == required
        }
    }

    /// A `CheckRun` or a `StatusContext` of the rollup.
    static func check(from json: [String: Any]) -> Check? {
        let startedAt = json["startedAt"] as? String
        // gh writes a missing URL as "".
        let url = ((json["detailsUrl"] ?? json["targetUrl"]) as? String).flatMap { $0.isEmpty ? nil : $0 }
        if let context = json["context"] as? String {
            let result: CheckResult
            switch (json["state"] as? String)?.uppercased() {
            case "SUCCESS": result = .success
            case "FAILURE", "ERROR": result = .failure
            default: result = .pending
            }
            return Check(name: context, workflowName: nil, result: result, startedAt: startedAt, url: url)
        }
        guard let name = json["name"] as? String else { return nil }
        let status = (json["status"] as? String)?.uppercased() ?? ""
        let conclusion = (json["conclusion"] as? String)?.uppercased() ?? ""
        let result: CheckResult
        if status != "COMPLETED" && !status.isEmpty {
            result = .pending
        } else {
            switch conclusion {
            case "SUCCESS": result = .success
            case "NEUTRAL": result = .neutral
            case "SKIPPED": result = .skipped
            case _ where GitHub.isRedCheck(conclusion): result = .failure
            default: result = .pending
            }
        }
        return Check(
            name: name, workflowName: json["workflowName"] as? String, result: result, startedAt: startedAt, url: url
        )
    }

    /// The latest run of each check (by workflow and name), in first-seen
    /// order. The sidebar's pull request keeps them too.
    static func latest(_ checks: [Check]) -> [Check] {
        var latest: [String: Check] = [:]
        var order: [String] = []
        for check in checks {
            let key = "\(check.workflowName ?? "")\u{0}\(check.name)"
            guard let known = latest[key] else {
                latest[key] = check
                order.append(key)
                continue
            }
            if startOrder(check) >= startOrder(known) { latest[key] = check }
        }
        return order.compactMap { latest[$0] }
    }

    /// A run not started yet (a rerun waiting for a runner) has no start,
    /// or gh's zero time: it is the latest.
    private static func startOrder(_ check: Check) -> String {
        GitHub.startTime(check.startedAt) ?? "~"
    }

    /// `Workflow / job`, as board.json may name a check; nil without a workflow.
    static func qualifiedName(name: String, workflow: String?) -> String? {
        guard let workflow, !workflow.isEmpty else { return nil }
        return "\(workflow) / \(name)"
    }
}
