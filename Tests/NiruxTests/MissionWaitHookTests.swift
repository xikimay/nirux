import NiruxCore
import XCTest
@testable import Nirux

/// The waiter Claude Code runs (`Nirux --hook mission-wait`), as its
/// command runs it, and how Nirux reads that the model took a letter in.
@MainActor
final class MissionWaitHookTests: XCTestCase {
    private let nirux = ["NIRUX_AGENT_UUID": "agent"]

    private func makeMailbox() -> MissionMailbox {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("nirux-mission-wait-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return MissionMailbox(root: root)
    }

    private func payload(_ fields: [String: String]) throws -> Data {
        try JSONSerialization.data(withJSONObject: fields)
    }

    /// A waiter run on its own thread, as its own process would.
    private final class Run: @unchecked Sendable {
        private let lock = NSLock()
        private var result: (code: Int32, printed: String)?
        var outcome: (code: Int32, printed: String)? { lock.withLock { result } }

        init(_ mailbox: MissionMailbox, payload: Data, environment: [String: String]) {
            DispatchQueue.global().async { [self] in
                var printed = ""
                let code = MissionWaitHook.run(
                    mailbox: mailbox, payload: payload, environment: environment, parent: getpid(), until: Date() + 30
                ) { printed += $0 }
                lock.withLock { result = (code, printed) }
            }
        }
    }

    func testAWaiterOutsideANiruxTerminalOrWithoutASessionLeavesAtOnce() throws {
        let mailbox = makeMailbox()
        let session = try payload(["session_id": "s1", "transcript_path": "/u/.claude/projects/p/s1.jsonl"])
        XCTAssertEqual(MissionWaitHook.run(mailbox: mailbox, payload: session, environment: [:], parent: getpid(), until: Date() + 30) { _ in }, 0)
        XCTAssertNil(mailbox.running(in: getpid()))
        XCTAssertNil(mailbox.transcript(of: "s1"))
        let noSession = try payload(["hook_event_name": "Stop"])
        XCTAssertEqual(MissionWaitHook.run(mailbox: mailbox, payload: noSession, environment: nirux, parent: getpid(), until: Date() + 30) { _ in }, 0)
    }

    /// It notes the conversation its claude runs and where its transcript
    /// is, waits alone on it, and prints what comes with status 2.
    func testAWaiterNotesItsSessionWaitsAloneAndPrintsWhatComes() throws {
        let mailbox = makeMailbox()
        let session = try payload(["session_id": "s1", "transcript_path": "/u/.claude/projects/p/s1.jsonl"])
        let run = Run(mailbox, payload: session, environment: nirux)
        waitUntil("the waiter is armed") { mailbox.isArmed("s1") }
        XCTAssertEqual(mailbox.running(in: getpid()), "s1")
        XCTAssertEqual(mailbox.transcript(of: "s1"), "/u/.claude/projects/p/s1.jsonl")
        XCTAssertEqual(
            MissionWaitHook.run(mailbox: mailbox, payload: session, environment: nirux, parent: getpid(), until: Date() + 30) { _ in }, 0,
            "a second waiter on the session leaves"
        )
        XCTAssertNil(run.outcome)
        try mailbox.post(.init(id: "e1", text: "[Nirux Mission] Hello", postedAt: 1), to: "s1")
        waitUntil("the waiter printed it") { run.outcome != nil }
        XCTAssertEqual(run.outcome?.code, 2)
        XCTAssertEqual(run.outcome?.printed, "[Nirux Mission] Hello")
        XCTAssertFalse(mailbox.isArmed("s1"))
    }

    /// Only a line of the turn that read it counts, never the line queuing
    /// the hook's output, nor an older line with the same text.
    func testTheModelReadALetterOnlyWhenATurnsOwnLineHoldsIt() throws {
        let transcript = FileManager.default.temporaryDirectory.appendingPathComponent("nirux-transcript-\(UUID().uuidString).jsonl")
        addTeardownBlock { try? FileManager.default.removeItem(at: transcript) }
        let letter = MissionMailbox.Letter(id: "e1", text: "[Nirux Mission] From \"Lead\":\nSay \"done\" when it is", postedAt: 1)
        let claimedAt: TimeInterval = 1_800_000_000
        func line(_ type: String, at time: TimeInterval) throws -> String {
            let stamp = ISO8601DateFormatter.string(
                from: Date(timeIntervalSince1970: time), timeZone: .gmt, formatOptions: [.withInternetDateTime, .withFractionalSeconds]
            )
            let body = "<system-reminder>\n\(MissionWaitHook.preamble) \(letter.text)\n</system-reminder>"
            let fields: [String: Any] = ["type": type, "timestamp": stamp, "content": body]
            return String(decoding: try JSONSerialization.data(withJSONObject: fields, options: [.withoutEscapingSlashes]), as: UTF8.self)
        }
        try (try [line("user", at: claimedAt - 60), line("queue-operation", at: claimedAt)].joined(separator: "\n") + "\n")
            .write(to: transcript, atomically: true, encoding: .utf8)
        XCTAssertFalse(MissionWaitHook.modelRead(letter, claimedAt: claimedAt, transcript: transcript.path))
        let handle = try FileHandle(forWritingTo: transcript)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((try line("user", at: claimedAt + 2) + "\n").utf8))
        try handle.close()
        XCTAssertTrue(MissionWaitHook.modelRead(letter, claimedAt: claimedAt, transcript: transcript.path))
        XCTAssertFalse(MissionWaitHook.modelRead(letter, claimedAt: claimedAt, transcript: nil))
    }
}
