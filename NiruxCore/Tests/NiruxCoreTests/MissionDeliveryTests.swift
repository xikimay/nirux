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
        #expect(try mailbox.retract("back", from: "session"))
        #expect(try !mailbox.retract("back", from: "session"))
        #expect(mailbox.claim("session", at: 3).map(\.id) == ["kept"])
        #expect(try !mailbox.retract("kept", from: "session"))
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
        #expect(try mailbox.retract("bad", from: "session"))
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
