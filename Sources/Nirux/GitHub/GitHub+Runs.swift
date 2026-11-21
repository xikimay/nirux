import Foundation

extension GitHub {
    /// A workflow run as `gh run list` gives it.
    struct WorkflowRun: Equatable, Sendable {
        let id: Int
        /// `completed`, `in_progress`, `queued`, `waiting`…
        let status: String
        /// `success`, `failure`, `cancelled`… once completed.
        let conclusion: String?
        let headSha: String
        /// `push`, `workflow_dispatch`…
        let event: String
        /// 1, then 2… for each rerun of the same run.
        var attempt = 1
        /// The commit's first line, for a push.
        var title: String?
        var url: String?
        var headBranch: String?
        var workflowName: String?
        var createdAt: Date?
        var updatedAt: Date?
        /// When its latest attempt started.
        var startedAt: Date?

        /// What `gh run list --json` is asked for, by every reader.
        static let fields = "databaseId,attempt,status,conclusion,headSha,event,displayTitle,url,headBranch,workflowName,"
            + "createdAt,updatedAt,startedAt"

        var isCompleted: Bool { status == "completed" }

        /// A rerun is the same run, but not the same result.
        var attemptKey: String { "\(id)#\(attempt)" }

        /// When a completed run last changed, else when it started.
        var shownDate: Date? { isCompleted ? (updatedAt ?? createdAt) : (createdAt ?? updatedAt) }
    }

    /// `gh run list --json …` output, newest first. Nil when it isn't a JSON
    /// list, or when a run lacks its id, status, commit or event: a run
    /// that can't be read might be the failed one.
    static func parseWorkflowRuns(_ data: Data) -> [WorkflowRun]? {
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else { return nil }
        let date = { (value: Any?) in (value as? String).flatMap { try? Date($0, strategy: .iso8601) } }
        var runs: [WorkflowRun] = []
        for run in json {
            guard let id = run["databaseId"] as? Int, let status = run["status"] as? String,
                  let headSha = objectID(run["headSha"]), let event = run["event"] as? String
            else { return nil }
            runs.append(WorkflowRun(
                id: id, status: status, conclusion: (run["conclusion"] as? String).flatMap { $0.isEmpty ? nil : $0 },
                headSha: headSha, event: event, attempt: run["attempt"] as? Int ?? 1, title: run["displayTitle"] as? String,
                url: run["url"] as? String, headBranch: run["headBranch"] as? String, workflowName: run["workflowName"] as? String,
                createdAt: date(run["createdAt"]), updatedAt: date(run["updatedAt"]), startedAt: date(run["startedAt"])
            ))
        }
        return runs
    }
}
