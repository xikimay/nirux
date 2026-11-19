import XCTest
@testable import Nirux

/// What the Lead's reviews found (ReviewFindings): the findings a call may
/// give, the round each review is, and the kinds that show up in a second
/// task.
final class ReviewFindingsTests: XCTestCase {
    private var state: URL!
    private let day: TimeInterval = 86_400
    private let now: TimeInterval = 1_800_000_000

    override func setUpWithError() throws {
        try super.setUpWithError()
        state = FileManager.default.temporaryDirectory.appendingPathComponent("nirux-findings-\(UUID().uuidString)")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: state)
        super.tearDown()
    }

    private func record(_ kinds: [String], task: String, pullRequest: Int?, at time: TimeInterval) -> ReviewFindings.Outcome {
        let findings = kinds.map { ReviewFindings.Finding(kind: $0, text: "a \($0) finding") }
        return ReviewFindings.recordNow(findings, task: task, pullRequest: pullRequest, spaceID: "S1", now: time, stateDirectory: state)
    }

    private func refusal(_ value: Any?) -> String? {
        guard case .failure(let refusal) = ReviewFindings.findings(value) else { return nil }
        return refusal.reason
    }

    /// Kinds become slugs, texts one line; an empty list, too many, a kind
    /// with nothing left, or a text too long are refused.
    func testAReviewGivesKindsAndTexts() throws {
        let given: [Any] = [["kind": " Animation end_deadline! ", "text": "Ends ran\non  a timer."], ["kind": "Réduire-Motion", "text": "x"]]
        guard case .success(let findings) = ReviewFindings.findings(given) else { return XCTFail("refused") }
        XCTAssertEqual(findings, [
            ReviewFindings.Finding(kind: "animation-end-deadline", text: "Ends ran on a timer."),
            ReviewFindings.Finding(kind: "reduire-motion", text: "x")
        ])
        XCTAssertNotNil(refusal([]))
        XCTAssertNotNil(refusal(Array(repeating: ["kind": "a", "text": "b"], count: ReviewFindings.maxFindings + 1)))
        XCTAssertNotNil(refusal([["kind": "!!!", "text": "b"]]))
        XCTAssertNotNil(refusal([["kind": "a", "text": String(repeating: "b", count: ReviewFindings.maxTextLength + 1)]]))
        XCTAssertNotNil(refusal([["kind": "a"]]))
    }

    /// Each review of a task and pull request is the next round; a kind
    /// another task had is said so, with both handles, the most seen kind
    /// first. Reviews past 30 days count for neither.
    func testRoundsAndKindsSeenInASecondTask() throws {
        _ = record(["old-kind", "layer"], task: "feat/old", pullRequest: 1, at: now - 31 * day)
        guard case .recorded(let first, _) = record(["layer"], task: "feat/a", pullRequest: 10, at: now - 2 * day),
              case .recorded(let second, _) = record(["timer"], task: "feat/a", pullRequest: 10, at: now - day),
              case .recorded(let other, let kinds) = record(["layer", "new"], task: "feat/b", pullRequest: nil, at: now)
        else { return XCTFail("not recorded") }
        XCTAssertEqual([first.round, second.round, other.round], [1, 2, 1])
        XCTAssertEqual(kinds.map(\.name).first, "layer")
        XCTAssertEqual(kinds.first?.handles, ["#10", "feat/b"])
        XCTAssertFalse(kinds.contains { $0.name == "old-kind" })

        let answer = ReviewFindings.answer(for: other, title: "B", kinds: kinds)
        XCTAssertTrue(answer.hasPrefix("Recorded round 1 of “B”: 2 findings."), answer)
        XCTAssertTrue(answer.contains("Seen in another task too: layer (#10, feat/b)."), answer)
        XCTAssertFalse(answer.contains("new ("), answer)
        XCTAssertTrue(answer.contains("Other kinds this space used in the last 30 days: timer."), answer)
        let url = try XCTUnwrap(ReviewFindings.lines.fileURL(spaceID: "S1", stateDirectory: state))
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int, 0o600)
    }

    /// A log at its size limit records nothing, and says so.
    func testAFullLogRecordsNothing() throws {
        let url = try XCTUnwrap(ReviewFindings.lines.fileURL(spaceID: "S1", stateDirectory: state))
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let line = try JSONEncoder().encode(ReviewFindings.Entry(time: now, task: "t", round: 1, findings: [])) + Data("\n".utf8)
        try Data(repeating: 0, count: 0).write(to: url)
        let handle = try FileHandle(forWritingTo: url)
        for _ in 0...(ReviewFindings.lines.maxFileBytes / line.count) { try handle.write(contentsOf: line) }
        try handle.close()
        XCTAssertEqual(record(["layer"], task: "feat/a", pullRequest: 1, at: now), .full)
    }
}
