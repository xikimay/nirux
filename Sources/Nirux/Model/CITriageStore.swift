import Foundation

/// What Nirux remembers of the failed runs it triaged, per repository
/// (`ci-triage.json` in the state directory):
///
/// - each run's verdict, so that a red pull request reads the same after a
///   relaunch, without asking GitHub or the model again;
/// - the tests that failed in it, which is how Nirux learns: when the same
///   run later passes (a rerun keeps the run, on the same commit), those
///   tests failed and then passed without a change. They are flaky, and
///   the next failure made only of such tests is called so (rule 6 of
///   `CITriage.decide`).
///
/// Read and written on the main actor only (`CITriageCenter`), which reads
/// the file again when another Nirux on the same state directory wrote it.
struct CITriageStore: Codable, Equatable {
    struct RunRecord: Codable, Equatable {
        /// `CITriage.signature` of the run's red checks when triaged: a
        /// later attempt that fails has another.
        var signature: String
        /// The names of those checks: the run passes once each of them
        /// does.
        var redChecks: [String]
        /// The tests that failed in that attempt (not the ones merely left
        /// unfinished: a job cancelled at its timeout stops every test that
        /// was running, flaky or not).
        var tests: [String]
        /// Those of the run's earlier attempts.
        var earlierTests: [String] = []
        /// "flaky", "real", "unsure", or "open": the rules left it to a
        /// model that gave no answer (it couldn't run), so it is asked
        /// again another time.
        var verdict: String
        var reason: String?
        var triagedAt: TimeInterval

        /// Nothing more to ask about this failure.
        var isFinal: Bool { verdict != "open" }

        var shown: CITriage.Verdict {
            switch verdict {
            case "flaky": return .flaky(reason: reason ?? CITriage.fallbackFlakyReason)
            case "real": return .real
            default: return .unsure
            }
        }

        init(
            signature: String, redChecks: [String], tests: [String], verdict: CITriage.Verdict, isUnanswered: Bool = false,
            triagedAt: TimeInterval
        ) {
            self.signature = signature
            self.redChecks = redChecks
            self.tests = tests
            self.triagedAt = triagedAt
            switch verdict {
            case .flaky(let reason):
                self.verdict = "flaky"
                self.reason = reason
            case .real:
                self.verdict = "real"
            case .unsure:
                self.verdict = isUnanswered ? "open" : "unsure"
            }
        }
    }

    struct Repository: Codable, Equatable {
        /// By run id.
        var runs: [String: RunRecord] = [:]
        /// Tests that failed and then passed on a rerun of the same commit,
        /// with when that was last seen.
        var flakyTests: [String: TimeInterval] = [:]
    }

    /// By `host/owner/name`, lowercased.
    var repositories: [String: Repository] = [:]

    /// A test fixed since stops counting as flaky: two months after its
    /// last failure that a rerun cured, a new failure of it is read
    /// afresh.
    static let flakyLifetime: TimeInterval = 60 * 24 * 60 * 60
    static let maxRunsPerRepository = 200
    static let maxFlakyTestsPerRepository = 500

    private static func key(_ repository: String) -> String { repository.lowercased() }

    func record(of run: CIFailure.Run) -> RunRecord? {
        repositories[Self.key(run.repository)]?.runs["\(run.id)"]
    }

    func knownFlaky(in repository: String, now: TimeInterval) -> Set<String> {
        let tests = repositories[Self.key(repository)]?.flakyTests ?? [:]
        return Set(tests.filter { now - $0.value < Self.flakyLifetime }.keys)
    }

    /// Keeps a triaged run. The tests of an attempt it replaces become
    /// earlier ones; read again (the same red checks), it keeps the earlier
    /// ones it had, and an answer owed twice is given up. The oldest runs
    /// go past `maxRunsPerRepository`.
    mutating func keep(_ record: RunRecord, of run: CIFailure.Run) {
        var repository = repositories[Self.key(run.repository)] ?? Repository()
        var record = record
        if let previous = repository.runs["\(run.id)"] {
            record.earlierTests = previous.signature == record.signature
                ? previous.earlierTests
                : Array(Set(previous.tests + previous.earlierTests)).sorted()
            // Owed a second time for the same failure: what can't be
            // answered now likely never will be. Kept as it is.
            if previous.signature == record.signature, !previous.isFinal, !record.isFinal { record.verdict = "unsure" }
        }
        repository.runs["\(run.id)"] = record
        if repository.runs.count > Self.maxRunsPerRepository {
            let oldest = repository.runs.sorted { $0.value.triagedAt < $1.value.triagedAt }
                .prefix(repository.runs.count - Self.maxRunsPerRepository)
            for (id, _) in oldest { repository.runs[id] = nil }
        }
        repositories[Self.key(run.repository)] = repository
    }

    /// Learns from the pull request's runs that pass now and failed when
    /// Nirux triaged them: their failing tests are flaky. A run passes
    /// when each check that was red is there and green, and none of its
    /// checks is red or still going. (A check another run of the same
    /// workflow took over is not there: that run says nothing of this
    /// one.) Returns whether the store changed.
    mutating func learn(
        fromPassedRunsOf checks: [(run: CIFailure.Run, name: String, result: ProjectBoard.CheckResult)], now: TimeInterval
    ) -> Bool {
        var results: [CIFailure.Run: [String: [ProjectBoard.CheckResult]]] = [:]
        for check in checks { results[check.run, default: [:]][check.name, default: []].append(check.result) }
        var changed = false
        for (run, byName) in results {
            let key = Self.key(run.repository)
            guard var repository = repositories[key], let record = repository.runs["\(run.id)"], !record.redChecks.isEmpty,
                  byName.values.allSatisfy({ !$0.contains(.failure) && !$0.contains(.pending) }),
                  record.redChecks.allSatisfy({ byName[$0]?.allSatisfy { $0 == .success } == true })
            else { continue }
            for test in Set(record.tests + record.earlierTests) { repository.flakyTests[test] = now }
            // Once: the run's record goes with what it taught.
            repository.runs["\(run.id)"] = nil
            if repository.flakyTests.count > Self.maxFlakyTestsPerRepository {
                let oldest = repository.flakyTests.sorted { $0.value < $1.value }
                    .prefix(repository.flakyTests.count - Self.maxFlakyTestsPerRepository)
                for (test, _) in oldest { repository.flakyTests[test] = nil }
            }
            repositories[key] = repository
            changed = true
        }
        return changed
    }

    // MARK: - On disk

    static var url: URL { Persistence.stateDirectory.appendingPathComponent("ci-triage.json") }

    /// Empty for a missing or unreadable file: the list is learned again.
    static func load(from url: URL = url) -> CITriageStore {
        (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(CITriageStore.self, from: $0) } ?? CITriageStore()
    }

    func save(to url: URL = url) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(self) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }
}
