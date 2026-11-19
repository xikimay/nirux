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

    private func record(
        _ kinds: [String], workspace: String, missionBranch: String? = nil, task: String, pullRequest: Int?, at time: TimeInterval
    ) -> ReviewFindings.Outcome {
        let findings = kinds.map { ReviewFindings.Finding(kind: $0, text: "a \($0) finding") }
        let review = ReviewFindings.Review(
            findings: findings, workspace: workspace, missionBranch: missionBranch, task: task, pullRequest: pullRequest, repository: nil
        )
        return ReviewFindings.recordNow(review, spaceID: "S1", now: time, stateDirectory: state)
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

    /// Each review of a task is its next round, and one task, under the
    /// name it was first known by, whatever its HEAD (detached, another
    /// branch) or pull request does; named by its pull request once it has
    /// one. A kind another task had is said so, the most seen kind first.
    /// Reviews past 30 days count for neither.
    func testRoundsAndKindsSeenInASecondTask() throws {
        _ = record(["old-kind", "layer"], workspace: "W-old", task: "feat/old", pullRequest: 1, at: now - 33 * day)
        guard case .recorded(let first, _) = record(["layer"], workspace: "W-A", task: "feat/a", pullRequest: nil, at: now - 3 * day),
              case .recorded(let second, _) = record(["timer", "layer"], workspace: "W-A", task: "feat/a", pullRequest: 10, at: now - 2 * day),
              case .recorded(let other, let kinds) = record(["layer", "new"], workspace: "W-B", task: "feat/b", pullRequest: nil, at: now - day)
        else { return XCTFail("not recorded") }
        XCTAssertEqual([first.round, second.round, other.round], [1, 2, 1])
        XCTAssertEqual(kinds.map(\.name).first, "layer")
        XCTAssertEqual(kinds.first?.handles, ["#10", "feat/b"])
        XCTAssertEqual(kinds.first?.taskCount, 2, "one task, whatever its pull request")
        XCTAssertFalse(kinds.contains { $0.name == "old-kind" })

        let answer = ReviewFindings.answer(for: other, title: "B", kinds: kinds)
        XCTAssertTrue(answer.hasPrefix("Recorded round 1 of “B”: 2 findings."), answer)
        XCTAssertTrue(answer.contains("Seen in another task too: layer (#10, feat/b)."), answer)
        guard case .recorded(let detached, let later) = record(["layer"], workspace: "W-A", task: "Add A", pullRequest: nil, at: now)
        else { return XCTFail("not recorded") }
        XCTAssertEqual([detached.task, String(detached.round)], ["feat/a", "3"], "HEAD detached in a rebase: the same task")
        XCTAssertEqual(later.first?.taskCount, 2)
        guard case .recorded(let started, _) = record(["new"], workspace: "W-M", missionBranch: "feat/m", task: "Title", pullRequest: nil, at: now)
        else { return XCTFail("not recorded") }
        XCTAssertEqual(started.task, "feat/m", "its Mission's branch, before its git context arrives")
        XCTAssertFalse(answer.contains("new ("), answer)
        XCTAssertTrue(answer.contains("Other kinds this space used in the last 30 days: timer."), answer)
        let url = try XCTUnwrap(ReviewFindings.lines.fileURL(spaceID: "S1", stateDirectory: state))
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int, 0o600)
    }

    /// A log at its size limit, or one that can't be written, records
    /// nothing and says so.
    func testALogThatTakesNothingRecordsNothing() throws {
        let url = try XCTUnwrap(ReviewFindings.lines.fileURL(spaceID: "S1", stateDirectory: state))
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        guard case .notRecorded(let unwritable) = record(["layer"], workspace: "W", task: "feat/a", pullRequest: 1, at: now)
        else { return XCTFail("a folder in its place takes no line") }
        XCTAssertTrue(unwritable.contains("couldn’t write"), unwritable)

        try FileManager.default.removeItem(at: url)
        let line = try JSONEncoder().encode(ReviewFindings.Entry(time: now, workspace: "W", task: "t", round: 1, findings: [])) + Data("\n".utf8)
        try Data().write(to: url)
        let handle = try FileHandle(forWritingTo: url)
        for _ in 0...(ReviewFindings.lines.maxFileBytes / line.count) { try handle.write(contentsOf: line) }
        try handle.close()
        guard case .notRecorded(let full) = record(["layer"], workspace: "W", task: "feat/a", pullRequest: 1, at: now)
        else { return XCTFail("a full log takes no line") }
        XCTAssertTrue(full.contains("full"), full)
    }

    /// A first line past 4 KB (a long review) is read whole: a recent one
    /// leaves the file as it is.
    func testALongFirstLineIsReadWhole() throws {
        let long = (1...ReviewFindings.maxFindings).map { _ in ["kind": "layer", "text": String(repeating: "x", count: ReviewFindings.maxTextLength)] }
        guard case .success(let findings) = ReviewFindings.findings(long) else { return XCTFail("refused") }
        let review = ReviewFindings.Review(findings: findings, workspace: "W", missionBranch: nil, task: "feat/a", pullRequest: nil, repository: nil)
        _ = ReviewFindings.recordNow(review, spaceID: "S1", now: now, stateDirectory: state)
        let url = try XCTUnwrap(ReviewFindings.lines.fileURL(spaceID: "S1", stateDirectory: state))
        let old = Date(timeIntervalSince1970: 1_000_000_000)
        try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: url.path)
        ReviewFindings.lines.trim(spaceID: "S1", now: now + day, stateDirectory: state)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date, old, "not rewritten")
        XCTAssertEqual(ReviewFindings.lines.load(spaceID: "S1", stateDirectory: state).count, 1)
    }
}
