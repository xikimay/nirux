import XCTest
@testable import Nirux

final class BranchReviewJUnitTests: XCTestCase {
    private typealias JUnit = BranchReview.JUnit

    private func parse(_ xml: String, snapshot: BranchReview.Snapshot = BranchReviewPageTests.snapshot()) throws -> BranchReview.Receipt {
        try JUnit.receipt(from: Data(xml.utf8), filename: "results.xml", snapshot: snapshot, id: "run", at: .distantPast)
    }

    func testSuiteCountsAndSnapshotBinding() throws {
        let dirty = BranchReviewPageTests.snapshot(hasUncommittedChanges: true)
        let run = try parse(#"<testsuite name="Package" tests="142" skipped="2" time="12.400"/>"#, snapshot: dirty)
        XCTAssertEqual(run.title, "Package")
        XCTAssertEqual(run.summary, "142 tests, 0 failures, 2 skipped (12.4s)")
        XCTAssertEqual(run.provenance, .local)
        XCTAssertEqual(run.status, .passed)
        XCTAssertEqual(run.head, dirty.head)
        XCTAssertEqual(run.workingTreeDigest, try XCTUnwrap(dirty.workingTreeDigest))
        XCTAssertEqual(run.freshness(head: dirty.head, tree: dirty.workingTree), .fresh)
        var files = dirty.files
        files[0].patchHash = "edited"
        let edited = BranchReviewControllerTests.snapshot(dirty, files: files)
        XCTAssertEqual(run.freshness(head: edited.head, tree: edited.workingTree), .stale(.localEdits))
        files[0].omission = .notRead
        XCTAssertThrowsError(try parse("<testsuite/>", snapshot: BranchReviewControllerTests.snapshot(dirty, files: files))) {
            XCTAssertEqual($0 as? JUnit.Problem, .incomplete)
        }
    }

    func testNestedSuitesMixReportedAndObservedCountsWithoutDoubleCounting() throws {
        let run = try parse("""
            <?xml version="1.0" encoding="UTF-8"?>
            <!-- report -->
            <testsuites tests="5">
              <testsuite tests="3" time="1.10"><testsuite><testcase/><testcase><skipped/></testcase></testsuite></testsuite>
              <testsuite time="2.20">
                <testcase classname="Foo" name="testBar"><failure/><failure/></testcase>
                <testcase name="bad"><error/><system-out><![CDATA[<!DOCTYPE html>]]></system-out></testcase>
              </testsuite>
            </testsuites>
            """)
        XCTAssertEqual(run.title, "results.xml")
        XCTAssertEqual(run.summary, "5 tests, 1 failure, 1 error, 1 skipped (3.3s): Foo.testBar, bad")
        XCTAssertEqual(run.status, .failed)
        XCTAssertEqual(try parse("<testsuite/>").status, .unknown)
        XCTAssertEqual(try parse(#"<testsuites><testsuite tests="0"/></testsuites>"#).status, .unknown)
        XCTAssertEqual(try parse("<testsuite><testcase/></testsuite>").status, .passed)
        XCTAssertEqual(try parse(#"<testsuite tests="2" errors="1"/>"#).status, .failed)
    }

    func testNamesAreVisibleBoundedAndLimitedToTheFirstFive() throws {
        let title = String(repeating: "🧪", count: 600)
        let cases = (1...6).map { #"<testcase name="case\#($0)&#x202e;\#(title)"><error/></testcase>"# }.joined()
        let run = try parse(#"<testsuite name="\#(title)">\#(cases)</testsuite>"#)
        let summary = try XCTUnwrap(run.summary)
        XCTAssertTrue(run.fitsStorage)
        XCTAssertTrue(run.title.hasSuffix("…"))
        for index in 1...5 { XCTAssertTrue(summary.contains("case\(index)⟨U+202E⟩")) }
        XCTAssertFalse(summary.contains("case6"))
        XCTAssertEqual(summary.filter { $0 == "…" }.count, 5)
    }

    func testRejectsMalformedNonJUnitAndContradictoryReports() {
        for xml in ["", "<report/>", "<testsuite>", "<testsuite/><testsuite/>", "<testsuite/>trailing",
                    "<testsuites><testcase/></testsuites>", "<testsuite><failure/></testsuite>", "<testsuite><html/></testsuite>",
                    #"<testsuite tests="-1"/>"#, #"<testsuite failures="many"/>"#, #"<testsuite time="nan"/>"#,
                    #"<testsuite failures="0"><testcase><failure/></testcase></testsuite>"#,
                    #"<testsuite><testsuite tests="9223372036854775807"/><testcase/></testsuite>"#] {
            XCTAssertThrowsError(try parse(xml), xml)
        }
    }

    func testExternalDeclarationsAreRefusedBeforeParsingInBothEncodings() throws {
        for encoding in [String.Encoding.utf8, .utf16] {
            let declaration = encoding == .utf8 ? "UTF-8" : "UTF-16"
            let prolog = #"<?xml version="1.0" encoding="\#(declaration)"?><!-- a comment -->"#
            func receipt(_ body: String) throws -> BranchReview.Receipt {
                let data = try XCTUnwrap((prolog + body).data(using: encoding))
                return try JUnit.receipt(from: data, filename: "run.xml", snapshot: BranchReviewPageTests.snapshot(), id: "run", at: .distantPast)
            }
            XCTAssertEqual(try receipt("<testsuite><testcase/></testsuite>").status, .passed)
            for dtd in [#"<!DOCTYPE testsuite SYSTEM "missing.dtd">"#,
                        #"<!DOCTYPE testsuite [<!ENTITY report SYSTEM "missing.txt">]>"#] {
                XCTAssertThrowsError(try receipt(dtd + "<testsuite/>")) { XCTAssertEqual($0 as? JUnit.Problem, .doctype) }
            }
        }
    }

    func testFileReadLimitsAndRejectsPipesAndSymlinks() throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }
        let report = temp.appendingPathComponent("run.xml")
        var data = Data("<testsuite/>".utf8)
        data.append(Data(repeating: 32, count: JUnit.maxBytes - data.count))
        try data.write(to: report)
        let snapshot = BranchReviewPageTests.snapshot()
        XCTAssertEqual(try JUnit.read(report, for: snapshot).title, "run.xml")
        data.append(32)
        try data.write(to: report)
        XCTAssertThrowsError(try JUnit.read(report, for: snapshot)) { XCTAssertEqual($0 as? JUnit.Problem, .tooLarge) }
        let link = temp.appendingPathComponent("link.xml")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: report)
        let pipe = temp.appendingPathComponent("pipe.xml")
        XCTAssertEqual(mkfifo(pipe.path, 0o600), 0)
        for url in [link, pipe, temp] {
            XCTAssertThrowsError(try JUnit.read(url, for: snapshot)) { XCTAssertEqual($0 as? JUnit.Problem, .unreadable) }
        }
    }

    @MainActor
    func testMenuImportPersistsAndReportsConcurrentStorageRefusals() throws {
        let snapshot = BranchReviewPageTests.snapshot()
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: temp) }
        let store = try XCTUnwrap(BranchReview.Store(repository: "/repo", branch: snapshot.branch, stateDirectory: temp))
        let page = try ReviewPage(snapshot: snapshot, handover: nil, reviewOpener: { snapshot in
            (store, store.open(head: snapshot.head, pullRequest: snapshot.pullRequest,
                               history: .init(isOwnCommit: { _ in true }, isInReflog: { _ in true })))
        })
        defer { page.close() }
        page.waitUntil("a writable review") { page.controller.review?.canWrite == true }
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        let url = temp.appendingPathComponent("run.xml")
        try Data(#"<testsuite name="Example" tests="1"/>"#.utf8).write(to: url)
        page.controller.chooseReport = { window, directory, select in
            XCTAssertTrue(window === page.window)
            XCTAssertEqual(directory.path, "/repo")
            select(url)
        }
        func attach() throws {
            let menu = page.controller.view.header.currentMenu()
            let item = try XCTUnwrap(menu.item(withTitle: "Attach Report…"))
            menu.performActionForItem(at: menu.index(of: item))
        }
        try attach()
        let row = try page.waitFor("document.querySelector('.receipt')", then: "document.querySelector('.receipt').textContent")
        XCTAssertTrue(row.contains("Passed · Local · Current"))
        XCTAssertEqual(store.load().record.receipts.map(\.title), ["Example"])

        try Data("<notJUnit/>".utf8).write(to: url)
        try attach()
        _ = try page.waitFor("document.querySelector('#report-problem').textContent.includes('valid JUnit XML')")
        XCTAssertEqual(store.load().record.receipts.count, 1)
        try Data("<testsuite/>".utf8).write(to: url)
        var selectAfterRefresh: (@MainActor (URL) -> Void)?
        page.controller.chooseReport = { _, _, select in selectAfterRefresh = select }
        try attach()
        let generation = page.controller.snapshotCount
        page.controller.reload()
        page.waitUntil("a refreshed snapshot") { page.controller.snapshotCount > generation }
        try XCTUnwrap(selectAfterRefresh)(url)
        _ = try page.waitFor("document.querySelector('#report-problem:not([hidden])').textContent.includes('Refresh the branch review')")
        XCTAssertEqual(store.load().record.receipts.count, 1)
        page.controller.chooseReport = { _, _, select in select(url) }

        let before = try Data(contentsOf: store.fileURL)
        var record = try JSONDecoder().decode([String: JSONValue].self, from: before)
        for futureSection in [true, false] {
            if futureSection { record["receipts"] = .object(["version": .int(2)]) } else { record["version"] = .int(123) }
            let future = try JSONEncoder().encode(record)
            try future.write(to: store.fileURL, options: .atomic)
            try attach()
            let fragment = futureSection ? "receipt format" : "newer"
            _ = try page.waitFor("document.querySelector('#report-problem:not([hidden])').textContent.includes('\(fragment)')")
            XCTAssertEqual(try Data(contentsOf: store.fileURL), future)
        }
        page.controller.chooseReport = { _, _, _ in XCTFail("Read-only review opened the picker") }
        try attach()
    }
}
