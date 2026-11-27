import Foundation
import NiruxCore
import Testing

struct KnowledgeLinksTests {
    static func brick(_ number: Int, restsOn: [String]? = nil, validatedAt: TimeInterval? = 1) -> KnowledgeBrick {
        KnowledgeBrickTests.brick("Fact \(number) about the views, one sentence long.", proofs: [.file(path: "f\(number).swift")],
                                  validatedAt: validatedAt).with(restsOn: restsOn)
    }

    @Test func citationsAreBrickIdsOncePerText() {
        #expect(KnowledgeLinks.cited(in: "Tests wait on state (b-0123456789ab, b-0123456789ab; see b-ffffffffffff).") == ["b-0123456789ab", "b-ffffffffffff"])
        #expect(KnowledgeLinks.cited(in: "b-0123 or xb-0123456789abc or b-0123456789AB").isEmpty)
        #expect(KnowledgeLinks.isBrickID("b-0123456789ab") && !KnowledgeLinks.isBrickID("b-0123456789ab "))
    }

    @Test func restingOnNothingKeepsABricksIdAndRestingOnSomethingChangesIt() {
        let plain = Self.brick(1)
        #expect(Self.brick(1, restsOn: []).id == plain.id, "a brick of the first version keeps its id")
        #expect(Self.brick(1, restsOn: ["b-0123456789ab"]).id != plain.id)
        #expect(Self.brick(1, restsOn: ["not-an-id"]).problem != nil)
        #expect(Self.brick(1, restsOn: (0..<6).map { String(format: "b-%012x", $0) }).problem != nil)
    }

    @Test func aBrickRestingOnOneNoLongerServedIsFlaggedDownTheChainUntilReconfirmed() throws {
        var loaded = KnowledgeStore.Loaded()
        let base = Self.brick(1)
        let middle = Self.brick(2, restsOn: [base.id])
        let top = Self.brick(3, restsOn: [middle.id])
        for brick in [base, middle, top] { loaded.bricks[brick.id] = brick }
        #expect(loaded.status(of: top.id, now: 10, macOS: 27) == .open)
        let closed = loaded.close(base.id, because: "f1.swift is gone.", now: 20)
        #expect(closed)
        guard case .flagged(let why)? = loaded.status(of: middle.id, now: 21, macOS: 27) else { Issue.record("middle not flagged"); return }
        #expect(why.contains(base.id) && why.contains("closed"))
        guard case .flagged? = loaded.status(of: top.id, now: 21, macOS: 27) else { Issue.record("top not flagged"); return }
        #expect(ServedKnowledge.compile(loaded, now: 21, macOS: 27).bricks.isEmpty)
        let confirmed = loaded.reconfirm(middle.id, now: 30, macOS: 27)
        #expect(confirmed)
        #expect(loaded.status(of: middle.id, now: 31, macOS: 27) == .open, "confirmed after its base closed")
        #expect(loaded.status(of: top.id, now: 31, macOS: 27) == .open)
        #expect(loaded.resting(on: base.id) == [middle.id])
    }

    @Test func confirmingTheTopOfAChainClearsItWhateverItsBaseIs() {
        var loaded = KnowledgeStore.Loaded()
        let base = Self.brick(1)
        let middle = Self.brick(2, restsOn: [base.id])
        let top = Self.brick(3, restsOn: [middle.id])
        for brick in [base, middle, top] { loaded.bricks[brick.id] = brick }
        _ = loaded.close(base.id, because: "gone", now: 20)
        _ = loaded.reconfirm(top.id, now: 30, macOS: 27)
        #expect(loaded.status(of: top.id, now: 31, macOS: 27) == .open, "its base is flagged since 20, it was confirmed at 30")
        guard case .flagged? = loaded.status(of: middle.id, now: 31, macOS: 27) else { Issue.record("middle cleared"); return }
        var tied = KnowledgeStore.Loaded()
        let system = KnowledgeBrickTests.brick("A fact that holds on one macOS only, one sentence.", proofs: [.file(path: "s.swift")], macOS: 26)
        let resting = Self.brick(4, restsOn: [system.id])
        for brick in [system, resting] { tied.bricks[brick.id] = brick }
        let stamped = tied.stampExpiries(now: 40, macOS: 27)
        #expect(stamped)
        guard case .flagged? = tied.status(of: resting.id, now: 41, macOS: 27) else { Issue.record("not flagged"); return }
        _ = tied.reconfirm(resting.id, now: 50, macOS: 27)
        #expect(tied.status(of: resting.id, now: 51, macOS: 27) == .open, "confirmed after its base expired")
    }

    @Test func aRestingBrickStopsBeingServedWithItsBase() {
        var loaded = KnowledgeStore.Loaded()
        let base = Self.brick(1).with(proofs: [.pullRequest(1)])
        let resting = Self.brick(2, restsOn: [base.id])
        for brick in [base, resting] { loaded.bricks[brick.id] = brick }
        let served = ServedKnowledge.compile(loaded, now: 10, macOS: 27).bricks.first { $0.id == resting.id }
        #expect(served?.servedUntil == base.expiry(BrickState()), "a stale served.json stops it with its base")
    }

    @Test func aBrickRestsOnEachOnceAndNeverOnWhatItReplaces() {
        #expect(Self.brick(1, restsOn: ["b-0123456789ab", "b-0123456789ab"]).problem != nil)
        var replacing = Self.brick(1, restsOn: ["b-0123456789ab"])
        replacing.replaces = "b-0123456789ab"
        #expect(replacing.problem?.contains("replaces") == true)
    }

    @Test func aBrickMayRestOnlyOnBricksAgentsGet() {
        var loaded = KnowledgeStore.Loaded()
        let base = Self.brick(1)
        loaded.bricks[base.id] = base
        #expect(loaded.refusal(of: Self.brick(2, restsOn: ["b-0123456789ab"], validatedAt: nil), now: 2, macOS: 27) == .restsOnUnknown("b-0123456789ab"))
        _ = loaded.suspect(base.id, because: "why", now: 3)
        #expect(loaded.refusal(of: Self.brick(2, restsOn: [base.id], validatedAt: nil), now: 4, macOS: 27) == .restsOnNotServed(base.id, .suspect("why")))
    }

    // MARK: Flags

    @Test func aFlagIsOneShortLineWithoutSecretsOrContactDetails() {
        #expect(KnowledgeFlag.problem(about: "backing layer", text: "the brick says clip, the code sets bounds", evidence: "GlassView.swift:40") == nil)
        #expect(KnowledgeFlag.problem(about: "", text: "x", evidence: nil) != nil)
        #expect(KnowledgeFlag.problem(about: "a", text: "two\nlines", evidence: nil) != nil)
        for leak in ["token = ghp_0123456789abcdefghijABCDEFGHIJ", "password: hunter22secret", "write to jane.doe@example.com",
                     "call +33 6 12 34 56 78", "key sk-ant-0123456789abcdefghijklmnop", "-----BEGIN RSA PRIVATE KEY-----",
                     "ring 06 12 34 56 78", "Authorization: Bearer abcdefghijklmnopqrstuvwxyz012345", "secret = \"s3cr3t-value\""] {
            #expect(KnowledgeFlag.problem(about: "x", text: leak, evidence: nil) != nil, "\(leak)")
        }
        for ordinary in ["commit 0123456789abcdef0123456789abcdef01234567 on main", "Resources/icon@2x.png has the wrong size",
                         "the run at +0000 2026-11-27 broke it", "PR #793 merged at 12:04:55", "macOS 27.2 and Swift 6.2",
                         "the remote is git@github.com:acme/app.git", "commits by noreply@anthropic.com", "let token = makeToken()",
                         "secret: keychainItem", "pkg@1.2.3-beta.rc"] {
            #expect(KnowledgeFlag.problem(about: "x", text: ordinary, evidence: nil) == nil, "\(ordinary)")
        }
    }

    @Test func flagsAreKeptNinetyDaysAndOnlyThoseOnABrickFaultIt() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("kf-\(UUID().uuidString)")
        let store = KnowledgeStore(spaceFolder: folder)
        let gap = KnowledgeFlag(time: 1, kind: .gap, brick: nil, about: "merge train", text: "riders show as Merge #N", evidence: nil, task: "w1")
        let error = KnowledgeFlag(time: 2, kind: .error, brick: "b-0123456789ab", about: "x", text: "wrong", evidence: nil, task: "w2")
        try KnowledgeFlag.append(gap, in: store)
        try KnowledgeFlag.append(error, in: store)
        #expect(KnowledgeFlag.load(in: store) == [gap, error])
        #expect(!gap.faultsItsBrick && error.faultsItsBrick)
        KnowledgeFlag.trim(in: store, now: 1.5 + Double(KnowledgeFlag.keptDays) * 86_400)
        #expect(KnowledgeFlag.load(in: store) == [error])
        var loaded = KnowledgeStore.Loaded()
        let first = loaded.dismissFlag(gap.id)
        let again = loaded.dismissFlag(gap.id)
        #expect(first && !again)
        #expect(loaded.state.dismissedFlags == [gap.id])
    }
}

extension KnowledgeBrick {
    func with(proofs: [Proof]) -> KnowledgeBrick {
        var brick = self
        brick.proofs = proofs
        return brick
    }

    func with(restsOn: [String]?) -> KnowledgeBrick {
        var brick = self
        brick.restsOn = restsOn
        return brick
    }
}
