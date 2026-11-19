import Foundation
import os

/// The daily pass (docs/design/daily-pass.md): what happened in a space
/// since its last pass, which its Lead reads (`daily_pass`) to propose
/// the rules that would have prevented the friction (`propose_rule`).
/// Nirux gathers the facts and the Lead judges them: nothing here changes
/// the brief.
enum DailyPass {
    /// A message typed this long after it was sent, or still waiting, was
    /// held.
    static let heldAfter = MissionEventCLI.instructionHeldNotice
    /// Under the 50,000 characters past which Claude Code saves an MCP
    /// result to a file.
    static let maxCharacters = 40_000
    /// What one section lists at most.
    static let maxItems = 30
    static let maxWhyLength = 300
    static let maxQuoteLength = 160
    static let maxAnswerLength = 300
    /// The sightings a kind lists at most.
    static let maxSightings = 6

    struct Window: Equatable, Sendable {
        var start: TimeInterval
        var end: TimeInterval

        func contains(_ time: TimeInterval?) -> Bool {
            guard let time else { return false }
            return time >= start && time <= end
        }
    }

    // MARK: - GitHub

    /// A pull request merged in the window, as `gh pr list` gives it.
    struct MergedPullRequest: Equatable, Sendable {
        var number: Int
        var title: String
        var branch: String
        var mergedAt: TimeInterval
        /// Its body's Why, on one line.
        var why: String?
        /// The headlines of its commits that name a review round.
        var roundCommits: [String]
        /// The highest round they name.
        var rounds: Int
    }

    /// A workflow run started again (`gh run list`'s attempt past 1).
    struct Rerun: Equatable, Sendable {
        var id: Int
        var attempt: Int
        var branch: String
        var workflow: String
        var conclusion: String
        /// When its latest attempt started.
        var startedAt: TimeInterval
    }

    /// What GitHub said of one of the space's repositories.
    struct RepositoryReport: Equatable, Sendable {
        /// `owner/name`.
        var name: String
        var merged: [MergedPullRequest] = []
        var reruns: [Rerun] = []
        /// Why part of it couldn't be read.
        var problems: [String] = []
        /// A read failed that may work next time: the next pass reads the
        /// window again.
        var readsAgain = false
    }

    struct ReadFailure: Error, Equatable {
        let message: String
        /// gh didn't answer in time: it may next time. Anything it said
        /// (signed out, no access) holds until someone acts.
        var retryable = false
    }

    typealias GitHubRead = @Sendable (_ arguments: [String]) -> Result<Data, ReadFailure>

    static let installedGitHub: GitHubRead = { arguments in
        guard let ghPath = PRDetect.installedGHPath() else { return .failure(ReadFailure(message: "gh isn’t installed")) }
        guard let result = GitHubCLIBoardClient.runGH(ghPath, arguments: arguments, timeout: 30, maxStandardOutputBytes: 8_000_000) else {
            return .failure(ReadFailure(message: "gh didn’t answer within 30 s", retryable: true))
        }
        guard result.terminationStatus == 0 else {
            let message = WorktreeCleanup.firstLine(String(decoding: result.standardError, as: UTF8.self))
            let text = message ?? "gh exited with status \(result.terminationStatus)"
            return .failure(ReadFailure(message: text, retryable: isPassing(text)))
        }
        return .success(result.standardOutput)
    }

    /// Past 49, gh's query (each commit's authors) passes GitHub's 500,000
    /// nodes and is refused.
    static let mergedLimit = 40
    /// How long before the window a run that is rerun in it may have
    /// started: `--created` reads a run's first attempt.
    static let rerunReach: TimeInterval = 2 * 86_400

    /// What gh says when the network or GitHub may answer next time (no
    /// network yet after a wake, a rate limit, a 5xx).
    static func isPassing(_ message: String) -> Bool {
        let lowered = message.lowercased()
        return ["error connecting", "could not resolve", "connection refused", "connection reset", "network is unreachable",
                "timeout", "timed out", "rate limit", "http 500", "http 502", "http 503", "http 504"].contains { lowered.contains($0) }
    }

    static func mergedArguments(repository: String, since: TimeInterval) -> [String] {
        [
            "pr", "list", "--repo", repository, "--state", "merged", "--search", "merged:>=" + isoTime(since),
            "--json", "number,title,headRefName,mergedAt,body,commits", "--limit", "\(mergedLimit)"
        ]
    }

    static func runArguments(repository: String, since: TimeInterval) -> [String] {
        [
            "run", "list", "--repo", repository, "--created", ">=" + isoTime(since - rerunReach),
            "--json", "databaseId,attempt,headBranch,conclusion,workflowName,startedAt", "--limit", "1000"
        ]
    }

    /// Each repository's pull requests merged and runs rerun in the
    /// window, the repositories read at once: the call's wait doesn't grow
    /// with their number. Never on the main thread.
    static func readGitHub(_ repositories: [String], window: Window, read: GitHubRead) -> [RepositoryReport] {
        let reports = OSAllocatedUnfairLock(initialState: [Int: RepositoryReport]())
        DispatchQueue.concurrentPerform(iterations: repositories.count) { index in
            let report = readGitHub(repositories[index], window: window, read: read)
            reports.withLock { $0[index] = report }
        }
        return reports.withLock { found in repositories.indices.compactMap { found[$0] } }
    }

    private static func readGitHub(_ name: String, window: Window, read: GitHubRead) -> RepositoryReport {
        var report = RepositoryReport(name: name)
        func failed(_ what: String, _ failure: ReadFailure) {
            report.problems.append("\(what): \(failure.message)")
            report.readsAgain = report.readsAgain || failure.retryable
        }
        switch read(mergedArguments(repository: name, since: window.start)).map(mergedPullRequests) {
        case .success(let merged?):
            report.merged = merged.filter { window.contains($0.mergedAt) }
            if merged.count >= mergedLimit { report.problems.append("only the \(mergedLimit) newest merged pull requests were read") }
        case .success(nil): failed("merged pull requests", ReadFailure(message: "gh’s answer wasn’t its JSON"))
        case .failure(let failure): failed("merged pull requests", failure)
        }
        switch read(runArguments(repository: name, since: window.start)).map(reruns) {
        case .success(let reruns?): report.reruns = reruns.filter { window.contains($0.startedAt) }
        case .success(nil): failed("workflow runs", ReadFailure(message: "gh’s answer wasn’t its JSON"))
        case .failure(let failure): failed("workflow runs", failure)
        }
        return report
    }

    /// Nil when `data` isn't a JSON list; an entry missing its number,
    /// title or merge time is left out.
    static func mergedPullRequests(_ data: Data) -> [MergedPullRequest]? {
        guard let list = (try? JSONSerialization.jsonObject(with: data)) as? [Any] else { return nil }
        return list.compactMap { item -> MergedPullRequest? in
            guard let json = item as? [String: Any], let number = json["number"] as? Int, let title = json["title"] as? String,
                  let mergedAt = (json["mergedAt"] as? String).flatMap(time(fromISO:))
            else { return nil }
            let headlines = (json["commits"] as? [Any] ?? []).compactMap { ($0 as? [String: Any])?["messageHeadline"] as? String }
            let rounds = headlines.filter { roundNumber($0) != nil }
            return MergedPullRequest(
                number: number, title: AgentText.clean(title, maxLength: 200) ?? "", branch: json["headRefName"] as? String ?? "",
                mergedAt: mergedAt, why: why(of: json["body"] as? String ?? ""),
                roundCommits: rounds, rounds: rounds.compactMap(roundNumber).max() ?? 0
            )
        }.sorted { $0.mergedAt < $1.mergedAt }
    }

    /// Nil when `data` isn't a JSON list.
    static func reruns(_ data: Data) -> [Rerun]? {
        guard let list = (try? JSONSerialization.jsonObject(with: data)) as? [Any] else { return nil }
        return list.compactMap { item -> Rerun? in
            guard let json = item as? [String: Any], let id = json["databaseId"] as? Int, let attempt = json["attempt"] as? Int, attempt > 1,
                  let startedAt = (json["startedAt"] as? String).flatMap(time(fromISO:))
            else { return nil }
            let conclusion = (json["conclusion"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "running"
            return Rerun(
                id: id, attempt: attempt, branch: json["headBranch"] as? String ?? "", workflow: json["workflowName"] as? String ?? "",
                conclusion: conclusion, startedAt: startedAt
            )
        }
    }

    /// N in a headline's "round N", in any case: "review round 2", "the
    /// Lead's round 1".
    static func roundNumber(_ headline: String) -> Int? {
        let words = headline.lowercased().split { !$0.isLetter && !$0.isNumber }
        return zip(words, words.dropFirst()).first { $0.0 == "round" && Int($0.1) != nil }.flatMap { Int($0.1) }
    }

    /// A body's "## Why" section on one line, else its first paragraph.
    static func why(of body: String) -> String? {
        let lines = body.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }
        let section: ArraySlice<String>
        if let heading = lines.firstIndex(where: { $0.lowercased() == "## why" }) {
            section = lines[(heading + 1)...].prefix { !$0.hasPrefix("#") }
        } else {
            section = lines.drop(while: \.isEmpty).prefix { !$0.isEmpty }
        }
        return AgentText.clean(section.joined(separator: " "), maxLength: maxWhyLength)
    }

    // MARK: - CI triage

    /// A failed run Nirux triaged (CITriageStore).
    struct TriagedRun: Equatable, Sendable {
        let id: String
        let pullRequest: Int?
        let verdict: String
        let reason: String?
        let tests: [String]
        let triagedAt: TimeInterval
    }

    /// The runs of these repositories (`owner/name`) Nirux triaged in the
    /// window, and the tests it learned are flaky then.
    static func ciFacts(_ store: CITriageStore, repositories: [String], window: Window) -> (runs: [TriagedRun], flakyTests: [String]) {
        let names = repositories.map { "/" + $0.lowercased() }
        let kept = store.repositories.filter { key, _ in names.contains { key.hasSuffix($0) } }.values
        let runs = kept.flatMap { repository in
            repository.runs.filter { window.contains($0.value.triagedAt) }.map { id, record in
                TriagedRun(
                    id: id, pullRequest: record.pullRequest, verdict: record.verdict, reason: record.reason,
                    tests: record.tests, triagedAt: record.triagedAt
                )
            }
        }
        let flaky = kept.flatMap { $0.flakyTests.filter { window.contains($0.value) }.keys }
        return (runs.sorted { $0.triagedAt < $1.triagedAt }, Array(Set(flaky)).sorted())
    }

    // MARK: - Missions

    struct MissionFact: Equatable, Sendable {
        enum Kind: String, Sendable {
            case held
            case givenUp = "given up"
            case crossed
            case handedToUser = "handed to the user"
            case answeredByUser = "answered by the user"
        }

        let kind: Kind
        /// "tell to feat/x", "question from feat/x"…: the Mission's branch
        /// (or title).
        let message: String
        let sentAt: TimeInterval
        /// What happened to it, after its sending time.
        let detail: String
        let excerpt: String
        /// The answer, for a question the user answered or that was
        /// handed to them.
        var answer: String?
        /// The user wrote `answer` in Nirux, rather than the parent.
        var answeredByUser = false
    }

    /// The messages of `missions` that went wrong in the window: held
    /// (typed `heldAfter` or more after they were sent, or still waiting),
    /// given up, crossed (typed once the other side had moved on); and the
    /// questions handed to the user or answered by them. Lines that look
    /// like a secret are withheld.
    static func missionFacts(_ missions: [Mission], window: Window, timeZone: TimeZone = .current) -> [MissionFact] {
        missions.flatMap { mission in
            mission.events.flatMap { event -> [MissionFact] in
                let reading = EventReading(mission: mission, event: event, window: window, timeZone: timeZone)
                switch event.kind {
                case .instruction: return [reading.instructionFact()].compactMap { $0 }
                case .question, .completed: return reading.childMessageFacts()
                case .response: return [reading.crossedAnswerFact()].compactMap { $0 }
                case .acknowledged: return []
                }
            }
        }.sorted { $0.sentAt < $1.sentAt }
    }

    /// One event of a Mission, read for the daily pass.
    private struct EventReading {
        let mission: Mission
        let event: MissionEvent
        let window: Window
        let timeZone: TimeZone

        private func fact(_ kind: MissionFact.Kind, _ message: String, _ detail: String, answer: MissionEvent? = nil) -> MissionFact {
            var fact = MissionFact(kind: kind, message: message, sentAt: event.timestamp, detail: detail, excerpt: quote(event.message))
            fact.answer = answer.map { quote($0.message, maxLength: maxAnswerLength) }
            fact.answeredByUser = answer?.answeredByUser == true
            return fact
        }

        private func at(_ time: TimeInterval) -> String {
            clock(time, timeZone: timeZone)
        }

        /// A tell given up, crossed (typed after the task's result), held,
        /// or still waiting.
        func instructionFact() -> MissionFact? {
            let message = "tell to \(mission.branch)"
            if let expired = event.expiredAt {
                // Its time ran out, or it went in only partly.
                guard window.contains(expired) else { return nil }
                return fact(.givenUp, message, "given up after \(duration(expired - event.timestamp))")
            }
            guard let typed = event.childConsumedAt else {
                let waited = window.end - event.timestamp
                guard window.contains(event.timestamp), waited >= heldAfter else { return nil }
                return fact(.held, message, "still untyped after \(duration(waited))")
            }
            guard window.contains(typed) else { return nil }
            let result = mission.events.first { $0.kind == .completed && $0.timestamp > event.timestamp && $0.timestamp < typed }
            if let result {
                return fact(.crossed, message, "typed at \(at(typed)), after its result (\(at(result.timestamp)))")
            }
            guard typed - event.timestamp >= heldAfter else { return nil }
            return fact(.held, message, "typed \(duration(typed - event.timestamp)) later")
        }

        /// A question or a result held on its way to the parent; a question
        /// the user answered.
        func childMessageFacts() -> [MissionFact] {
            let message = (event.kind == .question ? "question from " : "result from ") + mission.branch
            let answer = mission.events.first { $0.kind == .response && $0.inReplyTo == event.id }
            var facts: [MissionFact] = []
            if let typed = event.parentTypedAt {
                if window.contains(typed), typed - event.timestamp >= heldAfter {
                    facts.append(fact(.held, message, "typed into its parent \(duration(typed - event.timestamp)) later"))
                }
            } else if event.handedToUserBecause == nil {
                // Never typed into the Lead: Nirux types one for an hour only.
                // Another parent may have read it with `receive`.
                if let answer, answer.answeredByUser != true, mission.reportsToLead == true {
                    if window.contains(answer.timestamp), answer.timestamp - event.timestamp >= heldAfter {
                        let waited = duration(answer.timestamp - event.timestamp)
                        facts.append(fact(.held, message, "answered \(waited) later, never typed into its parent"))
                    }
                } else if answer == nil, event.parentConsumedAt == nil, window.contains(event.timestamp),
                          window.end - event.timestamp >= heldAfter {
                    facts.append(fact(.held, message, "not typed into its parent after \(duration(window.end - event.timestamp))"))
                }
            }
            guard event.kind == .question else { return facts }
            if let reason = event.handedToUserBecause, window.contains(answer?.timestamp ?? event.timestamp) {
                facts.append(fact(.handedToUser, message, "why: \(quote(reason))", answer: answer))
            } else if let answer, answer.answeredByUser == true, window.contains(answer.timestamp) {
                facts.append(fact(.answeredByUser, message, "the user answered it in Nirux", answer: answer))
            }
            return facts
        }

        /// An answer typed into the task after it had asked a newer question.
        func crossedAnswerFact() -> MissionFact? {
            guard let typed = event.childConsumedAt, window.contains(typed),
                  let question = mission.events.first(where: { $0.id == event.inReplyTo }),
                  let newer = mission.events.first(where: { other in
                      other.kind == .question && other.timestamp > question.timestamp && other.timestamp < typed
                  })
            else { return nil }
            return fact(.crossed, "answer to \(mission.branch)", "typed at \(at(typed)), after its newer question (\(at(newer.timestamp)))")
        }
    }

    // MARK: - The digest

    struct Facts: Sendable {
        var spaceName: String
        var window: Window
        /// The space's recorded reviews of the last 30 days.
        var findings: [ReviewFindings.Entry]
        var repositories: [RepositoryReport]
        var triagedRuns: [TriagedRun]
        var flakyTests: [String]
        var missions: [MissionFact]
        /// RuleProposalStore's: pending, and decided in the last 90 days.
        var proposals: [RuleProposal]
        /// The brief's "Rules learned", as sessions read them now.
        var briefRules: [String]

        /// Anything for the pass to read. What GitHub didn't say isn't: a
        /// signed-out gh would make every day one.
        var hasNews: Bool {
            findings.contains { window.contains($0.time) }
                || repositories.contains { !$0.merged.isEmpty || !$0.reruns.isEmpty }
                || !triagedRuns.isEmpty || !flakyTests.isEmpty || !missions.isEmpty
                || proposals.contains { window.contains($0.decidedAt) }
        }

        /// GitHub may answer next time: the window isn't marked read.
        var readsAgain: Bool { repositories.contains(where: \.readsAgain) }

        /// The Lead row's counts, read at `time`.
        func note(at time: TimeInterval) -> Note {
            let flaky = Set(flakyTests).union(triagedRuns.filter { $0.verdict == "flaky" }.flatMap(\.tests))
            let messages = missions.filter { [.held, .givenUp].contains($0.kind) }.count
            return Note(at: time, pullRequests: repositories.map(\.merged.count).reduce(0, +), flakyTests: flaky.count, messages: messages)
        }
    }

    /// What `daily_pass` answers: what to do, then the facts, cut past
    /// `maxCharacters`.
    static func digest(_ facts: Facts, timeZone: TimeZone = .current) -> String {
        let since = clock(facts.window.start, timeZone: timeZone)
        let header = "# Daily pass · \(facts.spaceName) · since \(since)"
        guard facts.hasNews else {
            let merged = facts.repositories.contains { !$0.problems.isEmpty } ? "" : "no pull request merged, "
            let quiet = header + "\n\nNothing happened since \(since): no review recorded, \(merged)no CI failure, "
                + "no Mission message held, no rule decided. Nothing to propose: say so in one line."
            return ([quiet] + [gitHubSection(facts)].compactMap { $0 }).joined(separator: "\n\n")
        }
        // The rules before the facts: a cut takes the end.
        let sections = [
            instructions(facts),
            gitHubSection(facts),
            rulesSection(facts, timeZone: timeZone),
            findingsSection(facts, timeZone: timeZone),
            pullRequestsSection(facts),
            ciSection(facts, timeZone: timeZone),
            missionsSection(facts, timeZone: timeZone)
        ].compactMap { $0 }
        let text = ([header] + sections).joined(separator: "\n\n")
        guard text.count > maxCharacters else { return text }
        return String(text.prefix(maxCharacters)) + "\n… (cut: the digest passed \(maxCharacters) characters)"
    }

    private static func instructions(_ facts: Facts) -> String {
        let pending = facts.proposals.filter(\.isPending).count
        let limit = RuleProposalStore.maxPending
        let free = max(0, limit - pending)
        guard free > 0 else {
            return "Propose no rule now: \(limit) already wait for the user. Tell them in a few lines what you would propose "
                + "once they decide, with its evidence from this digest."
        }
        return """
            Look for the friction a rule in the brief would have prevented, and propose at most \(free) with propose_rule \
            (\(pending) of \(limit) already wait for the user), the strongest first:
            - a finding kind seen in two tasks or more, or kinds that name one class in other words;
            - a pull request that needed three review rounds or more, or whose round commits name a class another one's do;
            - a test flaky twice, a message held, given up or crossed, a question you had to hand to the user, the user's answers.
            A rule is an instruction every later task follows, in one or two lines. A bug in Nirux or a flaky test is a task \
            to start, not a rule. Cite this digest's handles (#PR, run, test, task) in evidence. Drop a candidate the brief's \
            rules or the dismissed ones already say, in other words too. Then tell the user in a few lines what you \
            proposed and what you held back.
            """
    }

    private static func gitHubSection(_ facts: Facts) -> String? {
        let lines = facts.repositories.flatMap { report in report.problems.map { "- \(report.name): \($0)" } }
        guard !lines.isEmpty else { return nil }
        let after = facts.readsAgain
            ? "The next pass reads this window again. Read what you need with gh meanwhile."
            : "Read what you need with gh."
        return section("What GitHub didn’t say", lines + [after], total: lines.count + 1)
    }

    /// The kinds seen in the window, with where else they showed up in
    /// the last 30 days.
    private static func findingsSection(_ facts: Facts, timeZone: TimeZone) -> String? {
        let kinds = ReviewFindings.kinds(facts.findings).filter { kind in kind.sightings.contains { facts.window.contains($0.time) } }
        guard !kinds.isEmpty else { return nil }
        let lines = kinds.prefix(maxItems).map { kind in
            let tasks = kind.taskCount == 1 ? "1 task" : "\(kind.taskCount) tasks"
            let sightings = kind.sightings.suffix(maxSightings).map { "\($0.handle) round \($0.round) “\(quote($0.text))”" }
            return "- \(kind.name) · \(tasks): " + sightings.joined(separator: "; ")
        }
        return section("Review findings by kind (record_review, last 30 days)", lines, total: kinds.count)
    }

    private static func pullRequestsSection(_ facts: Facts) -> String? {
        // By branch: a task's reviews before its pull request count.
        let recordedRounds = Dictionary(facts.findings.map { ($0.task, $0.round) }, uniquingKeysWith: max)
        let parts = facts.repositories.compactMap { report -> String? in
            guard !report.merged.isEmpty else { return nil }
            let lines = report.merged.prefix(maxItems).map { pull in
                let rounds = max(pull.rounds, recordedRounds[pull.branch] ?? 0)
                let reruns = report.reruns.filter { $0.branch == pull.branch }.count
                var line = "- #\(pull.number) “\(pull.title)” · branch \(pull.branch)"
                line += rounds == 1 ? " · 1 review round" : " · \(rounds) review rounds"
                if reruns > 0 { line += reruns == 1 ? " · 1 rerun" : " · \(reruns) reruns" }
                if let why = pull.why { line += "\n  Why: \(why)" }
                if !pull.roundCommits.isEmpty {
                    line += "\n  Round commits: " + pull.roundCommits.prefix(maxSightings).map { "“\(quote($0))”" }.joined(separator: "; ")
                }
                return line
            }
            return section("Pull requests merged in \(report.name)", lines, total: report.merged.count)
        }
        return parts.isEmpty ? nil : parts.joined(separator: "\n\n")
    }

    private static func ciSection(_ facts: Facts, timeZone: TimeZone) -> String? {
        var lines = facts.triagedRuns.map { run in
            var line = "- run \(run.id)" + (run.pullRequest.map { " (#\($0))" } ?? "") + ": \(run.verdict)"
            if let reason = run.reason { line += ", \(quote(reason))" }
            if !run.tests.isEmpty { line += " · failed: " + run.tests.prefix(maxSightings).joined(separator: ", ") }
            return line + " · triaged \(clock(run.triagedAt, timeZone: timeZone))"
        }
        lines += facts.flakyTests.map { "- learned flaky (failed, then passed on a rerun of the same commit): \($0)" }
        for report in facts.repositories {
            let merged = Dictionary(report.merged.map { ($0.branch, $0.number) }, uniquingKeysWith: { first, _ in first })
            lines += report.reruns.map { rerun in
                "- rerun: run \(rerun.id) · \(rerun.workflow) · branch \(rerun.branch)"
                    + (merged[rerun.branch].map { " (#\($0))" } ?? "") + " · attempt \(rerun.attempt), \(rerun.conclusion)"
            }
        }
        guard !lines.isEmpty else { return nil }
        return section("CI", Array(lines.prefix(maxItems)), total: lines.count)
    }

    private static func missionsSection(_ facts: Facts, timeZone: TimeZone) -> String? {
        guard !facts.missions.isEmpty else { return nil }
        let lines = facts.missions.prefix(maxItems).map { fact in
            let sent = clock(fact.sentAt, timeZone: timeZone)
            var line = "- \(fact.kind.rawValue) · \(fact.message), sent \(sent), \(fact.detail): “\(fact.excerpt)”"
            if fact.kind == .handedToUser || fact.kind == .answeredByUser {
                let who = fact.answeredByUser ? "The user answered" : "Answered"
                line += fact.answer.map { "\n  \(who): “\($0)”" } ?? "\n  Not answered yet."
            }
            return line
        }
        return section("Mission messages", lines, total: facts.missions.count)
    }

    private static func rulesSection(_ facts: Facts, timeZone: TimeZone) -> String? {
        var parts: [String] = []
        let decided = facts.proposals.filter { facts.window.contains($0.decidedAt) }
        if !decided.isEmpty {
            parts.append(section("Rules the user decided since then", decided.prefix(maxItems).map { proposal in
                if proposal.wasInBrief == true { return "- already in the brief: “\(proposal.addedRule ?? proposal.rule)”" }
                if proposal.addedAt != nil { return "- added: “\(proposal.addedRule ?? proposal.rule)”" }
                return "- dismissed: “\(proposal.rule)”"
            }, total: decided.count))
        }
        let pending = facts.proposals.filter(\.isPending)
        if !pending.isEmpty {
            parts.append(section("Rules waiting for the user", pending.map { "- “\($0.rule)” (\($0.evidence))" }, total: pending.count))
        }
        if !facts.briefRules.isEmpty {
            parts.append(section("The brief's rules learned", facts.briefRules.prefix(maxItems * 2).map { "- \($0)" }, total: facts.briefRules.count))
        }
        let since = facts.window.end - RuleProposalStore.dismissedLifetime
        let dismissed = facts.proposals.filter { ($0.dismissedAt ?? -.infinity) >= since }
        if !dismissed.isEmpty {
            let lines = dismissed.prefix(maxItems).map { "- “\($0.rule)”" }
            parts.append(section("Rules dismissed in the last 90 days", lines, total: dismissed.count))
        }
        return parts.isEmpty ? nil : parts.joined(separator: "\n\n")
    }

    /// A heading and its lines, saying how many were left out.
    private static func section(_ title: String, _ lines: [String], total: Int) -> String {
        let more = total > lines.count ? ["- … and \(total - lines.count) more"] : []
        return (["## \(title)"] + lines + more).joined(separator: "\n")
    }

    // MARK: - The schedule

    /// The hour a pass is due after, local time, unless the space says.
    static let defaultHour = 6
    /// The Lead's last hook event at least this long ago: it isn't working.
    static let leadIdle: TimeInterval = 30 * 60
    /// The user away from Nirux at least this long: the pass won't hold
    /// up what they came back to ask the Lead.
    static let userAway: TimeInterval = 10 * 60
    /// How long the Lead row shows a pass's note.
    static let noteLifetime: TimeInterval = 24 * 3600

    /// No pass this soon after the last: an hour moved later, or a pass the
    /// user asked for just before the hour, doesn't bring a second.
    static let minimumGap: TimeInterval = 12 * 3600

    /// When `hour` last struck at or before `now`, local time (on a day
    /// the clock skips it, the time it jumps to).
    static func lastStroke(of hour: Int, before now: TimeInterval, timeZone: TimeZone = .current) -> TimeInterval {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let date = Date(timeIntervalSince1970: now)
        let stroke = { (day: Date) in calendar.date(bySettingHour: hour, minute: 0, second: 0, of: day) }
        guard let today = stroke(date) else { return now - 86_400 }
        if today <= date { return today.timeIntervalSince1970 }
        return calendar.date(byAdding: .day, value: -1, to: date).flatMap(stroke)?.timeIntervalSince1970 ?? now - 86_400
    }

    /// Due once `hour` struck since the last pass read, was typed, or found
    /// nothing to read, and `minimumGap` after it.
    static func isDue(_ state: DailyPassState, hour: Int, now: TimeInterval, timeZone: TimeZone = .current) -> Bool {
        let stroke = lastStroke(of: hour, before: now, timeZone: timeZone)
        let last = [state.end, state.typedAt, state.checkedAt].compactMap { $0 }.max() ?? -.infinity
        return last < stroke && now - last >= minimumGap
    }

    /// Never while the Lead works, waits on the user, or the user is around:
    /// its prompt free with no question for the user, its last hook event
    /// `leadIdle` ago, nothing waiting to be typed into it, the user away
    /// `userAway` (since the Mac woke, at least).
    static func isQuiet(
        promptFree: Bool, lastHookAt: TimeInterval, messageWaiting: Bool, awaySince: TimeInterval?, now: TimeInterval
    ) -> Bool {
        promptFree && now - lastHookAt >= leadIdle && !messageWaiting && (awaySince.map { now - $0 >= userAway } ?? false)
    }

    /// How long a check waits after GitHub didn't answer, or the pass
    /// couldn't be recorded.
    static let retryAfter: TimeInterval = 15 * 60

    /// What Nirux types into the Lead's prompt when a pass is due.
    static var prompt: String {
        "\(MissionPromptText.prefix) Daily pass: call daily_pass, then propose what would have prevented the day’s friction, "
            + "as its text says."
    }

    /// The Lead row's line for a day after a pass.
    struct Note: Codable, Equatable, Sendable {
        var at: TimeInterval
        var pullRequests: Int
        var flakyTests: Int
        /// Held or given up.
        var messages: Int
    }

    /// "6 PRs, 1 flaky test, 2 rules proposed".
    static func noteCounts(_ note: Note, rulesProposed: Int) -> String {
        func counted(_ count: Int, _ one: String, _ many: String) -> String? {
            count == 0 ? nil : "\(count) \(count == 1 ? one : many)"
        }
        return [
            counted(note.pullRequests, "PR", "PRs"), counted(note.flakyTests, "flaky test", "flaky tests"),
            counted(note.messages, "message held or lost", "messages held or lost"),
            counted(rulesProposed, "rule proposed", "rules proposed") ?? "no rule proposed"
        ].compactMap { $0 }.joined(separator: ", ")
    }

    // MARK: - Text

    /// `text` on one line, its lines that look like a secret withheld.
    static func quote(_ text: String, maxLength: Int = maxQuoteLength) -> String {
        let shown = TranscriptLastMessage.withholdingSecrets(text).text
        return AgentText.clean(MissionPromptText.quoted(shown), maxLength: maxLength) ?? ""
    }

    /// `11-19 06:12`.
    static func clock(_ time: TimeInterval, timeZone: TimeZone = .current) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let parts = calendar.dateComponents([.month, .day, .hour, .minute], from: Date(timeIntervalSince1970: time))
        return String(format: "%02d-%02d %02d:%02d", parts.month ?? 0, parts.day ?? 0, parts.hour ?? 0, parts.minute ?? 0)
    }

    /// `45 min`, `2 h 40 min`, `3 d 4 h`.
    static func duration(_ seconds: TimeInterval) -> String {
        let minutes = max(0, Int(seconds / 60))
        if minutes < 60 { return "\(minutes) min" }
        if minutes < 24 * 60 { return minutes % 60 == 0 ? "\(minutes / 60) h" : "\(minutes / 60) h \(minutes % 60) min" }
        let hours = minutes / 60
        return hours % 24 == 0 ? "\(hours / 24) d" : "\(hours / 24) d \(hours % 24) h"
    }

    static func isoTime(_ time: TimeInterval) -> String {
        ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: time))
    }

    static func time(fromISO text: String) -> TimeInterval? {
        ISO8601DateFormatter().date(from: text)?.timeIntervalSince1970
    }
}

/// When a space's last daily pass read, so the next one starts there:
/// `daily-pass.json` beside its brief, 0600. A file that can't be read
/// counts as none: the next pass reads the last day.
struct DailyPassState: Codable, Equatable, Sendable {
    static let fileName = "daily-pass.json"
    /// A call this soon after the last one reads its window again, longer:
    /// the Lead asking again (after a compaction, or a call that timed out)
    /// sees the same facts.
    static let extendWithin: TimeInterval = 2 * 3600
    static let firstWindow: TimeInterval = 24 * 3600
    static let longestWindow: TimeInterval = 7 * 24 * 3600

    var start: TimeInterval?
    var end: TimeInterval?
    /// When Nirux last typed the daily line into the Lead.
    var typedAt: TimeInterval?
    /// When a due pass last found nothing to read.
    var checkedAt: TimeInterval?
    /// The last pass's counts, for the Lead row.
    var note: DailyPass.Note?

    /// The window a call at `now` reads, and the state to save once it
    /// was read; nil for a call that reads the last window again, so calls
    /// in a row don't keep stretching it. Not after Nirux typed the daily
    /// line since that read: that call is a new pass. `extending` false
    /// reads from the last read only (the daily check's news).
    func reading(now: TimeInterval, extending: Bool = true) -> (window: DailyPass.Window, next: DailyPassState?) {
        // Not over a window a quiet check marked read either.
        if extending, let start, let end, now - end < Self.extendWithin, (typedAt ?? -.infinity) <= end,
           (checkedAt ?? -.infinity) < end {
            return (DailyPass.Window(start: max(start, now - Self.longestWindow), end: now), nil)
        }
        let window = DailyPass.Window(start: max(end ?? now - Self.firstWindow, now - Self.longestWindow), end: now)
        var next = self
        (next.start, next.end) = (window.start, window.end)
        return (window, next)
    }

    /// Once a call read `reading(now:)`'s window: marked read (unless
    /// GitHub may answer next time), with its note, which keeps the time of
    /// the pass a second read reads again: the rules proposed since count.
    func afterReading(_ next: DailyPassState?, readsAgain: Bool, note: DailyPass.Note) -> DailyPassState {
        var state = self
        if let next, !readsAgain { (state.start, state.end) = (next.start, next.end) }
        state.note = note
        if next == nil, let earlier = self.note { state.note?.at = earlier.at }
        return state
    }

    static func url(spaceID: String, stateDirectory: URL = Persistence.stateDirectory) -> URL? {
        SpaceBrief.directory(spaceID: spaceID, stateDirectory: stateDirectory)?.appendingPathComponent(fileName)
    }

    static func load(spaceID: String, stateDirectory: URL = Persistence.stateDirectory) -> DailyPassState {
        guard let url = url(spaceID: spaceID, stateDirectory: stateDirectory),
              case .data(let data) = BoardConfigStore.read(url, maxBytes: 64 * 1024)
        else { return DailyPassState() }
        return (try? JSONDecoder().decode(DailyPassState.self, from: data)) ?? DailyPassState()
    }

    func save(spaceID: String, stateDirectory: URL = Persistence.stateDirectory) throws {
        guard let url = Self.url(spaceID: spaceID, stateDirectory: stateDirectory) else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try SpaceDefaultsStore.writePrivately(try encoder.encode(self), to: url)
    }
}
