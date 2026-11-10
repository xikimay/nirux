import Foundation

/// Tells a flaky CI failure from a real one (docs/ci-failure-triage.md).
/// Rules read the failed run first: its jobs, the failing tests and errors
/// of its log, the files the pull request changes, what Nirux learned from
/// earlier reruns. They settled 9 failures in 10 on the 188 labelled runs
/// they were measured on, with no wrong call. What they leave open (failing
/// tests the pull request doesn't edit) goes to a model, see
/// `CITriageModel`.
///
/// Only a likely flake is ever shown: saying "flaky" of a real failure
/// hides it, saying nothing costs the look every red pull request costs
/// today.
enum CITriage {
    /// What Nirux says of a pull request's red checks.
    enum Verdict: Equatable, Sendable {
        /// A rerun of the same commit would probably pass. `reason` is one
        /// line for the user.
        case flaky(reason: String)
        /// The pull request's changes broke it.
        case real
        /// Nothing settles it: shown as a red pull request always was.
        case unsure

        var flakyReason: String? {
            if case .flaky(let reason) = self { return reason }
            return nil
        }
    }

    /// What the rules make of one failed run.
    enum Decision: Equatable, Sendable {
        case flaky(reason: String)
        case real
        /// Tests failed that the pull request doesn't edit and that aren't
        /// known to be flaky: the model's part.
        case open
        /// Nothing recognized in the log, or something missing: no verdict.
        case unknown
    }

    /// One job of the run, as `gh run view --json jobs` gives it.
    struct Job: Equatable, Sendable {
        /// Its id on GitHub (`databaseId`): a job run again in a later
        /// attempt has another, one carried over keeps its own.
        var id: Int?
        let name: String
        let conclusion: String
        /// The steps it has, run or not: none when it never got a runner.
        let stepCount: Int
        let failedSteps: [String]

        var isRed: Bool {
            ["failure", "cancelled", "timed_out"].contains(conclusion)
        }
    }

    struct RunFacts: Equatable, Sendable {
        let attempt: Int
        let headSHA: String
        let jobs: [Job]

        var redJobs: [Job] { jobs.filter(\.isRed) }
    }

    /// `gh run view <id> --json attempt,headSha,jobs`. Nil for anything
    /// else, or a commit that isn't a full hexadecimal name (it goes to
    /// `git`).
    static func runFacts(fromRunView data: Data) -> RunFacts? {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let attempt = object["attempt"] as? Int,
              let headSHA = object["headSha"] as? String, isCommitName(headSHA),
              let jobs = object["jobs"] as? [[String: Any]]
        else { return nil }
        return RunFacts(attempt: attempt, headSHA: headSHA, jobs: jobs.compactMap { job in
            guard let name = job["name"] as? String else { return nil }
            let steps = job["steps"] as? [[String: Any]] ?? []
            return Job(
                id: job["databaseId"] as? Int,
                name: name,
                conclusion: (job["conclusion"] as? String ?? "").lowercased(),
                stepCount: steps.count,
                failedSteps: steps.compactMap { step in
                    ["failure", "cancelled", "timed_out"].contains((step["conclusion"] as? String ?? "").lowercased())
                        ? step["name"] as? String : nil
                }
            )
        })
    }

    static func isCommitName(_ text: String) -> Bool {
        (40...64).contains(text.count) && text.allSatisfy { $0.isASCII && $0.isHexDigit }
    }

    // MARK: - Rules

    static let downloadReason = "A dependency download failed before any test ran."

    /// Why a job that ended without a single step did, from its check
    /// run's annotations: no runner took it, or the runner was lost. Nil
    /// for any other reason: a job GitHub refuses to start (its `runs-on`
    /// or matrix doesn't evaluate) is the pull request's doing, and one
    /// cancelled by hand is nobody's flake.
    static func neverRanReason(annotations: [String]) -> String? {
        if annotations.contains(where: { $0.contains("was not acquired by Runner") }) {
            return "No runner took the job: no step ran."
        }
        if annotations.contains(where: { $0.contains("lost communication with the server") }) {
            return "The runner was lost before any step ran."
        }
        return nil
    }

    /// What an earlier attempt of the run says of a job that is red now.
    enum EarlierAttempt: Equatable, Sendable {
        /// The run's first attempt, a job this attempt didn't run again
        /// (its failure is the same one, not a second), or one that
        /// passed before.
        case none
        /// The job ran in the attempt before, and failed with these.
        case failed(LogFindings)
        /// It ran before, and what it did couldn't be read: nothing says
        /// this failure isn't the second in a row.
        case unreadable
    }

    /// The rules on one red job's findings, in the order measured:
    ///
    /// - compile errors are real, and so is a crash in a file the pull
    ///   request changes;
    /// - with no failing test, a dependency download that failed is
    ///   flaky, unless the pull request changes the dependencies or the
    ///   attempt before failed the same way;
    /// - a test that fails again on a rerun of the same commit is real;
    /// - so is a failing test whose file the pull request changes: the
    ///   file of its class's name, or the one a failure was reported in;
    /// - failing tests all known to have failed and then passed on a
    ///   rerun are flaky;
    /// - any other failing test is open.
    ///
    /// A job whose log holds an error no rule reads (`LogFindings.otherErrors`,
    /// a signal with no test left unfinished), or whose earlier attempt is
    /// unknown, gets no verdict: neither flaky nor the model's.
    ///
    /// - `changedFiles`: the pull request's, nil when they couldn't be
    ///   read (then nothing says it leaves the failure alone).
    /// - `knownFlaky`: see `CITriageStore`.
    static func decide(
        _ findings: LogFindings, changedFiles: [String]?, earlier: EarlierAttempt, knownFlaky: Set<String>
    ) -> Decision {
        if !findings.compileErrors.isEmpty { return .real }
        if let changedFiles, findings.crashes.contains(where: { changes($0.file, in: changedFiles) }) { return .real }
        let names = findings.failingTestNames
        let isExplained = findings.otherErrors.isEmpty && (findings.signals.isEmpty || !findings.unfinished.isEmpty)
        guard !names.isEmpty else {
            guard !findings.downloadFailures.isEmpty, isExplained, findings.crashes.isEmpty, let changedFiles else { return .unknown }
            switch earlier {
            case .none: break
            case .unreadable: return .unknown
            case .failed(let before): if !before.downloadFailures.isEmpty { return .unknown }
            }
            if changedFiles.contains(where: isDependencyManifest) { return .unknown }
            return .flaky(reason: downloadReason)
        }
        if case .failed(let before) = earlier, names.contains(where: Set(before.failingTestNames).contains) { return .real }
        guard let changedFiles else { return .unknown }
        let changedNames = Set(changedFiles.map { ($0 as NSString).lastPathComponent })
        if names.contains(where: { changedNames.contains(testFileName(of: $0)) }) { return .real }
        if findings.tests.contains(where: { $0.failures.contains { changes(repositoryPath($0.file), in: changedFiles) } }) { return .real }
        // What the rules can't read, the model isn't shown either.
        guard earlier != .unreadable, isExplained else { return .unknown }
        // A crash no changed file accounts for may still be the pull
        // request's (a trap in the standard library): the model sees it.
        if findings.crashes.isEmpty, names.allSatisfy(knownFlaky.contains) { return .flaky(reason: knownFlakyReason(names)) }
        return .open
    }

    /// Whether `path`, as a log names a file, is one of the changed files:
    /// the same path, one ending the other at a folder, or Swift's
    /// `Module/File.swift` form (a crash's) with a changed file's name.
    static func changes(_ path: String, in changedFiles: [String]) -> Bool {
        let parts = path.split(separator: "/")
        return changedFiles.contains { changed in
            changed == path || path.hasSuffix("/" + changed) || changed.hasSuffix("/" + path)
                || (parts.count == 2 && (changed as NSString).lastPathComponent == String(parts[1]))
        }
    }

    /// SwiftPM's manifest and its pins: a pull request that changes them
    /// changes what is downloaded.
    static func isDependencyManifest(_ path: String) -> Bool {
        ["Package.swift", "Package.resolved"].contains((path as NSString).lastPathComponent)
    }

    /// `FooTests.swift` for `FooTests.testBar`: a test class usually sits
    /// in the file of its name (what the rule was measured with).
    static func testFileName(of testName: String) -> String {
        className(of: testName) + ".swift"
    }

    static func className(of testName: String) -> String {
        String(testName.prefix { $0 != "." })
    }

    static func methodName(of testName: String) -> String {
        testName.firstIndex(of: ".").map { String(testName[testName.index(after: $0)...]) } ?? ""
    }

    static func knownFlakyReason(_ names: [String]) -> String {
        names.count == 1
            ? "\(names[0]) has failed, then passed on a rerun of the same commit before."
            : "The \(names.count) failing tests have failed, then passed on a rerun of the same commit before."
    }

    /// A run's decision from its red jobs': real as soon as one is; none
    /// when one can't be read (what it hides may be real); open when one
    /// is; flaky only when every red job is (the first one's reason).
    static func combine(jobs decisions: [Decision]) -> Decision {
        if decisions.contains(.real) { return .real }
        guard let first = decisions.first, !decisions.contains(.unknown) else { return .unknown }
        return decisions.contains(.open) ? .open : first
    }

    /// A pull request's verdict from its runs': flaky only when every red
    /// run is (the first one's reason), real as soon as one is.
    static func combine(_ verdicts: [Verdict]) -> Verdict {
        if verdicts.contains(.real) { return .real }
        guard let first = verdicts.first, verdicts.allSatisfy({ $0.flakyReason != nil }) else { return .unsure }
        return first
    }

    /// What tells one failure of a pull request from the next: its red
    /// checks, each as `CIFailure.reportKey` (a rerun that fails again has
    /// new ones).
    static func signature(of checks: [ProjectBoard.Check]) -> String {
        checks.map(CIFailure.reportKey).sorted().joined(separator: "\u{1}")
    }
}
