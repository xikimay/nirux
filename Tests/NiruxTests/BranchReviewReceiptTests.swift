import XCTest
@testable import Nirux

final class BranchReviewReceiptTests: XCTestCase {
    typealias Receipt = BranchReview.Receipt
    private let head = String(repeating: "a", count: 40)

    private func receipt(
        _ id: String = "run", title: String = "swift test", provenance: Receipt.Provenance = .local, digest: String? = nil
    ) -> Receipt {
        Receipt(
            id: id, title: title, command: "swift test", status: .passed, summary: "12 tests passed", provenance: provenance,
            recordedAt: Date(timeIntervalSince1970: 1234.5), head: head, workingTreeDigest: digest
        )
    }

    func testFreshnessChecksHeadAndCompleteWorkingTree() throws {
        let clean = BranchReviewPageTests.snapshot()
        let dirty = BranchReviewPageTests.snapshot(hasUncommittedChanges: true)
        let cleanRun = receipt()
        let digest = try XCTUnwrap(dirty.workingTreeDigest)
        let localRun = receipt(digest: digest)

        XCTAssertNil(clean.workingTreeDigest)
        XCTAssertEqual(cleanRun.freshness(head: head, tree: clean.workingTree), .fresh)
        XCTAssertEqual(cleanRun.freshness(head: head, tree: dirty.workingTree), .stale(.localEdits))
        XCTAssertEqual(localRun.freshness(head: head, tree: clean.workingTree), .stale(.localEdits))
        XCTAssertEqual(localRun.freshness(head: head, tree: dirty.workingTree), .fresh)
        XCTAssertEqual(localRun.freshness(head: String(repeating: "b", count: 40), tree: dirty.workingTree), .stale(.earlierCommit))

        var files = Array(dirty.files.reversed())
        func tree() -> BranchReview.WorkingTree { BranchReviewControllerTests.snapshot(dirty, files: files).workingTree }
        XCTAssertEqual(tree().digest, digest)
        files[0].patchHash = "new patch"
        XCTAssertEqual(localRun.freshness(head: head, tree: tree()), .stale(.localEdits))
        files[0].omission = .notRead
        XCTAssertEqual(localRun.freshness(head: head, tree: tree()), .unverified)
        files[0].omission = nil
        files[0].patchHash = nil
        XCTAssertEqual(cleanRun.freshness(head: head, tree: tree()), .unverified)
    }

    func testStorageRoundTripSkipsBadEntriesAndCapsUpdates() throws {
        var record = BranchReview.Record()
        let local = receipt()
        let agent = receipt("agent", provenance: .agent, digest: String(repeating: "f", count: 64))
        let ci = receipt("check", provenance: .ci(url: "https://ci.example/run"))
        for run in [local, agent, ci] { XCTAssertTrue(record.addReceipt(run)) }
        var section = try XCTUnwrap(record.fields["receipts"]?.objectValue)
        XCTAssertEqual(section["version"], .int(1))
        section["items"] = .array([.null, .object([:])] + (section["items"]?.arrayValue ?? []))
        record.fields["receipts"] = .object(section)
        let fields = try JSONDecoder().decode([String: JSONValue].self, from: JSONEncoder().encode(record.fields))
        XCTAssertEqual(BranchReview.Record(fields: fields).receipts, [ci, agent, local])

        for id in 0...20 { XCTAssertTrue(record.addReceipt(receipt(String(id)))) }
        XCTAssertTrue(record.addReceipt(receipt("4", title: "rerun")))
        XCTAssertEqual(record.receipts.map(\.id), ["4"] + (1...20).reversed().filter { $0 != 4 }.map(String.init))
        XCTAssertEqual(record.receipts.first?.title, "rerun")
        XCTAssertFalse(record.addReceipt(receipt(title: String(repeating: "x", count: 513))))
    }

    func testNewerReceiptSchemaSurvivesOtherReviewWrites() {
        let future: JSONValue = .object(["version": .int(2), "payload": .array([.bool(true)])])
        var record = BranchReview.Record(fields: ["receipts": future])
        XCTAssertTrue(record.receipts.isEmpty)
        XCTAssertFalse(record.addReceipt(receipt()))
        XCTAssertTrue(record.markReviewed(BranchReviewPageTests.snapshot().files[0], head: head, at: Date()))
        XCTAssertTrue(record.addComment(id: "comment", anchor: .file("file"), text: "note", at: Date()))
        XCTAssertEqual(record.fields["receipts"], future)
    }

    func testCIRerunsUseThePRCommitAndTheReportedOutcome() throws {
        let json: [String: Any] = [
            "number": 1, "url": "https://github.com/o/r/pull/1", "baseRefName": "main", "headRefOid": head,
            "headRepositoryOwner": ["login": "o"], "headRepository": ["name": "r"],
            "statusCheckRollup": [
                ["name": "test", "workflowName": "CI", "conclusion": "FAILURE", "startedAt": "2026-01-01T11:00:00Z"],
                ["name": "test", "workflowName": "CI", "conclusion": "SUCCESS", "startedAt": "2026-01-01T12:00:00Z",
                 "completedAt": "2026-01-01T12:01:00Z", "detailsUrl": "https://ci.example/run"],
                ["context": "lint", "state": "ERROR"],
                ["name": "build", "status": "IN_PROGRESS"],
                ["name": "scan", "status": "COMPLETED", "conclusion": "SKIPPED"]
            ]
        ]
        let pr = try XCTUnwrap(BranchReview.pullRequest(from: json, headRepository: .init(owner: "o", name: "r")))
        let runs = pr.checkReceipts
        XCTAssertEqual(runs.map(\.status), [.passed, .failed, .running, .unknown])
        XCTAssertEqual(runs.first?.recordedAt.formatted(.iso8601), "2026-01-01T12:01:00Z")
        XCTAssertEqual(runs.first?.provenance, .ci(url: "https://ci.example/run"))
        XCTAssertEqual(runs.first?.title, "CI / test")
        XCTAssertEqual(runs.first?.head, head)
        XCTAssertEqual(runs.first?.workingTreeDigest, nil)
        let clean = BranchReviewPageTests.snapshot(pullRequest: .found(pr))
        XCTAssertEqual(BranchReview.page(for: clean, handover: nil).receipts?.first?.freshness, "Current")
        let dirty = BranchReviewPageTests.snapshot(pullRequest: .found(pr), hasUncommittedChanges: true)
        XCTAssertEqual(BranchReview.page(for: dirty, handover: nil).receipts?.first?.freshness, "Stale: local edits")
        XCTAssertEqual(runs.first?.freshness(head: String(repeating: "b", count: 40), tree: .clean), .stale(.earlierCommit))
    }

    @MainActor
    func testStoredAndCIReceiptsRenderAsTextAndOnlyHTTPSLinksOpen() throws {
        let state = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: state) }
        let title = "<b>run</b>\u{202E}"
        var pr = BranchReviewPageTests.pullRequest(baseRefName: "main")
        pr.checkReceipts = ["https://ci.example/run", "http://ci.example/run", "file:///tmp/check", "https://ci.example/\u{202E}"].map { url in
            Receipt(id: url, title: title, command: "<em>cmd</em>", status: .unknown, summary: "<i>summary</i>",
                    provenance: .ci(url: url), recordedAt: Date(), head: pr.headRefOid, workingTreeDigest: nil)
        }
        let snapshot = BranchReviewPageTests.snapshot(pullRequest: .found(pr))
        let agent = receipt("agent", title: title, provenance: .agent)
        let local = receipt()
        let store = try XCTUnwrap(BranchReview.Store(repository: "/repo", branch: snapshot.branch, stateDirectory: state))
        let history = BranchReview.History(isOwnCommit: { _ in true }, isInReflog: { _ in true })
        let access = try XCTUnwrap(store.open(head: head, pullRequest: .found(pr), history: history).access)
        _ = try store.update(access) { record in
            XCTAssertTrue(record.addReceipt(local))
            XCTAssertTrue(record.addReceipt(agent))
        }.get()
        var opened: URL?
        let page = try ReviewPage(snapshot: snapshot, handover: nil, openLink: { opened = $0 }, reviewOpener: { snapshot in
            (store, store.open(head: snapshot.head, pullRequest: snapshot.pullRequest, history: .init(isOwnCommit: { _ in true }, isInReflog: { _ in true })))
        })
        defer { page.close() }
        let text = try page.waitFor("document.querySelectorAll('.receipt').length === 6", then: "document.querySelector('.receipts').textContent")
        XCTAssertTrue(text.contains("<b>run</b>⟨U+202E⟩"))
        XCTAssertTrue(text.contains("<em>cmd</em>"))
        XCTAssertTrue(text.contains("<i>summary</i>"))
        XCTAssertTrue(text.contains("Passed · Agent · Current"))
        XCTAssertTrue(text.contains("Passed · Local · Current"))
        XCTAssertTrue(text.contains("Unknown · CI · Stale: earlier commit"))
        XCTAssertEqual(try page.run("return String(document.querySelectorAll('.receipt b, .receipt em, .receipt i').length);"), "0")
        XCTAssertEqual(try page.run("const links = document.querySelectorAll('.receipt a'); links[0].click(); return String(links.length);"), "1")
        page.waitUntil("the verified link to open") { opened != nil }
        XCTAssertEqual(opened?.absoluteString, "https://ci.example/run")
    }

    func testPageJSONOmitsEmptySectionAndPreservesReceiptText() throws {
        let snapshot = BranchReviewPageTests.snapshot()
        func json(_ runs: [Receipt]) throws -> [String: Any] {
            let page = BranchReview.page(for: snapshot, handover: nil, receipts: runs)
            return try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(page)) as? [String: Any])
        }
        XCTAssertNil(try json([])["receipts"])
        let rows = try XCTUnwrap(try json([receipt(title: "<b>&</b>")])["receipts"] as? [[String: String]])
        XCTAssertEqual(rows.first?["title"], "<b>&</b>")
        XCTAssertEqual(rows.first?["freshness"], "Current")
        XCTAssertEqual(rows.first?["provenance"], "Local")
    }
}
