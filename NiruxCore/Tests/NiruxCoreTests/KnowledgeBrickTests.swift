import Foundation
import NiruxCore
import Testing

struct KnowledgeBrickTests {
    static let anchor = "git:/repo/.git"

    static func brick(
        _ sentence: String = "AppKit rewrites a view's backing layer: its transform, clip and size.",
        subject: String = "backing layer", paths: [String] = ["Sources/Nirux/Views/**"], proofs: [Proof] = [.pullRequest(582)],
        macOS: Int? = nil, replaces: String? = nil, validatedAt: TimeInterval? = 1_000
    ) -> KnowledgeBrick {
        KnowledgeBrick(
            sentence: sentence, subject: subject, scope: .init(anchor: anchor, name: "nirux", paths: paths), proofs: proofs,
            macOS: macOS, replaces: replaces, proposedBy: "the Lead", validatedAt: validatedAt
        )
    }

    func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("knowledge-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    // MARK: Identity and shape

    @Test func aBrickIsKnownByItsFactNotByWhoProposedItOrWhen() {
        let first = Self.brick()
        var second = first
        second.proposedBy = "another Lead"
        second.validatedAt = 9_999
        #expect(first.id == second.id)
        #expect(first.id.hasPrefix("b-") && first.id.count == 14)
        var other = first
        other.proofs = [.pullRequest(594)]
        #expect(other.id != first.id)
    }

    @Test func aBrickIsOneSentenceOnProofsAboutRelativePaths() {
        #expect(Self.brick().problem == nil)
        #expect(Self.brick("Short.").problem != nil)
        #expect(Self.brick("AppKit owns the backing layer. Never set its transform by hand.").problem?.contains("one sentence") == true)
        #expect(Self.brick(subject: "x").problem != nil)
        #expect(Self.brick(paths: []).problem != nil)
        #expect(Self.brick(paths: ["/Users/me/repo/x.swift"]).problem != nil)
        #expect(Self.brick(paths: ["Sources/../../etc"]).problem != nil)
        #expect(Self.brick(proofs: []).problem != nil)
        #expect(Self.brick(proofs: [.commit("not-a-sha")]).problem != nil)
        #expect(Self.brick(proofs: [.page(url: "http://example.com", quote: "a quote long enough")]).problem != nil)
        #expect(Self.brick(proofs: [.said(quote: "keep it", day: "27/11/2026")]).problem != nil)
        #expect(Self.brick(proofs: [.test(path: "Tests/X.swift", name: "test foo")]).problem != nil)
    }

    @Test func proofsRoundTripThroughTheirKind() throws {
        let proofs: [Proof] = [
            .pullRequest(1), .commit("abc1234"), .file(path: "a.swift"), .text(path: "a.swift", text: "func a("),
            .test(path: "T.swift", name: "testA"), .page(url: "https://example.com/a", quote: "the page says this"),
            .said(quote: "do it", day: "2026-11-27")
        ]
        let data = try JSONEncoder().encode(proofs)
        #expect(try JSONDecoder().decode([Proof].self, from: data) == proofs)
        #expect(String(decoding: data, as: UTF8.self).contains(#""kind":"pullRequest""#))
    }

    // MARK: Status

    @Test func aBrickNoCheckCanContradictExpiresUntilReconfirmed() {
        let brick = Self.brick(proofs: [.pullRequest(582)], validatedAt: 0)
        var state = BrickState()
        #expect(brick.status(state, now: KnowledgeBrick.lifetime - 1, macOS: 27) == .open)
        guard case .expired = brick.status(state, now: KnowledgeBrick.lifetime, macOS: 27) else { Issue.record("not expired"); return }
        state.reconfirmedAt = KnowledgeBrick.lifetime
        #expect(brick.status(state, now: KnowledgeBrick.lifetime + 1, macOS: 27) == .open)
        let checked = Self.brick(proofs: [.pullRequest(582), .file(path: "a.swift")], validatedAt: 0)
        #expect(checked.expiry(BrickState()) == nil)
        #expect(checked.status(BrickState(), now: 10 * KnowledgeBrick.lifetime, macOS: 27) == .open)
    }

    @Test func aBrickTiedToMacOSExpiresOnAnotherMajorUntilReconfirmedThere() {
        let brick = Self.brick(proofs: [.file(path: "a.swift")], macOS: 27)
        var state = BrickState()
        #expect(brick.status(state, now: 2_000, macOS: 27) == .open)
        guard case .expired = brick.status(state, now: 2_000, macOS: 28) else { Issue.record("not expired"); return }
        state.reconfirmedMacOS = 28
        #expect(brick.status(state, now: 2_000, macOS: 28) == .open)
    }

    @Test func closedOutranksSuspectWhichOutranksExpired() {
        let brick = Self.brick(proofs: [.pullRequest(1)], validatedAt: 0)
        var state = BrickState()
        state.suspectAt = 1
        state.suspectBecause = "why"
        #expect(brick.status(state, now: 10 * KnowledgeBrick.lifetime, macOS: 27) == .suspect("why"))
        state.closedAt = 2
        state.closedBecause = "gone"
        #expect(brick.status(state, now: 0, macOS: 27) == .closed("gone"))
    }

    // MARK: Store

    @Test func theStoreKeepsBricksWrittenOnceAndIgnoresOnesChangedByHand() throws {
        let store = KnowledgeStore(spaceFolder: try folder())
        let brick = Self.brick()
        let id = try store.add(brick)
        #expect(try store.add(brick) == id)
        var state = KnowledgeState()
        state.bricks[id] = BrickState()
        try store.save(state, now: 0)
        #expect(store.load().bricks[id] == brick)
        #expect(store.load().state == state)
        let file = store.folder.appendingPathComponent("bricks/\(id).json")
        var edited = brick
        edited.sentence = "AppKit leaves a view's backing layer alone, whatever is set on it."
        try JSONEncoder().encode(edited).write(to: file)
        #expect(store.load().bricks[id] == nil)
        let attributes = try FileManager.default.attributesOfItem(atPath: store.folder.appendingPathComponent("state.json").path)
        #expect((attributes[.posixPermissions] as? Int) == 0o600)
    }

    @Test func aNewerStateIsReadButNeverChanged() throws {
        let store = KnowledgeStore(spaceFolder: try folder())
        try FileManager.default.createDirectory(at: store.folder, withIntermediateDirectories: true)
        try Data(#"{"schemaVersion": 99, "bricks": {}, "proposals": [], "checkedTips": {}}"#.utf8)
            .write(to: store.folder.appendingPathComponent("state.json"))
        let loaded = store.load()
        #expect(loaded.readOnlyReason != nil)
        #expect(loaded.refusal(of: Self.brick(), now: 0, macOS: 27) == .readOnly(loaded.readOnlyReason!))
    }

    @Test func savingDropsDecidedProposalsPastTheirLifetime() throws {
        let store = KnowledgeStore(spaceFolder: try folder())
        var state = KnowledgeState()
        var old = BrickProposal(brick: Self.brick(validatedAt: nil), proposedAt: 0)
        old.dismissedAt = 0
        let waiting = BrickProposal(brick: Self.brick(proofs: [.pullRequest(2)], validatedAt: nil), proposedAt: 0)
        state.proposals = [old, waiting]
        try store.save(state, now: KnowledgeStore.decidedLifetime + 1)
        #expect(store.load().state.proposals == [waiting])
    }

    // MARK: Proposing and deciding

    @Test func aProposalIsRefusedWhileTheSameWaitsWasDismissedOrIsABrick() {
        var loaded = KnowledgeStore.Loaded()
        let brick = Self.brick(validatedAt: nil)
        #expect(loaded.refusal(of: brick, now: 0, macOS: 27) == nil)
        loaded.state.proposals = [BrickProposal(brick: brick, proposedAt: 5)]
        #expect(loaded.refusal(of: brick, now: 6, macOS: 27) == .alreadyPending(since: 5))
        loaded.state.proposals[0].dismissedAt = 7
        #expect(loaded.refusal(of: brick, now: 8, macOS: 27) == .dismissed(at: 7))
        loaded.state.proposals = [BrickProposal(brick: brick, proposedAt: 5)]
        let done1 = loaded.validate(brick.id, now: 9)
        #expect(done1 != nil)
        #expect(loaded.refusal(of: brick, now: 10, macOS: 27) == .exists(.open))
        #expect(loaded.refusal(of: Self.brick(replaces: "b-000000000000", validatedAt: nil), now: 10, macOS: 27) == .replacesUnknown("b-000000000000"))
    }

    @Test func pendingProposalsCountAgainstTheSpacesTwentyBricks() {
        var loaded = KnowledgeStore.Loaded()
        for number in 1...KnowledgeStore.maxPending {
            loaded.state.proposals.append(BrickProposal(brick: Self.brick(proofs: [.pullRequest(number)], validatedAt: nil), proposedAt: 0))
        }
        #expect(loaded.refusal(of: Self.brick(proofs: [.pullRequest(100)], validatedAt: nil), now: 0, macOS: 27) == .tooManyPending)
        loaded.state.proposals.removeAll()
        for number in 1...KnowledgeStore.maxBricks {
            let brick = Self.brick(proofs: [.pullRequest(number)])
            loaded.bricks[brick.id] = brick
        }
        let next = Self.brick(proofs: [.pullRequest(100)], validatedAt: nil)
        #expect(loaded.refusal(of: next, now: 0, macOS: 27) == .full)
        let first = Self.brick(proofs: [.pullRequest(1)])
        #expect(loaded.refusal(of: Self.brick(proofs: [.pullRequest(100)], replaces: first.id, validatedAt: nil), now: 0, macOS: 27) == nil)
        let done2 = loaded.close(first.id, because: "gone", now: 1)
        #expect(done2)
        #expect(loaded.refusal(of: next, now: 1, macOS: 27) == nil)
    }

    @Test func validatingAReplacementClosesTheBrickItReplaces() {
        var loaded = KnowledgeStore.Loaded()
        let old = Self.brick()
        loaded.bricks[old.id] = old
        let new = Self.brick("AppKit rewrites a view's backing layer transform and clip at each layout.", replaces: old.id, validatedAt: nil)
        loaded.state.proposals = [BrickProposal(brick: new, proposedAt: 0)]
        let written = loaded.validate(new.id, now: 50)
        #expect(written?.validatedAt == 50)
        #expect(loaded.state(of: old.id).replacedBy == new.id)
        #expect(loaded.status(of: old.id, now: 51, macOS: 27) == .closed("Replaced by a brick you validated."))
        #expect(loaded.validate(new.id, now: 52) == nil)
    }

    @Test func reconfirmingClearsSuspicionButNeverReopensAClosedBrick() {
        var loaded = KnowledgeStore.Loaded()
        let brick = Self.brick()
        loaded.bricks[brick.id] = brick
        let done3 = loaded.suspect(brick.id, because: "you wrote about backing layer", now: 2)
        #expect(done3)
        let done4 = loaded.suspect(brick.id, because: "again", now: 3)
        #expect(!done4)
        #expect(loaded.status(of: brick.id, now: 3, macOS: 27) == .suspect("you wrote about backing layer"))
        let done5 = loaded.reconfirm(brick.id, now: 4, macOS: 27)
        #expect(done5)
        #expect(loaded.status(of: brick.id, now: 5, macOS: 27) == .open)
        let done6 = loaded.close(brick.id, because: "Closed by you.", now: 6)
        #expect(done6)
        let done7 = loaded.reconfirm(brick.id, now: 7, macOS: 27)
        #expect(!done7)
    }
}
