import Foundation
@testable import NiruxCore
import Testing

struct MissionDeliveryTests {
    typealias Letter = MissionMailbox.Letter
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    var mailbox: MissionMailbox { MissionMailbox(root: root) }

    @Test(arguments: [
        ([], false, nil),
        ([.typed], false, .typed),
        ([.typed], true, nil),
        ([.queue], false, .queue),
        ([.queue], true, .queue),
        ([.hook, .typed], true, .hook),
        ([.typed, .hook, .push], false, .push),
    ] as [(Set<MissionTransport>, Bool, MissionTransport?)])
    func policyTakesTheMostWantedCarrierAndTypesOnlyAsTheLast(carriers: Set<MissionTransport>, refused: Bool, expected: MissionTransport?) {
        #expect(MissionDeliveryPolicy.transport(carriers: carriers, typingRefused: refused) == expected)
    }

    @Test func lettersWaitInOrderUntilOneClaimTakesThemAll() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let second = Letter(id: "b", text: "second", postedAt: 20)
        let first = Letter(id: "a", text: "first", postedAt: 10)
        #expect(try mailbox.post(second, to: "session"))
        #expect(try mailbox.post(first, to: "session"))
        #expect(mailbox.waiting(for: "session") == [first, second])
        #expect(mailbox.claim("session", at: 30) == [first, second])
        #expect(mailbox.claim("session", at: 31).isEmpty)
        #expect(mailbox.waiting(for: "session").isEmpty)
        #expect(mailbox.claims().map(\.letter) == [first, second])
        #expect(mailbox.claims().map(\.claimedAt) == [30, 30])
    }

    @Test func aClaimedLetterCantBeTakenBackAndARetractedOneIsNeverClaimed() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        try mailbox.post(Letter(id: "kept", text: "", postedAt: 1), to: "session")
        try mailbox.post(Letter(id: "back", text: "", postedAt: 2), to: "session")
        #expect(try mailbox.retract("back", from: "session") == .retracted)
        #expect(mailbox.claim("session", at: 3).map(\.id) == ["kept"])
        #expect(try mailbox.retract("kept", from: "session") == .claimed)
    }

    /// Nirux types what it took back, and the mailbox keeps it until then:
    /// a crash in between loses nothing. "Unknown" is told apart from a
    /// hook's, so a failed post still gets typed.
    @Test func aRetractedLetterIsOwedUntilTypedAndNothingThereIsUnknown() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let letter = Letter(id: "back", text: "Now the docs.", postedAt: 2)
        try mailbox.post(letter, to: "session")
        #expect(try mailbox.retract("back", from: "session") == .retracted)
        let relaunched = MissionMailbox(root: root)
        #expect(relaunched.owed() == [.init(conversation: "session", letter: letter)])
        #expect(try relaunched.retract("back", from: "session") == .retracted, "still owed")
        #expect(try !relaunched.post(letter, to: "session"), "owed: not posted again")
        try relaunched.markTyped("back", in: "session")
        #expect(relaunched.owed().isEmpty)
        #expect(try relaunched.retract("back", from: "session") == .unknown)
        #expect(try relaunched.retract("never", from: "session") == .unknown)
        #expect(try relaunched.post(letter, to: "session"), "done with: it may go again")
    }

    @Test func aLetterWaitingOrClaimedIsntPostedAgain() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let letter = Letter(id: "once", text: "first", postedAt: 1)
        #expect(try mailbox.post(letter, to: "session"))
        #expect(try !mailbox.post(Letter(id: "once", text: "second", postedAt: 2), to: "session"))
        #expect(mailbox.claim("session", at: 3) == [letter])
        #expect(try !mailbox.post(letter, to: "session"))
        try mailbox.forget(try #require(mailbox.claims().first))
        #expect(try mailbox.post(letter, to: "session"))
    }

    @Test func aLetterAHookCantReadStaysForTyping() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        try mailbox.post(Letter(id: "good", text: "", postedAt: 1), to: "session")
        let unreadable = root.appendingPathComponent("session/waiting/bad.json")
        try Data("{".utf8).write(to: unreadable)
        #expect(mailbox.claim("session", at: 2).map(\.id) == ["good"])
        #expect(try mailbox.retract("bad", from: "session") == .retracted)
    }

    @Test func racingClaimsDeliverEachLetterOnce() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let ids = (0..<200).map { "letter\($0)" }
        for (index, id) in ids.enumerated() {
            try mailbox.post(Letter(id: id, text: id, postedAt: TimeInterval(index)), to: "session")
        }
        let box = mailbox
        let taken = Taken()
        DispatchQueue.concurrentPerform(iterations: 8) { claimer in
            taken.add(box.claim("session", at: TimeInterval(claimer)).map(\.id))
        }
        #expect(taken.ids.sorted() == ids.sorted())
    }

    @Test func forgottenClaimsLeaveAndOtherConversationsKeepTheirs() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        try mailbox.post(Letter(id: "x", text: "", postedAt: 1), to: "one")
        try mailbox.post(Letter(id: "y", text: "", postedAt: 2), to: "two")
        _ = mailbox.claim("one", at: 5)
        let claim = try #require(mailbox.claims().first)
        #expect(claim.conversation == "one")
        try mailbox.forget(claim)
        #expect(mailbox.claims().isEmpty)
        #expect(mailbox.waiting(for: "two").map(\.id) == ["y"])
    }

    /// A post racing a claim of the same letter: once claimed, never posted
    /// again until Nirux forgets the claim.
    @Test func aLetterRacingItsOwnClaimIsClaimedOnce() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let box = mailbox
        let conversations = (0..<400).map { "race\($0)" }
        for conversation in conversations { try box.post(Letter(id: "e", text: "", postedAt: 1), to: conversation) }
        for conversation in conversations {
            DispatchQueue.concurrentPerform(iterations: 2) { worker in
                if worker == 0 {
                    for _ in 0..<20 { _ = try? box.post(Letter(id: "e", text: "", postedAt: 1), to: conversation) }
                } else {
                    for time in 0..<20 { _ = box.claim(conversation, at: TimeInterval(time)) }
                }
            }
            _ = box.claim(conversation, at: 100)
        }
        let claimed = Dictionary(grouping: box.claims(), by: \.conversation).mapValues(\.count)
        #expect(claimed.values.allSatisfy { $0 == 1 }, "\(claimed.filter { $0.value > 1 })")
    }

    @Test func aClaimedLetterHoldsBackOnlyItsOwnID() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        try mailbox.post(Letter(id: "reply-ABC", text: "", postedAt: 1), to: "session")
        #expect(mailbox.claim("session", at: 5000).map(\.id) == ["reply-ABC"])
        #expect(try mailbox.post(Letter(id: "ABC", text: "", postedAt: 2), to: "session"))
        #expect(mailbox.claim("session", at: 5001).map(\.id) == ["ABC"])
    }

    @Test func aClaimWithNothingWaitingLeavesNothing() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(mailbox.claim("session", at: 1).isEmpty)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("session").path))
    }

    /// What is a day old goes, with its text, and so does what a crash left;
    /// folders go once empty. The rest stays.
    @Test func sweepingDropsWhatIsADayOldOrACrashLeft() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let now: TimeInterval = 10 * MissionMailbox.lifetime
        let old = now - MissionMailbox.lifetime - 1
        try mailbox.post(Letter(id: "stale", text: "secret", postedAt: old), to: "gone")
        try mailbox.post(Letter(id: "owed", text: "", postedAt: old), to: "typed")
        _ = try mailbox.retract("owed", from: "typed")
        try mailbox.post(Letter(id: "taken", text: "", postedAt: old), to: "claimed")
        _ = mailbox.claim("claimed", at: old)
        try mailbox.post(Letter(id: "fresh", text: "", postedAt: now - 10), to: "kept")
        let long = Date(timeIntervalSince1970: now - MissionMailbox.leftoverAge - 1)
        let draft = root.appendingPathComponent(".drafts/crash")
        try Data("{".utf8).write(to: draft)
        let marker = root.appendingPathComponent("kept/ids/lost")
        try Data().write(to: marker)
        for file in [draft, marker] { try FileManager.default.setAttributes([.modificationDate: long], ofItemAtPath: file.path) }
        let recent = root.appendingPathComponent("kept/ids/posting")
        try Data().write(to: recent)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: now)], ofItemAtPath: recent.path)

        mailbox.sweep(now: now)
        let left = try FileManager.default.contentsOfDirectory(atPath: root.path).sorted()
        #expect(left == [".drafts", "kept"])
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent(".drafts").path).isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("kept/ids").path).sorted() == ["fresh", "posting"])
        #expect(mailbox.waiting(for: "kept").map(\.id) == ["fresh"])
        #expect(mailbox.owed().isEmpty && mailbox.claims().isEmpty)
        #expect(try mailbox.post(Letter(id: "stale", text: "", postedAt: now), to: "gone"), "its marker went with it")
    }

    @Test(arguments: ["", ".", "..", "../up", "a/b", ".hidden", "é", String(repeating: "a", count: 129)])
    func namesThatCouldLeaveTheFolderAreRefused(name: String) throws {
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(throws: MissionMailbox.InvalidName(name: name)) { try mailbox.post(Letter(id: "ok", text: "", postedAt: 1), to: name) }
        #expect(throws: MissionMailbox.InvalidName(name: name)) { try mailbox.post(Letter(id: name, text: "", postedAt: 1), to: "ok") }
        #expect(throws: MissionMailbox.InvalidName(name: name)) { try mailbox.retract(name, from: "ok") }
        #expect(mailbox.claim(name, at: 1).isEmpty)
    }
}

private final class Taken: @unchecked Sendable {
    private let lock = NSLock()
    private var taken: [String] = []
    var ids: [String] { lock.withLock { taken } }
    func add(_ ids: [String]) { lock.withLock { taken += ids } }
}
