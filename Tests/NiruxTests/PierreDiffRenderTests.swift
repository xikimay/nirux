import AppKit
import WebKit
import XCTest

/// The committed `pierre-diff.bundle.js`, run in a WKWebView: the editor's
/// stacked diff, and the Branch Review page's diffs, which show text that
/// neither Nirux nor the user wrote (docs/branch-review.md, section 1.1).
/// The window is never shown: pierre renders what is near the viewport
/// right away.
final class PierreDiffRenderTests: XCTestCase {
    @MainActor
    func testEditorStackedDiffRendersEachFile() throws {
        let page = try BundlePage()
        defer { page.close() }
        let result = try page.run("""
            const root = document.getElementById("root");
            window.NiruxPierreDiff.renderMany(root, { title: "Full Branch Diff (2)", files: [
              { path: "/repo/Sources/App.swift", original: "let a = 1\\nlet b = 2\\n", modified: "let a = 1\\nlet b = 3\\n" },
              { path: "/repo/README.md", original: "# Title\\n", modified: "# Title\\n\\nMore.\\n" }
            ] });
            const lines = () => [...root.querySelectorAll("diffs-container")]
              .map((host) => [...(host.shadowRoot?.querySelectorAll("[data-line]") ?? [])].map((line) => line.textContent));
            while (lines().some((file) => file.length === 0)) await new Promise((resolve) => setTimeout(resolve, 20));
            return JSON.stringify({ summary: root.querySelector(".nirux-pierre-summary").textContent, lines: lines() });
            """)
        let rendered = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(result.utf8)) as? [String: Any])
        XCTAssertEqual(rendered["summary"] as? String, "Full Branch Diff (2)2 files")
        let lines = try XCTUnwrap(rendered["lines"] as? [[String]])
        // Split: each side's lines, the unchanged ones on both.
        XCTAssertEqual(lines.count, 2)
        XCTAssertTrue(lines[0].contains("let b = 2") && lines[0].contains("let b = 3"), "\(lines[0])")
        XCTAssertTrue(lines[1].contains("More."), "\(lines[1])")
    }

    /// The review page's path and lines are a branch's: HTML in them is
    /// text, and nothing they hold runs.
    @MainActor
    func testReviewDiffShowsCraftedPathAndLinesAsText() throws {
        let lines = [
            ("context", #"let markup = "<b>bold</b>""#),
            ("removed", #"let old = "</span><img src=x onerror=\"window.pwned = 'line'\">""#),
            ("added", "let new = \"<script>window.pwned = 'script'</script>\""),
            ("added", "let escape = \"\u{1B}[201~\u{202E}evil\u{202C}\"")
        ]
        let rendered = try renderReview(
            path: #"Sources/<img src=x onerror="window.pwned = 'path'">/A.swift"#,
            hunks: [(oldStart: 1, newStart: 1, lines: lines)]
        )
        XCTAssertEqual(rendered.lines, lines.map(\.1))
        XCTAssertEqual(rendered.elements, 0, "the diff holds elements made of its text")
        XCTAssertNil(rendered.pwned)
    }

    /// A line break inside a line, read as one, would end the line in the
    /// patch pierre parses: the rest would read as another line or a hunk.
    @MainActor
    func testLineBreakInsideALineStaysInThatLine() throws {
        let rendered = try renderReview(path: "A.swift", hunks: [(oldStart: 4, newStart: 4, lines: [
            ("added", "let a = 1\u{2028}@@ -1,1 +1,1 @@\r+let b = 2\u{2029}c\nd"),
            ("added", "let crlf = 3\r")
        ])])
        XCTAssertEqual(rendered.lines, ["let a = 1\u{2424}@@ -1,1 +1,1 @@\u{240D}+let b = 2\u{2424}c\u{2424}d", "let crlf = 3"])
        XCTAssertEqual(rendered.lineNumbers, ["4", "5"])
    }

    private struct ReviewRender {
        let lines: [String]
        let lineNumbers: [String]
        /// Elements whose tag a crafted string names.
        let elements: Int
        let pwned: String?
    }

    @MainActor
    private func renderReview(
        path: String, hunks: [(oldStart: Int, newStart: Int, lines: [(String, String)])]
    ) throws -> ReviewRender {
        let page = try BundlePage()
        defer { page.close() }
        let file: [String: Any] = [
            "path": path,
            "hunks": hunks.map { hunk in
                [
                    "oldStart": hunk.oldStart, "newStart": hunk.newStart, "section": "",
                    "lines": hunk.lines.map { ["kind": $0.0, "text": $0.1] }
                ] as [String: Any]
            }
        ]
        let json = String(decoding: try JSONSerialization.data(withJSONObject: file), as: UTF8.self)
        let result = try page.run("""
            const root = document.getElementById("root");
            const review = window.NiruxPierreDiff.createReview(document);
            review.renderFile(root, \(json));
            const shadow = () => root.querySelector("diffs-container")?.shadowRoot;
            const lines = () => [...(shadow()?.querySelectorAll("[data-line]") ?? [])];
            // Highlighted: the tokens came back from the highlighter.
            while (lines().length === 0 || !shadow().querySelector("[data-line] span[style]")) {
              await new Promise((resolve) => setTimeout(resolve, 20));
            }
            return JSON.stringify({
              lines: lines().map((line) => line.querySelector("[data-column-content]")?.textContent ?? line.textContent),
              lineNumbers: [...shadow().querySelectorAll("[data-column-number]")].map((cell) => cell.textContent),
              elements: shadow().querySelectorAll("b, img, script").length + document.querySelectorAll("b, img, script").length,
              pwned: window.pwned ?? null
            });
            """)
        let rendered = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(result.utf8)) as? [String: Any])
        return ReviewRender(
            lines: rendered["lines"] as? [String] ?? [],
            lineNumbers: rendered["lineNumbers"] as? [String] ?? [],
            elements: rendered["elements"] as? Int ?? -1,
            pwned: rendered["pwned"] as? String
        )
    }
}

/// A blank page with the committed bundle, in a window that is never shown.
@MainActor
private final class BundlePage {
    private static let bundle = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Sources/Nirux/EditorAssets/pierre-diff.bundle.js")

    private let window: NSWindow
    private let webView: WKWebView

    init() throws {
        let config = WKWebViewConfiguration()
        config.userContentController.addUserScript(WKUserScript(
            source: try String(contentsOf: Self.bundle, encoding: .utf8),
            injectionTime: .atDocumentEnd, forMainFrameOnly: true
        ))
        let frame = NSRect(x: 0, y: 0, width: 900, height: 700)
        webView = WKWebView(frame: frame, configuration: config)
        window = NSWindow(contentRect: frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = webView
        webView.loadHTMLString("<!doctype html><meta charset=utf-8><body><div id=root></div></body>", baseURL: nil)
        let deadline = Date().addingTimeInterval(30)
        while webView.isLoading || webView.url == nil {
            guard Date() < deadline else { throw PageError("the page didn't load") }
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        guard try run("return typeof window.NiruxPierreDiff") == "object" else { throw PageError("the bundle didn't run") }
    }

    /// Runs `body` as an async function in the page; it returns a string.
    func run(_ body: String, timeout: TimeInterval = 30) throws -> String {
        var outcome: Result<Any, Error>?
        webView.callAsyncJavaScript(body, arguments: [:], in: nil, in: .page) { outcome = $0 }
        let deadline = Date().addingTimeInterval(timeout)
        while outcome == nil {
            guard Date() < deadline else { throw PageError("the script didn't finish in \(Int(timeout)) s") }
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        guard let value = try outcome?.get() as? String else { throw PageError("the script returned no string") }
        return value
    }

    func close() {
        window.close()
    }

    struct PageError: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }
}
