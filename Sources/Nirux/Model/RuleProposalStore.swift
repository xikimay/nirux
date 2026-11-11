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

    var isPending: Bool { dismissedAt == nil }
}

/// The rules a space's Lead proposed that wait for the user, and those the
/// user dismissed, kept 90 days so the same one isn't proposed again. An
/// added rule leaves the file: the brief holds it. In
/// `<state dir>/projects/<space id>/rule-proposals.json`, beside the brief,
/// created 0600 and replaced atomically. Only the app writes it (the Lead's
/// calls reach it through LeadChannel).
///
/// A file this build can't read is taken as empty and replaced at the next
/// change (what it held only waited for a click); one written by a newer
/// Nirux (`schemaVersion`), or that isn't a small regular file, is never
/// replaced.
struct RuleProposalStore: Sendable {
    static let fileName = "rule-proposals.json"
    static let schemaVersion = 1
    /// Proposals the user hasn't looked at yet: past these the Lead waits.
    static let maxPending = 3
    static let dismissedLifetime: TimeInterval = 90 * 24 * 3600
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
        case .missing, .unreadableBytes:
            return Loaded(proposals: [])
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

    /// Writes `proposals`, without the dismissed ones past their lifetime.
    func save(_ proposals: [RuleProposal], now: Date = Date()) throws {
        let kept = proposals.filter { proposal in
            proposal.dismissedAt.map { now.timeIntervalSince1970 - $0 < Self.dismissedLifetime } ?? true
        }
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
            LearnedRules.comparable(proposal.rule) == key
                && (proposal.dismissedAt.map { now.timeIntervalSince1970 - $0 < lifetime } ?? true)
        }) {
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

    /// Takes a pending proposal out: added, it leaves the file; dismissed,
    /// it stays, dated. Nil when it no longer waits (decided elsewhere).
    @discardableResult
    func decide(_ id: String, added: Bool, now: Date = Date()) throws -> RuleProposal? {
        let loaded = load()
        if let reason = loaded.readOnlyReason { throw ProjectMemory.WriteError.failed(reason) }
        guard let index = loaded.proposals.firstIndex(where: { $0.id == id && $0.isPending }) else { return nil }
        var proposals = loaded.proposals
        var decided = proposals[index]
        if added {
            proposals.remove(at: index)
        } else {
            decided.dismissedAt = now.timeIntervalSince1970
            proposals[index] = decided
        }
        try save(proposals, now: now)
        return decided
    }
}
