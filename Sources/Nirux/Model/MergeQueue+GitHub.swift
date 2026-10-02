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

    /// What a signature check found (see `releaseRequirement`).
    enum ReleaseSignature: Equatable, Sendable {
        case release
        /// The Security framework's status for the step that failed.
        case notRelease(OSStatus)

        /// Statuses that mean the check itself was misused (flags, a bad
        /// requirement, a bad argument), not that the code isn't the release:
        /// such an error once kept the nightly from shipping.
        static let misuse: Set<OSStatus> = [
            errSecCSInvalidFlags, errSecCSReqInvalid, errSecCSReqUnsupported, errSecCSInvalidObjectRef, errSecParam
        ]

        var isMisuse: Bool {
            if case .notRelease(let status) = self { return Self.misuse.contains(status) }
            return false
        }

        /// "OSStatus -67050: code failed to satisfy specified code requirement(s)".
        var detail: String {
            guard case .notRelease(let status) = self else { return "the notarized release" }
            let message = (SecCopyErrorMessageString(status, nil) as String?) ?? "unknown error"
            return "OSStatus \(status): \(message)" + (isMisuse ? " (the check was misused)" : "")
        }
    }

    /// Whether this build may change GitHub, and why, for the log and a dry
    /// run's stop: the notarized release run on the real state, or any
    /// build with `NIRUX_MERGE_QUEUE_LIVE=1`. Agents build and click through
    /// Nirux inside Nirux on a state of their own (`NIRUX_STATE_DIR`, which
    /// the installed app never sets), and LaunchServices opens a bundle with
    /// no variable at all: their builds aren't notarized, and a bundle next
    /// to a `Package.swift` (`scripts/bundle.sh`'s, in a checkout) is
    /// refused even if someone notarized it by hand. The signature is only
    /// asked for when the rest doesn't decide.
    static func liveDecision(
        environment: [String: String], bundleURL: URL, signature: () -> ReleaseSignature
    ) -> (isLive: Bool, reason: String) {
        if let decided = decisionWithoutSignature(environment: environment, bundleURL: bundleURL) { return decided }
        let result = signature()
        return result == .release
            ? (true, "the notarized release on the real state")
            : (false, "not the notarized release (\(result.detail))")
    }

    /// The decision when it doesn't need the signature; nil when it does.
    static func decisionWithoutSignature(environment: [String: String], bundleURL: URL) -> (isLive: Bool, reason: String)? {
        if environment["NIRUX_MERGE_QUEUE_LIVE"] == "1" { return (true, "NIRUX_MERGE_QUEUE_LIVE=1") }
        guard (environment["NIRUX_STATE_DIR"] ?? "").isEmpty else { return (false, "NIRUX_STATE_DIR is set") }
        guard bundleURL.pathExtension == "app" else { return (false, "not an app bundle") }
        let checkoutManifest = bundleURL.deletingLastPathComponent().appendingPathComponent("Package.swift").path
        guard !FileManager.default.fileExists(atPath: checkoutManifest) else { return (false, "a build inside a checkout") }
        return nil
    }

    /// The nightly's signature: a Developer ID Application certificate, and
    /// Apple's notarization, stapled to the app so it is checked offline.
    /// The nightly runs `Nirux --check-release-signature` on the app it
    /// publishes, so a release whose queue would stay a dry run fails there.
    static let releaseRequirement = "anchor apple generic"
        + " and certificate 1[field.1.2.840.113635.100.6.2.6] exists"
        + " and certificate leaf[field.1.2.840.113635.100.6.1.13] exists"
        + " and notarized"

    /// `releaseRequirement` compiled, or the status that refused it.
    private static func requirement() -> (requirement: SecRequirement?, status: OSStatus) {
        var requirement: SecRequirement?
        let status = SecRequirementCreateWithString(releaseRequirement as CFString, [], &requirement)
        return (status == errSecSuccess ? requirement : nil, status)
    }

    /// This running process against `releaseRequirement`, with its path.
    /// Default flags check what establishes its identity against the code
    /// the kernel runs. (A static check's flags, such as
    /// kSecCSDoNotValidateResources, are refused here: errSecCSInvalidFlags.)
    static func ownReleaseSignature() -> (signature: ReleaseSignature, path: String?) {
        var code: SecCode?
        var status = SecCodeCopySelf([], &code)
        guard status == errSecSuccess, let code else { return (.notRelease(status), nil) }
        // Where it runs from, for the nightly's log only.
        var staticCode: SecStaticCode?
        var url: CFURL?
        let path = SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess
            && staticCode.map { SecCodeCopyPath($0, [], &url) == errSecSuccess } == true ? (url as URL?)?.path : nil
        let (requirement, requirementStatus) = requirement()
        guard let requirement else { return (.notRelease(requirementStatus), path) }
        status = SecCodeCheckValidity(code, [], requirement)
        return (status == errSecSuccess ? .release : .notRelease(status), path)
    }

    /// The app (or binary) at `path` against `releaseRequirement`: its
    /// signature, sealed resources and requirement, as on disk. For a
    /// downloaded nightly, say.
    static func releaseSignature(atPath path: String) -> ReleaseSignature {
        var staticCode: SecStaticCode?
        var status = SecStaticCodeCreateWithPath(URL(fileURLWithPath: path).standardizedFileURL as CFURL, [], &staticCode)
        guard status == errSecSuccess, let staticCode else { return .notRelease(status) }
        let (requirement, requirementStatus) = requirement()
        guard let requirement else { return .notRelease(requirementStatus) }
        status = SecStaticCodeCheckValidity(staticCode, [], requirement)
        return status == errSecSuccess ? .release : .notRelease(status)
    }

    /// This process's signature, kept once it is definitive: the release,
    /// or code that fails the requirement or isn't signed. Anything else (a
    /// busy system service, a bundle replaced mid-check) is checked again
    /// the next time a queue asks.
    static func currentSignature() -> ReleaseSignature {
        if let known = knownSignature.value { return known }
        let signature = ownReleaseSignature().signature
        if [.release, .notRelease(errSecCSReqFailed), .notRelease(errSecCSUnsigned)].contains(signature) {
            knownSignature.value = signature
        }
        return signature
    }

    private static let knownSignature = LockedSignature()

    private final class LockedSignature: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: ReleaseSignature?
        var value: ReleaseSignature? {
            get { lock.withLock { stored } }
            set { lock.withLock { stored = newValue } }
        }
    }

    /// Checks the signature off the main thread as Nirux launches, when the
    /// decision needs it: an install may replace the bundle later. A queue
    /// opened before it ends checks it itself, on the thread that asks (the
    /// main thread, from the board), in about a tenth of a second.
    static func checkSignatureAtLaunch(
        environment: [String: String] = ProcessInfo.processInfo.environment, bundleURL: URL = Bundle.main.bundleURL
    ) {
        guard decisionWithoutSignature(environment: environment, bundleURL: bundleURL) == nil else { return }
        DispatchQueue.global(qos: .utility).async { _ = currentSignature() }
    }

    /// `Nirux --check-release-signature [path]`. Without a path: this app,
    /// with the requirement, the Security status and the queue's decision
    /// in this process's environment; exits 0 only when its queue would be
    /// live. With a path: that app's files; exits 0 for the release. Either
    /// way 1 for anything else, and 2 for a misused check or wrong
    /// arguments.
    static func checkReleaseSignatureCommand(
        _ arguments: [String],
        environment: [String: String] = ProcessInfo.processInfo.environment,
        bundleURL: URL = Bundle.main.bundleURL
    ) -> Int32 {
        let usage = "usage: Nirux --check-release-signature [path-to-app]"
        guard arguments.count <= 1 else {
            print(usage)
            return 2
        }
        if let path = arguments.first {
            guard FileManager.default.fileExists(atPath: path) else {
                print("no app at \(path)\n\(usage)")
                return 2
            }
            let signature = releaseSignature(atPath: path)
            print("app: \(path)\nrequirement: \(releaseRequirement)\nresult: \(signature.detail)")
            return signature == .release ? 0 : signature.isMisuse ? 2 : 1
        }
        let (signature, path) = ownReleaseSignature()
        let decision = liveDecision(environment: environment, bundleURL: bundleURL) { signature }
        print("app: \(path ?? "(this process)")\nrequirement: \(releaseRequirement)\nresult: \(signature.detail)\n"
            + "merge queue: \(decision.isLive ? "live" : "dry run"): \(decision.reason)")
        return signature.isMisuse ? 2 : decision.isLive ? 0 : 1
    }

    /// The client this build runs its queues with: `live`, or a dry run of
    /// it that reads GitHub and journals the mutations it would make, and
    /// says why.
    static func client(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        bundleURL: URL = Bundle.main.bundleURL,
        signature: @autoclosure () -> ReleaseSignature = currentSignature(),
        live: @autoclosure () -> any MergeQueueGitHub = GitHubCLIQueueClient.installed
    ) -> any MergeQueueGitHub {
        let client = live()
        let decision = liveDecision(environment: environment, bundleURL: bundleURL, signature: signature)
        NSLog("[MergeQueue] %@: %@", decision.isLive ? "live" : "dry run", decision.reason)
        return decision.isLive ? client : DryRunQueueClient(wrapped: client, reason: decision.reason)
    }
}

/// Reads through `wrapped`; mutations are never sent, only described.
struct DryRunQueueClient: MergeQueueGitHub {
    let wrapped: any MergeQueueGitHub
    /// Why this build is a dry run, for the queue's stop.
    var reason = "a dry run"

    var isDryRun: Bool { true }

    func read(_ read: MergeQueue.Read, settings: BoardConfig.QueueSettings) -> Result<MergeQueue.ReadResult, MergeQueue.ClientError> {
        wrapped.read(read, settings: settings)
    }

    func mutate(_ mutation: MergeQueue.Mutation, settings: BoardConfig.QueueSettings) -> MergeQueue.MutationResult {
        .dryRun(command: wrapped.commandLine(mutation, settings: settings), reason: reason)
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
        case .pullRequestDetails(let number):
            return parse(call(Self.pullRequestDetailsArguments(repository: repository, number: number)),
                         MergeQueue.parsePullRequestDetails).map { .pullRequestDetails($0) }
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

    static func pullRequestDetailsArguments(repository: String, number: Int) -> [String] {
        graphQL(pullRequestDetailsQuery, strings: ownerAndName(repository), integers: [("number", number)])
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

    /// A rename out of `.github/workflows/` shows under its new path only:
    /// GraphQL gives no previous path.
    static let pullRequestDetailsQuery = """
    query($owner: String!, $name: String!, $number: Int!) {
      repository(owner: $owner, name: $name) {
        pullRequest(number: $number) {
          title
          files(first: \(MergeQueue.PullRequestDetails.maxFiles)) { pageInfo { hasNextPage } nodes { path } }
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
