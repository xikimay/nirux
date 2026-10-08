import Foundation
import os

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
        completion: @escaping @MainActor @Sendable (FetchResult) -> Void
    ) {
        DispatchQueue.global(qos: .utility).async {
            let result = fetch(branch: branch, cwd: cwd)
            DispatchQueue.main.async { completion(result) }
        }
    }

    /// Where the GitHub CLI is looked for; nil when it isn't there. The
    /// Project Board finds it the same way.
    static func installedGHPath() -> String? {
        ["/opt/homebrew/bin/gh", "/usr/local/bin/gh"].first { FileManager.default.fileExists(atPath: $0) }
    }

    private static func fetch(branch: String, cwd: String) -> FetchResult {
        guard let ghPath = installedGHPath(),
              let context = GitDetect.context(at: cwd),
              context.branch == branch
        else { return .failure }

        let result = fetch(
            branch: branch,
            ghPath: ghPath,
            context: context
        )
        guard case .success(let context, var info?) = result,
              let host = context.upstreamRepository?.host
        else { return result }
        // The gh user unknown: no mark, rather than one on their own branches.
        if let author = info.otherAuthor, viewerLogin(ghPath: ghPath, host: host) ?? author == author {
            info.otherAuthor = nil
        }
        return .success(context: context, info: info)
    }

    private static let viewerLogins = OSAllocatedUnfairLock(initialState: [String: String]())

    /// The gh user on `host`, asked once per launch; nil while gh can't say.
    private static func viewerLogin(ghPath: String, host: String) -> String? {
        if let login = viewerLogins.withLock({ $0[host] }) { return login }
        guard let result = GitHubCLIBoardClient.runGH(
            ghPath, arguments: ["api", "user", "--hostname", host, "--jq", ".login"], timeout: 30
        ), result.terminationStatus == 0,
              let login = String(data: result.standardOutput, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !login.isEmpty
        else { return nil }
        viewerLogins.withLock { $0[host] = login }
        return login
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
            cliContext: cliContext
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
        cliContext: GitHubCLIContext
    ) -> [[String: Any]]? {
        let fields = [
            "number", "state", "headRefOid", "headRepositoryOwner",
            "headRepository", "isDraft", "statusCheckRollup",
            "reviewDecision", "mergeable", "url", "additions",
            "deletions", "changedFiles", "title", "author"
        ].joined(separator: ",")
        let result = BoundedProcess.run(
            executableURL: URL(fileURLWithPath: cliContext.executablePath),
            arguments: ["pr", "list", "--head", branch,
                        "--state", state,
                        "--json", fields,
                        "--limit", String(limit)],
            currentDirectoryURL: URL(fileURLWithPath: cliContext.repositoryRoot),
            timeout: cliContext.timeout
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

    static func pullRequestInfo(from candidate: [String: Any]) -> PRInfo {
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
        // Red as the Project Board defines it (docs/project-board.md,
        // section 3.2): only the latest run of each check counts.
        let checks = ProjectBoard.latest(rollup.compactMap(ProjectBoard.check(from:)))
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
            state: candidate["state"] as? String ?? "",
            isDraft: candidate["isDraft"] as? Bool ?? false,
            ciStatus: ciStatus,
            checks: checks,
            reviewDecision: candidate["reviewDecision"] as? String,
            mergeable: candidate["mergeable"] as? String,
            url: candidate["url"] as? String ?? "",
            additions: candidate["additions"] as? Int,
            deletions: candidate["deletions"] as? Int,
            changedFiles: candidate["changedFiles"] as? Int,
            title: candidate["title"] as? String,
            otherAuthor: (candidate["author"] as? [String: Any])?["login"] as? String
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
        // A mission's handover is the agent's note, not the work: a repo
        // that tracks one would show it changed in every new worktree.
        let handovers = BranchReview.Handover.names.map { ":(top,exclude)\($0)" }
        guard let output = gitOutput(
            arguments: noIndexRefresh + ["diff", "--shortstat", "--"] + handovers,
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
