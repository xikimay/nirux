import AppKit
import Darwin
import XCTest
@testable import Nirux

final class BranchReviewBrowserCaptureTests: XCTestCase {
    private typealias BrowserReceipt = BranchReview.BrowserReceipt

    private func makeTempStateDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("nirux-browser-receipt-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    private func makeSampleImage() throws -> CGImage {
        let context = try XCTUnwrap(CGContext(
            data: nil, width: 4, height: 4, bitsPerComponent: 8, bytesPerRow: 16,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        return try XCTUnwrap(context.makeImage())
    }

    @MainActor
    private func saveScreenshot(
        workspaceID: String,
        stateDirectory: URL,
        url: String = "https://localhost:3000/dashboard?token=secret#frag",
        consoleErrors: Int = 0,
        networkErrors: Int = 0,
        timestamp: Date = Date(timeIntervalSince1970: 1_700_000_000)
    ) throws -> URL {
        let capture = BrowserCapture(
            url: URL(string: url),
            timestamp: timestamp,
            viewport: CGSize(width: 800, height: 600),
            consoleErrorCount: consoleErrors,
            networkErrorCount: networkErrors
        )
        return try capture.save(try makeSampleImage(), workspaceID: workspaceID, stateDirectory: stateDirectory)
    }

    private func saveDiagnostics(
        workspaceID: String,
        stateDirectory: URL,
        url: String = "https://localhost:3000/dashboard",
        consoleErrors: Int = 0,
        networkErrors: Int = 0,
        events: [BrowserDiagnostics.Event] = [],
        timestamp: Date = Date(timeIntervalSince1970: 1_700_000_000)
    ) throws -> URL {
        let snapshot = BrowserCapture.DiagnosticsSnapshot(
            url: BrowserCapture.sanitizedURLString(url),
            timestamp: timestamp,
            consoleErrorCount: consoleErrors,
            networkErrorCount: networkErrors,
            events: events
        )
        return try BrowserCapture.saveDiagnostics(snapshot, workspaceID: workspaceID, stateDirectory: stateDirectory)
    }

    // MARK: - 1. Valid attachment & snapshot digest staleness

    @MainActor
    func testAttachScreenshotAndDiagnosticsBindsToSnapshotDigestAndTurnsStaleOnLocalEdit() throws {
        let state = try makeTempStateDirectory()
        let workspaceA = UUID().uuidString
        let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
        let screenshot = try saveScreenshot(workspaceID: workspaceA, stateDirectory: state, timestamp: timestamp)
        let diagnostics = try saveDiagnostics(
            workspaceID: workspaceA, stateDirectory: state,
            events: [BrowserDiagnostics.Event(kind: .warn, message: "minor warning")],
            timestamp: timestamp
        )
        let dirty = BranchReviewPageTests.snapshot(hasUncommittedChanges: true)
        let input = BrowserReceipt.Input(
            workspaceID: workspaceA,
            url: "https://user:pass@localhost:3000/dashboard?token=secret#section",
            capturedAt: timestamp,
            consoleErrorCount: 0,
            networkErrorCount: 0,
            screenshotPath: screenshot.path,
            diagnosticsPath: diagnostics.path
        )

        let receipt = try BrowserReceipt.receipt(from: input, for: dirty, workspaceID: workspaceA, stateDirectory: state, id: "cap-1")
        XCTAssertEqual(receipt.id, "cap-1")
        XCTAssertEqual(receipt.provenance, .local)
        XCTAssertEqual(receipt.status, .passed)
        XCTAssertEqual(receipt.title, "https://localhost:3000/dashboard")
        XCTAssertEqual(receipt.summary, "0 console errors, 0 network errors · screenshot + diagnostics")
        XCTAssertEqual(receipt.head, dirty.head)
        XCTAssertEqual(receipt.workingTreeDigest, try XCTUnwrap(dirty.workingTreeDigest))
        XCTAssertEqual(receipt.browserCapture?.workspaceID, workspaceA)
        XCTAssertEqual(receipt.browserCapture?.url, "https://localhost:3000/dashboard")
        XCTAssertEqual(receipt.browserCapture?.screenshotPath, screenshot.path.realPath)
        XCTAssertEqual(receipt.browserCapture?.diagnosticsPath, diagnostics.path.realPath)
        XCTAssertEqual(receipt.freshness(head: dirty.head, tree: dirty.workingTree), .fresh)

        // Any local edit changes the working tree digest and marks the receipt stale.
        var editedFiles = dirty.files
        editedFiles[0].patchHash = "edited-patch"
        let edited = BranchReviewControllerTests.snapshot(dirty, files: editedFiles)
        XCTAssertEqual(receipt.freshness(head: edited.head, tree: edited.workingTree), .stale(.localEdits))

        // A new HEAD marks the receipt stale for an earlier commit.
        let newerHead = String(repeating: "b", count: 40)
        XCTAssertEqual(receipt.freshness(head: newerHead, tree: dirty.workingTree), .stale(.earlierCommit))
    }

    func testDiagnosticsCountsConsoleExceptionsRejectionsAndNetworkFailures() {
        var buffer = BrowserDiagnostics()
        buffer.append(kind: .error, message: "console error")
        buffer.append(kind: .exception, message: "uncaught ReferenceError")
        buffer.append(kind: .rejection, message: "unhandled rejection")
        buffer.append(kind: .warn, message: "warning only")
        buffer.append(kind: .fetch, message: "500 https://localhost:3000/api")
        buffer.append(kind: .xhr, message: "404 https://localhost:3000/missing")
        XCTAssertEqual(buffer.consoleErrorCount, 3)
        XCTAssertEqual(buffer.networkErrorCount, 2)
    }

    // MARK: - 2. Incomplete snapshot refusal

    @MainActor
    func testRefusesAttachmentWhenWorkspaceSnapshotIsIncomplete() throws {
        let state = try makeTempStateDirectory()
        let workspaceA = UUID().uuidString
        let screenshot = try saveScreenshot(workspaceID: workspaceA, stateDirectory: state)
        let dirty = BranchReviewPageTests.snapshot(hasUncommittedChanges: true)
        var unreadFiles = dirty.files
        unreadFiles[0].omission = .notRead
        let incomplete = BranchReviewControllerTests.snapshot(dirty, files: unreadFiles)
        XCTAssertEqual(incomplete.workingTree, .incomplete)

        let input = BrowserReceipt.Input(
            workspaceID: workspaceA,
            url: "https://localhost:3000/",
            capturedAt: Date(timeIntervalSince1970: 1_700_000_000),
            consoleErrorCount: 0,
            networkErrorCount: 0,
            screenshotPath: screenshot.path,
            diagnosticsPath: nil
        )
        XCTAssertThrowsError(try BrowserReceipt.receipt(from: input, for: incomplete, workspaceID: workspaceA, stateDirectory: state)) { error in
            XCTAssertEqual(error as? BrowserReceipt.Problem, .incompleteSnapshot)
        }

        // Also verify controller refuses attachment and persists nothing.
        let store = try XCTUnwrap(BranchReview.Store(repository: "/repo", branch: incomplete.branch, stateDirectory: state))
        let page = try ReviewPage(
            snapshot: incomplete, handover: nil, workspaceID: workspaceA, stateDirectory: state,
            reviewOpener: { snap in
                (store, store.open(head: snap.head, pullRequest: snap.pullRequest,
                                   history: .init(isOwnCommit: { _ in true }, isInReflog: { _ in true })))
            }
        )
        defer { page.close() }
        page.waitUntil("writable review") { page.controller.review?.canWrite == true }

        var attachResult: Result<Void, Error>?
        page.controller.attachBrowserCapture(input) { attachResult = $0 }
        page.waitUntil("incomplete snapshot refusal") { attachResult != nil }
        if case .failure(let error)? = attachResult {
            XCTAssertEqual(error as? BrowserReceipt.Problem, .incompleteSnapshot)
        } else {
            XCTFail("Expected incomplete snapshot refusal")
        }
        _ = try page.waitFor("document.querySelector('#report-problem:not([hidden])').textContent.includes('full working tree')")
        XCTAssertTrue(store.load().record.receipts.isEmpty)
    }

    // MARK: - 3. Strict cross-workspace isolation (including symlinks & traversal)

    @MainActor
    func testCrossWorkspaceIsolationRejectsAttachmentTraversalSymlinksAndViewing() throws {
        let state = try makeTempStateDirectory()
        let workspaceA = UUID().uuidString
        let workspaceB = UUID().uuidString
        let screenshotA = try saveScreenshot(workspaceID: workspaceA, stateDirectory: state)
        let diagnosticsA = try saveDiagnostics(workspaceID: workspaceA, stateDirectory: state)
        _ = try saveScreenshot(workspaceID: workspaceB, stateDirectory: state)
        let snapshot = BranchReviewPageTests.snapshot()

        func input(workspaceID: String, screenshot: String?, diagnostics: String? = nil) -> BrowserReceipt.Input {
            BrowserReceipt.Input(
                workspaceID: workspaceID,
                url: "https://localhost:3000/app",
                capturedAt: Date(timeIntervalSince1970: 1_700_000_000),
                consoleErrorCount: 0,
                networkErrorCount: 0,
                screenshotPath: screenshot,
                diagnosticsPath: diagnostics
            )
        }

        // Mismatched workspace ID.
        XCTAssertThrowsError(try BrowserReceipt.receipt(
            from: input(workspaceID: workspaceA, screenshot: screenshotA.path),
            for: snapshot, workspaceID: workspaceB, stateDirectory: state
        )) { XCTAssertEqual($0 as? BrowserReceipt.Problem, .crossWorkspaceCapture) }

        // Spoofed workspace B ID pointing directly to workspace A's screenshot or diagnostics.
        XCTAssertThrowsError(try BrowserReceipt.receipt(
            from: input(workspaceID: workspaceB, screenshot: screenshotA.path),
            for: snapshot, workspaceID: workspaceB, stateDirectory: state
        )) { XCTAssertEqual($0 as? BrowserReceipt.Problem, .crossWorkspaceCapture) }

        XCTAssertThrowsError(try BrowserReceipt.receipt(
            from: input(workspaceID: workspaceB, screenshot: nil, diagnostics: diagnosticsA.path),
            for: snapshot, workspaceID: workspaceB, stateDirectory: state
        )) { XCTAssertEqual($0 as? BrowserReceipt.Problem, .crossWorkspaceCapture) }

        // Path traversal from B into A.
        let folderB = state.appendingPathComponent("captures").appendingPathComponent(workspaceB)
        let traversal = folderB.path + "/../\(workspaceA)/\(screenshotA.lastPathComponent)"
        XCTAssertThrowsError(try BrowserReceipt.receipt(
            from: input(workspaceID: workspaceB, screenshot: traversal),
            for: snapshot, workspaceID: workspaceB, stateDirectory: state
        )) { XCTAssertEqual($0 as? BrowserReceipt.Problem, .crossWorkspaceCapture) }

        // Symlink inside B pointing to A's PNG.
        let linkInB = folderB.appendingPathComponent("capture-link.png")
        try FileManager.default.createSymbolicLink(at: linkInB, withDestinationURL: screenshotA)
        XCTAssertThrowsError(try BrowserReceipt.receipt(
            from: input(workspaceID: workspaceB, screenshot: linkInB.path),
            for: snapshot, workspaceID: workspaceB, stateDirectory: state
        )) { XCTAssertEqual($0 as? BrowserReceipt.Problem, .crossWorkspaceCapture) }

        // Symlinked workspace folder pointing to A's capture folder.
        let workspaceC = UUID().uuidString
        let folderC = state.appendingPathComponent("captures").appendingPathComponent(workspaceC)
        try FileManager.default.createSymbolicLink(
            at: folderC,
            withDestinationURL: state.appendingPathComponent("captures").appendingPathComponent(workspaceA)
        )
        let viaSymlinkedFolder = folderC.appendingPathComponent(screenshotA.lastPathComponent)
        XCTAssertThrowsError(try BrowserReceipt.receipt(
            from: input(workspaceID: workspaceC, screenshot: viaSymlinkedFolder.path),
            for: snapshot, workspaceID: workspaceC, stateDirectory: state
        )) { XCTAssertEqual($0 as? BrowserReceipt.Problem, .crossWorkspaceCapture) }

        // Non-PNG regular file and FIFO inside B's folder are rejected.
        let fakePNG = folderB.appendingPathComponent("capture-fake.png")
        try Data("not a png".utf8).write(to: fakePNG)
        XCTAssertThrowsError(try BrowserReceipt.receipt(
            from: input(workspaceID: workspaceB, screenshot: fakePNG.path),
            for: snapshot, workspaceID: workspaceB, stateDirectory: state
        )) { XCTAssertEqual($0 as? BrowserReceipt.Problem, .crossWorkspaceCapture) }

        let pipePNG = folderB.appendingPathComponent("capture-pipe.png")
        XCTAssertEqual(mkfifo(pipePNG.path, 0o600), 0)
        XCTAssertThrowsError(try BrowserReceipt.receipt(
            from: input(workspaceID: workspaceB, screenshot: pipePNG.path),
            for: snapshot, workspaceID: workspaceB, stateDirectory: state
        )) { XCTAssertEqual($0 as? BrowserReceipt.Problem, .crossWorkspaceCapture) }

        // Reading / viewing in workspace B's Branch Review must NEVER expose workspace A's receipt.
        let receiptA = try BrowserReceipt.receipt(
            from: input(workspaceID: workspaceA, screenshot: screenshotA.path),
            for: snapshot, workspaceID: workspaceA, stateDirectory: state, id: "receipt-a"
        )
        let pageForA = BranchReview.page(for: snapshot, handover: nil, receipts: [receiptA], workspaceID: workspaceA, stateDirectory: state)
        XCTAssertEqual(pageForA.receipts?.count, 1)
        XCTAssertEqual(pageForA.receipts?.first?.artifactID, "receipt-a")

        let pageForB = BranchReview.page(for: snapshot, handover: nil, receipts: [receiptA], workspaceID: workspaceB, stateDirectory: state)
        XCTAssertNil(pageForB.receipts)

        let pageWithoutWorkspace = BranchReview.page(for: snapshot, handover: nil, receipts: [receiptA], workspaceID: nil, stateDirectory: state)
        XCTAssertNil(pageWithoutWorkspace.receipts)

        // Tampered stored receipt claiming workspace B while pointing to workspace A's PNG is denied on read too.
        let tampered = BranchReview.Receipt(
            id: "tampered",
            title: "https://localhost:3000/app",
            command: nil,
            status: .passed,
            summary: "0 console errors, 0 network errors · screenshot",
            provenance: .local,
            recordedAt: Date(timeIntervalSince1970: 1_700_000_000),
            head: snapshot.head,
            workingTreeDigest: snapshot.workingTreeDigest,
            browserCapture: .init(
                workspaceID: workspaceB,
                url: "https://localhost:3000/app",
                capturedAt: Date(timeIntervalSince1970: 1_700_000_000),
                consoleErrorCount: 0,
                networkErrorCount: 0,
                screenshotPath: screenshotA.path,
                diagnosticsPath: nil
            )
        )
        let pageTampered = BranchReview.page(for: snapshot, handover: nil, receipts: [tampered], workspaceID: workspaceB, stateDirectory: state)
        XCTAssertNil(pageTampered.receipts)
    }

    // MARK: - 4. Rollback-safe JSON encoding & decoding

    @MainActor
    func testRollbackSafeReceiptEncodingAndDecoding() throws {
        // Simulates an older Nirux build's Receipt schema without `browserCapture`.
        struct LegacyReceipt: Codable, Equatable {
            let id: String
            let title: String
            let command: String?
            let status: BranchReview.Receipt.Status
            let summary: String?
            let provenance: BranchReview.Receipt.Provenance
            let recordedAt: Date
            let head: String
            let workingTreeDigest: String?
        }

        let state = try makeTempStateDirectory()
        let workspaceA = UUID().uuidString
        let screenshot = try saveScreenshot(workspaceID: workspaceA, stateDirectory: state)
        let snapshot = BranchReviewPageTests.snapshot(hasUncommittedChanges: true)
        let timestamp = Date(timeIntervalSince1970: 1_700_000_123)
        let receipt = try BrowserReceipt.receipt(
            from: BrowserReceipt.Input(
                workspaceID: workspaceA,
                url: "https://localhost:5173/checkout",
                capturedAt: timestamp,
                consoleErrorCount: 1,
                networkErrorCount: 2,
                screenshotPath: screenshot.path,
                diagnosticsPath: nil
            ),
            for: snapshot, workspaceID: workspaceA, stateDirectory: state, id: "browser-1"
        )

        // Round-trip through BranchReview.Record.
        var record = BranchReview.Record()
        XCTAssertTrue(record.addReceipt(receipt))
        let encodedFields = try JSONEncoder().encode(record.fields)
        let decodedFields = try JSONDecoder().decode([String: JSONValue].self, from: encodedFields)
        XCTAssertEqual(BranchReview.Record(fields: decodedFields).receipts, [receipt])

        // Older Nirux build decodes the stored JSON cleanly, ignoring `browserCapture`.
        let section = try XCTUnwrap(decodedFields["receipts"]?.objectValue)
        XCTAssertEqual(section["version"], .int(1))
        let firstItem = try XCTUnwrap(section["items"]?.arrayValue?.first)
        let itemData = try JSONEncoder().encode(firstItem)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let legacy = try decoder.decode(LegacyReceipt.self, from: itemData)
        XCTAssertEqual(legacy.id, "browser-1")
        XCTAssertEqual(legacy.provenance, .local)
        XCTAssertEqual(legacy.status, .failed)
        XCTAssertEqual(legacy.title, "https://localhost:5173/checkout")
        XCTAssertEqual(legacy.summary, "1 console error, 2 network errors · screenshot")
        XCTAssertEqual(legacy.head, snapshot.head)
        XCTAssertEqual(legacy.workingTreeDigest, snapshot.workingTreeDigest)

        // Newer build decodes future extra keys on both Receipt and BrowserArtifact cleanly.
        var extended = try XCTUnwrap(firstItem.objectValue)
        extended["futureTopLevelField"] = .string("ignored")
        var extendedCapture = try XCTUnwrap(extended["browserCapture"]?.objectValue)
        extendedCapture["futureNestedField"] = .bool(true)
        extended["browserCapture"] = .object(extendedCapture)
        let extendedRecord = BranchReview.Record(fields: [
            "receipts": .object(["version": .int(1), "items": .array([.object(extended)])])
        ])
        XCTAssertEqual(extendedRecord.receipts, [receipt])

        // Older BrowserCapture PNG metadata without networkErrorCount decodes with 0.
        let legacyCaptureJSON = #"{"url":"https://example.test","timestamp":"2026-11-22T12:00:00Z","viewport":[100,200],"consoleErrorCount":2}"#
        let isoDecoder = JSONDecoder()
        isoDecoder.dateDecodingStrategy = .iso8601
        let decodedCapture = try isoDecoder.decode(BrowserCapture.self, from: Data(legacyCaptureJSON.utf8))
        XCTAssertEqual(decodedCapture.consoleErrorCount, 2)
        XCTAssertEqual(decodedCapture.networkErrorCount, 0)
    }

    // MARK: - 5. Branch Review UI rendering (clean, with errors, stale) & safe artifact click

    @MainActor
    func testBranchReviewRendersCleanErrorsAndStaleBrowserReceiptsAndOpensArtifactSafely() throws {
        let state = try makeTempStateDirectory()
        let workspaceA = UUID().uuidString
        let screenshot = try saveScreenshot(workspaceID: workspaceA, stateDirectory: state)
        let diagnostics = try saveDiagnostics(
            workspaceID: workspaceA, stateDirectory: state,
            consoleErrors: 2, networkErrors: 1,
            events: [
                .init(kind: .error, message: "boom"),
                .init(kind: .exception, message: "uncaught"),
                .init(kind: .fetch, message: "500 https://localhost:3000/api")
            ]
        )

        let currentSnapshot = BranchReviewPageTests.snapshot(hasUncommittedChanges: true)
        let cleanReceipt = try BrowserReceipt.receipt(
            from: BrowserReceipt.Input(
                workspaceID: workspaceA,
                url: "https://localhost:3000/clean",
                capturedAt: Date(timeIntervalSince1970: 1_700_000_100),
                consoleErrorCount: 0,
                networkErrorCount: 0,
                screenshotPath: screenshot.path,
                diagnosticsPath: nil
            ),
            for: currentSnapshot, workspaceID: workspaceA, stateDirectory: state, id: "clean-1"
        )
        let errorReceipt = try BrowserReceipt.receipt(
            from: BrowserReceipt.Input(
                workspaceID: workspaceA,
                url: "https://localhost:3000/<b>broken</b>",
                capturedAt: Date(timeIntervalSince1970: 1_700_000_200),
                consoleErrorCount: 2,
                networkErrorCount: 1,
                screenshotPath: nil,
                diagnosticsPath: diagnostics.path
            ),
            for: currentSnapshot, workspaceID: workspaceA, stateDirectory: state, id: "errors-1"
        )
        let staleReceipt = BranchReview.Receipt(
            id: "stale-1",
            title: "<b>old</b>\u{202E}",
            command: nil,
            status: .passed,
            summary: "0 console errors, 0 network errors · screenshot",
            provenance: .local,
            recordedAt: Date(timeIntervalSince1970: 1_700_000_000),
            head: currentSnapshot.head,
            workingTreeDigest: String(repeating: "f", count: 64),
            browserCapture: .init(
                workspaceID: workspaceA,
                url: "https://localhost:3000/old",
                capturedAt: Date(timeIntervalSince1970: 1_700_000_000),
                consoleErrorCount: 0,
                networkErrorCount: 0,
                screenshotPath: screenshot.path,
                diagnosticsPath: nil
            )
        )

        let store = try XCTUnwrap(BranchReview.Store(repository: "/repo", branch: currentSnapshot.branch, stateDirectory: state))
        let history = BranchReview.History(isOwnCommit: { _ in true }, isInReflog: { _ in true })
        let access = try XCTUnwrap(store.open(head: currentSnapshot.head, pullRequest: currentSnapshot.pullRequest, history: history).access)
        _ = try store.update(access) { record in
            XCTAssertTrue(record.addReceipt(staleReceipt))
            XCTAssertTrue(record.addReceipt(errorReceipt))
            XCTAssertTrue(record.addReceipt(cleanReceipt))
        }.get()

        let page = try ReviewPage(
            snapshot: currentSnapshot, handover: nil, workspaceID: workspaceA, stateDirectory: state,
            reviewOpener: { snap in
                (store, store.open(head: snap.head, pullRequest: snap.pullRequest, history: history))
            }
        )
        defer { page.close() }

        var openedReceiptID: String?
        var openedScreenshotPath: String?
        page.controller.presentReceiptArtifact = { receipt, artifacts in
            openedReceiptID = receipt.id
            openedScreenshotPath = artifacts.screenshotURL?.path
        }

        let text = try page.waitFor("document.querySelectorAll('.receipt').length === 3", then: "document.querySelector('.receipts').textContent")
        XCTAssertTrue(text.contains("https://localhost:3000/clean"))
        XCTAssertTrue(text.contains("<b>old</b>⟨U+202E⟩"))
        XCTAssertTrue(text.contains("No errors · Local browser · Current"))
        XCTAssertTrue(text.contains("0 console errors, 0 network errors · screenshot"))
        XCTAssertTrue(text.contains("Errors · Local browser · Current"))
        XCTAssertTrue(text.contains("2 console errors, 1 network error · diagnostics"))
        XCTAssertTrue(text.contains("No errors · Local browser · Stale: local edits"))
        XCTAssertTrue(text.contains("Preview screenshot"))
        XCTAssertTrue(text.contains("View diagnostics"))
        XCTAssertFalse(text.localizedCaseInsensitiveContains("approved"))
        // HTML is never interpreted and browser URLs are never turned into external links.
        XCTAssertEqual(try page.run("return String(document.querySelectorAll('.receipt b, .receipt a').length);"), "0")

        // Clicking "Preview screenshot" invokes Swift's validated artifact handler.
        _ = try page.run("document.querySelector('.receipt-artifact').click(); return 'clicked';")
        page.waitUntil("artifact preview callback") { openedReceiptID != nil }
        XCTAssertEqual(openedReceiptID, "clean-1")
        XCTAssertEqual(openedScreenshotPath, screenshot.path.realPath)

        // Removing the screenshot keeps the receipt row readable while refusing stale artifact open cleanly.
        try FileManager.default.removeItem(at: screenshot)
        let pageAfterDelete = BranchReview.page(
            for: currentSnapshot, handover: nil, receipts: [cleanReceipt], workspaceID: workspaceA, stateDirectory: state
        )
        XCTAssertEqual(pageAfterDelete.receipts?.count, 1)
        XCTAssertNil(pageAfterDelete.receipts?.first?.artifactID)
        page.controller.openReceiptArtifact(id: "clean-1")
        _ = try page.waitFor("document.querySelector('#report-problem:not([hidden])').textContent.includes('no longer available')")
    }

    @MainActor
    func testIsolatedBrowserManualAttachFlowPersistsReceiptAndNeverAutoAttaches() throws {
        try UIFlowHarness.run { harness in
            let workspace = try XCTUnwrap(harness.shell.activeWorkspace)
            let state = URL(fileURLWithPath: harness.stateDirectory)
            let snapshot = BranchReviewPageTests.snapshot(hasUncommittedChanges: true)
            let store = try XCTUnwrap(BranchReview.Store(repository: harness.repo, branch: snapshot.branch, stateDirectory: state))
            let history = BranchReview.History(isOwnCommit: { _ in true }, isInReflog: { _ in true })
            harness.shell.branchReviewReader = { _, _, _ in (.snapshot(snapshot), nil) }
            harness.shell.branchReviewOpener = { snap in
                (store, store.open(head: snap.head, pullRequest: snap.pullRequest, history: history))
            }
            harness.shell.branchReviewBranchCheck = { _ in true }

            let html = URL(fileURLWithPath: harness.repo + "/browser-receipt.html")
            try "<body>UI receipt fixture<script>console.error('ui failure')</script></body>"
                .write(to: html, atomically: true, encoding: .utf8)
            harness.shell.openWebView(url: html.absoluteString, in: workspace, isIsolated: true)
            let browser = try XCTUnwrap(workspace.columns[safe: workspace.focusedIndex]?.webViewColumn)
            let diagnostics = try XCTUnwrap(browser.diagnostics)
            guard harness.waitUntil("fixture error", { diagnostics.buffer.consoleErrorCount == 1 && !browser.webView.isLoading }) else { return }

            let menu = browser.header.currentMenu()
            @MainActor func select(_ title: String) throws {
                menu.performActionForItem(at: menu.index(of: try XCTUnwrap(menu.item(withTitle: title))))
            }

            // Capturing screenshot alone does NOT automatically attach a receipt.
            try select("Capture Screenshot")
            harness.waitUntil("screenshot saved sheet") { harness.window.attachedSheet != nil }
            XCTAssertTrue(store.load().record.receipts.isEmpty)

            // Clicking the 3rd button ("Attach to Branch Review") attaches explicitly.
            let screenshotSheet = try XCTUnwrap(harness.window.attachedSheet)
            harness.window.endSheet(screenshotSheet, returnCode: .alertThirdButtonReturn)
            harness.waitUntil("receipt persisted and confirmation sheet shown") {
                store.load().record.receipts.count == 1
                    && harness.window.attachedSheet != nil
                    && harness.window.attachedSheet !== screenshotSheet
            }

            let attached = try XCTUnwrap(store.load().record.receipts.first)
            XCTAssertEqual(attached.status, .failed)
            XCTAssertEqual(attached.browserCapture?.workspaceID, workspace.id)
            XCTAssertEqual(attached.browserCapture?.consoleErrorCount, 1)
            XCTAssertEqual(attached.browserCapture?.networkErrorCount, 0)
            XCTAssertNotNil(attached.browserCapture?.screenshotPath)
            XCTAssertNotNil(attached.browserCapture?.diagnosticsPath)

            // Dismiss the confirmation sheet ("Attached to Branch Review").
            let confirmSheet1 = try XCTUnwrap(harness.window.attachedSheet)
            harness.window.endSheet(confirmSheet1, returnCode: .alertFirstButtonReturn)
            harness.waitUntil("confirmation sheet closed") { harness.window.attachedSheet == nil }

            // Explicit manual attach from the Diagnostics sheet persists a diagnostics-only receipt.
            try select("Diagnostics…")
            harness.waitUntil("diagnostics sheet") { harness.window.attachedSheet != nil }
            let diagnosticsSheet = try XCTUnwrap(harness.window.attachedSheet)
            let attachResponse = NSApplication.ModalResponse(
                rawValue: NSApplication.ModalResponse.alertThirdButtonReturn.rawValue + 1
            )
            harness.window.endSheet(diagnosticsSheet, returnCode: attachResponse)
            harness.waitUntil("diagnostics receipt persisted and confirmation sheet shown") {
                store.load().record.receipts.count == 2
                    && harness.window.attachedSheet != nil
                    && harness.window.attachedSheet !== diagnosticsSheet
            }
            let diagReceipt = try XCTUnwrap(store.load().record.receipts.first)
            XCTAssertNil(diagReceipt.browserCapture?.screenshotPath)
            XCTAssertNotNil(diagReceipt.browserCapture?.diagnosticsPath)
            XCTAssertEqual(diagReceipt.browserCapture?.consoleErrorCount, 1)

            let confirmSheet2 = try XCTUnwrap(harness.window.attachedSheet)
            harness.window.endSheet(confirmSheet2, returnCode: .alertFirstButtonReturn)
            harness.waitUntil("second confirmation sheet closed") { harness.window.attachedSheet == nil }
        }
    }
}
