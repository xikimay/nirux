import Foundation

enum PRDetect {
    private struct GitHubCLIContext {
        let executablePath: String
        let repositoryRoot: String
        let timeout: TimeInterval
    }

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
        startFolder: String?,
        completion: @escaping @MainActor @Sendable (FetchResult) -> Void
    ) {
        DispatchQueue.global(qos: .utility).async {
            let result = fetch(branch: branch, cwd: cwd, startFolder: startFolder)
            DispatchQueue.main.async { completion(result) }
        }
    }

    private static func fetch(branch: String, cwd: String, startFolder: String?) -> FetchResult {
        guard let ghPath = GitHub.CLI.installedPath(),
              let context = GitDetect.context(at: cwd, startFolder: startFolder),
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
        let cliContext = GitHubCLIContext(
            executablePath: ghPath,
            repositoryRoot: context.identity.repositoryRoot,
            timeout: timeout
        )
        guard let openCandidates = candidates(
            branch: branch,
            state: "open",
            limit: Int.max,
            cliContext: cliContext
        ) else { return .failure }

        let sortedOpenCandidates = openCandidates
            .filter { GitHub.PullRequestState($0["state"] as? String) == .open }
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
            cliContext: cliContext
        ) else { return .failure }
        let matchingTerminalCandidates = terminalCandidates
            .filter {
                guard let state = GitHub.PullRequestState($0["state"] as? String) else { return false }
                return (state == .merged || state == .closed)
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
            info: terminalCandidate.flatMap { pullRequestInfo(from: $0) }
        )
    }

    private static func candidates(
        branch: String,
        state: String,
        limit: Int,
        cliContext: GitHubCLIContext
    ) -> [[String: Any]]? {
        let fields = [
            "number", "state", "headRefOid", "headRepositoryOwner",
            "headRepository", "isDraft", "statusCheckRollup",
            "reviewDecision", "mergeable", "url", "additions",
            "deletions", "changedFiles", "baseRefName", "autoMergeRequest"
        ].joined(separator: ",")
        let call = GitHub.CLI.Call(
            ["pr", "list", "--head", branch, "--state", state, "--json", fields, "--limit", String(limit)],
            in: URL(fileURLWithPath: cliContext.repositoryRoot), timeout: cliContext.timeout
        )
        let output = try? GitHub.CLI.run(call, gh: cliContext.executablePath).flatMap(\.result).get()
        return output.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [[String: Any]] }
    }

    private static func pullRequestNumberDescending(
        _ lhs: [String: Any],
        _ rhs: [String: Any]
    ) -> Bool {
        (lhs["number"] as? Int ?? 0) > (rhs["number"] as? Int ?? 0)
    }

    static func pullRequestInfo(from candidate: [String: Any]) -> PRInfo? {
        guard let state = GitHub.PullRequestState(candidate["state"] as? String) else { return nil }
        let rollup = candidate["statusCheckRollup"] as? [[String: Any]] ?? []
        let conclusions = rollup.compactMap { $0["conclusion"] as? String }
        // One running check keeps the rollup pending: a CheckRun that has
        // not completed (empty conclusion) or a pending commit status. A
        // mix of finished and running checks is not a success yet.
        let hasRunningCheck = rollup.contains { check in
            if let state = check["state"] as? String {
                return ["PENDING", "EXPECTED"].contains(state.uppercased())
            }
            if let status = check["status"] as? String, status.uppercased() != "COMPLETED" {
                return true
            }
            return (check["conclusion"] as? String)?.isEmpty ?? false
        }
        let allChecksPending = !rollup.isEmpty && conclusions.allSatisfy({ $0.isEmpty })
        let checks = GitHub.latest(rollup.compactMap(GitHub.check(from:)))
        let ciStatus: String?
        if checks.contains(where: { $0.result == .failure }) {
            ciStatus = "FAILURE"
        } else if conclusions.contains("PENDING") || allChecksPending || hasRunningCheck {
            ciStatus = "PENDING"
        } else if !conclusions.isEmpty {
            ciStatus = "SUCCESS"
        } else {
            ciStatus = nil
        }

        return PRInfo(
            number: candidate["number"] as? Int ?? 0,
            state: state,
            isDraft: candidate["isDraft"] as? Bool ?? false,
            ciStatus: ciStatus,
            checks: checks,
            reviewDecision: candidate["reviewDecision"] as? String,
            mergeable: candidate["mergeable"] as? String,
            url: candidate["url"] as? String ?? "",
            additions: candidate["additions"] as? Int,
            deletions: candidate["deletions"] as? Int,
            changedFiles: candidate["changedFiles"] as? Int,
            headRefOid: (candidate["headRefOid"] as? String)?.lowercased(),
            baseRefName: candidate["baseRefName"] as? String,
            autoMerges: candidate["autoMergeRequest"] is [String: Any]
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
        startFolder: String?,
        completion: @escaping @MainActor @Sendable (DiffStatsResult) -> Void
    ) {
        DispatchQueue.global(qos: .utility).async {
            let result = diffStats(cwd: cwd, startFolder: startFolder)
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
        startFolder: String? = nil,
        gitPath: String = "/usr/bin/git"
    ) -> DiffStatsResult {
        let context: GitContext
        switch GitDetect.observe(at: cwd, startFolder: startFolder, gitPath: gitPath) {
        case .observed(let observedContext):
            context = observedContext
        case .notRepository:
            return .notApplicable
        case .failure:
            return .failure
        }
        guard let output = gitOutput(
            arguments: noIndexRefresh + ["diff", "--shortstat"],
            cwd: cwd,
            gitPath: gitPath
        ) else { return .failure }
        let stats = output.trimmingCharacters(in: .whitespacesAndNewlines)
        return .observed(context: context, stats: stats.isEmpty ? nil : stats)
    }

    private static func diffPaths(cwd: String) -> [String] {
        // User-initiated: unlike the background shortstat, this may refresh
        // the index, or it would list touched-but-unchanged files.
        guard let output = gitOutput(arguments: ["diff", "--name-only"], cwd: cwd) else { return [] }
        return output
            .split(separator: "\n")
            .map(String.init)
            .filter { !$0.isEmpty }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    /// `git diff` refreshes and rewrites `.git/index` even under
    /// GIT_OPTIONAL_LOCKS=0. `--shortstat` still leaves stat-only changes
    /// out without the refresh (`--name-only` would not).
    private static let noIndexRefresh = ["-c", "diff.autoRefreshIndex=false"]

    private static func gitOutput(
        arguments: [String],
        cwd: String,
        gitPath: String = "/usr/bin/git"
    ) -> String? {
        guard let result = BoundedProcess.run(
            executableURL: URL(fileURLWithPath: gitPath),
            arguments: arguments,
            currentDirectoryURL: URL(fileURLWithPath: cwd),
            environment: GitDetect.readOnlyEnvironment
        ), result.terminationStatus == 0 else { return nil }
        return String(data: result.standardOutput, encoding: .utf8) ?? ""
    }
}
