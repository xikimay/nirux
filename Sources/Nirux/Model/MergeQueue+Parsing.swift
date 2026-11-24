import Foundation

// MARK: - Parsing gh's output

extension MergeQueue {
    private static func object(_ data: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    /// `gh api rate_limit`.
    static func parseRateLimit(_ data: Data) -> RateLimit? {
        let resources = GitHub.dig(object(data), "resources")
        guard let core = GitHub.dig(resources, "core") as? [String: Any], let graphQL = GitHub.dig(resources, "graphql") as? [String: Any],
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

    /// `rules/branches/{branch}`: whether a `required_status_checks` rule applies.
    static func parseRulesRequireChecks(_ data: Data) -> Bool? {
        guard let rules = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else { return nil }
        return rules.contains { $0["type"] as? String == "required_status_checks" }
    }

    /// GraphQL `repository.mergeQueue(branch:)`: whether it isn't null.
    /// A missing field is unreadable, not "none".
    static func parseMergeQueue(_ data: Data) -> Bool? {
        guard let repository = GitHub.dig(object(data), "data", "repository") as? [String: Any],
              let mergeQueue = repository["mergeQueue"]
        else { return nil }
        return !(mergeQueue is NSNull)
    }

    /// Every field asked for must be there: a missing one would read as
    /// "no auto-merge" or "not a draft".
    static func parsePullRequest(_ data: Data) -> PullRequestSnapshot? {
        (GitHub.dig(object(data), "data", "repository", "pullRequest") as? [String: Any]).flatMap(pullRequest)
    }

    /// `pullRequests(headRefName:)`: every node must read in full.
    static func parsePullRequests(_ data: Data) -> [PullRequestSnapshot]? {
        guard let nodes = GitHub.dig(object(data), "data", "repository", "pullRequests", "nodes") as? [[String: Any]] else { return nil }
        let pullRequests = nodes.compactMap(pullRequest)
        return pullRequests.count == nodes.count ? pullRequests : nil
    }

    /// `repository.ref(qualifiedName:)`: its commit, nil when the ref is
    /// `null` (no such branch). A missing field is unreadable.
    static func parseBranchTip(_ data: Data) -> String?? {
        guard let repository = GitHub.dig(object(data), "data", "repository") as? [String: Any],
              let ref = repository["ref"] else { return nil }
        if ref is NSNull { return .some(nil) }
        return GitHub.objectID(GitHub.dig(ref, "target", "oid")).map { .some($0) }
    }

    private static func pullRequest(_ json: [String: Any]) -> PullRequestSnapshot? {
        guard let number = json["number"] as? Int,
              let isDraft = json["isDraft"] as? Bool,
              let isInMergeQueue = json["isInMergeQueue"] as? Bool,
              let autoMerge = json["autoMergeRequest"],
              json["mergeCommit"] != nil,
              let state = GitHub.PullRequestState(json["state"] as? String),
              let headRefName = json["headRefName"] as? String,
              let headOid = GitHub.objectID(json["headRefOid"]),
              let baseRefName = json["baseRefName"] as? String,
              let url = json["url"] as? String
        else { return nil }
        let headRepository = (GitHub.dig(json, "headRepository", "owner", "login") as? String).flatMap { owner in
            (GitHub.dig(json, "headRepository", "name") as? String).map { GitHubRepository(owner: owner, name: $0) }
        }
        let mergeCommit = json["mergeCommit"] as? [String: Any]
        let parents = (GitHub.dig(mergeCommit, "parents", "nodes") as? [[String: Any]] ?? []).compactMap { GitHub.objectID($0["oid"]) }
        return PullRequestSnapshot(
            number: number,
            state: state,
            isDraft: isDraft,
            headRefName: headRefName,
            headOid: headOid,
            baseRefName: baseRefName,
            headRepository: headRepository,
            mergeable: (json["mergeable"] as? String)?.uppercased() ?? "UNKNOWN",
            hasAutoMerge: !(autoMerge is NSNull),
            isInMergeQueue: isInMergeQueue,
            mergeCommit: GitHub.objectID(mergeCommit?["oid"]),
            mergeCommitParents: parents,
            url: url
        )
    }

    /// The details query: a missing field is unreadable, not "no file".
    static func parsePullRequestDetails(_ data: Data) -> PullRequestDetails? {
        guard let json = GitHub.dig(object(data), "data", "repository", "pullRequest") as? [String: Any],
              let title = json["title"] as? String,
              let nodes = GitHub.dig(json, "files", "nodes") as? [[String: Any]],
              let hasMore = GitHub.dig(json, "files", "pageInfo", "hasNextPage") as? Bool
        else { return nil }
        let files = nodes.compactMap { $0["path"] as? String }
        guard files.count == nodes.count else { return nil }
        let count = json["changedFiles"] as? Int
        let allPathsKnown = count == files.count && nodes.allSatisfy { node in
            guard let path = node["path"] as? String, !path.isEmpty, let type = node["changeType"] as? String else { return false }
            // A rename includes its destination only.
            return ["ADDED", "MODIFIED", "DELETED"].contains(type)
        }
        return PullRequestDetails(title: title, files: files, hasMoreFiles: hasMore || (count ?? 0) > PullRequestDetails.maxFiles,
                                  head: GitHub.objectID(json["headRefOid"]), baseBranch: json["baseRefName"] as? String,
                                  allPathsKnown: allPathsKnown)
    }

    /// The checks query: every suite's latest check runs, and the commit
    /// statuses. More than one page of suites or runs can't be judged:
    /// a check left unread could be red.
    static func parseChecks(_ data: Data, sha: String) -> Result<CommitChecks, GitHub.CLI.Failure> {
        guard let repository = GitHub.dig(object(data), "data", "repository") as? [String: Any] else {
            return .failure(.unreadable("checks of \(sha.prefix(7))"))
        }
        guard let commit = repository["object"] as? [String: Any] else {
            return .failure(.refused(status: nil, message: "GitHub doesn’t know commit \(sha.prefix(7))."))
        }
        let unreadable = Result<CommitChecks, GitHub.CLI.Failure>.failure(.unreadable("checks of \(sha.prefix(7))"))
        let tooMany = Result<CommitChecks, GitHub.CLI.Failure>.failure(
            .refused(status: nil, message: "\(sha.prefix(7)) has more checks than Nirux reads.")
        )
        // A connection or page left unread could hold a red check.
        guard let suites = commit["checkSuites"] as? [String: Any], let suiteNodes = suites["nodes"] as? [[String: Any]],
              let moreSuites = GitHub.dig(suites, "pageInfo", "hasNextPage") as? Bool, commit["status"] != nil
        else { return unreadable }
        if moreSuites { return tooMany }
        var checks = CommitChecks()
        for suite in suiteNodes {
            guard let runs = suite["checkRuns"] as? [String: Any], let runNodes = runs["nodes"] as? [[String: Any]],
                  let moreRuns = GitHub.dig(runs, "pageInfo", "hasNextPage") as? Bool
            else { return unreadable }
            if moreRuns { return tooMany }
            let workflowRun = suite["workflowRun"] as? [String: Any]
            let workflow = GitHub.dig(workflowRun, "workflow", "name") as? String
            let workflowID = GitHub.dig(workflowRun, "workflow", "databaseId") as? Int
            for run in runNodes {
                guard let id = run["databaseId"] as? Int, let name = run["name"] as? String,
                      let status = run["status"] as? String
                else { return .failure(.unreadable("a check run of \(sha.prefix(7))")) }
                checks.runs.append(CommitChecks.CheckRun(
                    id: id,
                    name: name,
                    workflow: workflow,
                    workflowID: workflowID,
                    app: GitHub.dig(suite, "app", "slug") as? String,
                    workflowRunID: workflowRun?["databaseId"] as? Int,
                    status: status.uppercased(),
                    conclusion: (run["conclusion"] as? String)?.uppercased()
                ))
            }
        }
        let status = commit["status"] as? [String: Any]
        if status != nil, status?["contexts"] as? [[String: Any]] == nil { return unreadable }
        for context in status?["contexts"] as? [[String: Any]] ?? [] {
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
              let base = GitHub.objectID(json["base_commit"])
        else { return nil }
        return Comparison(status: status, aheadBy: ahead, behindBy: behind, baseCommit: base)
    }

    /// The commit filter's `{sha, committer, parents, tree}`.
    static func parseCommit(_ data: Data) -> CommitInfo? {
        guard let json = object(data), let sha = GitHub.objectID(json["sha"]), let parents = json["parents"] as? [Any] else { return nil }
        let ids = parents.compactMap(GitHub.objectID)
        guard ids.count == parents.count else { return nil }
        return CommitInfo(sha: sha, committerLogin: json["committer"] as? String, parents: ids, tree: GitHub.objectID(json["tree"]))
    }
}
