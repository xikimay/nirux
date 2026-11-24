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

    @Test(arguments: [
        (nil, "s", false, nil, ["s"], .post("s")),
        (nil, "s", false, nil, [], .type),
        (nil, nil, false, nil, ["s"], .type),
        (nil, "s", false, "older", ["s"], .type),
        (nil, "s", false, "s", ["s"], .post("s")),
        (.waiting(conversation: "s"), "s", false, nil, ["s"], .leave),
        (.waiting(conversation: "s"), "s", false, nil, [], .retract("s")),
        (.waiting(conversation: "old"), "s", false, nil, ["old", "s"], .retract("old")),
        (.claimed(conversation: "s", at: 1), "s", false, nil, [], .leave),
        (.claimed(conversation: "old", at: 1), nil, false, nil, [], .leave),
        (.claimed(conversation: "old", at: 1), "s", true, nil, ["s"], .release),
    ] as [(MissionLetterPlace?, String?, Bool, String?, Set<String>, MissionHookStep)])
    func aHookTakesAMessageOnlyWhileItsWaiterWaitsOnTheRecipientsConversation(
        place: MissionLetterPlace?, recipient: String?, ended: Bool, sentTo: String?, armed: Set<String>, expected: MissionHookStep
    ) {
        #expect(MissionDeliveryPolicy.hookStep(place: place, recipient: recipient, ended: ended, sentTo: sentTo, isArmed: armed.contains) == expected)
    }

    @Test func placesSayWhereEachLetterWaitsOrWasClaimed() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        try mailbox.post(Letter(id: "a", text: "", postedAt: 1), to: "one")
        try mailbox.post(Letter(id: "b", text: "", postedAt: 2), to: "two")
        _ = mailbox.claim("two", at: 3)
        #expect(mailbox.places() == ["a": .waiting(conversation: "one"), "b": .claimed(conversation: "two", at: 3)])
    }

    @Test func oneWaiterAtATimeArmsAConversation() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(!mailbox.isArmed("session"))
        var first = try mailbox.arm("session")
        #expect(first != nil)
        #expect(mailbox.isArmed("session"))
        #expect(!mailbox.isArmed("other"))
        #expect(try mailbox.arm("session") == nil)
        first = nil
        #expect(!mailbox.isArmed("session"))
        #expect(try mailbox.arm("session") != nil)
    }

    @Test func aWaiterGetsWhatIsPostedWhileItWaits() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let box = mailbox
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) {
            _ = try? box.post(Letter(id: "late", text: "hello", postedAt: 1), to: "session")
        }
        let letters = box.letters(for: "session", whileRunning: getpid(), until: Date() + 10)
        #expect(letters.map(\.text) == ["hello"])
        #expect(mailbox.claims().map(\.letter.id) == ["late"])
    }

    @Test func aWaiterStopsWhenItsParentExitsOrItsTimeRunsOut() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let parent = Process()
        parent.executableURL = URL(fileURLWithPath: "/bin/sleep")
        parent.arguments = ["30"]
        try parent.run()
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) { parent.terminate() }
        let started = Date()
        #expect(mailbox.letters(for: "session", whileRunning: parent.processIdentifier, until: started + 20).isEmpty)
        #expect(Date().timeIntervalSince(started) < 10)
        #expect(mailbox.letters(for: "session", whileRunning: getpid(), until: Date() + 0.3).isEmpty)
        try mailbox.post(Letter(id: "kept", text: "", postedAt: 1), to: "session")
        #expect(mailbox.waiting(for: "session").map(\.id) == ["kept"])
    }

    @Test func pruningKeepsConversationsWithLettersClaimsOrAWaiter() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        try mailbox.post(Letter(id: "a", text: "", postedAt: 1), to: "waiting")
        try mailbox.post(Letter(id: "b", text: "", postedAt: 1), to: "claimed")
        _ = mailbox.claim("claimed", at: 2)
        try mailbox.post(Letter(id: "c", text: "", postedAt: 1), to: "done")
        _ = try mailbox.retract("c", from: "done")
        let waiter = try mailbox.arm("armed")
        mailbox.prune()
        let left = try FileManager.default.contentsOfDirectory(atPath: root.path).filter { !$0.hasPrefix(".") }.sorted()
        #expect(left == ["armed", "claimed", "waiting"])
        withExtendedLifetime(waiter) {}
    }
}

private final class Taken: @unchecked Sendable {
    private let lock = NSLock()
    private var taken: [String] = []
    var ids: [String] { lock.withLock { taken } }
    func add(_ ids: [String]) { lock.withLock { taken += ids } }
}
