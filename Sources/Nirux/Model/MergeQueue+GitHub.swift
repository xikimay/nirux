import Foundation
import Security

// MARK: - Client

/// The merge queue's `gh` calls (docs/project-board.md, section 3): reads
/// by commit, and the three mutations. Separate from the board's client,
/// which only reads. Each call runs `gh` and blocks: never on the main
/// thread. The shell holds the client, so tests inject a fake: GitHub's
/// runners have `gh`, and a test must never reach the network.
protocol MergeQueueGitHub: Sendable {
    /// Mutations go to the journal only (a dev build).
    var isDryRun: Bool { get }
    /// One GitHub read. `.local` isn't one: the driver reads it.
    func read(_ read: MergeQueue.Read, settings: BoardConfig.QueueSettings) -> Result<MergeQueue.ReadResult, MergeQueue.ClientError>
    /// Sent once: the engine never sends a mutation again.
    func mutate(_ mutation: MergeQueue.Mutation, settings: BoardConfig.QueueSettings) -> MergeQueue.MutationResult
    /// What a mutation runs, for the journal.
    func commandLine(_ mutation: MergeQueue.Mutation, settings: BoardConfig.QueueSettings) -> String
}

extension MergeQueue {
    enum ClientError: Error, Equatable, Sendable {
        /// The GitHub CLI isn't where Nirux looks for it.
        case ghMissing
        case notSignedIn(String)
        /// The primary rate limit, until `resetAt` when `rate_limit` says.
        case rateLimited(resetAt: Date?)
        case secondaryRateLimit(String)
        /// GitHub answered with an error: its HTTP status (none for a
        /// GraphQL error) and message.
        case refused(status: Int?, message: String)
        /// gh didn't start or timed out, GitHub couldn't be reached, or a
        /// server error: the call may have gone through.
        case noAnswer(String)
        /// gh exited 0 with output Nirux can't read.
        case unreadable(String)
    }

    /// Whether this build may change GitHub: Nirux signed with a Developer
    /// ID (the nightly) and run on the real state, or any build with
    /// `NIRUX_MERGE_QUEUE_LIVE=1`. Agents build and click through Nirux
    /// inside Nirux: their builds are signed ad hoc, wherever they are
    /// copied and however they are opened (LaunchServices passes no
    /// variable), and they run on a state of their own (`NIRUX_STATE_DIR`,
    /// which the installed app never sets).
    static func isLive(environment: [String: String], isSignedForRelease: Bool) -> Bool {
        if environment["NIRUX_MERGE_QUEUE_LIVE"] == "1" { return true }
        return isSignedForRelease && (environment["NIRUX_STATE_DIR"] ?? "").isEmpty
    }

    /// Whether this process is signed with a Developer ID Application
    /// certificate, and its signature holds. The nightly's is; `swift build`
    /// and `scripts/bundle.sh` sign ad hoc unless given an identity.
    static func isSignedWithDeveloperID() -> Bool {
        let developerID = "anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] exists"
            + " and certificate leaf[field.1.2.840.113635.100.6.1.13] exists"
        var code: SecCode?
        var requirement: SecRequirement?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
              SecRequirementCreateWithString(developerID as CFString, [], &requirement) == errSecSuccess, let requirement
        else { return false }
        return SecCodeCheckValidity(code, [], requirement) == errSecSuccess
    }

    /// The client this build runs its queues with: `live`, or a dry run of
    /// it that reads GitHub and journals the mutations it would make.
    static func client(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        isSignedForRelease: @autoclosure () -> Bool = isSignedWithDeveloperID(),
        live: @autoclosure () -> any MergeQueueGitHub = GitHubCLIQueueClient.installed
    ) -> any MergeQueueGitHub {
        let client = live()
        return isLive(environment: environment, isSignedForRelease: isSignedForRelease())
            ? client : DryRunQueueClient(wrapped: client)
    }
}

/// Reads through `wrapped`; mutations are never sent, only described.
struct DryRunQueueClient: MergeQueueGitHub {
    let wrapped: any MergeQueueGitHub

    var isDryRun: Bool { true }

    func read(_ read: MergeQueue.Read, settings: BoardConfig.QueueSettings) -> Result<MergeQueue.ReadResult, MergeQueue.ClientError> {
        wrapped.read(read, settings: settings)
    }

    func mutate(_ mutation: MergeQueue.Mutation, settings: BoardConfig.QueueSettings) -> MergeQueue.MutationResult {
        .dryRun(wrapped.commandLine(mutation, settings: settings))
    }

    func commandLine(_ mutation: MergeQueue.Mutation, settings: BoardConfig.QueueSettings) -> String {
        wrapped.commandLine(mutation, settings: settings)
    }
}

/// The real client: `gh` run by `run`, from a folder outside every
/// checkout, with the board's neutral environment. Every call names
/// github.com (`--repo github.com/…`, `--hostname github.com`): a
/// terminal's `GH_HOST` would otherwise send it to another server.
struct GitHubCLIQueueClient: MergeQueueGitHub {
    struct Output: Sendable {
        let status: Int32
        let standardOutput: Data
        let standardError: Data
    }

    /// Runs gh with these arguments; nil output when it didn't start or
    /// timed out. Tests record the arguments instead.
    let run: @Sendable (_ arguments: [String], _ timeout: TimeInterval) -> Result<Output, MergeQueue.ClientError>

    var isDryRun: Bool { false }

    static let readTimeout: TimeInterval = 60
    static let mutationTimeout: TimeInterval = 120

    static var installed: GitHubCLIQueueClient {
        GitHubCLIQueueClient { arguments, timeout in
            // Looked up at each call, like the board's: a gh installed since launch is found.
            guard let ghPath = PRDetect.installedGHPath() else { return .failure(.ghMissing) }
            guard let result = GitHubCLIBoardClient.runGH(ghPath, arguments: arguments, timeout: timeout) else {
                return .failure(.noAnswer("gh couldn’t start, or took longer than \(Int(timeout)) s"))
            }
            return .success(Output(status: result.terminationStatus, standardOutput: result.standardOutput,
                                   standardError: result.standardError))
        }
    }

    // MARK: Reads

    func read(_ read: MergeQueue.Read, settings: BoardConfig.QueueSettings) -> Result<MergeQueue.ReadResult, MergeQueue.ClientError> {
        let repository = settings.repository
        switch read {
        case .auth:
            return call(Self.authArguments).map { _ -> MergeQueue.ReadResult in .signedIn }.flatMapError { error in
                switch error {
                // No answer or a rate limit: retried or paused like any read.
                case .ghMissing, .notSignedIn, .rateLimited, .secondaryRateLimit, .noAnswer:
                    return .failure(error)
                case .refused, .unreadable:
                    return .failure(.notSignedIn(Self.message(of: error)))
                }
            }
        case .rateLimit:
            return parse(call(Self.rateLimitArguments), MergeQueue.parseRateLimit).map { .rateLimit($0) }
        case .baseMergeQueue:
            // A `merge_queue` rule, or GraphQL's mergeQueue, which also
            // sees classic branch protection.
            return parse(call(Self.rulesArguments(repository: repository, branch: settings.baseBranch)),
                         MergeQueue.parseRulesRequireMergeQueue).flatMap { hasRule in
                parse(call(Self.mergeQueueArguments(repository: repository, branch: settings.baseBranch)),
                      MergeQueue.parseMergeQueue).map { .baseMergeQueue(hasRule || $0) }
            }
        case .pullRequest(let number):
            return parse(call(Self.pullRequestArguments(repository: repository, number: number)),
                         MergeQueue.parsePullRequest).map { .pullRequest($0) }
        case .checks(let sha):
            return call(Self.checksArguments(repository: repository, sha: sha)).flatMap { output in
                MergeQueue.parseChecks(output.standardOutput, sha: sha).map { .checks($0) }
            }
        case .compare(let base, let head):
            switch call(Self.compareArguments(repository: repository, base: base, head: head)) {
            case .success(let output):
                return MergeQueue.parseComparison(output.standardOutput).map { .success(.comparison($0)) }
                    ?? .failure(.unreadable("compare"))
            case .failure(.refused(404?, _)):
                return .success(.comparison(nil))
            case .failure(let error):
                return .failure(error)
            }
        case .commit(let sha):
            return parse(call(Self.commitArguments(repository: repository, sha: sha)), MergeQueue.parseCommit)
                .map { .commit($0) }
        case .baseRuns, .pushRuns:
            guard let workflow = settings.postMergeWorkflow else { return .success(.runs([])) }
            var commit: String?
            if case .pushRuns(let sha) = read { commit = sha }
            return parse(call(Self.runArguments(repository: repository, workflow: workflow, branch: settings.baseBranch,
                                                pushCommit: commit)),
                         MergeQueue.parseRuns).map { .runs($0) }
        case .local:
            return .failure(.unreadable("the local worktrees aren’t a GitHub read"))
        }
    }

    // MARK: Mutations

    func mutate(_ mutation: MergeQueue.Mutation, settings: BoardConfig.QueueSettings) -> MergeQueue.MutationResult {
        switch run(Self.mutationArguments(mutation, repository: settings.repository), Self.mutationTimeout) {
        case .failure(let error):
            return Self.mutationResult(error)
        case .success(let output) where output.status == 0:
            return .sent
        case .success(let output):
            return Self.mutationResult(Self.classify(output))
        }
    }

    func commandLine(_ mutation: MergeQueue.Mutation, settings: BoardConfig.QueueSettings) -> String {
        (["gh"] + Self.mutationArguments(mutation, repository: settings.repository)).map(Self.shellQuoted).joined(separator: " ")
    }

    static func mutationResult(_ error: MergeQueue.ClientError) -> MergeQueue.MutationResult {
        switch error {
        case .ghMissing: return .refused(status: nil, message: "gh isn’t installed")
        case .notSignedIn(let message): return .refused(status: 401, message: message)
        case .rateLimited: return .rateLimited("API rate limit exceeded")
        case .secondaryRateLimit(let message): return .rateLimited(message)
        case .refused(let status, let message): return .refused(status: status, message: message)
        case .noAnswer(let message): return .uncertain(message)
        case .unreadable(let output): return .uncertain("gh answered with something Nirux can’t read: \(output)")
        }
    }

    // MARK: Running gh

    /// gh's output when it exited 0, else its error. A primary rate limit
    /// asks `rate_limit` (free) when the limit resets.
    private func call(_ arguments: [String]) -> Result<Output, MergeQueue.ClientError> {
        switch run(arguments, Self.readTimeout) {
        case .failure(let error):
            return .failure(error)
        case .success(let output) where output.status == 0:
            return .success(output)
        case .success(let output):
            let error = Self.classify(output)
            guard case .rateLimited = error else { return .failure(error) }
            let limit = try? run(Self.rateLimitArguments, Self.readTimeout).get()
            let reset = limit.flatMap { $0.status == 0 ? MergeQueue.parseRateLimit($0.standardOutput) : nil }
                .flatMap(Self.resetOfExhaustedPool)
            return .failure(.rateLimited(resetAt: reset))
        }
    }

    private func parse<Value>(
        _ output: Result<Output, MergeQueue.ClientError>, _ parser: (Data) -> Value?
    ) -> Result<Value, MergeQueue.ClientError> {
        output.flatMap { output in
            parser(output.standardOutput).map { .success($0) }
                ?? .failure(.unreadable(WorktreeCleanup.firstLine(String(decoding: output.standardOutput, as: UTF8.self)) ?? ""))
        }
    }

    /// The later reset of the pools with nothing left.
    static func resetOfExhaustedPool(_ limit: MergeQueue.RateLimit) -> Date? {
        [(limit.coreRemaining, limit.coreReset), (limit.graphQLRemaining, limit.graphQLReset)]
            .filter { $0.0 == 0 }.map(\.1).max()
    }

    /// What a failed gh run means (section 4): a rate limit, a sign-in, an
    /// error GitHub answered, or no answer.
    static func classify(_ output: Output) -> MergeQueue.ClientError {
        let standardError = String(decoding: output.standardError, as: UTF8.self)
        let standardOutput = String(decoding: output.standardOutput, as: UTF8.self)
        let text = standardError + "\n" + standardOutput
        let lowered = text.lowercased()
        let json = (try? JSONSerialization.jsonObject(with: output.standardOutput)) as? [String: Any]
        let graphQLErrors = json?["errors"] as? [[String: Any]] ?? []
        let status = httpStatus(standardError) ?? (json?["status"] as? String).flatMap { Int($0) }
        let message = (json?["message"] as? String)
            ?? graphQLErrors.compactMap { $0["message"] as? String }.first
            ?? WorktreeCleanup.firstLine(standardError).map(strippingPrefix)
            ?? "gh exited with status \(output.status)"

        if lowered.contains("secondary rate limit") || lowered.contains("abuse detection") {
            return .secondaryRateLimit(message)
        }
        if lowered.contains("api rate limit exceeded") || graphQLErrors.contains(where: { $0["type"] as? String == "RATE_LIMITED" })
            || status == 429 {
            return .rateLimited(resetAt: nil)
        }
        if status == 401 || output.status == 4 || lowered.contains("gh auth login") || lowered.contains("bad credentials") {
            return .notSignedIn(message)
        }
        if let status {
            return (500..<600).contains(status) ? .noAnswer("HTTP \(status): \(message)") : .refused(status: status, message: message)
        }
        if graphQLErrors.contains(where: { $0["type"] is String }) || standardError.hasPrefix("GraphQL:")
            || lowered.contains("is not mergeable") || lowered.contains("could not find any workflows") {
            return .refused(status: nil, message: message)
        }
        return .noAnswer(message)
    }

    /// `gh api`'s `… (HTTP 422)`, or the other commands' `HTTP 404: …`.
    static func httpStatus(_ text: String) -> Int? {
        if let range = text.range(of: #"\(HTTP \d{3}\)"#, options: .regularExpression) {
            return Int(text[range].dropFirst(6).prefix(3))
        }
        if let range = text.range(of: #"(?m)^(gh: )?HTTP \d{3}:"#, options: .regularExpression) {
            return Int(text[range].suffix(4).prefix(3))
        }
        return nil
    }

    private static func strippingPrefix(_ line: String) -> String {
        var line = line
        if line.hasPrefix("gh: ") { line.removeFirst(4) }
        if let range = line.range(of: #" \(HTTP \d{3}\)$"#, options: .regularExpression) { line.removeSubrange(range) }
        return line
    }

    static func message(of error: MergeQueue.ClientError) -> String {
        switch error {
        case .ghMissing: return "gh isn’t installed"
        case .notSignedIn(let message), .secondaryRateLimit(let message), .noAnswer(let message): return message
        case .rateLimited: return "API rate limit exceeded"
        case .refused(let status, let message): return status.map { "\(message) (HTTP \($0))" } ?? message
        case .unreadable(let output): return "gh answered with something Nirux can’t read: \(output)"
        }
    }

    /// Plain words stay as they are, so the journal reads like the command
    /// typed by hand.
    static func shellQuoted(_ argument: String) -> String {
        let safe = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_./=:@%+,")
        guard !argument.isEmpty, argument.unicodeScalars.allSatisfy(safe.contains) else {
            return AgentHookInstaller.shellQuoted(argument)
        }
        return argument
    }

    // MARK: Arguments

    static let host = "github.com"

    /// A branch or a commit in a REST path: everything but unreserved
    /// characters percent-encoded, `/`, `#` and `%` included.
    static func pathComponent(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: CharacterSet(
            charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~"
        )) ?? value
    }

    /// The active account only: another account's stale token doesn't
    /// make the one gh uses signed out.
    static let authArguments = ["auth", "status", "--hostname", host, "--active"]
    static let rateLimitArguments = ["api", "--hostname", host, "rate_limit"]

    static func rulesArguments(repository: String, branch: String) -> [String] {
        ["api", "--hostname", host, "repos/\(repository)/rules/branches/\(pathComponent(branch))?per_page=100"]
    }

    /// `-f` sends each value as a plain string: `-F` would read `@file`
    /// and turn `true` or `12` into other types.
    private static func graphQL(_ query: String, strings: [(String, String)], integers: [(String, Int)] = []) -> [String] {
        ["api", "graphql", "--hostname", host, "-f", "query=\(query)"]
            + strings.flatMap { ["-f", "\($0.0)=\($0.1)"] }
            + integers.flatMap { ["-F", "\($0.0)=\($0.1)"] }
    }

    private static func ownerAndName(_ repository: String) -> [(String, String)] {
        let parts = repository.split(separator: "/", maxSplits: 1).map(String.init)
        return [("owner", parts.first ?? ""), ("name", parts.count > 1 ? parts[1] : "")]
    }

    static func mergeQueueArguments(repository: String, branch: String) -> [String] {
        graphQL(mergeQueueQuery, strings: ownerAndName(repository) + [("branch", branch)])
    }

    static func pullRequestArguments(repository: String, number: Int) -> [String] {
        graphQL(pullRequestQuery, strings: ownerAndName(repository), integers: [("number", number)])
    }

    static func checksArguments(repository: String, sha: String) -> [String] {
        graphQL(checksQuery, strings: ownerAndName(repository) + [("oid", sha)])
    }

    /// Only the counts and the base commit: a compare lists up to 300
    /// files and 250 commits.
    static func compareArguments(repository: String, base: String, head: String) -> [String] {
        ["api", "--hostname", host, "repos/\(repository)/compare/\(pathComponent(base))...\(pathComponent(head))",
         "--jq", "{status, ahead_by, behind_by, base_commit: .base_commit.sha}"]
    }

    /// REST, not GraphQL: only REST names `web-flow` as the committer of a
    /// commit GitHub made.
    static func commitArguments(repository: String, sha: String) -> [String] {
        ["api", "--hostname", host, "repos/\(repository)/commits/\(pathComponent(sha))",
         "--jq", "{sha, committer: .committer.login, parents: [.parents[].sha]}"]
    }

    static let runFields = "databaseId,attempt,status,conclusion,headSha,event,displayTitle,url"

    /// The runs on the base whatever their event (a manual dispatch shares
    /// the nightly's concurrency group), or the push runs of a merge commit.
    static func runArguments(repository: String, workflow: String, branch: String, pushCommit: String?) -> [String] {
        var arguments = ["run", "list", "--repo", "\(host)/\(repository)", "--workflow", workflow, "--branch", branch]
        if let pushCommit {
            arguments += ["--event", "push", "--commit", pushCommit, "--limit", "10"]
        } else {
            arguments += ["--limit", "50"]
        }
        return arguments + ["--json", runFields]
    }

    /// Never `--admin`, `--auto`, `--delete-branch` or `--rebase`; a merge
    /// and a branch update always carry the SHA they were decided on.
    static func mutationArguments(_ mutation: MergeQueue.Mutation, repository: String) -> [String] {
        switch mutation {
        case .updateBranch(let number, let head):
            return ["api", "--hostname", host, "--method", "PUT", "repos/\(repository)/pulls/\(number)/update-branch",
                    "-f", "expected_head_sha=\(head)"]
        case .rerun(let runID):
            return ["run", "rerun", "\(runID)", "--repo", "\(host)/\(repository)", "--failed"]
        case .merge(let number, let head, let method):
            return ["pr", "merge", "\(number)", "--repo", "\(host)/\(repository)", "--\(method.rawValue)",
                    "--match-head-commit", head]
        }
    }

    static let pullRequestQuery = """
    query($owner: String!, $name: String!, $number: Int!) {
      repository(owner: $owner, name: $name) {
        pullRequest(number: $number) {
          number state isDraft url headRefName headRefOid baseRefName
          headRepository { name owner { login } }
          mergeable isInMergeQueue
          autoMergeRequest { enabledAt }
          mergeCommit { oid parents(first: 2) { nodes { oid } } }
        }
      }
    }
    """

    /// The latest check run of each check (`LATEST`), with its workflow
    /// and run; more than one page of either fails closed.
    static let checksQuery = """
    query($owner: String!, $name: String!, $oid: GitObjectID!) {
      repository(owner: $owner, name: $name) {
        object(oid: $oid) {
          ... on Commit {
            checkSuites(first: 50) {
              pageInfo { hasNextPage }
              nodes {
                app { slug }
                workflowRun { databaseId workflow { databaseId name } }
                checkRuns(first: 100, filterBy: {checkType: LATEST}) {
                  pageInfo { hasNextPage }
                  nodes { databaseId name status conclusion }
                }
              }
            }
            status { contexts { context state } }
          }
        }
      }
    }
    """

    static let mergeQueueQuery = """
    query($owner: String!, $name: String!, $branch: String!) {
      repository(owner: $owner, name: $name) { mergeQueue(branch: $branch) { id } }
    }
    """
}
