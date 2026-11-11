import XCTest
@testable import Nirux

/// The rules a Lead proposed (RuleProposalStore): what waits for the
/// user, what can't be proposed (in the brief, waiting, dismissed, one too
/// many), what a decision leaves, and files it must not replace.
final class RuleProposalStoreTests: XCTestCase {
    private var state: URL!
    private var store: RuleProposalStore!
    private let lead = (workspaceID: "lead-workspace", agentUUID: "lead-agent")
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    override func setUpWithError() throws {
        try super.setUpWithError()
        state = FileManager.default.temporaryDirectory.appendingPathComponent("nirux-proposals-\(UUID().uuidString)")
        store = try XCTUnwrap(RuleProposalStore(spaceID: "space", stateDirectory: state))
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: state)
        super.tearDown()
    }

    private func propose(_ rule: String, brief: String = "", at date: Date? = nil) -> RuleProposalStore.ProposeOutcome {
        store.propose(rule: rule, evidence: "#395, #417", briefText: brief, lead: lead, now: date ?? now)
    }

    private func proposed(_ outcome: RuleProposalStore.ProposeOutcome) throws -> RuleProposal {
        guard case .proposed(let proposal) = outcome else {
            XCTFail("not proposed: \(outcome)")
            throw XCTSkip("not proposed")
        }
        return proposal
    }

    /// A proposal waits, cleaned, with its Lead, in a 0600 file.
    func testAProposalWaitsForTheUser() throws {
        let proposal = try proposed(propose("  Tests wait on state,\nnever on a sleep. "))
        XCTAssertEqual(proposal.rule, "Tests wait on state, never on a sleep.")
        XCTAssertEqual(proposal.evidence, "#395, #417")
        XCTAssertEqual(proposal.leadWorkspaceID, "lead-workspace")
        XCTAssertEqual(proposal.leadAgentUUID, "lead-agent")
        XCTAssertEqual(store.load().pending, [proposal])
        let attributes = try FileManager.default.attributesOfItem(atPath: store.fileURL.path)
        XCTAssertEqual(attributes[.posixPermissions] as? Int, 0o600)
        XCTAssertEqual(store.fileURL.lastPathComponent, "rule-proposals.json")
        XCTAssertEqual(store.fileURL.deletingLastPathComponent().lastPathComponent, "space")
    }

    /// Never twice: not what the brief says, not what waits, not what the
    /// user dismissed (90 days), and not past three waiting.
    func testWhatCantBeProposed() throws {
        XCTAssertEqual(
            propose("Tests wait on state.", brief: "## Rules learned\n- tests wait on STATE (learned 2026-11-11, #395)\n"),
            .inBrief(day: "2026-11-11")
        )
        let first = try proposed(propose("Tests wait on state."))
        XCTAssertEqual(propose("tests  wait on state"), .alreadyPending(since: first.proposedAt))
        _ = try proposed(propose("Check who owns the screen first."))
        _ = try proposed(propose("Never show a model's words next to Yes."))
        XCTAssertEqual(propose("A fourth rule."), .tooMany)
        XCTAssertEqual(store.load().pending.count, 3)

        try store.decide(first.id, added: false, now: now)
        let dismissed = store.propose(rule: "Tests wait on state", evidence: "#1", briefText: "", lead: lead, now: now.addingTimeInterval(86_400))
        XCTAssertEqual(dismissed, .dismissed(at: now.timeIntervalSince1970))
        // Once its 90 days are over, it can come back.
        let later = now.addingTimeInterval(RuleProposalStore.dismissedLifetime + 1)
        XCTAssertEqual(try proposed(propose("Tests wait on state", at: later)).rule, "Tests wait on state")
        XCTAssertFalse(store.load().proposals.contains { $0.dismissedAt != nil }, "the old dismissal went at the save")

        if case .refused = propose("") {} else { XCTFail("an empty rule") }
        if case .refused = propose("Wait <!-- hidden") {} else { XCTFail("a comment mark") }
    }

    /// Added, it leaves the file (the brief holds it); dismissed, it stays,
    /// dated; decided already, nothing happens.
    func testADecisionTakesTheProposalOut() throws {
        let added = try proposed(propose("Tests wait on state."))
        let dismissed = try proposed(propose("Check who owns the screen first."))
        XCTAssertEqual(try store.decide(added.id, added: true, now: now)?.id, added.id)
        XCTAssertEqual(try store.decide(dismissed.id, added: false, now: now)?.dismissedAt, now.timeIntervalSince1970)
        XCTAssertEqual(store.load().proposals.map(\.id), [dismissed.id])
        XCTAssertTrue(store.load().pending.isEmpty)
        XCTAssertNil(try store.decide(added.id, added: false, now: now))
        XCTAssertNil(try store.decide(dismissed.id, added: true, now: now))
    }

    /// A file this build can't read only held clicks to come: replaced.
    /// A newer Nirux's, or anything but a small regular file, stays.
    func testFilesItMustNotReplace() throws {
        try FileManager.default.createDirectory(at: store.fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: store.fileURL)
        XCTAssertEqual(store.load().proposals, [])
        _ = try proposed(propose("Tests wait on state."))

        let newer = Data(#"{"schemaVersion": 2, "proposals": [], "more": true}"#.utf8)
        try newer.write(to: store.fileURL)
        XCTAssertNotNil(store.load().readOnlyReason)
        if case .refused = propose("Check who owns the screen first.") {} else { XCTFail("a newer file") }
        XCTAssertThrowsError(try store.decide("any", added: true))
        XCTAssertEqual(try Data(contentsOf: store.fileURL), newer)

        try FileManager.default.removeItem(at: store.fileURL)
        XCTAssertEqual(mkfifo(store.fileURL.path, 0o600), 0)
        XCTAssertNotNil(store.load().readOnlyReason)
        if case .refused = propose("Check who owns the screen first.") {} else { XCTFail("a FIFO") }
        XCTAssertNil(RuleProposalStore(spaceID: "../escape", stateDirectory: state))
    }
}
