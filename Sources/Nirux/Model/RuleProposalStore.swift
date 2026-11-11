import Foundation

/// A rule a space's Lead proposed for the brief (see LearnedRules).
struct RuleProposal: Codable, Equatable, Sendable {
    let id: String
    let rule: String
    /// Where the defect showed up: "#395, #417".
    let evidence: String
    /// Epoch seconds.
    let proposedAt: TimeInterval
    /// The Lead terminal that proposed it: it hears what the user decided.
    let leadWorkspaceID: String?
    let leadAgentUUID: String?
    /// Epoch seconds; nil while it waits for the user.
    var dismissedAt: TimeInterval?
    /// Epoch seconds, once the user added it, and the words they added it
    /// with (they may have edited it).
    var addedAt: TimeInterval?
    var addedRule: String?

    var isPending: Bool { dismissedAt == nil && addedAt == nil }
    /// When the user decided it, if they did.
    var decidedAt: TimeInterval? { dismissedAt ?? addedAt }
}

/// The rules a space's Lead proposed that wait for the user, and those the
/// user decided (added, perhaps edited, or dismissed), kept 90 days so the
/// same one isn't proposed again in either wording, even once taken out of
/// the brief; the newest 100 decided ones at most. In
/// `<state dir>/projects/<space id>/rule-proposals.json`, beside the brief,
/// created 0600 and replaced atomically. Only the app writes it (the Lead's
/// calls reach it through LeadChannel).
///
/// A file that isn't JSON this build reads is taken as empty and replaced
/// at the next change: the app writes it atomically, so only something
/// else's write leaves one, and it held only clicks to come. One that can't
/// be read just now (permissions, too many open files), one written by a
/// newer Nirux (`schemaVersion`), or one that isn't a small regular file is
/// never replaced: proposing waits, and its dismissals still hold.
struct RuleProposalStore: Sendable {
    static let fileName = "rule-proposals.json"
    static let schemaVersion = 1
    /// Proposals the user hasn't looked at yet: past these the Lead waits.
    static let maxPending = 3
    static let dismissedLifetime: TimeInterval = 90 * 24 * 3600
    /// Decided proposals kept at most: the file never grows past its limit.
    static let maxDecided = 100
    static let maxFileBytes = 256 * 1024

    let fileURL: URL

    /// Nil for a space id that isn't a plain name (see `SpaceBrief.directory`).
    init?(spaceID: String, stateDirectory: URL = Persistence.stateDirectory) {
        guard let folder = SpaceBrief.directory(spaceID: spaceID, stateDirectory: stateDirectory) else { return nil }
        fileURL = folder.appendingPathComponent(Self.fileName)
    }

    private struct File: Codable {
        var schemaVersion: Int
        var proposals: [RuleProposal]
    }

    struct Loaded: Equatable, Sendable {
        var proposals: [RuleProposal]
        /// Why it can't be changed, or nil.
        var readOnlyReason: String?

        var pending: [RuleProposal] { proposals.filter(\.isPending).sorted { $0.proposedAt < $1.proposedAt } }
    }

    func load() -> Loaded {
        switch BoardConfigStore.read(fileURL, maxBytes: Self.maxFileBytes) {
        case .missing:
            return Loaded(proposals: [])
        case .unreadableBytes:
            return Loaded(proposals: [], readOnlyReason: "\(Self.fileName) can’t be read just now: try again.")
        case .tooLarge, .notARegularFile:
            return Loaded(proposals: [], readOnlyReason: "\(Self.fileName) isn’t a small regular file: Nirux leaves it alone.")
        case .data(let data):
            // A newer build's file: read what decodes, never write it back.
            let version = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["schemaVersion"] as? Int
            if let version, version > Self.schemaVersion {
                let proposals = (try? JSONDecoder().decode(File.self, from: data))?.proposals ?? []
                return Loaded(proposals: proposals, readOnlyReason: "A newer Nirux keeps this space’s proposed rules.")
            }
            return Loaded(proposals: (try? JSONDecoder().decode(File.self, from: data))?.proposals ?? [])
        }
    }

    /// Writes `proposals`, without the decided ones past their lifetime or
    /// past the newest `maxDecided`.
    func save(_ proposals: [RuleProposal], now: Date = Date()) throws {
        let recent = proposals.filter { proposal in
            proposal.decidedAt.map { now.timeIntervalSince1970 - $0 < Self.dismissedLifetime } ?? true
        }
        let dropped = Set(recent.filter { !$0.isPending }.sorted { ($0.decidedAt ?? 0) > ($1.decidedAt ?? 0) }
            .dropFirst(Self.maxDecided).map(\.id))
        let kept = recent.filter { !dropped.contains($0.id) }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(File(schemaVersion: Self.schemaVersion, proposals: kept))
        try SpaceDefaultsStore.writePrivately(data, to: fileURL)
    }

    // MARK: - Changes

    enum ProposeOutcome: Equatable {
        case proposed(RuleProposal)
        /// The brief says it already; the day it was learned, if it says.
        case inBrief(day: String?)
        case alreadyPending(since: TimeInterval)
        case dismissed(at: TimeInterval)
        /// Added, perhaps in other words, perhaps taken out of the brief since.
        case added(at: TimeInterval, as: String)
        case tooMany
        case refused(String)
    }

    /// Records a proposal unless the brief (its text: `briefText`) already
    /// says it, it waits already, the user dismissed it, or `maxPending`
    /// wait already.
    func propose(
        rule: String, evidence: String, briefText: String, lead: (workspaceID: String, agentUUID: String)?, now: Date = Date()
    ) -> ProposeOutcome {
        let rule = LearnedRules.cleaned(rule, limit: LearnedRules.maxRuleLength)
        let evidence = LearnedRules.cleaned(evidence, limit: LearnedRules.maxEvidenceLength)
        if let problem = LearnedRules.problem(rule: rule, evidence: evidence) { return .refused(problem) }
        if let existing = LearnedRules.existingRule(matching: rule, in: briefText) { return .inBrief(day: existing.day) }
        let loaded = load()
        if let reason = loaded.readOnlyReason { return .refused(reason) }
        let key = LearnedRules.comparable(rule)
        let lifetime = Self.dismissedLifetime
        if let same = loaded.proposals.first(where: { proposal in
            [proposal.rule, proposal.addedRule].contains { $0.map(LearnedRules.comparable) == key }
                && (proposal.decidedAt.map { now.timeIntervalSince1970 - $0 < lifetime } ?? true)
        }) {
            if let addedAt = same.addedAt { return .added(at: addedAt, as: same.addedRule ?? same.rule) }
            return same.dismissedAt.map { .dismissed(at: $0) } ?? .alreadyPending(since: same.proposedAt)
        }
        guard loaded.pending.count < Self.maxPending else { return .tooMany }
        let proposal = RuleProposal(
            id: UUID().uuidString, rule: rule, evidence: evidence, proposedAt: now.timeIntervalSince1970,
            leadWorkspaceID: lead?.workspaceID, leadAgentUUID: lead?.agentUUID
        )
        do {
            try save(loaded.proposals + [proposal], now: now)
        } catch {
            return .refused("Nirux couldn’t save the proposal: \(error.localizedDescription)")
        }
        return .proposed(proposal)
    }

    /// Records the user's decision on a pending proposal: added (as
    /// `addedRule`, their words) or dismissed, dated. Nil when it no longer
    /// waits (decided elsewhere).
    @discardableResult
    func decide(_ id: String, added: Bool, addedRule: String? = nil, now: Date = Date()) throws -> RuleProposal? {
        let loaded = load()
        if let reason = loaded.readOnlyReason { throw ProjectMemory.WriteError.failed(reason) }
        guard let index = loaded.proposals.firstIndex(where: { $0.id == id && $0.isPending }) else { return nil }
        var proposals = loaded.proposals
        var decided = proposals[index]
        if added {
            decided.addedAt = now.timeIntervalSince1970
            decided.addedRule = addedRule ?? decided.rule
        } else {
            decided.dismissedAt = now.timeIntervalSince1970
        }
        proposals[index] = decided
        try save(proposals, now: now)
        return decided
    }
}
