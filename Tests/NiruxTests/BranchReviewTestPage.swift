import AppKit
import WebKit
import XCTest
@testable import Nirux

/// A Branch Review column showing `snapshot`, in a window never shown.
@MainActor
final class ReviewPage {
    let controller: BranchReviewController
    /// The roots the column asked to watch, in turn: no real watcher runs.
    let watchers = BranchReviewControllerTests.Recorder<String>()
    let window: NSWindow
    private let webView: WKWebView

    convenience init(
        snapshot: BranchReview.Snapshot, handover: BranchReview.Handover?,
        patchReader: @escaping BranchReviewController.PatchReader = { _, _ in nil },
        openLink: @escaping (URL) -> Void = { _ in },
        reviewOpener: @escaping BranchReviewController.ReviewOpener = { _ in nil },
        branchCheck: @escaping BranchReviewController.BranchCheck = { _ in true },
        headOrder: @escaping BranchReviewController.HeadOrder = { _, ancestor, descendant in ancestor == descendant }
    ) throws {
        try self.init(
            reader: { _, _, _ in (.snapshot(snapshot), handover) }, patchReader: patchReader, openLink: openLink,
            reviewOpener: reviewOpener, branchCheck: branchCheck, headOrder: headOrder
        )
    }

    /// Waits for the first read to show a page, unless `waitsForPage` is
    /// false. No review file opens unless `reviewOpener` opens one: never
    /// the real state's.
    init(
        reader: @escaping BranchReviewController.Reader,
        patchReader: @escaping BranchReviewController.PatchReader = { _, _ in nil },
        openLink: @escaping (URL) -> Void = { _ in }, waitsForPage: Bool = true,
        makeWatcher: BranchReviewController.WatcherFactory? = nil, worktree: String = "/repo",
        reviewOpener: @escaping BranchReviewController.ReviewOpener = { _ in nil },
        branchCheck: @escaping BranchReviewController.BranchCheck = { _ in true },
        headOrder: @escaping BranchReviewController.HeadOrder = { _, ancestor, descendant in ancestor == descendant }
    ) throws {
        let watchers = watchers
        controller = BranchReviewController(
            worktree: worktree, branch: nil, reader: reader, patchReader: patchReader,
            makeWatcher: makeWatcher ?? { layout, _, _ in
                _ = watchers.append(layout.worktreeRoot)
                return nil
            },
            reviewOpener: reviewOpener, branchCheck: branchCheck, headOrder: headOrder
        )
        controller.view.openLink = openLink
        // Tests wait seconds, not the app's.
        controller.watchTiming = .init(settle: 0.2, metadataSettle: 0.1, maxWait: 0.8, quietMaxWait: 3.2)
        let frame = NSRect(x: 0, y: 0, width: 900, height: 800)
        window = NSWindow(contentRect: frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = controller.view
        webView = try XCTUnwrap(controller.view.subviews.compactMap { $0 as? WKWebView }.first)
        controller.reload()
        waitUntil("the page to load") { [controller] in controller.view.isPageReady }
        if waitsForPage { try waitForPage() }
    }

    /// Until the page shows a review.
    func waitForPage() throws {
        waitUntil("the read") { [controller] in controller.snapshot != nil && !controller.isReading }
        _ = try run("""
            const deadline = Date.now() + 10000;
            while (!document.querySelector("#page:not([hidden]) .groups") && Date.now() < deadline) await new Promise((resolve) => setTimeout(resolve, 20));
            return "";
            """)
    }

    func waitUntil(_ description: String, timeout: TimeInterval = 30, _ condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else { return XCTFail("timed out waiting for \(description)") }
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
    }

    /// Runs `body` as an async function in the page; it returns a string.
    func run(_ body: String, timeout: TimeInterval = 30) throws -> String {
        let outcome = Outcome()
        webView.callAsyncJavaScript(body, arguments: [:], in: nil, in: .page) { outcome.result = $0 }
        waitUntil("the script", timeout: timeout) { outcome.result != nil }
        return try XCTUnwrap(try outcome.result?.get() as? String)
    }

    /// The column leaves its window as when it closes: its watcher stops.
    func close() {
        window.contentView = nil
        window.close()
    }

    /// Set on the main thread, where WebKit calls back.
    private final class Outcome: @unchecked Sendable {
        var result: Result<Any, Error>?
    }
}
