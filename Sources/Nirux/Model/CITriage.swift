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

    static let neverRanReason = "The job never started: no step ran."
    static let downloadReason = "A dependency download failed before any test ran."

    /// Before the log is read: every red job of the run ended without a
    /// single step (no runner took it, or the runner was lost). Not a run
    /// without jobs: a workflow file GitHub refuses is a real failure.
    static func decisionBeforeLog(_ facts: RunFacts) -> Decision? {
        let red = facts.redJobs
        guard !red.isEmpty, red.allSatisfy({ $0.stepCount == 0 }) else { return nil }
        return .flaky(reason: neverRanReason)
    }

    /// The rules on a log's findings, in the order measured:
    /// compile errors are real; with no failing test, a dependency
    /// download that failed is flaky; a test that fails again on a rerun
    /// of the same commit is real; so is a failing test whose file the
    /// pull request changes; failing tests all known to have failed and
    /// then passed on a rerun are flaky; any other failing test is open.
    ///
    /// - `changedFiles`: the pull request's, nil when they couldn't be
    ///   read (then failing tests stay without a verdict: nothing says the
    ///   pull request leaves them alone).
    /// - `previousAttemptTests`: what failed in an earlier attempt of this
    ///   run.
    /// - `knownFlaky`: see `CITriageStore`.
    static func decide(
        _ findings: LogFindings, changedFiles: [String]?,
        previousAttemptTests: Set<String>, knownFlaky: Set<String>
    ) -> Decision {
        if !findings.compileErrors.isEmpty { return .real }
        let names = findings.failingTestNames
        guard !names.isEmpty else {
            return findings.downloadFailures.isEmpty ? .unknown : .flaky(reason: downloadReason)
        }
        if names.contains(where: previousAttemptTests.contains) { return .real }
        guard let changedFiles else { return .unknown }
        let changedNames = Set(changedFiles.map { ($0 as NSString).lastPathComponent })
        if names.contains(where: { changedNames.contains(testFileName(of: $0)) }) { return .real }
        if names.allSatisfy(knownFlaky.contains) { return .flaky(reason: knownFlakyReason(names)) }
        return .open
    }

    /// `FooTests.swift` for `FooTests.testBar`: a test class sits in the
    /// file of its name (what the rule was measured with).
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
