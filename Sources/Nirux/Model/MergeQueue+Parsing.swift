import Foundation

// MARK: - Parsing gh's output

extension MergeQueue {
    private static func object(_ data: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private static func dig(_ json: Any?, _ path: String...) -> Any? {
        path.reduce(json) { value, key in (value as? [String: Any])?[key] }
    }

    /// A full commit SHA, lowercased; nil for anything else.
    static func objectID(_ value: Any?) -> String? {
        guard let value = value as? String, [40, 64].contains(value.count), value.allSatisfy(\.isHexDigit) else { return nil }
        return value.lowercased()
    }

    /// `gh api rate_limit`.
    static func parseRateLimit(_ data: Data) -> RateLimit? {
        let resources = dig(object(data), "resources")
        guard let core = dig(resources, "core") as? [String: Any], let graphQL = dig(resources, "graphql") as? [String: Any],
              let coreRemaining = core["remaining"] as? Int, let coreReset = core["reset"] as? Double,
              let graphQLRemaining = graphQL["remaining"] as? Int, let graphQLReset = graphQL["reset"] as? Double
        else { return nil }
        return RateLimit(
            coreRemaining: coreRemaining, coreReset: Date(timeIntervalSince1970: coreReset),
            graphQLRemaining: graphQLRemaining, graphQLReset: Date(timeIntervalSince1970: graphQLReset)
        )
    }

    /// `rules/branches/{branch}`: whether a `merge_queue` rule applies.
    static func parseRulesRequireMergeQueue(_ data: Data) -> Bool? {
        guard let rules = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else { return nil }
        return rules.contains { $0["type"] as? String == "merge_queue" }
    }

    /// GraphQL `repository.mergeQueue(branch:)`: whether it isn't null.
    static func parseMergeQueue(_ data: Data) -> Bool? {
        guard let repository = dig(object(data), "data", "repository") as? [String: Any] else { return nil }
        return !(repository["mergeQueue"] == nil || repository["mergeQueue"] is NSNull)
    }

    static func parsePullRequest(_ data: Data) -> PullRequestSnapshot? {
        guard let json = dig(object(data), "data", "repository", "pullRequest") as? [String: Any],
              let number = json["number"] as? Int,
              let state = (json["state"] as? String)?.uppercased(),
              let headRefName = json["headRefName"] as? String,
              let headOid = objectID(json["headRefOid"]),
              let baseRefName = json["baseRefName"] as? String,
              let url = json["url"] as? String
        else { return nil }
        let headRepository = (dig(json, "headRepository", "owner", "login") as? String).flatMap { owner in
            (dig(json, "headRepository", "name") as? String).map { GitHubRepository(owner: owner, name: $0) }
        }
        let autoMerge = json["autoMergeRequest"]
        let mergeCommit = json["mergeCommit"] as? [String: Any]
        let parents = (dig(mergeCommit, "parents", "nodes") as? [[String: Any]] ?? []).compactMap { objectID($0["oid"]) }
        return PullRequestSnapshot(
            number: number,
            state: state,
            isDraft: json["isDraft"] as? Bool ?? false,
            headRefName: headRefName,
            headOid: headOid,
            baseRefName: baseRefName,
            headRepository: headRepository,
            mergeable: (json["mergeable"] as? String)?.uppercased() ?? "UNKNOWN",
            hasAutoMerge: !(autoMerge == nil || autoMerge is NSNull),
            // Missing reads as queued: fail closed.
            isInMergeQueue: json["isInMergeQueue"] as? Bool ?? true,
            mergeCommit: objectID(mergeCommit?["oid"]),
            mergeCommitParents: parents,
            url: url
        )
    }

    /// The checks query: every suite's latest check runs, and the commit
    /// statuses. More than one page of suites or runs can't be judged:
    /// a check left unread could be red.
    static func parseChecks(_ data: Data, sha: String) -> Result<CommitChecks, ClientError> {
        guard let repository = dig(object(data), "data", "repository") as? [String: Any] else {
            return .failure(.unreadable("checks of \(sha.prefix(7))"))
        }
        guard let commit = repository["object"] as? [String: Any] else {
            return .failure(.refused(status: nil, message: "GitHub doesn’t know commit \(sha.prefix(7))."))
        }
        let suites = commit["checkSuites"] as? [String: Any]
        let tooMany = Result<CommitChecks, ClientError>.failure(
            .refused(status: nil, message: "\(sha.prefix(7)) has more checks than Nirux reads.")
        )
        if dig(suites, "pageInfo", "hasNextPage") as? Bool == true { return tooMany }
        var checks = CommitChecks()
        for suite in suites?["nodes"] as? [[String: Any]] ?? [] {
            let runs = suite["checkRuns"] as? [String: Any]
            if dig(runs, "pageInfo", "hasNextPage") as? Bool == true { return tooMany }
            let workflowRun = suite["workflowRun"] as? [String: Any]
            let workflow = dig(workflowRun, "workflow", "name") as? String
            for run in runs?["nodes"] as? [[String: Any]] ?? [] {
                guard let id = run["databaseId"] as? Int, let name = run["name"] as? String,
                      let status = run["status"] as? String
                else { return .failure(.unreadable("a check run of \(sha.prefix(7))")) }
                checks.runs.append(CommitChecks.CheckRun(
                    id: id,
                    name: name,
                    workflow: workflow,
                    app: dig(suite, "app", "slug") as? String,
                    workflowRunID: workflowRun?["databaseId"] as? Int,
                    status: status.uppercased(),
                    conclusion: (run["conclusion"] as? String)?.uppercased()
                ))
            }
        }
        for context in dig(commit, "status", "contexts") as? [[String: Any]] ?? [] {
            guard let name = context["context"] as? String, let state = context["state"] as? String else {
                return .failure(.unreadable("a commit status of \(sha.prefix(7))"))
            }
            checks.statuses.append(CommitChecks.Status(context: name, state: state.uppercased()))
        }
        return .success(checks)
    }

    /// The compare filter's `{status, ahead_by, behind_by, base_commit}`.
    static func parseComparison(_ data: Data) -> Comparison? {
        guard let json = object(data), let status = json["status"] as? String,
              let ahead = json["ahead_by"] as? Int, let behind = json["behind_by"] as? Int,
              let base = objectID(json["base_commit"])
        else { return nil }
        return Comparison(status: status, aheadBy: ahead, behindBy: behind, baseCommit: base)
    }

    /// The commit filter's `{sha, committer, parents}`.
    static func parseCommit(_ data: Data) -> CommitInfo? {
        guard let json = object(data), let sha = objectID(json["sha"]), let parents = json["parents"] as? [Any] else { return nil }
        let ids = parents.compactMap(objectID)
        guard ids.count == parents.count else { return nil }
        return CommitInfo(sha: sha, committerLogin: json["committer"] as? String, parents: ids)
    }

    /// `gh run list --json …`, newest first.
    static func parseRuns(_ data: Data) -> [Run]? {
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else { return nil }
        var runs: [Run] = []
        for run in json {
            guard let id = run["databaseId"] as? Int, let status = run["status"] as? String,
                  let headSha = objectID(run["headSha"]), let event = run["event"] as? String
            else { return nil }
            let conclusion = (run["conclusion"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            runs.append(Run(id: id, status: status, conclusion: conclusion, headSha: headSha, event: event,
                            title: run["displayTitle"] as? String, url: run["url"] as? String))
        }
        return runs
    }
}
