import Foundation

/// A workspace pull request whose CI turned red, and the two actions on it
/// (docs/ci-failure-actions.md). Both work on GitHub Actions runs of the
/// pull request's own repository, parsed out of the red checks' URLs:
/// anyone who can post a check chooses its URL, and what GitHub returns is
/// never typed into an agent or passed to `gh` as is.
enum CIFailure {
    struct Run: Equatable, Sendable {
        /// `host/owner/name`, as `gh --repo` takes it.
        let repository: String
        let id: Int
    }

    /// The red checks of an open pull request, once their run is over: a
    /// run with a job still going can be neither rerun nor read.
    static func redChecks(_ pullRequest: PRInfo) -> [ProjectBoard.Check] {
        guard pullRequest.state.uppercased() == "OPEN" else { return [] }
        let running = Set(pullRequest.checks.filter { $0.result == .pending }.compactMap(run(of:)).map(\.id))
        return pullRequest.checks.filter { check in
            check.result == .failure && !(run(of: check).map { running.contains($0.id) } ?? false)
        }
    }

    /// The Actions runs of the red checks in the pull request's repository,
    /// each once, in order.
    static func runs(_ pullRequest: PRInfo) -> [Run] {
        guard let own = parse(pullRequest.url), own.rest.first == "pull" else { return [] }
        var runs: [Run] = []
        for run in redChecks(pullRequest).compactMap(run(of:))
        where run.repository.lowercased() == own.repository.lowercased() && !runs.contains(run) {
            runs.append(run)
        }
        return runs
    }

    /// A red check is reported once: a rerun or a new status starts again.
    static func reportKey(_ check: ProjectBoard.Check) -> String {
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
        let commands = runs.map { "`gh run view \($0.id) --repo \($0.repository) --log-failed`" }
        return "CI failed on PR #\(pullRequest). Run \(commands.joined(separator: " and ")), then tell me why it failed."
    }

    static func rerunArguments(_ run: Run) -> [String] {
        ["run", "rerun", "\(run.id)", "--repo", run.repository, "--failed"]
    }

    /// `gh run rerun --failed`: nil once GitHub accepted it, else why not.
    /// Runs gh: off the main thread.
    static func rerun(_ run: Run) -> String? {
        guard let ghPath = PRDetect.installedGHPath() else { return ProjectBoard.FetchError.ghMissing.message }
        guard let result = GitHubCLIBoardClient.runGH(ghPath, arguments: rerunArguments(run), timeout: 30)
        else { return "Run \(run.id): gh couldn’t start, or took longer than 30 s." }
        guard result.terminationStatus != 0 else { return nil }
        let stderr = String(data: result.standardError, encoding: .utf8) ?? ""
        return "Run \(run.id): " + (WorktreeCleanup.firstLine(stderr) ?? "exit status \(result.terminationStatus)")
    }

    private static func run(of check: ProjectBoard.Check) -> Run? {
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
