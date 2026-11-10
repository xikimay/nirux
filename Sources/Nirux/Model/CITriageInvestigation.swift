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
/// on what `gh` returns (the run's jobs, its failed log, the attempt
/// before, the pull request's files), then the model on what they leave
/// open, with the failing tests' source and the changed declarations read
/// from the local repository. Blocks on `gh` and `git`: off the main
/// thread.
enum CITriageInvestigation {
    struct Effects: Sendable {
        /// `gh` with these arguments: its standard output, nil when it
        /// failed, timed out or wrote more than `maxBytes`.
        var gh: @Sendable (_ arguments: [String], _ timeout: TimeInterval, _ maxBytes: Int) -> Data?
        /// `git`, read-only, in a repository: its standard output, nil
        /// when it failed.
        var git: @Sendable (_ arguments: [String], _ repositoryRoot: String) -> Data?
        /// The blobs named `<commit>:<path>`, in order, nil for one that
        /// isn't there: one `git cat-file --batch`, as git stores them (no
        /// filter or text conversion of the repository's configuration).
        var blobs: @Sendable (_ objects: [String], _ repositoryRoot: String) -> [Data?]
        /// The model's verdict on an input, nil without one.
        var model: @Sendable (Data) async -> CITriage.Verdict?

        static let live = Effects(gh: runGH, git: runGit, blobs: readBlobs, model: CITriageModel.verdict(for:))
    }

    struct Request: Equatable, Sendable {
        let run: CIFailure.Run
        let pullRequest: Int
        /// The workspace's checkout, where the pull request's commit
        /// usually is: without it the model reads names only.
        let repositoryRoot: String?
        /// Whether an agent of this repository runs on the account the
        /// model would (`NiruxShellView.isCITriageModelAllowed`).
        let isModelAllowed: Bool
        let knownFlaky: Set<String>
        /// The names of the run's checks the pull request showed red: the
        /// verdict is shown for them, so it is made of their jobs only.
        var redChecks: Set<String> = []
    }

    struct Outcome: Equatable, Sendable {
        var verdict: CITriage.Verdict = .unsure
        /// The tests that failed in the run, for the store.
        var tests: [String] = []
        /// The run was read (its jobs at least): worth remembering. False
        /// when `gh` failed, which may pass.
        var wasRead = false
        /// The rules left it to the model, and no answer came (it may not
        /// run for this workspace, or couldn't just now): asked again
        /// another time.
        var isUnanswered = false
    }

    /// The rules' part needs no model: an outcome, or the input of the
    /// model that will give one.
    private enum Reading: Sendable {
        case settled(Outcome)
        case open(Outcome, modelInput: Data)
    }

    /// `isStillWanted` is asked before anything goes to the model: the
    /// option may have been turned off while `gh` was read.
    static func investigate(
        _ request: Request, effects: Effects = .live, isStillWanted: @Sendable () async -> Bool = { true }
    ) async -> Outcome {
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
            if await isStillWanted(), let verdict = await effects.model(modelInput) {
                outcome.verdict = verdict
            } else {
                outcome.isUnanswered = true
            }
            return outcome
        }
    }

    private static let readQueue = DispatchQueue(label: "com.nirux.ci-triage.read", qos: .utility)

    private static func read(_ request: Request, effects: Effects) -> Reading {
        let run = request.run
        guard let facts = effects.gh(runViewArguments(run), 30, 1 << 20).flatMap(CITriage.runFacts(fromRunView:)),
              !facts.redJobs.isEmpty,
              // A job rerun since the pull request was read (red then,
              // running now) would be judged by the others: read later.
              request.redChecks.isEmpty || Set(facts.redJobs.map(\.name)) == request.redChecks
        else { return .settled(Outcome()) }
        // Each red job gets its decision: one that ran no step from why it
        // didn't, the others from their part of the failed log.
        var decisions: [CITriage.Decision] = facts.redJobs.filter { $0.stepCount == 0 }.map { job in
            let annotations = annotationsArguments(run, job: job).flatMap { effects.gh($0, 30, 1 << 20) }
                .map { String(decoding: $0, as: UTF8.self).split(whereSeparator: \.isNewline).map(String.init) }
            return annotations.flatMap(CITriage.neverRanReason(annotations:)).map { .flaky(reason: $0) } ?? .unknown
        }
        let ran = facts.redJobs.filter { $0.stepCount > 0 }
        var outcome = Outcome(wasRead: true)
        guard !ran.isEmpty else {
            outcome.verdict = verdict(of: CITriage.combine(jobs: decisions))
            return .settled(outcome)
        }
        guard let log = effects.gh(failedLogArguments(run, attempt: facts.attempt), 90, maxLogBytes) else { return .settled(Outcome()) }
        let findings = jobFindings(of: ran, in: CITriage.findings(inFailedLog: log))
        let merged = CITriage.LogFindings.merged(findings)
        // Failed, not merely unfinished: what a pass on the rerun may teach.
        outcome.tests = merged.tests.map(\.name)
        // A compile error is real whatever else there is: nothing more to
        // ask of GitHub.
        guard merged.compileErrors.isEmpty else {
            outcome.verdict = .real
            return .settled(outcome)
        }
        let files = merged.isEmpty ? nil : changedFilesArguments(request)
            .flatMap { effects.gh($0, 60, 16 << 20) }.flatMap(CITriage.changedFiles(fromFileList:))
        let earlier = facts.attempt > 1 ? earlierAttempts(of: ran, facts: facts, run: run, effects: effects) : [:]
        decisions += zip(ran, findings).map { job, found in
            CITriage.decide(found, changedFiles: files?.map(\.path), earlier: earlier[job.name] ?? .none, knownFlaky: request.knownFlaky)
        }
        let decision = CITriage.combine(jobs: decisions)
        guard decision == .open else {
            outcome.verdict = verdict(of: decision)
            return .settled(outcome)
        }
        guard request.isModelAllowed, let files else {
            outcome.isUnanswered = true
            return .settled(outcome)
        }
        // A failing test the commit doesn't declare where it was looked
        // for (one the base branch brought, the run testing their merge; or
        // one declared out of reach): no verdict now, asked again later.
        guard let evidence = evidence(facts: facts, findings: merged, files: files, request: request, effects: effects) else {
            outcome.isUnanswered = true
            return .settled(outcome)
        }
        return .open(outcome, modelInput: CITriage.modelInput(evidence))
    }

    private static func verdict(of decision: CITriage.Decision) -> CITriage.Verdict {
        switch decision {
        case .flaky(let reason): return .flaky(reason: reason)
        case .real: return .real
        case .open, .unknown: return .unsure
        }
    }

    /// Each job's findings, by the log's job column: none for a job the
    /// log has no line of (nothing recognized: no verdict for the run). A
    /// log without columns is its only job's.
    static func jobFindings(of jobs: [CITriage.Job], in log: [(job: String, findings: CITriage.LogFindings)]) -> [CITriage.LogFindings] {
        if jobs.count == 1, log.count == 1, log[0].job.isEmpty { return [log[0].findings] }
        return jobs.map { job in log.first { $0.job == job.name }?.findings ?? CITriage.LogFindings() }
    }

    /// What the attempt before says of each job this attempt ran again (a
    /// job GitHub carried over keeps its id: its failure is the same one).
    /// A job that failed before gets what it failed with; all of them are
    /// unreadable when `gh` can't tell.
    private static func earlierAttempts(
        of jobs: [CITriage.Job], facts: CITriage.RunFacts, run: CIFailure.Run, effects: Effects
    ) -> [String: CITriage.EarlierAttempt] {
        let unreadable = Dictionary(jobs.map { ($0.name, CITriage.EarlierAttempt.unreadable) }) { first, _ in first }
        guard let before = effects.gh(runViewArguments(run, attempt: facts.attempt - 1), 30, 1 << 20)
            .flatMap(CITriage.runFacts(fromRunView:)), jobs.allSatisfy({ $0.id != nil })
        else { return unreadable }
        let ranAgain = jobs.filter { job in before.jobs.contains { $0.name == job.name && $0.isRed && $0.id != job.id } }
        guard !ranAgain.isEmpty else { return [:] }
        guard let log = effects.gh(failedLogArguments(run, attempt: facts.attempt - 1), 90, maxLogBytes) else { return unreadable }
        let found = CITriage.findings(inFailedLog: log)
        // A job that failed then and left nothing the parser reads (a hang
        // cancelled at its timeout leaves no failed step) may have failed
        // the same way: unreadable, not clean.
        return Dictionary(ranAgain.map { job in
            let before = found.first { $0.job == job.name }?.findings
            return (job.name, before.map { $0.isEmpty ? .unreadable : .failed($0) } ?? .unreadable)
        }) { first, _ in first }
    }

    /// A failed job's log is about 1 MB here, 5 MB at most.
    static let maxLogBytes = 32 << 20

    static func runViewArguments(_ run: CIFailure.Run, attempt: Int? = nil) -> [String] {
        ["run", "view", "\(run.id)", "--repo", run.repository] + (attempt.map { ["--attempt", "\($0)"] } ?? [])
            + ["--json", "attempt,headSha,jobs"]
    }

    /// The failed steps' output of one attempt of the run: the one whose
    /// jobs were just read, not a rerun started since.
    static func failedLogArguments(_ run: CIFailure.Run, attempt: Int) -> [String] {
        ["run", "view", "\(run.id)", "--repo", run.repository, "--attempt", "\(attempt)", "--log-failed"]
    }

    /// `host`, `owner`, `name` of `host/owner/name`.
    private static func parts(of repository: String) -> [String]? {
        let parts = repository.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        return parts.count == 3 && parts.allSatisfy { !$0.isEmpty } ? parts : nil
    }

    /// Every file of the pull request, a page of 100 at a time, one JSON
    /// object a line, each patch cut at `maxPatchLength` (a generated file's
    /// would fill the output for nothing: only where its changes start is
    /// read). Nil unless the repository reads `host/owner/name`.
    static func changedFilesArguments(_ request: Request) -> [String]? {
        guard let parts = parts(of: request.run.repository) else { return nil }
        return ["api", "--hostname", parts[0], "--paginate",
                "repos/\(parts[1])/\(parts[2])/pulls/\(request.pullRequest)/files?per_page=100",
                "--jq", ".[] | {filename, patch: ((.patch // \"\") | .[0:\(maxPatchLength)])}"]
    }

    static let maxPatchLength = 20_000

    /// The messages GitHub attached to a job's check run, one a line: why
    /// a job that ran no step didn't.
    static func annotationsArguments(_ run: CIFailure.Run, job: CITriage.Job) -> [String]? {
        guard let parts = parts(of: run.repository), let id = job.id else { return nil }
        return ["api", "--hostname", parts[0], "repos/\(parts[1])/\(parts[2])/check-runs/\(id)/annotations",
                "--jq", ".[].message"]
    }

    /// What the model reads: the findings, the pull request's files, and
    /// from the local repository (when it holds the run's commit) the
    /// source of the first failing tests and the declarations each Swift
    /// file's patch edits. Nil when the repository holds the commit and
    /// none of those tests can be found in it.
    static func evidence(
        facts: CITriage.RunFacts, findings: CITriage.LogFindings, files: [CITriage.ChangedFile],
        request: Request, effects: Effects
    ) -> CITriage.Evidence? {
        var evidence = CITriage.Evidence(jobs: facts.jobs, attempt: facts.attempt, findings: findings)
        evidence.changes = files.map { CITriage.Change(path: $0.path) }
        let commit = facts.headSHA
        // A partial clone fetches what it lacks on read (git older than
        // 2.44 ignores GIT_NO_LAZY_FETCH): names only, nothing read.
        guard let root = request.repositoryRoot, effects.git(["config", "--get", "extensions.partialClone"], root) == nil,
              effects.git(["cat-file", "-e", "\(commit)^{commit}"], root) != nil
        else { return evidence }
        func sources(at paths: [String]) -> [String?] {
            // A path with a newline can't be asked for on a line.
            let asked = paths.filter { !$0.contains(where: \.isNewline) }
            let blobs = effects.blobs(asked.map { "\(commit):\($0)" }, root)
            let byPath = Dictionary(zip(asked, blobs).map { ($0, $1) }) { first, _ in first }
            return paths.map { path in (byPath[path] ?? nil).map { String(decoding: $0, as: UTF8.self) } }
        }
        let tree = effects.git(["ls-tree", "-r", "--name-only", "-z", commit], root)
            .map { $0.split(separator: 0).map { String(decoding: $0, as: UTF8.self) } } ?? []
        for name in findings.failingTestNames.prefix(CITriage.promptSources) {
            let reported = findings.tests.first { $0.name == name }?.failures.map { CITriage.repositoryPath($0.file) } ?? []
            guard let found = testSource(of: name, reported: reported, tree: tree, commit: commit, root: root, effects: effects, read: sources)
            else { return nil }
            evidence.sources.append(found)
        }
        let swift = files.enumerated().prefix(CITriage.promptFiles).filter { $0.element.path.hasSuffix(".swift") && $0.element.patch != nil }
        for (file, text) in zip(swift, sources(at: swift.map(\.element.path))) {
            guard let patch = file.element.patch, let text else { continue }
            evidence.changes[file.offset].declarations = CITriage.declarations(editedBy: patch, in: text)
        }
        return evidence
    }

    /// Where the failing test is declared at the commit: in its class, an
    /// extension of it, or a superclass (two levels up), looked for first
    /// in the file of the class's name and the files its failures were
    /// reported in, then wherever `git grep` finds the class or the method.
    private static func testSource(
        of name: String, reported: [String], tree: [String], commit: String, root: String, effects: Effects,
        read: ([String]) -> [String?]
    ) -> CITriage.TestSource? {
        let method = CITriage.methodName(of: name)
        var types = [CITriage.className(of: name)]
        var texts: [(path: String, text: String)] = []
        func add(_ paths: [String]) {
            let fresh = paths.reduce(into: [String]()) { list, path in
                if !list.contains(path), !texts.contains(where: { $0.path == path }) { list.append(path) }
            }
            for (path, text) in zip(fresh, read(fresh)) { if let text { texts.append((path, text)) } }
        }
        func search() -> CITriage.TestSource? {
            texts.lazy.compactMap { file in
                CITriage.testBody(method: method, inTypes: Set(types), in: file.text).map {
                    CITriage.TestSource(name: name, path: file.path, lines: $0)
                }
            }.first
        }
        let type = types[0]
        add(tree.filter { ($0 as NSString).lastPathComponent == "\(type).swift" } + reported.filter(tree.contains))
        if let found = search() { return found }
        add(grepFiles(["class \(type)", "extension \(type)", "func \(method)"], commit: commit, root: root, effects: effects))
        for _ in 0..<2 {
            if let found = search() { return found }
            guard let parent = texts.lazy.compactMap({ CITriage.superclass(of: types[types.count - 1], in: $0.text) }).first,
                  !types.contains(parent)
            else { return nil }
            types.append(parent)
            add(tree.filter { ($0 as NSString).lastPathComponent == "\(parent).swift" }
                + grepFiles(["class \(parent)", "extension \(parent)"], commit: commit, root: root, effects: effects))
        }
        return search()
    }

    /// The Swift files of the commit holding one of `words` (`git grep`,
    /// fixed whole words), eight at most. Words of identifiers only: they
    /// come from a log.
    private static func grepFiles(_ words: [String], commit: String, root: String, effects: Effects) -> [String] {
        let words = words.filter { $0.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" || $0 == " " } }
        guard !words.isEmpty else { return [] }
        let output = effects.git(["grep", "-l", "-z", "-w", "-F"] + words.flatMap { ["-e", $0] } + [commit, "--", "*.swift"], root) ?? Data()
        // "<commit>:<path>" each.
        return output.split(separator: 0).compactMap { entry in
            let text = String(decoding: entry, as: UTF8.self)
            return text.hasPrefix(commit + ":") ? String(text.dropFirst(commit.count + 1)) : nil
        }.prefix(8).map { $0 }
    }

    @Sendable private static func runGH(_ arguments: [String], timeout: TimeInterval, maxBytes: Int) -> Data? {
        guard let ghPath = PRDetect.installedGHPath(),
              let result = GitHubCLIBoardClient.runGH(ghPath, arguments: arguments, timeout: timeout, maxStandardOutputBytes: maxBytes),
              result.terminationStatus == 0
        else { return nil }
        return result.standardOutput
    }

    /// Read-only, and local: a partial clone doesn't fetch what it lacks.
    private static let gitEnvironment = GitDetect.readOnlyEnvironment.merging(["GIT_NO_LAZY_FETCH": "1"]) { _, new in new }

    @Sendable private static func runGit(_ arguments: [String], repositoryRoot: String) -> Data? {
        guard let result = BoundedProcess.run(
            executableURL: URL(fileURLWithPath: "/usr/bin/git"), arguments: arguments,
            currentDirectoryURL: URL(fileURLWithPath: repositoryRoot),
            environment: gitEnvironment, timeout: 15, maxStandardOutputBytes: 8 << 20
        ), result.terminationStatus == 0
        else { return nil }
        return result.standardOutput
    }

    @Sendable private static func readBlobs(_ objects: [String], repositoryRoot: String) -> [Data?] {
        guard !objects.isEmpty, let outcome = BoundedProcess.execute(
            executableURL: URL(fileURLWithPath: "/usr/bin/git"), arguments: ["cat-file", "--batch"],
            currentDirectoryURL: URL(fileURLWithPath: repositoryRoot), environment: .inherited(adding: gitEnvironment),
            standardInput: Data((objects.joined(separator: "\n") + "\n").utf8), timeout: 30, maxStandardOutputBytes: 64 << 20
        ), outcome.stop == nil, outcome.terminationStatus == 0
        else { return objects.map { _ in nil } }
        return blobs(count: objects.count, inBatchOutput: outcome.standardOutput)
    }

    /// `git cat-file --batch`'s answers, in order: "<id> <type> <size>",
    /// a newline, the content, a newline; or one line ending " missing".
    static func blobs(count: Int, inBatchOutput output: Data) -> [Data?] {
        var blobs: [Data?] = []
        var cursor = output.startIndex
        while blobs.count < count, cursor < output.endIndex, let newline = output[cursor...].firstIndex(of: 0x0A) {
            let header = String(decoding: output[cursor..<newline], as: UTF8.self).split(separator: " ")
            cursor = output.index(after: newline)
            guard header.count == 3, header[1] == "blob", let size = Int(header[2]), size >= 0,
                  output.distance(from: cursor, to: output.endIndex) >= size
            else {
                // Missing, or not a file: its line is all there is. A
                // tree or a commit has content to step over.
                if header.count == 3, let size = Int(header[2]), output.distance(from: cursor, to: output.endIndex) > size {
                    cursor = output.index(cursor, offsetBy: size + 1)
                }
                blobs.append(nil)
                continue
            }
            blobs.append(Data(output[cursor..<output.index(cursor, offsetBy: size)]))
            cursor = output.index(cursor, offsetBy: min(size + 1, output.distance(from: cursor, to: output.endIndex)))
        }
        return blobs + Array(repeating: nil, count: max(0, count - blobs.count))
    }
}
