import Foundation

enum PRDetect {
    enum FetchResult: Sendable {
        case success(context: GitContext, info: PRInfo?)
        case failure
    }

    enum DiffStatsResult: Equatable, Sendable {
        case observed(context: GitContext, stats: String?)
        case notApplicable
        case failure
    }

    /// Inactive workspaces are archival UI. They keep their last-known PR
    /// metadata but must never spend GitHub GraphQL quota in the background.
    static func shouldRefresh(isInactive: Bool, branch: String?) -> Bool {
        guard !isInactive,
              let branch = branch?.trimmingCharacters(in: .whitespacesAndNewlines)
        else { return false }
        return !branch.isEmpty
    }

    /// Fetch PR info for the given branch. Runs `gh` CLI.
    static func fetchAsync(
        branch: String,
        cwd: String,
        completion: @escaping @MainActor @Sendable (FetchResult) -> Void
    ) {
        DispatchQueue.global(qos: .utility).async {
            let result = fetch(branch: branch, cwd: cwd)
            DispatchQueue.main.async { completion(result) }
        }
    }

    private static func fetch(branch: String, cwd: String) -> FetchResult {
        let ghPath = ["/opt/homebrew/bin/gh", "/usr/local/bin/gh"]
            .first { FileManager.default.fileExists(atPath: $0) }
        guard let ghPath,
              let context = GitDetect.context(at: cwd),
              context.branch == branch
        else { return .failure }

        return fetch(
            branch: branch,
            ghPath: ghPath,
            context: context
        )
    }

    static func fetch(
        branch: String,
        ghPath: String,
        context: GitContext,
        timeout: TimeInterval = 30
    ) -> FetchResult {
        guard let upstreamRepository = context.upstreamRepository else { return .failure }
        guard let openCandidates = candidates(
            branch: branch,
            state: "open",
            limit: Int.max,
            ghPath: ghPath,
            repositoryRoot: context.identity.repositoryRoot,
            timeout: timeout
        ) else { return .failure }

        let sortedOpenCandidates = openCandidates
            .filter { ($0["state"] as? String)?.uppercased() == "OPEN" }
            .sorted(by: pullRequestNumberDescending)
        if !sortedOpenCandidates.isEmpty {
            if let openCandidate = sortedOpenCandidates.first(where: {
                repository(for: $0) == upstreamRepository
            }) {
                return .success(context: context, info: pullRequestInfo(from: openCandidate))
            }
            guard sortedOpenCandidates.allSatisfy({ repository(for: $0) != nil })
            else { return .failure }
        }

        guard !context.identity.isDirty else {
            return .success(context: context, info: nil)
        }
        guard let head = context.identity.head else {
            return .success(context: context, info: nil)
        }

        guard let terminalCandidates = candidates(
            branch: branch,
            state: "all",
            limit: Int.max,
            ghPath: ghPath,
            repositoryRoot: context.identity.repositoryRoot,
            timeout: timeout
        ) else { return .failure }
        let matchingTerminalCandidates = terminalCandidates
            .filter {
                guard let state = ($0["state"] as? String)?.uppercased() else { return false }
                return (state == "MERGED" || state == "CLOSED")
                    && ($0["headRefOid"] as? String) == head
            }
        guard matchingTerminalCandidates.allSatisfy({ repository(for: $0) != nil })
        else { return .failure }
        let terminalCandidate = matchingTerminalCandidates
            .filter { repository(for: $0) == upstreamRepository }
            .sorted(by: pullRequestNumberDescending)
            .first
        return .success(
            context: context,
            info: terminalCandidate.map { pullRequestInfo(from: $0) }
        )
    }

    private static func candidates(
        branch: String,
        state: String,
        limit: Int,
        ghPath: String,
        repositoryRoot: String,
        timeout: TimeInterval
    ) -> [[String: Any]]? {
        let result = BoundedProcess.run(
            executableURL: URL(fileURLWithPath: ghPath),
            arguments: ["pr", "list", "--head", branch,
                        "--state", state,
                        "--json", "number,state,headRefOid,headRepositoryOwner,headRepository,isDraft,statusCheckRollup,reviewDecision,mergeable,url,additions,deletions,changedFiles",
                        "--limit", String(limit)],
            currentDirectoryURL: URL(fileURLWithPath: repositoryRoot),
            timeout: timeout
        )
        guard let result, result.terminationStatus == 0 else { return nil }
        return try? JSONSerialization.jsonObject(
            with: result.standardOutput
        ) as? [[String: Any]]
    }

    private static func pullRequestNumberDescending(
        _ lhs: [String: Any],
        _ rhs: [String: Any]
    ) -> Bool {
        (lhs["number"] as? Int ?? 0) > (rhs["number"] as? Int ?? 0)
    }

    private static func pullRequestInfo(from candidate: [String: Any]) -> PRInfo {
        let rollup = candidate["statusCheckRollup"] as? [[String: Any]] ?? []
        let conclusions = rollup.compactMap { $0["conclusion"] as? String }
        let allChecksPending = !rollup.isEmpty && conclusions.allSatisfy({ $0.isEmpty })
        let ciStatus: String?
        let failedCheckUrl: String?
        if conclusions.contains("FAILURE") {
            ciStatus = "FAILURE"
            failedCheckUrl = rollup
                .first { ($0["conclusion"] as? String) == "FAILURE" }
                .flatMap { $0["detailsUrl"] as? String }
        } else if conclusions.contains("PENDING") || allChecksPending {
            ciStatus = "PENDING"
            failedCheckUrl = nil
        } else if !conclusions.isEmpty {
            ciStatus = "SUCCESS"
            failedCheckUrl = nil
        } else {
            ciStatus = nil
            failedCheckUrl = nil
        }

        return PRInfo(
            number: candidate["number"] as? Int ?? 0,
            state: candidate["state"] as? String ?? "",
            isDraft: candidate["isDraft"] as? Bool ?? false,
            ciStatus: ciStatus,
            failedCheckUrl: failedCheckUrl,
            reviewDecision: candidate["reviewDecision"] as? String,
            mergeable: candidate["mergeable"] as? String,
            url: candidate["url"] as? String ?? "",
            additions: candidate["additions"] as? Int,
            deletions: candidate["deletions"] as? Int,
            changedFiles: candidate["changedFiles"] as? Int
        )
    }

    private static func repository(for candidate: [String: Any]) -> GitHubRepository? {
        guard let owner = candidate["headRepositoryOwner"] as? [String: Any],
              let login = owner["login"] as? String,
              let repository = candidate["headRepository"] as? [String: Any],
              let name = repository["name"] as? String,
              let url = candidate["url"] as? String
        else { return nil }
        return GitHubRepository(repositoryURL: url, owner: login, name: name)
    }

    /// Get diff stats via git
    static func diffStatsAsync(
        cwd: String,
        completion: @escaping @MainActor @Sendable (DiffStatsResult) -> Void
    ) {
        DispatchQueue.global(qos: .utility).async {
            let result = diffStats(cwd: cwd)
            DispatchQueue.main.async { completion(result) }
        }
    }

    static func diffPathsAsync(cwd: String, completion: @escaping @MainActor @Sendable ([String]) -> Void) {
        DispatchQueue.global(qos: .utility).async {
            let result = diffPaths(cwd: cwd)
            DispatchQueue.main.async { completion(result) }
        }
    }

    static func diffStats(
        cwd: String,
        gitPath: String = "/usr/bin/git"
    ) -> DiffStatsResult {
        let context: GitContext
        switch GitDetect.observe(at: cwd, gitPath: gitPath) {
        case .observed(let observedContext):
            context = observedContext
        case .notRepository:
            return .notApplicable
        case .failure:
            return .failure
        }
        guard let output = gitOutput(
            arguments: ["diff", "--shortstat"],
            cwd: cwd,
            gitPath: gitPath
        ) else { return .failure }
        let stats = output.trimmingCharacters(in: .whitespacesAndNewlines)
        return .observed(context: context, stats: stats.isEmpty ? nil : stats)
    }

    private static func diffPaths(cwd: String) -> [String] {
        guard let output = gitOutput(arguments: ["diff", "--name-only"], cwd: cwd) else { return [] }
        return output
            .split(separator: "\n")
            .map(String.init)
            .filter { !$0.isEmpty }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    private static func gitOutput(
        arguments: [String],
        cwd: String,
        gitPath: String = "/usr/bin/git"
    ) -> String? {
        guard let result = BoundedProcess.run(
            executableURL: URL(fileURLWithPath: gitPath),
            arguments: arguments,
            currentDirectoryURL: URL(fileURLWithPath: cwd)
        ), result.terminationStatus == 0 else { return nil }
        return String(data: result.standardOutput, encoding: .utf8) ?? ""
    }
}
