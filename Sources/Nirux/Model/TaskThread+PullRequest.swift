import Foundation

extension TaskThread {
    /// What `pullRequestHistory(_:)` reads, as `gh pr view <url> --json` takes it.
    static let pullRequestFields = "number,url,title,state,createdAt,closedAt,mergedAt,mergeCommit,commits,reviews,statusCheckRollup"
    static let maxCommits = 100

    /// A pull request's history as `gh pr view --json` gives it: its
    /// opening, its newest commits, its reviews, its checks' last results,
    /// its merge or close. Nil for anything else.
    static func pullRequestHistory(_ data: Data) -> [Event]? {
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let number = json["number"] as? Int, let url = json["url"] as? String
        else { return nil }
        var events: [Event] = []
        if let opened = time(json["createdAt"]) {
            events.append(Event(time: opened, kind: .pullRequest, text: json["title"] as? String, number: number, ref: url))
        }
        let commits = (json["commits"] as? [[String: Any]] ?? []).compactMap { commit -> Event? in
            guard let at = time(commit["committedDate"]), let oid = commit["oid"] as? String else { return nil }
            return Event(time: at, kind: .commit, text: commit["messageHeadline"] as? String, ref: oid.lowercased())
        }
        events += commits.suffix(maxCommits)
        events += (json["reviews"] as? [[String: Any]] ?? []).compactMap { review in
            time(review["submittedAt"]).map { at in
                Event(
                    time: at, kind: .prReview, text: (review["author"] as? [String: Any])?["login"] as? String,
                    detail: (review["state"] as? String)?.lowercased()
                )
            }
        }
        let checks = ProjectBoard.latest((json["statusCheckRollup"] as? [[String: Any]] ?? []).compactMap(ProjectBoard.check(from:)))
        // gh writes a queued run's start as year 1.
        if let last = checks.compactMap({ $0.startedAt?.hasPrefix("0001-") == false ? time($0.startedAt) : nil }).max() {
            let failed = checks.filter { $0.result == .failure }.map(\.name)
            let pending = checks.contains { $0.result == .pending }
            let text = failed.isEmpty ? "\(checks.count) checks" : "\(failed.count) of \(checks.count) failed: \(failed.joined(separator: ", "))"
            events.append(Event(time: last, kind: .checks, text: text, detail: !failed.isEmpty ? "failed" : pending ? "pending" : "passed"))
        }
        if let merged = time(json["mergedAt"]) {
            let commit = ((json["mergeCommit"] as? [String: Any])?["oid"] as? String)?.lowercased()
            events.append(Event(time: merged, kind: .merged, number: number, ref: commit))
        } else if (json["state"] as? String)?.uppercased() == "CLOSED", let closed = time(json["closedAt"]) {
            events.append(Event(time: closed, kind: .prClosed, number: number))
        }
        return events
    }

    private static func time(_ value: Any?) -> TimeInterval? {
        (value as? String).flatMap { try? Date($0, strategy: .iso8601) }?.timeIntervalSince1970
    }
}
