import Foundation

/// What the Lead's reviews found, as it records them (`record_review`,
/// docs/design/daily-pass.md). Each finding has a kind, a short class name
/// the Lead reuses across tasks, so a class that comes back in a second
/// task shows at once (where `propose_rule` comes in), and the daily pass
/// reads them. Kept 30 days in `review-findings.jsonl` (SpaceLog).
enum ReviewFindings {
    static let lines = SpaceLog<Entry>(fileName: "review-findings.jsonl", keptDays: 30, maxFileBytes: 2_000_000) { $0.time }
    static let maxFindings = 20
    static let maxKindLength = 40
    static let maxTextLength = 300
    /// How many of the space's other kinds an answer lists.
    static let maxKindsListed = 20

    struct Finding: Codable, Equatable, Sendable {
        var kind: String
        var text: String
    }

    struct Entry: Codable, Equatable, Sendable {
        var time: TimeInterval
        /// The task's workspace: what tells one task's reviews from
        /// another's, whatever its branch or pull request become.
        var workspace: String
        /// Its branch, else its folder or title.
        var task: String
        var pullRequest: Int?
        /// The Nth review recorded for this task.
        var round: Int
        var findings: [Finding]

        /// How the daily pass names it: its pull request, else the task.
        var handle: String { pullRequest.map { "#\($0)" } ?? task }

        enum CodingKeys: String, CodingKey { case time = "t", workspace, task, pullRequest = "pr", round, findings }
    }

    // MARK: - A call's findings

    struct Refusal: Error, Equatable {
        let reason: String
    }

    /// `kind` as a slug: lowercase ASCII letters and digits, any other run
    /// as one "-". "" when nothing is left.
    static func slug(_ kind: String) -> String {
        var slug = ""
        var pendingDash = false
        for character in kind.folding(options: [.diacriticInsensitive, .widthInsensitive], locale: nil).lowercased() {
            guard character.isASCII, character.isLetter || character.isNumber else {
                pendingDash = true
                continue
            }
            if pendingDash, !slug.isEmpty { slug.append("-") }
            pendingDash = false
            slug.append(character)
        }
        return slug
    }

    /// A call's `findings`, their kinds slugged and texts on one line.
    static func findings(_ value: Any?) -> Result<[Finding], Refusal> {
        guard let items = value as? [Any], !items.isEmpty else {
            return .failure(Refusal(reason: "findings must list 1 to \(maxFindings) findings, each {kind, text}."))
        }
        guard items.count <= maxFindings else {
            return .failure(Refusal(reason: "At most \(maxFindings) findings per review: record the ones a rule could prevent."))
        }
        var findings: [Finding] = []
        for item in items {
            guard let object = item as? [String: Any], let kind = object["kind"] as? String, let text = object["text"] as? String else {
                return .failure(Refusal(reason: "Each finding is {kind, text}, both strings."))
            }
            let slug = slug(kind)
            guard !slug.isEmpty, slug.count <= maxKindLength else {
                let example = "\"test-waits-on-sleep\""
                return .failure(Refusal(reason: "A kind is a short class name: 1 to \(maxKindLength) letters, digits and dashes (\(example))."))
            }
            guard let line = AgentText.clean(text, maxLength: maxTextLength * 4), line.count <= maxTextLength else {
                return .failure(Refusal(reason: "A finding's text holds 1 to \(maxTextLength) characters."))
            }
            findings.append(Finding(kind: slug, text: line))
        }
        return .success(findings)
    }

    // MARK: - Kinds

    /// A finding as a kind lists it.
    struct Sighting: Equatable, Sendable {
        let workspace: String
        let handle: String
        let round: Int
        let time: TimeInterval
        let text: String
    }

    struct Kind: Equatable, Sendable {
        let name: String
        /// Oldest first.
        let sightings: [Sighting]

        /// The tasks it showed up in, by handle, each once, in order.
        var handles: [String] {
            var seen = Set<String>()
            return sightings.filter { seen.insert($0.workspace).inserted }.map(\.handle)
        }

        var taskCount: Int { Set(sightings.map(\.workspace)).count }
    }

    /// Every kind of `entries`: the ones seen in the most tasks first, then
    /// the latest seen.
    static func kinds(_ entries: [Entry]) -> [Kind] {
        var sightings: [String: [Sighting]] = [:]
        for entry in entries.sorted(by: { $0.time < $1.time }) {
            for finding in entry.findings {
                sightings[finding.kind, default: []].append(Sighting(
                    workspace: entry.workspace, handle: entry.handle, round: entry.round, time: entry.time, text: finding.text
                ))
            }
        }
        return sightings.map { Kind(name: $0.key, sightings: $0.value) }.sorted { left, right in
            (left.taskCount, left.sightings.last?.time ?? 0, right.name) > (right.taskCount, right.sightings.last?.time ?? 0, left.name)
        }
    }

    // MARK: - Recording

    enum Outcome: Equatable, Sendable {
        /// The entry written, and the space's kinds of the last 30 days, it
        /// included.
        case recorded(Entry, [Kind])
        /// Nothing was written, for this reason.
        case notRecorded(String)
    }

    /// The review of a task, as `record` takes it.
    struct Review: Sendable {
        let findings: [Finding]
        let workspace: String
        /// Its branch, else its folder or title.
        let task: String
        let pullRequest: Int?
    }

    /// Records a review on `lines`'s queue, as the next round of its task;
    /// `completion` hears it on the main actor.
    static func record(
        _ review: Review, spaceID: String, now: TimeInterval = Date().timeIntervalSince1970,
        stateDirectory: URL = Persistence.stateDirectory, completion: @escaping @MainActor @Sendable (Outcome) -> Void
    ) {
        lines.queue.async {
            let outcome = recordNow(review, spaceID: spaceID, now: now, stateDirectory: stateDirectory)
            DispatchQueue.main.async { @MainActor in completion(outcome) }
        }
    }

    /// `record`'s work, on the caller's thread. The trim leaves the last 30
    /// days only.
    static func recordNow(_ review: Review, spaceID: String, now: TimeInterval, stateDirectory: URL) -> Outcome {
        lines.trim(spaceID: spaceID, now: now, stateDirectory: stateDirectory)
        guard !lines.isFull(spaceID: spaceID, stateDirectory: stateDirectory) else {
            return .notRecorded("The space’s review log is full: it frees up as reviews pass 30 days.")
        }
        let earlier = lines.load(spaceID: spaceID, stateDirectory: stateDirectory)
        let entry = Entry(
            time: now, workspace: review.workspace, task: review.task, pullRequest: review.pullRequest,
            round: earlier.filter { $0.workspace == review.workspace }.count + 1, findings: review.findings
        )
        guard lines.append(entry, spaceID: spaceID, stateDirectory: stateDirectory) else {
            return .notRecorded("Nirux couldn’t write the space’s review log.")
        }
        return .recorded(entry, kinds(earlier + [entry]))
    }

    /// What the Lead hears once a review of the task titled `title` is recorded.
    static func answer(for entry: Entry, title: String, kinds: [Kind]) -> String {
        let count = entry.findings.count
        var text = "Recorded round \(entry.round) of “\(title)”" + (entry.pullRequest.map { " (#\($0))" } ?? "")
            + ": \(count) finding\(count == 1 ? "" : "s")."
        let own = Set(entry.findings.map(\.kind))
        let repeated = kinds.filter { own.contains($0.name) && $0.taskCount > 1 }
        if !repeated.isEmpty {
            text += " Seen in another task too: "
                + repeated.map { "\($0.name) (\($0.handles.joined(separator: ", ")))" }.joined(separator: "; ")
                + ". If a rule in the brief would have prevented it, propose one with propose_rule."
        }
        let others = kinds.filter { !own.contains($0.name) }.prefix(maxKindsListed).map(\.name)
        if !others.isEmpty {
            text += " Other kinds this space used in the last 30 days: \(others.joined(separator: ", ")). "
                + "Reuse one for a finding of the same class."
        }
        return text
    }
}
