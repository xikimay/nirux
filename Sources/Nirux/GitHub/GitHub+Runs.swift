import Foundation

extension GitHub {
    /// A workflow run as `gh run list` gives it.
    struct WorkflowRun: Equatable, Sendable {
        /// `completed`, `in_progress`, `queued`…
        let status: String
        /// `success`, `failure`, `cancelled`… once completed.
        let conclusion: String?
        let headSha: String
        let createdAt: Date?
        let updatedAt: Date?
        let url: String?

        var isCompleted: Bool { status == "completed" }

        /// When a completed run last changed, else when it started.
        var shownDate: Date? { isCompleted ? (updatedAt ?? createdAt) : (createdAt ?? updatedAt) }
    }

    /// `gh run list --json …` output, newest first; nil when it isn't a
    /// JSON list.
    static func parseWorkflowRuns(_ data: Data) -> [WorkflowRun]? {
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else { return nil }
        let formatter = ISO8601DateFormatter()
        return json.compactMap { run in
            guard let status = run["status"] as? String, let headSha = run["headSha"] as? String else { return nil }
            let conclusion = (run["conclusion"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            return WorkflowRun(
                status: status,
                conclusion: conclusion,
                headSha: headSha,
                createdAt: (run["createdAt"] as? String).flatMap(formatter.date(from:)),
                updatedAt: (run["updatedAt"] as? String).flatMap(formatter.date(from:)),
                url: run["url"] as? String
            )
        }
    }
}
