import XCTest
@testable import Nirux

/// DO NOT MERGE. A session record written at its claude's start in
/// milliseconds, read back: as LeadToolsFlowTests wrote it before #669
/// (`startedAt * 1000`), and as it writes it since (one millisecond later).
@MainActor
final class ZZRecordRoundTripTests: XCTestCase {
    func testARecordAMillisecondAfterTheStartIsItsProcesss() {
        let base = Date().timeIntervalSince1970.rounded(.down)
        var refused = (atStart: 0, after: 0)
        let count = 100_000
        for i in 0..<count {
            let start = base + TimeInterval(i / 1000) + TimeInterval((i * 7919) % 1_000_000) / 1_000_000
            let process = ProcessInstance(pid: 4242, startedAt: start)
            @MainActor func shows(_ milliseconds: Double) -> Bool {
                let json = #"{"status":"waiting","waitingFor":"dialog open","statusUpdatedAt":\#(milliseconds)}"#
                return ClaudeSessionRecord(json: Data(json.utf8), writtenAt: start)?.showsWait(of: process) == true
            }
            if !shows(start * 1000) { refused.atStart += 1 }
            if !shows(start * 1000 + 1) { refused.after += 1 }
        }
        print("ZZ statusUpdatedAt = startedAt * 1000: \(refused.atStart) of \(count) read as an earlier process's")
        print("ZZ statusUpdatedAt = startedAt * 1000 + 1: \(refused.after) of \(count)")
        XCTAssertGreaterThan(refused.atStart, 0, "the defect #669 fixed shows")
        XCTAssertEqual(refused.after, 0)
    }
}
