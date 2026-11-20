import Foundation

/// A workspace pull request whose CI turned red, and the two actions on it
/// (docs/design/ci-failure-actions.md). Both work on GitHub Actions runs of the
/// pull request's own repository, parsed out of the red checks' URLs:
/// anyone who can post a check chooses its URL, and what GitHub returns is
/// never typed into an agent or passed to `gh` as is.
enum CIFailure {
    struct Run: Hashable, Sendable {
        /// `host/owner/name`, as `gh --repo` takes it.
        let repository: String
        let id: Int
    }

    /// The red checks of an open pull request, once their run is over: a
    /// run with a job still going can be neither rerun nor read.
    static func redChecks(_ pullRequest: PRInfo) -> [GitHub.Check] {
        guard pullRequest.state == .open else { return [] }
        let running = Set(pullRequest.checks.filter { $0.result == .pending }.compactMap(run(of:)).map(\.id))
        return pullRequest.checks.filter { check in
            check.result == .failure && !(run(of: check).map { running.contains($0.id) } ?? false)
        }
    }

    /// The Actions runs of the red checks in the pull request's repository,
    /// each once, in order.
    static func runs(_ pullRequest: PRInfo) -> [Run] {
        runs(of: redChecks(pullRequest), in: pullRequest)
    }

    /// The Actions runs of `checks` in the pull request's repository, each
    /// once, in order.
    static func runs(of checks: [GitHub.Check], in pullRequest: PRInfo) -> [Run] {
        guard let own = parse(pullRequest.url), own.rest.first == "pull" else { return [] }
        var runs: [Run] = []
        for run in checks.compactMap(run(of:))
        where run.repository.lowercased() == own.repository.lowercased() && !runs.contains(run) {
            runs.append(run)
        }
        return runs
    }

    /// The red checks of each Actions run of the pull request's repository,
    /// runs in order. Nil when a red check is anything else (a commit
    /// status, another repository's run) or the pull request has none:
    /// what can't be read can't be called flaky (see `CITriage`).
    static func redChecksByRun(_ pullRequest: PRInfo) -> [(run: Run, checks: [GitHub.Check])]? {
        guard let own = parse(pullRequest.url), own.rest.first == "pull" else { return nil }
        var byRun: [(run: Run, checks: [GitHub.Check])] = []
        for check in redChecks(pullRequest) {
            guard let run = run(of: check), run.repository.lowercased() == own.repository.lowercased() else { return nil }
            if let index = byRun.firstIndex(where: { $0.run == run }) {
                byRun[index].checks.append(check)
            } else {
                byRun.append((run, [check]))
            }
        }
        return byRun.isEmpty ? nil : byRun
    }

    /// Every check of the pull request that is an Actions run of its
    /// repository, with its name and result: what tells a run that passes
    /// now.
    static func ownRunResults(_ pullRequest: PRInfo) -> [(run: Run, name: String, result: GitHub.CheckResult)] {
        guard let own = parse(pullRequest.url), own.rest.first == "pull" else { return [] }
        return pullRequest.checks.compactMap { check in
            guard let run = run(of: check), run.repository.lowercased() == own.repository.lowercased() else { return nil }
            return (run, check.name, check.result)
        }
    }

    /// A red check is reported once: a rerun or a new status starts again.
    static func reportKey(_ check: GitHub.Check) -> String {
        [check.workflowName ?? "", check.name, check.startedAt ?? "", check.url ?? ""].joined(separator: "\u{0}")
    }

    /// `https://<host>/<owner>/<name>/actions/runs/<id>[/job/<job>]`.
    static func run(checkURL: String) -> Run? {
        guard let parsed = parse(checkURL), parsed.rest.count >= 3, parsed.rest[0] == "actions", parsed.rest[1] == "runs",
              parsed.rest[2].allSatisfy({ $0.isASCII && $0.isNumber }), let id = Int(parsed.rest[2])
        else { return nil }
        return Run(repository: parsed.repository, id: id)
    }

    static func whyFailedPrompt(pullRequest: Int, runs: [Run]) -> String {
        "CI failed on PR #\(pullRequest). Run \(logCommands(runs)), then tell me why it failed."
    }

    /// Nirux's own round (`PRFollowUp`): the fix too, or nothing pushed
    /// for a failure the branch didn't cause.
    static func fixPrompt(pullRequest: Int, runs: [Run]) -> String {
        "CI failed on PR #\(pullRequest). Run \(logCommands(runs)), find why it failed, fix it, run the checks, "
            + "commit and push. If this branch didn't cause it, say so and push nothing."
    }

    private static func logCommands(_ runs: [Run]) -> String {
        runs.map { "`gh run view \($0.id) --repo \($0.repository) --log-failed`" }.joined(separator: " and ")
    }

    static func rerunArguments(_ run: Run) -> [String] {
        ["run", "rerun", "\(run.id)", "--repo", run.repository, "--failed"]
    }

    /// `gh run rerun --failed`: nil once GitHub accepted it, else why not.
    /// Runs gh: off the main thread.
    static func rerun(_ run: Run, gh: GitHub.CLI.Runner = GitHub.CLI.installed) -> String? {
        switch gh(.init(rerunArguments(run))).flatMap(\.result) {
        case .success: return nil
        case .failure(.ghMissing): return "\(GitHub.CLI.missing): run \(run.id) can’t be rerun."
        case .failure(let failure): return "Run \(run.id): \(failure.message)"
        }
    }

    private static func run(of check: GitHub.Check) -> Run? {
        check.url.flatMap(run(checkURL:))
    }

    /// `host/owner/name` and the rest of the path of
    /// `https://<host>/<owner>/<name>/…`, from plain ASCII parts only.
    private static func parse(_ string: String) -> (repository: String, rest: [String])? {
        guard let components = URLComponents(string: string), components.scheme == "https",
              let host = components.host?.lowercased(), host.allSatisfy(isHostCharacter)
        else { return nil }
        let path = components.path.split(separator: "/", omittingEmptySubsequences: false).dropFirst().map(String.init)
        guard path.count >= 2,
              path[0 ..< 2].allSatisfy({ $0.allSatisfy(isNameCharacter) && !$0.allSatisfy { $0 == "." } })
        else { return nil }
        return ("\(host)/\(path[0])/\(path[1])", Array(path.dropFirst(2)))
    }

    private static func isHostCharacter(_ character: Character) -> Bool {
        character.isASCII && (character.isLetter || character.isNumber || character == "." || character == "-")
    }

    private static func isNameCharacter(_ character: Character) -> Bool {
        character.isASCII && (character.isLetter || character.isNumber || "._-".contains(character))
    }
}
