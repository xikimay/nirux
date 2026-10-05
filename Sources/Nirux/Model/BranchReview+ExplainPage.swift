import Foundation

// MARK: - Explain on the page (sections 2 and 4.3)

extension BranchReview {
    /// Whether Explain can run: a `claude` that confines its runs, logged
    /// in. Otherwise the page disables Explain and says why.
    enum ExplainAvailability: Equatable, Sendable {
        case ready(ClaudeCLI, ExplainAccount)
        case unavailable(String)

        /// Locates claude and reads its account, as a run will use them.
        /// Runs claude: call it off the main thread.
        static func check(
            locate: () -> ClaudeCLI.Located = { ClaudeCLI.locate() },
            account: (ClaudeCLI) -> ExplainAccount? = { $0.account() }
        ) -> ExplainAvailability {
            let cli: ClaudeCLI
            switch locate() {
            case .ready(let found): cli = found
            case .missing:
                return .unavailable("Explain runs Claude Code, and Nirux found no claude. Install it, then Refresh.")
            case .tooOld(let paths):
                return .unavailable(
                    "Explain needs Claude Code 2.1.284 or later: the claude at \(paths.joined(separator: ", ")) is older. "
                        + "Update it, then Refresh."
                )
            case .unknown(let paths):
                return .unavailable("Nirux couldn’t check the claude at \(paths.joined(separator: ", ")). Refresh to try again.")
            }
            guard let found = account(cli) else {
                return .unavailable("Nirux couldn’t read claude’s account (claude auth status). Refresh to try again.")
            }
            guard found.isLoggedIn else {
                return .unavailable("claude isn’t logged in. Run claude in a terminal and log in, then Refresh.")
            }
            return .ready(cli, found)
        }
    }
}

extension BranchReview.ExplainAccount {
    /// Who a run bills: the first-use notice asks again when it changes.
    var identity: String {
        [method, provider ?? "", email ?? ""].joined(separator: "\u{1F}")
    }
}

extension BranchReview.ExplainSettings {
    /// The models Settings offers, measured on five merged PRs (section
    /// 4.2): Opus found the most, Sonnet runs faster.
    static let models = ["claude-opus-5-5", "claude-sonnet-5-5"]
    /// What `claude --effort` takes.
    static let efforts = ["low", "medium", "high", "xhigh", "max"]

    /// The saved model and effort, or the defaults. A model set by hand in
    /// the state file stays, if it reads as a model id: it becomes an
    /// argument of claude, which must not take it for an option.
    static func saved(_ settings: PersistedSettings? = Persistence.load()?.settings) -> Self {
        var saved = Self()
        if let model = settings?.explainModel, isModelID(model) { saved.model = model }
        if let effort = settings?.explainEffort, efforts.contains(effort) { saved.effort = effort }
        return saved
    }

    /// Lowercase letters, digits and `.-_:/[]` (`claude-opus-5-5[1m]`, a
    /// Bedrock id), starting with a letter. Never `--`: claude looks for
    /// some of its options anywhere in its arguments
    /// (`--dangerously-skip-permissions`).
    static func isModelID(_ text: String) -> Bool {
        guard let first = text.unicodeScalars.first, ("a"..."z").contains(first), text.utf8.count <= 100,
              !text.contains("--")
        else { return false }
        return text.unicodeScalars.allSatisfy { ("a"..."z").contains($0) || ("0"..."9").contains($0) || ".-_:/[]".unicodeScalars.contains($0) }
    }

    /// These settings with a model or effort claude couldn't take as such
    /// put back to the defaults: the last check before they become its
    /// arguments.
    var checked: Self {
        var checked = self
        if !Self.isModelID(model) { checked.model = Self.defaultModel }
        if !Self.efforts.contains(effort) { checked.effort = Self.defaultEffort }
        return checked
    }

    /// "Medium" for `medium`, "Extra high" for `xhigh`.
    static func effortTitle(_ effort: String) -> String {
        effort == "xhigh" ? "Extra high" : effort.prefix(1).uppercased() + effort.dropFirst()
    }

    /// "Opus 5.5" for `claude-opus-5-5`; another id as it is.
    static func displayName(of model: String) -> String {
        let parts = model.split(separator: "-").map(String.init)
        guard parts.count >= 4, parts[0] == "claude", parts[1].allSatisfy(\.isLetter),
              Int(parts[2]) != nil, Int(parts[3]) != nil
        else { return model }
        return parts[1].prefix(1).uppercased() + parts[1].dropFirst() + " \(parts[2]).\(parts[3])"
    }
}

extension BranchReview.Page {
    /// What Explain found for the branch, once it has an overview: shown
    /// as Claude's, labeled with the model and the head it read.
    struct Explanation: Encodable, Equatable, Sendable {
        struct Claim: Encodable, Equatable, Sendable {
            let claim: String
            /// "partly", "contradicts", "notInDiff".
            let verdict: String
            let evidence: String
        }

        let overview: String
        let head: String
        /// "Opus 5.5".
        let model: String
        /// The head it read is the one the page shows.
        let isCurrent: Bool
        /// The claims the code doesn't match. Matching claims are only
        /// counted, in neutral text: nothing from the model reads as
        /// approval.
        let claims: [Claim]
        let matching: Int
        let questions: [String]
    }

    /// Explain's button and what it says: whether it can run, the run
    /// waiting or under way, how the last one ended, and today's usage.
    struct ExplainBar: Encodable, Equatable, Sendable {
        enum State: String, Encodable, Sendable {
            /// Nirux looks for claude and its account.
            case checking
            case unavailable
            case ready
            case queued
            case running
            /// Cancelled: the run stops, and keeps what it reported.
            case stopping
        }

        struct Progress: Encodable, Equatable, Sendable {
            let part: Int
            let parts: Int
            /// Reads, greps and globs so far.
            let reads: Int
            let retries: Int
            /// When the run started, in milliseconds since 1970.
            let startedAt: Double
        }

        struct Usage: Encodable, Equatable, Sendable {
            let runs: Int
            let tokens: Int
            /// At API prices: a stopped run has none, so the total is at
            /// least this when `isComplete` is false.
            let costUSD: Double
            let isComplete: Bool
        }

        var state = State.checking
        /// Why it can't run, or how the last Explain ended.
        var message: String?
        /// "claude.ai, Max", once known.
        var account: String?
        /// Something was explained already: the next Explain sends only
        /// the files `changed` since, and those not explained yet.
        var explained = false
        var changed = 0
        var unexplained = 0
        /// The files Explain sends without the cache ("Explain again").
        var sendable = 0
        /// Untracked files Explain would send if included.
        var untracked = 0
        var includeUntracked = false
        var progress: Progress?
        /// Today's runs on this branch, when there were any.
        var usage: Usage?
    }
}

extension BranchReview {
    /// The bar's counts and usage for `snapshot`, from what Explain kept.
    static func explainBar(
        _ bar: Page.ExplainBar, snapshot: Snapshot, explanation: Explanation?, now: Date = Date()
    ) -> Page.ExplainBar {
        var bar = bar
        let explanation = explanation?.pruned(to: Set(snapshot.files.map(\.path)))
        var request = ExplainRequest()
        request.includeUntracked = bar.includeUntracked
        bar.sendable = snapshot.files.filter { explainSkipReason($0, request: request) == nil }.count
        request.includeUntracked = true
        bar.untracked = snapshot.files.filter { $0.isUntracked && explainSkipReason($0, request: request) == nil }.count
        let toExplain = explanation?.pathsToExplain(in: snapshot, includeUntracked: bar.includeUntracked)
        bar.explained = toExplain != nil
        bar.changed = toExplain?.filter { explanation?.files[$0] != nil }.count ?? 0
        bar.unexplained = (toExplain?.count ?? 0) - bar.changed
        if let usage = explanation?.usage(on: now), usage.tokens > 0 || usage.costUSD > 0 {
            let runs = explanation?.runs.filter { Calendar.current.isDate($0.date, inSameDayAs: now) }.count ?? 0
            bar.usage = .init(runs: runs, tokens: usage.tokens, costUSD: usage.costUSD, isComplete: usage.isComplete)
        } else {
            bar.usage = nil
        }
        return bar
    }

    static func pageExplanation(_ explanation: Explanation?, snapshot: Snapshot) -> Page.Explanation? {
        guard let explanation, explanation.hasOverview else { return nil }
        return Page.Explanation(
            overview: explanation.overview, head: explanation.head,
            model: ExplainSettings.displayName(of: explanation.model), isCurrent: explanation.head == snapshot.head,
            claims: explanation.claims.filter { $0.verdict != .matches }
                .map { Page.Explanation.Claim(claim: $0.claim, verdict: $0.verdict.rawValue, evidence: $0.evidence) },
            matching: explanation.claims.filter { $0.verdict == .matches }.count,
            questions: explanation.questions
        )
    }

    /// The groups once explained: what isn't committed first, as before,
    /// then Claude's intent groups in its order, most important file first,
    /// then "Other changes" for the files no group places, then the folded
    /// groups. A path the branch doesn't have is dropped, and a file in two
    /// groups stays in the first. Before Explain, the path groups.
    static func pageGroups(_ snapshot: Snapshot, explanation: Explanation?, ids: [String: Int]) -> [Page.Group] {
        let pathGroups = snapshot.groups
        func group(_ kind: FileGroup.Kind, _ paths: [String]) -> Page.Group {
            Page.Group(key: kind.key, title: kind.title, isFolded: kind.isFolded, files: paths.compactMap { ids[$0] })
        }
        guard let explanation, explanation.hasOverview, !explanation.groups.isEmpty else {
            return pathGroups.map { group($0.kind, $0.paths) }
        }
        let byPath = pathGroups.filter { if case .path = $0.kind { return true } else { return false } }.flatMap(\.paths)
        let rank = Dictionary(byPath.enumerated().map { ($1, $0) }) { first, _ in first }
        func ordered(_ paths: [String]) -> [String] {
            paths.sorted {
                let (left, right) = (explanation.files[$0]?.importance ?? 0, explanation.files[$1]?.importance ?? 0)
                return left != right ? left > right : rank[$0, default: 0] < rank[$1, default: 0]
            }
        }
        var placed = Set<String>()
        // Two groups of one intent and title are one: the page keys a
        // group's state by them.
        var intentGroups: [(intent: ExplainOutput.Intent, title: String, paths: [String])] = []
        for intentGroup in explanation.groups {
            let paths = intentGroup.paths.filter { rank[$0] != nil && placed.insert($0).inserted }
            guard !paths.isEmpty else { continue }
            if let index = intentGroups.firstIndex(where: { $0.intent == intentGroup.intent && $0.title == intentGroup.title }) {
                intentGroups[index].paths += paths
            } else {
                intentGroups.append((intentGroup.intent, intentGroup.title, paths))
            }
        }
        var groups = pathGroups.filter { $0.kind == .uncommitted }.map { group($0.kind, $0.paths) }
        groups += intentGroups.map {
            Page.Group(
                key: "intent.\($0.intent.rawValue).\($0.title)", title: $0.title, isFolded: false,
                files: ordered($0.paths).compactMap { ids[$0] }, intent: $0.intent.rawValue
            )
        }
        let others = byPath.filter { !placed.contains($0) }
        if !others.isEmpty {
            groups.append(Page.Group(
                key: "intent.other", title: "Other changes", isFolded: false, files: others.compactMap { ids[$0] }, intent: "other"
            ))
        }
        return groups + pathGroups.filter(\.kind.isFolded).map { group($0.kind, $0.paths) }
    }
}

extension BranchReview.ExplainResult.Ending {
    /// What the bar says once the Explain is over; nil when the page shows
    /// it all.
    var message: String? {
        switch self {
        case .explained: return nil
        case .upToDate: return "Every file Claude reads is explained at its current version."
        case .nothingToSend: return "Nothing for Claude to read: only folded, binary, secret or untracked files changed."
        case .cantKeep(let reason): return reason
        case .couldNotCopy: return "Nirux couldn’t make the read-only copy of the branch Claude reads."
        case .stopped(let outcome):
            switch outcome {
            case .explained: return nil
            case .cancelled: return "Explain stopped. What Claude finished is kept; Explain again sends the rest."
            case .timedOut:
                return "Claude took too long (6 minutes, or 3 without a word). What it finished is kept; Explain again sends the rest."
            case .usageLimit(let resetsAt):
                let reset = resetsAt.map { " It resets at \($0.formatted(date: .omitted, time: .shortened))." } ?? ""
                return "Claude’s usage limit is reached.\(reset)"
            case .failed(let failure): return failure.message
            }
        }
    }
}
