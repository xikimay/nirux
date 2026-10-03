import Foundation

// MARK: - Client

/// The board's `gh` reads (docs/project-board.md, section 6). Each call
/// runs `gh` and blocks: never on the main thread. `NiruxShellView` holds
/// the client, so tests inject a fake: GitHub's runners have `gh`, and a
/// test must never reach the network.
protocol ProjectBoardGitHub: Sendable {
    /// `gh pr list` of `repository` (`owner/name`) as JSON: the open pull
    /// requests with their checks, or the recently merged ones.
    func pullRequests(repository: String, state: ProjectBoard.PullRequestList) -> Result<Data, ProjectBoard.FetchError>
    /// `gh run list` as JSON: the last push run of `workflow` on `branch`.
    func postMergeRuns(repository: String, workflow: String, branch: String) -> Result<Data, ProjectBoard.FetchError>
}

extension ProjectBoard {
    enum PullRequestList: Sendable {
        /// Up to 100 open pull requests, with their checks.
        case open
        /// The last 30 merged, for the "merged, clean up" rows.
        case merged
    }

    enum FetchError: Error, Equatable, Sendable {
        /// The GitHub CLI isn't where Nirux looks for it.
        case ghMissing
        /// gh failed: its first line of error, or why it didn't run.
        case failed(String)
        /// gh answered with something that isn't the JSON asked for.
        case unreadable

        var message: String {
            switch self {
            case .ghMissing: return "gh isn’t installed: pull requests can’t be read."
            case .failed(let reason): return "gh: \(reason)"
            case .unreadable: return "gh answered with something Nirux can’t read."
            }
        }
    }
}

/// The real client: the GitHub CLI where `PRDetect` finds it (looked up at
/// each call, so a gh installed since launch is found), run through
/// `BoundedProcess` from a folder outside every checkout.
struct GitHubCLIBoardClient: ProjectBoardGitHub {
    /// Where gh is; nil when it isn't installed.
    var findGH: @Sendable () -> String? = { PRDetect.installedGHPath() }
    var timeout: TimeInterval = 30

    static var installed: GitHubCLIBoardClient { GitHubCLIBoardClient() }

    /// Plain JSON whatever the terminal Nirux was started from asked for.
    static let environment = [
        "GH_PROMPT_DISABLED": "1", "GH_NO_UPDATE_NOTIFIER": "1",
        "NO_COLOR": "1", "CLICOLOR_FORCE": "0", "GH_FORCE_TTY": ""
    ]

    static let openFields = [
        "number", "state", "headRefName", "headRefOid", "headRepositoryOwner", "headRepository",
        "baseRefName", "isDraft", "mergeable", "statusCheckRollup", "url"
    ].joined(separator: ",")
    static let mergedFields = [
        "number", "state", "headRefName", "headRefOid", "headRepositoryOwner", "headRepository", "baseRefName", "url"
    ].joined(separator: ",")
    static let runFields = "status,conclusion,headSha,createdAt,updatedAt,url"

    /// `--repo` names the host: a terminal's `GH_HOST` would otherwise
    /// point `owner/name` at another server.
    static func pullRequestArguments(repository: String, state: ProjectBoard.PullRequestList) -> [String] {
        switch state {
        case .open:
            return ["pr", "list", "--repo", "github.com/\(repository)", "--state", "open", "--limit", "100",
                    "--json", openFields]
        case .merged:
            return ["pr", "list", "--repo", "github.com/\(repository)", "--state", "merged", "--limit", "30",
                    "--json", mergedFields]
        }
    }

    static func runArguments(repository: String, workflow: String, branch: String) -> [String] {
        ["run", "list", "--repo", "github.com/\(repository)", "--workflow", workflow, "--branch", branch,
         "--event", "push", "--limit", "1", "--json", runFields]
    }

    func pullRequests(repository: String, state: ProjectBoard.PullRequestList) -> Result<Data, ProjectBoard.FetchError> {
        run(Self.pullRequestArguments(repository: repository, state: state))
    }

    func postMergeRuns(repository: String, workflow: String, branch: String) -> Result<Data, ProjectBoard.FetchError> {
        run(Self.runArguments(repository: repository, workflow: workflow, branch: branch))
    }

    /// gh at `ghPath`, from a folder outside every checkout, with the
    /// neutral environment. Nil when it didn't start or timed out. The
    /// merge queue runs gh through it too.
    static func runGH(_ ghPath: String, arguments: [String], timeout: TimeInterval) -> BoundedProcessResult? {
        BoundedProcess.run(
            executableURL: URL(fileURLWithPath: ghPath),
            arguments: arguments,
            currentDirectoryURL: FileManager.default.temporaryDirectory,
            environment: environment,
            timeout: timeout,
            captureStandardError: true
        )
    }

    private func run(_ arguments: [String]) -> Result<Data, ProjectBoard.FetchError> {
        guard let ghPath = findGH() else { return .failure(.ghMissing) }
        guard let result = Self.runGH(ghPath, arguments: arguments, timeout: timeout) else {
            return .failure(.failed("it couldn’t start, or took longer than \(Int(timeout)) s"))
        }
        guard result.terminationStatus == 0 else {
            let stderr = String(data: result.standardError, encoding: .utf8) ?? ""
            return .failure(.failed(WorktreeCleanup.firstLine(stderr) ?? "exit status \(result.terminationStatus)"))
        }
        return .success(result.standardOutput)
    }
}

// MARK: - Parsing

extension ProjectBoard {
    /// `gh pr list --json …` output. A pull request missing a field it
    /// needs is left out; nil when the output isn't a JSON list.
    static func parsePullRequests(_ data: Data, repository: GitHubRepository) -> [PullRequest]? {
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else { return nil }
        return json.compactMap { pullRequest(from: $0, repository: repository) }
    }

    static func pullRequest(from json: [String: Any], repository: GitHubRepository) -> PullRequest? {
        guard let number = json["number"] as? Int,
              let state = (json["state"] as? String)?.uppercased(),
              let headRefName = json["headRefName"] as? String, !headRefName.isEmpty,
              let headOid = json["headRefOid"] as? String,
              let url = json["url"] as? String
        else { return nil }
        let rollup = json["statusCheckRollup"] as? [[String: Any]] ?? []
        return PullRequest(
            number: number,
            state: state,
            headRefName: headRefName,
            headOid: headOid.lowercased(),
            baseRefName: json["baseRefName"] as? String,
            isDraft: json["isDraft"] as? Bool ?? false,
            mergeable: (json["mergeable"] as? String)?.uppercased(),
            checks: rollup.compactMap(check(from:)),
            url: url,
            // The clean-up's own test: head owner and name, on the PR's host.
            isFromConfiguredRepository: WorktreeCleanup.pullRequest(from: json, headRepository: repository) != nil
        )
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
            case "FAILURE", "CANCELLED", "TIMED_OUT", "ACTION_REQUIRED", "STARTUP_FAILURE", "STALE": result = .failure
            default: result = .pending
            }
        }
        return Check(
            name: name, workflowName: json["workflowName"] as? String, result: result, startedAt: startedAt, url: url
        )
    }

    /// `gh run list --json …` output, newest first; nil when it isn't a
    /// JSON list.
    static func parseRuns(_ data: Data) -> [WorkflowRun]? {
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

// MARK: - What the columns say

extension ProjectBoard {
    /// The checks of a pull request as the Checks column shows them: each
    /// required check by name, then the others folded.
    struct RequiredCheck: Equatable {
        let name: String
        /// Nil: no check of that name ran on the pull request.
        let result: CheckResult?
    }

    struct CheckSummary: Equatable {
        let required: [RequiredCheck]
        let others: [CheckResult]

        var hasPending: Bool {
            required.contains { $0.result == .pending } || others.contains(.pending)
        }

        /// "test ✓ · others: 1 ✗, 2 …"
        var text: String {
            var parts = required.map { check in
                check.result.map { "\(check.name) \(ProjectBoard.glyph($0))" } ?? "\(check.name) missing"
            }
            if !others.isEmpty {
                let failed = others.filter { $0 == .failure }.count
                let pending = others.filter { $0 == .pending }.count
                var counts: [String] = []
                if failed > 0 { counts.append("\(failed) ✗") }
                if pending > 0 { counts.append("\(pending) ●") }
                parts.append(counts.isEmpty ? "others ✓" : "others: " + counts.joined(separator: ", "))
            }
            return parts.joined(separator: " · ")
        }

        /// The worst result shown, for the text's color.
        var worst: CheckResult? {
            let results = required.map { $0.result ?? .pending } + others
            return results.max()
        }
    }

    static func glyph(_ result: CheckResult) -> String {
        switch result {
        case .success: return "✓"
        case .failure: return "✗"
        case .pending: return "●"
        case .neutral: return "neutral"
        case .skipped: return "skipped"
        }
    }

    /// Only the latest run of each check counts: a rerun replaces the run
    /// it reran. Several matching a required name (jobs of several
    /// workflows) show the worst of them.
    static func checkSummary(_ checks: [Check], required: [String]) -> CheckSummary {
        let current = latest(checks)
        return CheckSummary(
            required: required.map { name in
                RequiredCheck(name: name, result: current.filter { $0.matches(name) }.map(\.result).max())
            },
            others: current.filter { check in !required.contains { check.matches($0) } }.map(\.result)
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
        guard let startedAt = check.startedAt, !startedAt.isEmpty, !startedAt.hasPrefix("0001-") else { return "~" }
        return startedAt
    }

    /// "#52 open", "#52 draft", "#52 conflict", "#52 draft · conflict",
    /// "#52 merged". A base other than the configured one is named ("→ dev").
    static func pullRequestText(_ pullRequest: PullRequest, baseBranch: String?) -> String {
        var text = "#\(pullRequest.number) "
        if pullRequest.isOpen {
            switch (pullRequest.isDraft, pullRequest.isConflicting) {
            case (true, true): text += "draft · conflict"
            case (true, false): text += "draft"
            case (false, true): text += "conflict"
            case (false, false): text += "open"
            }
        } else {
            text += pullRequest.state.lowercased()
        }
        if pullRequest.isOpen, let base = pullRequest.baseRefName, let baseBranch, base != baseBranch {
            text += " → \(base)"
        }
        return text
    }

    /// "nightly: success 20:27, 60e0ff2": the workflow file's name, the
    /// run's conclusion (else its status) and time, and its commit.
    static func runSummary(_ run: WorkflowRun?, workflow: String, now: Date, timeZone: TimeZone = .current) -> String {
        let label = (workflow as NSString).deletingPathExtension
        guard let run else { return "\(label): no run yet" }
        let completed = run.status == "completed"
        let outcome = completed
            ? (run.conclusion ?? "completed")
            : run.status.replacingOccurrences(of: "_", with: " ")
        var parts = [outcome]
        if let date = completed ? (run.updatedAt ?? run.createdAt) : (run.createdAt ?? run.updatedAt) {
            parts.append(clockTime(date, now: now, timeZone: timeZone))
        }
        let head = parts.joined(separator: " ")
        return "\(label): \(head), \(WorktreeCleanup.short(run.headSha))"
    }

    /// "20:27" today, "26 Sep 20:27" another day.
    /// Built from calendar fields rather than a DateFormatter: it runs at
    /// each render.
    static func clockTime(_ date: Date, now: Date, timeZone: TimeZone = .current) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let parts = calendar.dateComponents([.day, .month, .hour, .minute], from: date)
        let time = String(format: "%02d:%02d", parts.hour ?? 0, parts.minute ?? 0)
        guard !calendar.isDate(date, inSameDayAs: now), let day = parts.day, let month = parts.month,
              let name = monthNames[safe: month - 1]
        else { return time }
        return "\(day) \(name) \(time)"
    }

    private static let monthNames = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
}
