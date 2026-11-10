import Foundation

/// The model's part of the triage: Claude Sonnet through `claude -p`, on
/// the failures the rules leave open. Measured on those (11 flakes, 10
/// real failures, 98 regressions that edit no test): 9 of the 11 flakes
/// found, no regression called flaky, 3.4 s at the median. Haiku found 6
/// or 7. About one run a week reaches it, so its price doesn't count.
enum CITriageModel {
    /// A full model name, not an alias that would move to the next model.
    static let model = "claude-sonnet-5-5"
    /// Measured p90: 5 s. A verdict that late no longer holds a
    /// notification back anyway (see `CITriageCenter.notificationHold`).
    static let timeout: TimeInterval = 45

    static let client = ClaudeOneShotRunner.Client(
        model: model, systemPrompt: CITriage.systemPrompt, timeout: timeout, maxBudgetUSD: "0.25",
        maxConcurrentRuns: 2, folderName: "NiruxCITriage"
    )

    /// On the account every client shares: a run of the turn-end
    /// classifier billed per call rests this one too.
    static let runner = ClaudeOneShotRunner(client: client)

    /// Nil when no run could go, or it gave no answer.
    @Sendable static func verdict(for input: Data) async -> CITriage.Verdict? {
        await runner.answer(to: input, read: CITriage.verdict(fromAnswer:))
    }
}

/// Reads one failed run of a pull request and says what it is: the rules
/// on what `gh` returns (the run's jobs, its failed log, the pull
/// request's files), then the model on what they leave open, with the
/// failing tests' source and the changed declarations read from the local
/// repository. Blocks on `gh` and `git`: off the main thread.
enum CITriageInvestigation {
    struct Effects: Sendable {
        /// `gh` with these arguments: its standard output, nil when it
        /// failed, timed out or wrote more than `maxBytes`.
        var gh: @Sendable (_ arguments: [String], _ timeout: TimeInterval, _ maxBytes: Int) -> Data?
        /// `git`, read-only, in a repository: its standard output, nil
        /// when it failed.
        var git: @Sendable (_ arguments: [String], _ repositoryRoot: String) -> Data?
        /// The model's verdict on an input, nil without one.
        var model: @Sendable (Data) async -> CITriage.Verdict?

        static let live = Effects(gh: runGH, git: runGit, model: CITriageModel.verdict(for:))
    }

    struct Request: Equatable, Sendable {
        let run: CIFailure.Run
        let pullRequest: Int
        /// The workspace's checkout, where the pull request's commit
        /// usually is: without it the model reads names only.
        let repositoryRoot: String?
        /// Whether the workspace's agent runs on the account the model
        /// would (`CITriageCenter.isModelAllowed`).
        let isModelAllowed: Bool
        let previousAttemptTests: Set<String>
        let knownFlaky: Set<String>
    }

    struct Outcome: Equatable, Sendable {
        var verdict: CITriage.Verdict = .unsure
        /// The failing tests of the run, for the store.
        var tests: [String] = []
        /// The run was read (its jobs at least): worth remembering. False
        /// when `gh` failed, which may pass.
        var wasRead = false
    }

    /// The rules' part needs no model: an outcome, or the input of the
    /// model that will give one.
    private enum Reading: Sendable {
        case settled(Outcome)
        case open(Outcome, modelInput: Data)
    }

    static func investigate(_ request: Request, effects: Effects = .live) async -> Outcome {
        // `gh` and `git` block for seconds: on a queue of their own, not
        // on a thread of the concurrency pool, and one run at a time (a
        // launch with many red pull requests doesn't start as many `gh`).
        let reading: Reading = await withCheckedContinuation { continuation in
            readQueue.async { continuation.resume(returning: read(request, effects: effects)) }
        }
        switch reading {
        case .settled(let outcome):
            return outcome
        case .open(var outcome, let modelInput):
            outcome.verdict = await effects.model(modelInput) ?? .unsure
            return outcome
        }
    }

    private static let readQueue = DispatchQueue(label: "com.nirux.ci-triage.read", qos: .utility)

    private static func read(_ request: Request, effects: Effects) -> Reading {
        guard let facts = effects.gh(runViewArguments(request.run), 30, 1 << 20).flatMap(CITriage.runFacts(fromRunView:)),
              !facts.redJobs.isEmpty
        else { return .settled(Outcome()) }
        if case .flaky(let reason)? = CITriage.decisionBeforeLog(facts) {
            return .settled(Outcome(verdict: .flaky(reason: reason), wasRead: true))
        }
        guard let log = effects.gh(failedLogArguments(request.run), 90, maxLogBytes) else { return .settled(Outcome()) }
        let findings = CITriage.findings(inFailedLog: log)
        var outcome = Outcome(tests: findings.failingTestNames, wasRead: true)
        // The files only matter for failing tests.
        var files: [CITriage.ChangedFile]?
        if findings.compileErrors.isEmpty, !outcome.tests.isEmpty, let arguments = changedFilesArguments(request) {
            files = effects.gh(arguments, 60, 16 << 20).flatMap(CITriage.changedFiles(fromFileList:))
        }
        switch CITriage.decide(
            findings, changedFiles: files?.map(\.path),
            previousAttemptTests: request.previousAttemptTests, knownFlaky: request.knownFlaky
        ) {
        case .flaky(let reason):
            outcome.verdict = .flaky(reason: reason)
        case .real:
            outcome.verdict = .real
        case .unknown:
            break
        case .open:
            guard request.isModelAllowed, let files else { break }
            let evidence = evidence(facts: facts, findings: findings, files: files, request: request, effects: effects)
            return .open(outcome, modelInput: CITriage.modelInput(evidence))
        }
        return .settled(outcome)
    }

    /// A failed job's log is about 1 MB here, 5 MB at most.
    static let maxLogBytes = 32 << 20

    static func runViewArguments(_ run: CIFailure.Run) -> [String] {
        ["run", "view", "\(run.id)", "--repo", run.repository, "--json", "attempt,headSha,jobs"]
    }

    /// The failed steps' output of the run's latest attempt.
    static func failedLogArguments(_ run: CIFailure.Run) -> [String] {
        ["run", "view", "\(run.id)", "--repo", run.repository, "--log-failed"]
    }

    /// Every file of the pull request, a page of 100 at a time, one JSON
    /// object a line, each patch cut at `maxPatchLength` (a generated file's
    /// would fill the output for nothing: only where its changes start is
    /// read). Nil unless the repository reads `host/owner/name`.
    static func changedFilesArguments(_ request: Request) -> [String]? {
        let parts = request.run.repository.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 3, parts.allSatisfy({ !$0.isEmpty }) else { return nil }
        return ["api", "--hostname", parts[0], "--paginate",
                "repos/\(parts[1])/\(parts[2])/pulls/\(request.pullRequest)/files?per_page=100",
                "--jq", ".[] | {filename, patch: ((.patch // \"\") | .[0:\(maxPatchLength)])}"]
    }

    static let maxPatchLength = 20_000

    /// What the model reads: the findings, the pull request's files, and
    /// from the local repository (when it holds the run's commit) the
    /// source of the first failing tests and the declarations each Swift
    /// file's patch edits.
    static func evidence(
        facts: CITriage.RunFacts, findings: CITriage.LogFindings, files: [CITriage.ChangedFile],
        request: Request, effects: Effects
    ) -> CITriage.Evidence {
        var evidence = CITriage.Evidence(jobs: facts.jobs, attempt: facts.attempt, findings: findings)
        evidence.changes = files.map { CITriage.Change(path: $0.path) }
        let commit = facts.headSHA
        guard let root = request.repositoryRoot, effects.git(["cat-file", "-e", "\(commit)^{commit}"], root) != nil
        else { return evidence }
        // The blob as git stores it: no filter or text conversion of the
        // repository's configuration runs.
        func source(at path: String) -> String? {
            effects.git(["cat-file", "blob", "\(commit):\(path)"], root).map { String(decoding: $0, as: UTF8.self) }
        }
        let tree = effects.git(["ls-tree", "-r", "--name-only", "-z", commit], root)
            .map { $0.split(separator: 0).map { String(decoding: $0, as: UTF8.self) } } ?? []
        for name in findings.failingTestNames.prefix(CITriage.promptSources) {
            let fileName = CITriage.testFileName(of: name)
            let reported = findings.tests.first { $0.name == name }?.failures.map { CITriage.repositoryPath($0.file) } ?? []
            let candidates = tree.filter { ($0 as NSString).lastPathComponent == fileName } + reported.filter(tree.contains)
            for path in candidates {
                guard let lines = source(at: path).flatMap({ CITriage.testBody(method: CITriage.methodName(of: name), in: $0) })
                else { continue }
                evidence.sources.append(CITriage.TestSource(name: name, path: path, lines: lines))
                break
            }
        }
        for (index, file) in files.enumerated().prefix(CITriage.promptFiles) where file.path.hasSuffix(".swift") {
            guard let patch = file.patch, let text = source(at: file.path) else { continue }
            evidence.changes[index].declarations = CITriage.declarations(editedBy: patch, in: text)
        }
        return evidence
    }

    @Sendable private static func runGH(_ arguments: [String], timeout: TimeInterval, maxBytes: Int) -> Data? {
        guard let ghPath = PRDetect.installedGHPath(),
              let result = BoundedProcess.run(
                  executableURL: URL(fileURLWithPath: ghPath), arguments: arguments,
                  currentDirectoryURL: FileManager.default.temporaryDirectory,
                  environment: GitHubCLIBoardClient.environment, timeout: timeout, maxStandardOutputBytes: maxBytes
              ), result.terminationStatus == 0
        else { return nil }
        return result.standardOutput
    }

    @Sendable private static func runGit(_ arguments: [String], repositoryRoot: String) -> Data? {
        guard let result = BoundedProcess.run(
            executableURL: URL(fileURLWithPath: "/usr/bin/git"), arguments: arguments,
            currentDirectoryURL: URL(fileURLWithPath: repositoryRoot),
            environment: GitDetect.readOnlyEnvironment, timeout: 15, maxStandardOutputBytes: 8 << 20
        ), result.terminationStatus == 0
        else { return nil }
        return result.standardOutput
    }
}
