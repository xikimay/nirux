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

    /// The review page's lines are a branch's: HTML in them is text, and
    /// nothing they hold runs. pierre's file header is off, so the path only
    /// picks the language today; it stays crafted in case the header comes
    /// back.
    @MainActor
    func testReviewDiffShowsCraftedLinesAsText() throws {
        let lines = [
            ("context", #"let markup = "<b>bold</b>""#),
            ("removed", #"let old = "</span><img src=x onerror="window.pwned = 'line'">""#),
            ("added", "let new = \"<script>window.pwned = 'script'</script>\""),
            ("added", "let escape = \"\u{1B}[201~\""),
            ("context", "}")
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
        let rendered = try renderReview(path: "A.swift", hunks: [
            (oldStart: 4, newStart: 4, lines: [("added", "let a = 1\u{2028}@@ -1,1 +1,1 @@\r+let b = 2\u{2029}c\nd")]),
            // A CRLF file's line ending.
            (oldStart: 20, newStart: 20, lines: [("removed", "let crlf = 3\r"), ("added", "let crlf = 4\r")])
        ])
        XCTAssertEqual(
            rendered.lines,
            ["let a = 1⟨U+2028⟩@@ -1,1 +1,1 @@⟨U+000D⟩+let b = 2⟨U+2029⟩c⟨U+000A⟩d", "let crlf = 3", "let crlf = 4"]
        )
        XCTAssertEqual(rendered.lineNumbers, ["4", "20", "20"])
        XCTAssertNil(rendered.uncolored)
    }

    /// Only the line ending changed: hidden, the two lines would read the
    /// same.
    @MainActor
    func testLineEndingChangeShowsTheCarriageReturn() throws {
        let rendered = try renderReview(path: "A.swift", hunks: [
            (oldStart: 1, newStart: 1, lines: [("removed", "let a = 1\r"), ("added", "let a = 1")]),
            // CRLF lines added to an LF file.
            (oldStart: 10, newStart: 10, lines: [("context", "let b = 2"), ("added", "let c = 3\r")]),
            // A CRLF file whose last line, without a newline, has no CR.
            (oldStart: 20, newStart: 20, lines: [
                ("context", "foo();\r"), ("removed", "}"), ("noNewlineMarker", ""),
                ("added", "bar();\r"), ("added", "}"), ("noNewlineMarker", "")
            ])
        ])
        XCTAssertEqual(rendered.lines, [
            "let a = 1⟨U+000D⟩", "let a = 1", "let b = 2", "let c = 3⟨U+000D⟩", "foo();", "}", "bar();", "}"
        ])
    }

    /// The editor highlights `Dockerfile` by its name; so does the review,
    /// whatever folder it is in.
    @MainActor
    func testLanguageComesFromTheFileName() throws {
        let rendered = try renderReview(path: "docker/Dockerfile", hunks: [(oldStart: 1, newStart: 1, lines: [
            ("added", "FROM alpine:3.20"), ("added", "RUN apk add git")
        ])])
        XCTAssertEqual(rendered.lines, ["FROM alpine:3.20", "RUN apk add git"])
        XCTAssertTrue(rendered.colored)
    }

    /// A kind the wrapper doesn't know, even one named like an `Object`
    /// member, is left out, and the hunk's numbers ignore it.
    @MainActor
    func testUnknownLineKindIsLeftOut() throws {
        let rendered = try renderReview(path: "A.swift", hunks: [(oldStart: 1, newStart: 1, lines: [
            ("added", "let a = 1"), ("toString", "let b = 2"), ("added", "let c = 3")
        ])])
        XCTAssertEqual(rendered.lines, ["let a = 1", "let c = 3"])
        XCTAssertEqual(rendered.lineNumbers, ["1", "2"])
    }

    /// pierre colors a whole file at once, on the page's main thread: past
    /// a size, the diff is plain text, and says so.
    @MainActor
    func testLargeFileIsPlainTextAndSaysSo() throws {
        let lines = (0..<2000).map { ("added", "export const value\($0) = compute(\($0));") }
        let rendered = try renderReview(path: "Large.ts", highlighted: false, hunks: [(oldStart: 0, newStart: 1, lines: lines)])
        XCTAssertEqual(rendered.uncolored, "large")
        XCTAssertEqual(rendered.lines.first, "export const value0 = compute(0);")
    }

    /// A page that reloads creates a new review on the same root: the old
    /// one's diffs go, and it renders nothing more.
    @MainActor
    func testNewReviewOnTheSameRootReplacesTheOldOne() throws {
        let page = try BundlePage()
        defer { page.close() }
        let result = try page.run("""
            const root = document.getElementById("root");
            const file = { path: "A.swift", hunks: [{ oldStart: 1, newStart: 1, section: "", lines: [{ kind: "added", text: "let a = 1" }] }] };
            const old = window.NiruxPierreDiff.createReview(document);
            old.renderFile(root, file);
            window.NiruxPierreDiff.createReview(document).renderFile(root, file);
            let oldRenders = true;
            try { old.renderFile(root, file); } catch { oldRenders = false; }
            return JSON.stringify({ hosts: root.querySelectorAll("diffs-container").length, oldRenders });
            """)
        XCTAssertEqual(result, #"{"hosts":1,"oldRenders":false}"#)
    }

    /// A bidi control reorders what follows it ("Trojan Source"), an
    /// invisible character changes a name unseen: the line shows them.
    @MainActor
    func testBidiAndInvisibleCharactersShowTheirCodePoint() throws {
        let rendered = try renderReview(path: "A.swift", hunks: [(oldStart: 1, newStart: 1, lines: [
            ("added", "let isAdmin = false /*\u{202E} } \u{2066}if (isAdmin)\u{2069} \u{2066} begin admins only */"),
            ("added", "let user\u{200B}Name = \"\u{FEFF}\u{E0041}\u{3164}\""),
            ("added", "eval(decode(\"\u{E0158}\u{E0159}\u{FE01}\"))"),
            // Two selectors are enough to encode a payload; after an emoji,
            // one picks its look.
            ("added", "eval(decode(\"\u{FE0E}\u{FE0F}\u{FE0E}\")) // x\u{FE0F}"),
            ("added", "let heart = \"❤\u{FE0F}\", one = \"1\u{FE0F}\u{20E3}\"")
        ])])
        XCTAssertEqual(rendered.lines, [
            "let isAdmin = false /*⟨U+202E⟩ } ⟨U+2066⟩if (isAdmin)⟨U+2069⟩ ⟨U+2066⟩ begin admins only */",
            "let user⟨U+200B⟩Name = \"⟨U+FEFF⟩⟨U+E0041⟩⟨U+3164⟩\"",
            "eval(decode(\"⟨U+E0158⟩⟨U+E0159⟩⟨U+FE01⟩\"))",
            "eval(decode(\"⟨U+FE0E⟩⟨U+FE0F⟩⟨U+FE0E⟩\")) // x⟨U+FE0F⟩",
            "let heart = \"❤\u{FE0F}\", one = \"1\u{FE0F}\u{20E3}\""
        ])
    }

    /// pierre's own lookup of the extension finds `Object.prototype`'s
    /// members (a function for `.constructor`): the file never rendered.
    @MainActor
    func testPathNamedLikeAnObjectMemberStillRenders() throws {
        for path in ["lib/init.constructor", "toString", "lib/x.__proto__"] {
            let rendered = try renderReview(
                path: path, highlighted: false, hunks: [(oldStart: 1, newStart: 1, lines: [("added", "module.exports = 1")])]
            )
            XCTAssertEqual(rendered.lines, ["module.exports = 1"], path)
        }
    }

    /// git marks an unchanged last line without a newline on both sides;
    /// unified view drew the marker twice in one row, and lines overlapped.
    @MainActor
    func testUnchangedLastLineWithoutNewlineShowsOneMarker() throws {
        let rendered = try renderReview(path: "A.swift", hunks: [(oldStart: 1, newStart: 1, lines: [
            ("removed", "let a = 1"), ("added", "let a = 2"), ("context", "}"), ("noNewlineMarker", "")
        ])])
        XCTAssertEqual(rendered.lines, ["let a = 1", "let a = 2", "}"])
        XCTAssertEqual(rendered.noNewlineMarkers, 1)
    }

    /// Off screen, a file is a placeholder; it must take the height the
    /// file renders at, or the page jumps as the user scrolls. The window
    /// is never shown, so animation frames don't fire: timers stand in.
    @MainActor
    func testFilesOffScreenKeepTheirHeightWhenTheyRender() throws {
        let page = try BundlePage()
        defer { page.close() }
        let result = try page.run("""
            window.requestAnimationFrame = (callback) => setTimeout(() => callback(performance.now()), 0);
            const root = document.getElementById("root");
            // A line height in fractions of a point, which the review
            // rounds to whole points: WebKits lay fractions out apart.
            const review = window.NiruxPierreDiff.createReview(document, { lineHeight: 18.3 });
            const containers = [];
            for (let index = 0; index < 30; index++) {
              const container = document.createElement("div");
              root.append(container);
              containers.push(container);
              const lines = Array.from({ length: 60 }, (_, line) => ({
                kind: line % 9 === 0 ? "added" : line % 13 === 0 ? "removed" : "context", text: `let v${line} = ${index}`
              }));
              review.renderFile(container, { path: `F${index}.swift`, hunks: [
                { oldStart: 5, newStart: 5, section: "", lines },
                { oldStart: 200, newStart: 210, section: "", lines: lines.slice(0, 8).concat([{ kind: "noNewlineMarker", text: "" }]) }
              ] });
            }
            const rendered = (container) => container.querySelector("diffs-container").shadowRoot?.querySelectorAll("[data-line]").length > 0;
            const heights = () => containers.map((container) => container.getBoundingClientRect().height);
            const until = async (condition) => {
              const deadline = Date.now() + 10000;
              while (!condition() && Date.now() < deadline) await new Promise((resolve) => setTimeout(resolve, 20));
            };
            // Files far down turn into placeholders, once the page sees
            // where they are.
            await until(() => rendered(containers[0]) && !rendered(containers.at(-1)));
            const before = heights();
            const placeholders = containers.filter((container) => !rendered(container)).length;
            window.scrollTo(0, document.documentElement.scrollHeight);
            await until(() => rendered(containers.at(-1)));
            return JSON.stringify({ before, after: heights(), placeholders, lastRendered: rendered(containers.at(-1)) });
            """)
        let rendered = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(result.utf8)) as? [String: Any])
        let before = try XCTUnwrap(rendered["before"] as? [Double])
        XCTAssertGreaterThan(rendered["placeholders"] as? Int ?? 0, 10, "files far down render as placeholders")
        XCTAssertEqual(rendered["lastRendered"] as? Bool, true, "scrolling renders the last file")
        XCTAssertEqual(rendered["after"] as? [Double], before)
        XCTAssertEqual(Set(before).count, 1, "\(before)")
    }

    private struct ReviewRender {
        let lines: [String]
        let lineNumbers: [String]
        let noNewlineMarkers: Int
        /// The host's `data-uncolored`.
        let uncolored: String?
        /// The highlighter colored its tokens.
        let colored: Bool
        /// Elements whose tag a crafted string names.
        let elements: Int
        let pwned: String?
    }

    @MainActor
    private func renderReview(
        path: String, highlighted: Bool = true, hunks: [(oldStart: Int, newStart: Int, lines: [(String, String)])]
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
            // Highlighted, unless plain text: the tokens came back from the
            // highlighter. After 10 s, what rendered.
            const deadline = Date.now() + 10000;
            const done = () => lines().length > 0 && (\(highlighted) ? !!shadow().querySelector("[data-line] span[style]") : true);
            while (!done() && Date.now() < deadline) await new Promise((resolve) => setTimeout(resolve, 20));
            return JSON.stringify({
              lines: lines().map((line) => line.textContent),
              lineNumbers: [...shadow().querySelectorAll("[data-column-number]")].map((cell) => cell.textContent),
              noNewlineMarkers: shadow().querySelectorAll("[data-no-newline]").length,
              uncolored: root.querySelector("diffs-container").dataset.uncolored ?? null,
              colored: !!shadow().querySelector("[data-line] span[style]"),
              elements: shadow().querySelectorAll("b, img, script").length + document.querySelectorAll("b, img, script").length,
              pwned: window.pwned ?? null
            });
            """)
        let rendered = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(result.utf8)) as? [String: Any])
        return ReviewRender(
            lines: rendered["lines"] as? [String] ?? [],
            lineNumbers: rendered["lineNumbers"] as? [String] ?? [],
            noNewlineMarkers: rendered["noNewlineMarkers"] as? Int ?? -1,
            uncolored: rendered["uncolored"] as? String,
            colored: rendered["colored"] as? Bool ?? false,
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
        // The handler is @Sendable in recent SDKs: it fills a box rather
        // than a captured variable.
        let outcome = Outcome()
        webView.callAsyncJavaScript(body, arguments: [:], in: nil, in: .page) { outcome.result = $0 }
        let deadline = Date().addingTimeInterval(timeout)
        while outcome.result == nil {
            guard Date() < deadline else { throw PageError("the script didn't finish in \(Int(timeout)) s") }
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        guard let value = try outcome.result?.get() as? String else { throw PageError("the script returned no string") }
        return value
    }

    /// Set on the main thread, where WebKit calls back.
    private final class Outcome: @unchecked Sendable {
        var result: Result<Any, Error>?
    }

    func close() {
        window.close()
    }

    struct PageError: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }
}
