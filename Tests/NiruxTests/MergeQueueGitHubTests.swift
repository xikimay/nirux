import Security
import XCTest
@testable import Nirux

/// The merge queue's `gh` calls and what it reads from them. The fixtures
/// are real `gh` 2.100.0 output (2026-09-28), anonymized: owner,
/// repository, commits, ids and URLs changed. The auto-merge pull request,
/// the second page of checks and the `update-branch` errors are shaped by
/// hand on GitHub's documented bodies (no mutation was ever sent).
final class MergeQueueGitHubTests: XCTestCase {
    private let settings = MQ.settings()

    // MARK: Fixtures

    static let mergedPullRequest = """
    {"data":{"repository":{"pullRequest":{"number":60,"state":"MERGED","isDraft":false,\
    "url":"https://github.com/acme/widgets/pull/60","headRefName":"feat/project-board",\
    "headRefOid":"5E2F337CF1ADC0556B3AF834C437F68C0D1AEF01","baseRefName":"main",\
    "headRepository":{"name":"widgets","owner":{"login":"acme"}},"mergeable":"UNKNOWN","isInMergeQueue":false,\
    "autoMergeRequest":null,"mergeCommit":{"oid":"0e6c4b40586583d7b53ecf26775cf2ecabd76c02",\
    "parents":{"nodes":[{"oid":"2c8b4f5e91a2f5fd8d309ec64feebc7b72ceea03"},\
    {"oid":"5e2f337cf1adc0556b3af834c437f68c0d1aef01"}]}}}}}}
    """

    static let autoMergePullRequest = """
    {"data":{"repository":{"pullRequest":{"number":61,"state":"OPEN","isDraft":false,\
    "url":"https://github.com/acme/widgets/pull/61","headRefName":"feat/keep-awake",\
    "headRefOid":"db9ac6679f88a24b3a210d8e042c3c4b73f47b04","baseRefName":"main",\
    "headRepository":{"name":"widgets","owner":{"login":"Acme"}},"mergeable":"MERGEABLE","isInMergeQueue":false,\
    "autoMergeRequest":{"enabledAt":"2026-09-28T17:20:00Z"},"mergeCommit":null}}}}
    """

    static let missingPullRequest = """
    {"data":{"repository":{"pullRequest":null}},"errors":[{"type":"NOT_FOUND","path":["repository","pullRequest"],\
    "locations":[{"line":3,"column":5}],"message":"Could not resolve to a PullRequest with the number of 999999."}]}
    """

    static let checks = """
    {"data":{"repository":{"object":{"checkSuites":{"pageInfo":{"hasNextPage":false},"nodes":[\
    {"app":{"slug":"vercel"},"workflowRun":null,"checkRuns":{"pageInfo":{"hasNextPage":false},"nodes":[]}},\
    {"app":{"slug":"github-actions"},"workflowRun":{"databaseId":1003173,"workflow":{"databaseId":78419332,"name":"CodeQL"}},\
    "checkRuns":{"pageInfo":{"hasNextPage":false},"nodes":[\
    {"databaseId":5671411,"name":"Analyze (swift)","status":"COMPLETED","conclusion":"SUCCESS"},\
    {"databaseId":5671712,"name":"Analyze (actions)","status":"COMPLETED","conclusion":"SUCCESS"},\
    {"databaseId":5672529,"name":"Analyze (javascript-typescript)","status":"COMPLETED","conclusion":"SUCCESS"}]}},\
    {"app":{"slug":"github-actions"},"workflowRun":{"databaseId":1009748,"workflow":{"databaseId":16092770,"name":"Tests"}},\
    "checkRuns":{"pageInfo":{"hasNextPage":false},"nodes":[\
    {"databaseId":5688518,"name":"test","status":"COMPLETED","conclusion":"SUCCESS"}]}},\
    {"app":{"slug":"github-advanced-security"},"workflowRun":null,"checkRuns":{"pageInfo":{"hasNextPage":false},\
    "nodes":[{"databaseId":5865854,"name":"CodeQL","status":"COMPLETED","conclusion":"NEUTRAL"}]}}]},\
    "status":null}}}}
    """

    static let unknownCommitChecks = #"{"data":{"repository":{"object":null}}}"#

    static let webFlowCommit = """
    {"committer":"web-flow","parents":["584dea8a87e6ab2ce67ca55be95120bb8fc36b05",\
    "2c8b4f5e91a2f5fd8d309ec64feebc7b72ceea03"],"sha":"5e2f337cf1adc0556b3af834c437f68c0d1aef01"}
    """

    static let userCommit = """
    {"committer":"octocat","parents":["6a8dd7790f9931772cd6fafe45074cadedac0c06"],\
    "sha":"584dea8a87e6ab2ce67ca55be95120bb8fc36b05"}
    """

    static let comparison = """
    {"ahead_by":0,"base_commit":"fa74b4ce919c2b94a0f7bc88fbba3845357c9a07","behind_by":9,"status":"behind"}
    """

    static let notFound = """
    {"message":"Not Found","documentation_url":"https://docs.github.com/rest/commits/commits#compare-two-commits",\
    "status":"404"}
    """

    static let runs = """
    [{"conclusion":"","databaseId":3457684887,"displayTitle":"Merge pull request #57 from acme/feat/keep-awake",\
    "event":"push","headSha":"fa74b4ce919c2b94a0f7bc88fbba3845357c9a07","status":"in_progress",\
    "url":"https://github.com/acme/widgets/actions/runs/3457684887"},\
    {"conclusion":"success","databaseId":3397820361,"displayTitle":"Merge pull request #60 from acme/feat/project-board",\
    "event":"push","headSha":"0e6c4b40586583d7b53ecf26775cf2ecabd76c02","status":"completed",\
    "url":"https://github.com/acme/widgets/actions/runs/3397820361"},\
    {"conclusion":"failure","databaseId":3002928004,"displayTitle":"Nightly Release","event":"workflow_dispatch",\
    "headSha":"bfa4a65643bd3c9ec1a50fdda1b85fb008dc2a08","status":"completed",\
    "url":"https://github.com/acme/widgets/actions/runs/3002928004"}]
    """

    static let rateLimit = """
    {"resources":{"core":{"limit":5000,"used":0,"remaining":5000,"reset":1790619930},\
    "search":{"limit":30,"used":0,"remaining":30,"reset":1790616390},\
    "graphql":{"limit":5000,"used":3,"remaining":4997,"reset":1790619350}},\
    "rate":{"limit":5000,"used":0,"remaining":5000,"reset":1790619930}}
    """

    // MARK: Parsers

    func testPullRequest() throws {
        let merged = try XCTUnwrap(MergeQueue.parsePullRequest(Data(Self.mergedPullRequest.utf8)))
        XCTAssertEqual(merged.number, 60)
        XCTAssertEqual(merged.state, "MERGED")
        XCTAssertEqual(merged.headOid, "5e2f337cf1adc0556b3af834c437f68c0d1aef01")
        XCTAssertEqual(merged.headRepository, MQ.widgets)
        XCTAssertEqual(merged.mergeCommit, "0e6c4b40586583d7b53ecf26775cf2ecabd76c02")
        XCTAssertEqual(merged.mergeCommitParents, ["2c8b4f5e91a2f5fd8d309ec64feebc7b72ceea03",
                                                   "5e2f337cf1adc0556b3af834c437f68c0d1aef01"])
        XCTAssertFalse(merged.hasAutoMerge)
        XCTAssertFalse(merged.isInMergeQueue)

        let autoMerge = try XCTUnwrap(MergeQueue.parsePullRequest(Data(Self.autoMergePullRequest.utf8)))
        XCTAssertTrue(autoMerge.hasAutoMerge)
        XCTAssertTrue(autoMerge.isOpen)
        XCTAssertNil(autoMerge.mergeCommit)
        // GitHub ignores case in owner/name.
        XCTAssertEqual(autoMerge.headRepository, MQ.widgets)

        XCTAssertNil(MergeQueue.parsePullRequest(Data(Self.missingPullRequest.utf8)))
        // A field it asked for and didn't get: unreadable, never a default.
        for field in [#""isInMergeQueue":false,"#, #""isDraft":false,"#, #""autoMergeRequest":{"enabledAt":"2026-09-28T17:20:00Z"},"#] {
            let missing = Self.autoMergePullRequest.replacingOccurrences(of: field, with: "")
            XCTAssertNil(MergeQueue.parsePullRequest(Data(missing.utf8)), field)
        }
        XCTAssertNil(MergeQueue.parseMergeQueue(Data(#"{"data":{"repository":{}}}"#.utf8)))
    }

    func testChecksByCommit() throws {
        let checks = try MergeQueue.parseChecks(Data(Self.checks.utf8), sha: MQ.sha("a")).get()
        XCTAssertEqual(checks.runs.count, 5)
        let test = try XCTUnwrap(checks.runs.first { $0.name == "test" })
        XCTAssertEqual(test.workflow, "Tests")
        XCTAssertEqual(test.workflowRunID, 1009748)
        XCTAssertEqual(test.workflowID, 16092770)
        XCTAssertEqual(test.conclusion, "SUCCESS")
        let codeQL = try XCTUnwrap(checks.runs.first { $0.name == "CodeQL" })
        XCTAssertNil(codeQL.workflow)
        XCTAssertEqual(codeQL.app, "github-advanced-security")

        // `test` is green; CodeQL's neutral check neither helps nor blocks.
        let verdict = MergeQueue.judge(checks, required: ["test", "CodeQL / Analyze (swift)"])
        XCTAssertTrue(verdict.allRequiredGreen)
        XCTAssertTrue(verdict.otherFailures.isEmpty)
        XCTAssertEqual(MergeQueue.judge(checks, required: ["CodeQL"]).notGreen, ["CodeQL (neutral)"])

        let secondPage = Self.checks.replacingOccurrences(of: #"{"pageInfo":{"hasNextPage":false},"nodes":[]}"#,
                                                          with: #"{"pageInfo":{"hasNextPage":true},"nodes":[]}"#)
        guard case .failure(.refused(_, let message)) = MergeQueue.parseChecks(Data(secondPage.utf8), sha: MQ.sha("a")) else {
            return XCTFail("a second page must fail closed")
        }
        XCTAssertTrue(message.contains("more checks than Nirux reads"))
        guard case .failure(.refused) = MergeQueue.parseChecks(Data(Self.unknownCommitChecks.utf8), sha: MQ.sha("a")) else {
            return XCTFail("an unknown commit is refused")
        }
        // A page it can't tell is the last one fails closed.
        let noPageInfo = Self.checks.replacingOccurrences(of: #""pageInfo":{"hasNextPage":false},"nodes":[]"#, with: #""nodes":[]"#)
        guard case .failure(.unreadable) = MergeQueue.parseChecks(Data(noPageInfo.utf8), sha: MQ.sha("a")) else {
            return XCTFail("a missing pageInfo")
        }
    }

    func testCommitComparisonRunsAndLimits() throws {
        let update = try XCTUnwrap(MergeQueue.parseCommit(Data(Self.webFlowCommit.utf8)))
        XCTAssertEqual(update.committerLogin, "web-flow")
        XCTAssertEqual(update.parents.count, 2)
        XCTAssertEqual(MergeQueue.parseCommit(Data(Self.userCommit.utf8))?.committerLogin, "octocat")
        XCTAssertEqual(MergeQueue.parseCommit(Data(#"{"sha":"x","committer":null,"parents":[]}"#.utf8)), nil)

        XCTAssertEqual(MergeQueue.parseComparison(Data(Self.comparison.utf8)),
                       MergeQueue.Comparison(status: "behind", aheadBy: 0, behindBy: 9,
                                             baseCommit: "fa74b4ce919c2b94a0f7bc88fbba3845357c9a07"))
        XCTAssertNil(MergeQueue.parseComparison(Data(Self.notFound.utf8)))

        let runs = try XCTUnwrap(MergeQueue.parseRuns(Data(Self.runs.utf8)))
        XCTAssertEqual(runs.map(\.id), [3457684887, 3397820361, 3002928004])
        XCTAssertFalse(runs[0].isCompleted)
        XCTAssertNil(runs[0].conclusion)
        XCTAssertEqual(runs[2].event, "workflow_dispatch")
        XCTAssertTrue(MergeQueue.runFailed(runs[2]))
        XCTAssertFalse(MergeQueue.runFailed(MQ.run(1, head: MQ.sha("a"), conclusion: "cancelled")))

        let limit = try XCTUnwrap(MergeQueue.parseRateLimit(Data(Self.rateLimit.utf8)))
        XCTAssertEqual(limit.coreRemaining, 5000)
        XCTAssertEqual(limit.graphQLRemaining, 4997)
        XCTAssertEqual(limit.graphQLReset, Date(timeIntervalSince1970: 1790619350))

        XCTAssertEqual(MergeQueue.parseRulesRequireMergeQueue(Data("[]".utf8)), false)
        XCTAssertEqual(MergeQueue.parseRulesRequireMergeQueue(Data(#"[{"type":"deletion"},{"type":"merge_queue"}]"#.utf8)), true)
        XCTAssertEqual(MergeQueue.parseMergeQueue(Data(#"{"data":{"repository":{"mergeQueue":null}}}"#.utf8)), false)
        XCTAssertEqual(MergeQueue.parseMergeQueue(Data(#"{"data":{"repository":{"mergeQueue":{"id":"MQ_1"}}}}"#.utf8)), true)
    }

    // MARK: Errors

    private func output(_ status: Int32, stdout: String = "", stderr: String) -> GitHubCLIQueueClient.Output {
        GitHubCLIQueueClient.Output(status: status, standardOutput: Data(stdout.utf8), standardError: Data(stderr.utf8))
    }

    func testErrorsAreClassified() {
        XCTAssertEqual(GitHubCLIQueueClient.classify(output(1, stdout: Self.notFound, stderr: "gh: Not Found (HTTP 404)\n")),
                       .refused(status: 404, message: "Not Found"))
        XCTAssertEqual(GitHubCLIQueueClient.classify(output(
            1, stdout: #"{"message":"There are no new commits on the base branch.","status":"422"}"#,
            stderr: "gh: There are no new commits on the base branch. (HTTP 422)\n"
        )), .refused(status: 422, message: "There are no new commits on the base branch."))
        XCTAssertEqual(GitHubCLIQueueClient.classify(output(
            1, stdout: Self.missingPullRequest, stderr: "gh: Could not resolve to a PullRequest with the number of 999999.\n"
        )), .refused(status: nil, message: "Could not resolve to a PullRequest with the number of 999999."))
        XCTAssertEqual(GitHubCLIQueueClient.classify(output(
            1, stderr: "GraphQL: Head branch was modified. Review and try the merge again. (mergePullRequest)\n"
        )), .refused(status: nil, message: "GraphQL: Head branch was modified. Review and try the merge again. (mergePullRequest)"))
        XCTAssertEqual(GitHubCLIQueueClient.classify(output(
            1, stderr: "gh: API rate limit exceeded for user ID 1. (HTTP 403)\n"
        )), .rateLimited(resetAt: nil))
        XCTAssertEqual(GitHubCLIQueueClient.classify(output(
            1, stdout: #"{"errors":[{"type":"RATE_LIMITED","message":"API rate limit already exceeded for user ID 1."}]}"#,
            stderr: "gh: API rate limit already exceeded for user ID 1.\n"
        )), .rateLimited(resetAt: nil))
        guard case .secondaryRateLimit = GitHubCLIQueueClient.classify(output(
            1, stderr: "gh: You have exceeded a secondary rate limit. Please wait a few minutes before you try again. (HTTP 403)\n"
        )) else { return XCTFail("secondary rate limit") }
        guard case .notSignedIn = GitHubCLIQueueClient.classify(output(4, stderr: "To get started with GitHub CLI, please run:  gh auth login\n"))
        else { return XCTFail("signed out") }
        XCTAssertEqual(GitHubCLIQueueClient.classify(output(1, stderr: "HTTP 404: Not Found (https://api.github.com/repos/acme/widgets/actions/workflows/nightly.yml)\n")),
                       .refused(status: 404, message: "HTTP 404: Not Found (https://api.github.com/repos/acme/widgets/actions/workflows/nightly.yml)"))
        guard case .refused(nil, _) = GitHubCLIQueueClient.classify(output(
            1, stderr: "X Pull request acme/widgets#52 is not mergeable: the merge commit cannot be cleanly created.\n"
        )) else { return XCTFail("a merge gh refused") }
        guard case .refused = GitHubCLIQueueClient.classify(output(1, stderr: "could not find any workflows named nightly.yml\n"))
        else { return XCTFail("a workflow gone for good") }
        guard case .noAnswer = GitHubCLIQueueClient.classify(output(1, stderr: "gh: Server Error (HTTP 502)\n"))
        else { return XCTFail("a server error may have gone through") }
        guard case .noAnswer = GitHubCLIQueueClient.classify(output(
            1, stderr: "Post \"https://api.github.com/graphql\": dial tcp: lookup api.github.com: no such host\n"
        )) else { return XCTFail("no answer") }
    }

    func testReadErrorsMapToPausesRetriesOrStops() {
        let now: TimeInterval = 100
        let date = Date(timeIntervalSince1970: 1_000)
        XCTAssertEqual(MergeQueue.readFailure(.rateLimited(resetAt: date.addingTimeInterval(300)), now: now, date: date),
                       .rateLimited(resumeAt: 405))
        XCTAssertEqual(MergeQueue.readFailure(.rateLimited(resetAt: nil), now: now, date: date), .rateLimited(resumeAt: 160))
        XCTAssertEqual(MergeQueue.readFailure(.secondaryRateLimit("slow down"), now: now, date: date), .secondaryRateLimit)
        XCTAssertEqual(MergeQueue.readFailure(.refused(status: 404, message: "Not Found"), now: now, date: date),
                       .refused("Not Found (HTTP 404)"))
        guard case .transient = MergeQueue.readFailure(.noAnswer("timeout"), now: now, date: date) else { return XCTFail() }
        XCTAssertEqual(GitHubCLIQueueClient.mutationResult(.noAnswer("timeout")), .uncertain("timeout"))
        XCTAssertEqual(GitHubCLIQueueClient.mutationResult(.refused(status: 422, message: "x")), .refused(status: 422, message: "x"))
        XCTAssertEqual(GitHubCLIQueueClient.mutationResult(.secondaryRateLimit("slow")), .rateLimited("slow"))
    }

    // MARK: Arguments

    /// Every call names github.com, and no mutation can run without its SHA
    /// or with a forbidden flag.
    func testArgumentsNameGitHubAndPinEveryMutation() {
        let a = MQ.sha("a")
        let reads: [[String]] = [
            GitHubCLIQueueClient.authArguments,
            GitHubCLIQueueClient.rateLimitArguments,
            GitHubCLIQueueClient.rulesArguments(repository: "acme/widgets", branch: "main"),
            GitHubCLIQueueClient.mergeQueueArguments(repository: "acme/widgets", branch: "main"),
            GitHubCLIQueueClient.pullRequestArguments(repository: "acme/widgets", number: 52),
            GitHubCLIQueueClient.checksArguments(repository: "acme/widgets", sha: a),
            GitHubCLIQueueClient.compareArguments(repository: "acme/widgets", base: "main", head: a),
            GitHubCLIQueueClient.commitArguments(repository: "acme/widgets", sha: a),
            GitHubCLIQueueClient.runArguments(repository: "acme/widgets", workflow: "nightly.yml", branch: "main", pushCommit: nil),
            GitHubCLIQueueClient.runArguments(repository: "acme/widgets", workflow: "nightly.yml", branch: "main", pushCommit: a)
        ]
        for arguments in reads {
            XCTAssertTrue(arguments.contains("--hostname") || arguments.contains("--repo"), "\(arguments)")
            XCTAssertTrue(arguments.contains("github.com") || arguments.contains("github.com/acme/widgets"), "\(arguments)")
            XCTAssertNil(ForbiddenCalls.problem(arguments), "\(arguments)")
        }
        // Runs on the base: any event (a manual dispatch counts); a merge's: its push run.
        XCTAssertFalse(reads[8].contains("--event"))
        XCTAssertEqual(Array(reads[9].suffix(8)), ["--event", "push", "--commit", a, "--limit", "10", "--json",
                                                   GitHubCLIQueueClient.runFields])
        XCTAssertEqual(GitHubCLIQueueClient.pullRequestArguments(repository: "acme/widgets", number: 52).suffix(6),
                       ["-f", "owner=acme", "-f", "name=widgets", "-F", "number=52"])

        let mutations: [MergeQueue.Mutation] = [
            .updateBranch(number: 52, expectedHead: a), .rerun(runID: 900), .merge(number: 52, head: a, method: .merge),
            .merge(number: 52, head: a, method: .squash)
        ]
        for mutation in mutations {
            let arguments = GitHubCLIQueueClient.mutationArguments(mutation, repository: "acme/widgets")
            XCTAssertNil(ForbiddenCalls.problem(arguments), "\(arguments)")
        }
        XCTAssertEqual(GitHubCLIQueueClient.mutationArguments(.merge(number: 52, head: a, method: .squash), repository: "acme/widgets"),
                       ["pr", "merge", "52", "--repo", "github.com/acme/widgets", "--squash", "--match-head-commit", a])
        XCTAssertEqual(GitHubCLIQueueClient.mutationArguments(.updateBranch(number: 52, expectedHead: a), repository: "acme/widgets"),
                       ["api", "--hostname", "github.com", "--method", "PUT", "repos/acme/widgets/pulls/52/update-branch",
                        "-f", "expected_head_sha=\(a)"])
        XCTAssertEqual(GitHubCLIQueueClient.mutationArguments(.rerun(runID: 900), repository: "acme/widgets"),
                       ["run", "rerun", "900", "--repo", "github.com/acme/widgets", "--failed"])

        // The checker itself catches what it must.
        XCTAssertNotNil(ForbiddenCalls.problem(["pr", "merge", "52", "--repo", "github.com/acme/widgets", "--merge"]))
        XCTAssertNotNil(ForbiddenCalls.problem(["pr", "merge", "52", "--admin", "--match-head-commit", a]))
        XCTAssertNotNil(ForbiddenCalls.problem(["pr", "update-branch", "52", "--rebase"]))
        XCTAssertNotNil(ForbiddenCalls.problem(["api", "--method", "PUT", "repos/acme/widgets/pulls/52/update-branch"]))
    }

    func testBranchesArePercentEncodedInRESTPaths() {
        XCTAssertEqual(GitHubCLIQueueClient.pathComponent("release/1.0#2%"), "release%2F1.0%232%25")
        XCTAssertEqual(GitHubCLIQueueClient.compareArguments(repository: "acme/widgets", base: "rel#1", head: MQ.sha("a"))[3],
                       "repos/acme/widgets/compare/rel%231...\(MQ.sha("a"))")
        XCTAssertEqual(GitHubCLIQueueClient.rulesArguments(repository: "acme/widgets", branch: "a/b")[3],
                       "repos/acme/widgets/rules/branches/a%2Fb?per_page=100")
        // GraphQL takes the branch as a plain string value.
        XCTAssertTrue(GitHubCLIQueueClient.mergeQueueArguments(repository: "acme/widgets", branch: "rel#1").contains("branch=rel#1"))
    }

    // MARK: The client end to end, with a recorded gh

    func testTheClientReadsAndClassifiesThroughGh() throws {
        let gh = ScriptedGH()
        gh.answer(prefix: ["api", "graphql"], containing: "pullRequest(number", stdout: Self.mergedPullRequest)
        gh.answer(prefix: ["api", "--hostname", "github.com"], containing: "/compare/",
                  status: 1, stdout: Self.notFound, stderr: "gh: Not Found (HTTP 404)\n")
        gh.answer(prefix: ["auth", "status"], status: 1, stderr: "You are not logged into any GitHub hosts. To log in, run: gh auth login\n")
        gh.answer(prefix: ["run", "list"], stdout: Self.runs)
        let client = GitHubCLIQueueClient(run: gh.run)

        let pullRequest = try client.read(.pullRequest(60), settings: settings).get()
        guard case .pullRequest(let snapshot) = pullRequest else { return XCTFail("\(pullRequest)") }
        XCTAssertEqual(snapshot.number, 60)
        XCTAssertEqual(try client.read(.compare(base: MQ.sha("a"), head: MQ.sha("b")), settings: settings).get(), .comparison(nil))
        guard case .failure(.notSignedIn) = client.read(.auth, settings: settings) else { return XCTFail("signed out") }
        guard case .runs(let runs) = try client.read(.baseRuns, settings: settings).get() else { return XCTFail() }
        XCTAssertEqual(runs.count, 3)
        // gh auth status that can't reach GitHub is retried, not "signed out".
        gh.answer(prefix: ["auth", "status"], status: 1,
                  stderr: "X Timeout trying to log in to github.com account acme (keyring)\n")
        guard case .failure(.noAnswer) = client.read(.auth, settings: settings) else { return XCTFail("no answer") }
        XCTAssertTrue(gh.forbidden.isEmpty, "\(gh.forbidden)")
    }

    func testAPrimaryRateLimitAsksWhenItResets() {
        let gh = ScriptedGH()
        gh.answer(prefix: ["api", "graphql"], status: 1,
                  stdout: #"{"errors":[{"type":"RATE_LIMITED","message":"API rate limit already exceeded for user ID 1."}]}"#,
                  stderr: "gh: API rate limit already exceeded for user ID 1.\n")
        gh.answer(prefix: ["api", "--hostname", "github.com", "rate_limit"],
                  stdout: Self.rateLimit.replacingOccurrences(of: #""remaining":4997"#, with: #""remaining":0"#))
        let client = GitHubCLIQueueClient(run: gh.run)
        guard case .failure(.rateLimited(let reset)) = client.read(.pullRequest(52), settings: settings) else {
            return XCTFail("rate limited")
        }
        XCTAssertEqual(reset, Date(timeIntervalSince1970: 1790619350))
    }

    func testMutationResultsComeFromGhsExit() {
        let gh = ScriptedGH()
        gh.answer(prefix: ["pr", "merge"], stdout: "")
        gh.answer(prefix: ["api", "--hostname", "github.com", "--method", "PUT"], status: 1,
                  stdout: #"{"message":"merge conflict between base and head","status":"422"}"#,
                  stderr: "gh: merge conflict between base and head (HTTP 422)\n")
        let client = GitHubCLIQueueClient(run: gh.run)
        XCTAssertEqual(client.mutate(.merge(number: 52, head: MQ.sha("a"), method: .merge), settings: settings), .sent)
        XCTAssertEqual(client.mutate(.updateBranch(number: 52, expectedHead: MQ.sha("a")), settings: settings),
                       .refused(status: 422, message: "merge conflict between base and head"))
        XCTAssertEqual(gh.calls.count, 2)
        XCTAssertTrue(gh.forbidden.isEmpty)
    }

    // MARK: Dry run

    func testDevBuildsGetTheDryRunClient() {
        let live = GitHubCLIQueueClient { _, _ in XCTFail("no gh in tests"); return .failure(.ghMissing) }
        // Refused by the requirement, not by the check itself: an API misuse
        // (errSecCSInvalidFlags) read as "not the release" once, and kept
        // the nightly from shipping; a requirement typo would too
        // (errSecCSReqInvalid). Calculator is an Apple bundle, not a
        // Developer ID one; xctest, which runs these tests, is signed ad hoc.
        XCTAssertEqual(MergeQueue.releaseSignature(atPath: "/System/Applications/Calculator.app"), .notRelease(errSecCSReqFailed))
        XCTAssertEqual(MergeQueue.ownReleaseSignature().signature, .notRelease(errSecCSReqFailed))
        // The command: 1 for an app that isn't the release or a queue that
        // would be a dry run, 2 for wrong arguments, never "not the release".
        XCTAssertEqual(MergeQueue.checkReleaseSignatureCommand(["/System/Applications/Calculator.app"]), 1)
        XCTAssertEqual(MergeQueue.checkReleaseSignatureCommand([], environment: [:],
                                                               bundleURL: URL(fileURLWithPath: "/Applications/Nirux.app")), 1)
        let calculator = "/System/Applications/Calculator.app"
        XCTAssertEqual(MergeQueue.checkReleaseSignatureCommand([calculator, calculator]), 2)
        XCTAssertEqual(MergeQueue.checkReleaseSignatureCommand(["/tmp/no-such-app-\(UUID().uuidString).app"]), 2)

        let installed = URL(fileURLWithPath: "/Applications/Nirux.app")
        let release = { MergeQueue.ReleaseSignature.release }
        let adHoc = { MergeQueue.ReleaseSignature.notRelease(errSecCSReqFailed) }
        func isLive(_ environment: [String: String], in bundle: URL = installed,
                    signed signature: () -> MergeQueue.ReleaseSignature) -> Bool {
            MergeQueue.liveDecision(environment: environment, bundleURL: bundle, signature: signature).isLive
        }
        // The release on the real state is live; an unsigned build isn't,
        // unless asked for, and only with exactly "1".
        XCTAssertTrue(isLive([:], signed: release))
        XCTAssertFalse(isLive([:], signed: adHoc))
        XCTAssertFalse(isLive(["NIRUX_MERGE_QUEUE_LIVE": "true"], signed: adHoc))
        XCTAssertTrue(isLive(["NIRUX_MERGE_QUEUE_LIVE": "1"], signed: adHoc))
        // On a state of its own, even the release is a dry run, unless asked for.
        XCTAssertFalse(isLive(["NIRUX_STATE_DIR": "/tmp/nirux-dev-x"], signed: release))
        XCTAssertTrue(isLive(["NIRUX_STATE_DIR": "/tmp/nirux-dev-x", "NIRUX_MERGE_QUEUE_LIVE": "1"], signed: adHoc))
        // scripts/bundle.sh's bundle, in a checkout, stays a dry run even
        // notarized by hand, and its signature isn't even checked.
        let checkout = FileManager.default.temporaryDirectory.appendingPathComponent("nirux-bundle-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: checkout, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: checkout) }
        FileManager.default.createFile(atPath: checkout.appendingPathComponent("Package.swift").path, contents: Data())
        XCTAssertFalse(isLive([:], in: checkout.appendingPathComponent("Nirux.app")) {
            XCTFail("checked the signature of a build in a checkout")
            return .release
        })
        // Asking for it still works there; a bare executable is never the app.
        XCTAssertTrue(isLive(["NIRUX_MERGE_QUEUE_LIVE": "1"], in: checkout.appendingPathComponent("Nirux.app"), signed: adHoc))
        XCTAssertFalse(isLive([:], in: URL(fileURLWithPath: "/usr/local/bin/nirux"), signed: release))
        // A live Nirux doesn't pass it on to what its terminals run.
        let terminal = WorkspaceState.makeTerminalEnvironment(
            profileID: "p", workspaceID: "w", agentUUID: "u", missionID: nil, missionHandoffsEnabled: false,
            executablePath: nil, launchID: "l"
        )
        let inherited = ["NIRUX_MERGE_QUEUE_LIVE": "1"].merging(terminal) { _, terminal in terminal }
        XCTAssertFalse(isLive(inherited, signed: adHoc))
        XCTAssertTrue(MergeQueue.liveDecision(environment: [:], bundleURL: installed, signature: adHoc).reason
            .hasPrefix("not the notarized release (OSStatus -67050: "))

        let dryRun = MergeQueue.client(environment: [:], bundleURL: installed, signature: .notRelease(errSecCSReqFailed),
                                       live: live)
        XCTAssertTrue(dryRun.isDryRun)
        let mutation = MergeQueue.Mutation.merge(number: 52, head: MQ.sha("a"), method: .merge)
        guard case .dryRun(let command, let reason) = dryRun.mutate(mutation, settings: settings) else {
            return XCTFail("a dry run sent a mutation")
        }
        XCTAssertEqual(command, live.commandLine(mutation, settings: settings))
        XCTAssertTrue(reason.hasPrefix("not the notarized release"), reason)
        XCTAssertTrue(MergeQueue.Files(projectID: "p", stateDirectory: URL(fileURLWithPath: "/s"), dryRun: true)?
            .journal.lastPathComponent == "queue.dry-run.log")
    }
}

/// What no merge queue call may ever be (section 4): `--admin`, `--auto`,
/// `--delete-branch`, `--rebase`, or a merge or branch update without the
/// SHA it was decided on.
enum ForbiddenCalls {
    static func problem(_ arguments: [String]) -> String? {
        for flag in ["--admin", "--auto", "--delete-branch", "-d", "--rebase", "-r", "--disable-auto"]
        where arguments.contains(flag) {
            return "forbidden flag \(flag)"
        }
        if arguments.starts(with: ["pr", "merge"]) {
            guard let index = arguments.firstIndex(of: "--match-head-commit"),
                  let sha = arguments[safe: index + 1], MergeQueue.objectID(sha) != nil
            else { return "a merge without --match-head-commit <sha>" }
        }
        if arguments.contains(where: { $0.hasSuffix("/update-branch") }) || arguments.starts(with: ["pr", "update-branch"]) {
            guard !arguments.starts(with: ["pr", "update-branch"]),
                  let field = arguments.first(where: { $0.hasPrefix("expected_head_sha=") }),
                  MergeQueue.objectID(String(field.dropFirst("expected_head_sha=".count))) != nil
            else { return "a branch update without expected_head_sha" }
        }
        return nil
    }
}

/// A recorded `gh`: answers by argument prefix and fails every forbidden
/// call it sees.
final class ScriptedGH: @unchecked Sendable {
    private struct Answer {
        let prefix: [String]
        let containing: String?
        let output: GitHubCLIQueueClient.Output
    }

    private let lock = NSLock()
    private var answers: [Answer] = []
    private(set) var calls: [[String]] = []
    private(set) var forbidden: [String] = []

    func answer(prefix: [String], containing: String? = nil, status: Int32 = 0, stdout: String = "", stderr: String = "") {
        lock.lock()
        defer { lock.unlock() }
        answers.insert(Answer(prefix: prefix, containing: containing,
                              output: .init(status: status, standardOutput: Data(stdout.utf8), standardError: Data(stderr.utf8))),
                       at: 0)
    }

    var run: @Sendable ([String], TimeInterval) -> Result<GitHubCLIQueueClient.Output, MergeQueue.ClientError> {
        { [self] arguments, _ in self.respond(arguments) }
    }

    private func respond(_ arguments: [String]) -> Result<GitHubCLIQueueClient.Output, MergeQueue.ClientError> {
        lock.lock()
        defer { lock.unlock() }
        calls.append(arguments)
        if let problem = ForbiddenCalls.problem(arguments) {
            forbidden.append(problem)
            XCTFail("forbidden gh call: \(problem): \(arguments)")
        }
        guard let answer = answers.first(where: { answer in
            arguments.starts(with: answer.prefix) && answer.containing.map { text in arguments.contains { $0.contains(text) } } ?? true
        }) else {
            return .failure(.noAnswer("no scripted answer for \(arguments.prefix(4))"))
        }
        return .success(answer.output)
    }
}
