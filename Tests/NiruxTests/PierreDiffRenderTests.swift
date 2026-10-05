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

    // MARK: Annotations, the gutter button and selected lines

    /// Each annotation shows the page's element under its line: a removed
    /// line's by its number in the base, an added line's by its number in
    /// the working tree, an unchanged line's by either, in the list's order.
    /// Nothing of the annotation is markup, and an element that fails
    /// leaves the diff as it was.
    @MainActor
    func testAnnotationsShowThePageElementsUnderTheirLines() throws {
        let page = try BundlePage()
        defer { page.close() }
        let result = try page.run(Self.harness + """
            const calls = [];
            const review = window.NiruxPierreDiff.createReview(document, {
              renderAnnotation(annotation, container) {
                const call = `${annotation.side} ${annotation.lineNumber} ${annotation.key} ${container === root}`;
                if (!calls.includes(call)) calls.push(call);
                if (annotation.key === "throws") throw new Error("a card that fails");
                const card = document.createElement("div");
                card.textContent = annotation.key;
                return card;
              }
            });
            review.renderFile(root, { path: "A.swift", hunks, annotations: [
              { side: "additions", lineNumber: 21, key: "on added" },
              { side: "deletions", lineNumber: 11, key: "on removed" },
              { side: "additions", lineNumber: 22, key: '<img src=x onerror="window.pwned = 1">' },
              { side: "additions", lineNumber: 22, key: "throws" },
              { side: "additions", lineNumber: 20, key: "first" },
              { side: "deletions", lineNumber: 10, key: "second, by its base number" },
              // Left out: malformed, off the diff's lines, a second time.
              { side: "toString", lineNumber: 20, key: "side" }, { side: "additions", lineNumber: "20", key: "number" },
              { side: "additions", lineNumber: 20, key: 5 }, null,
              { side: "additions", lineNumber: 500, key: "not a line of the diff" },
              { side: "deletions", lineNumber: 21, key: "not a line of the base" },
              { side: "additions", lineNumber: 21, key: "on added" }
            ] });
            await until(() => rows().filter((row) => row.startsWith("↳")).length === 4);
            return JSON.stringify({
              rows: rows(), calls,
              elements: document.querySelectorAll("img").length + shadow().querySelectorAll("img").length,
              pwned: window.pwned ?? null
            });
            """)
        let rendered = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(result.utf8)) as? [String: Any], result)
        XCTAssertEqual(rendered["rows"] as? [String], [
            "func a() {", "↳ first | second, by its base number",
            "  old()", "↳ on removed",
            "  new()", "↳ on added",
            "}", #"↳ <img src=x onerror="window.pwned = 1">"#
        ])
        XCTAssertEqual(rendered["calls"] as? [String], [
            "additions 21 on added true", "deletions 11 on removed true",
            #"additions 22 <img src=x onerror="window.pwned = 1"> true"#, "additions 22 throws true",
            "additions 20 first true", "additions 20 second, by its base number true"
        ])
        XCTAssertEqual(rendered["elements"] as? Int, 0)
        XCTAssertTrue(rendered["pwned"] is NSNull, "\(rendered["pwned"] ?? "")")
    }

    /// `setAnnotations` renders the file again at once, in the same
    /// element: the page finds its new element in place on return, and one
    /// that stays keeps its element and its focus, whatever is added or
    /// removed before it. The file takes the height of what it shows. The
    /// same annotations again render nothing. The page's `onRendered`
    /// throwing stops none of it.
    @MainActor
    func testSetAnnotationsUpdatesTheFileInPlace() throws {
        let page = try BundlePage()
        defer { page.close() }
        let result = try page.run(Self.harness + """
            const made = new Map();
            const calls = [];
            const review = window.NiruxPierreDiff.createReview(document, {
              // Thrown after each render: logged, it stops nothing.
              onRendered() { throw new Error("a page that fails"); },
              renderAnnotation(annotation) {
                calls.push(annotation.key);
                const card = document.createElement("div");
                card.style.height = "60px";
                card.append(annotation.key, document.createElement("input"));
                made.set(annotation.key, card);
                return card;
              }
            });
            const shown = (key) => made.get(key)?.parentElement?.assignedSlot != null;
            const a = { side: "additions", lineNumber: 21, key: "a" };
            const x = { side: "deletions", lineNumber: 11, key: "x" };
            review.renderFile(root, { path: "A.swift", hunks, annotations: [a] });
            await until(() => shown("a"));
            const host = root.querySelector("diffs-container");
            made.get("a").querySelector("input").focus();
            const focused = () => document.activeElement === made.get("a").querySelector("input");
            const height = () => root.getBoundingClientRect().height;
            const first = height();
            const firstRow = shadow().querySelector("[data-line]");
            review.setAnnotations(root, [{ ...a }]);
            const again = firstRow.isConnected;
            // Before it in the list.
            review.setAnnotations(root, [x, a]);
            const added = {
              shown: shown("x"), grew: height() - first, sameHost: root.querySelector("diffs-container") === host,
              focused: focused(), calls: [...calls], rows: rows()
            };
            review.setAnnotations(root, [a]);
            const removed = { xConnected: made.get("x").isConnected, focused: focused(), grew: height() - first, calls: [...calls] };
            review.setAnnotations(root, []);
            const none = { aConnected: made.get("a").isConnected, grew: height() - first, rows: rows() };
            // On one line: a new one before, then the order turned.
            const b = { side: "additions", lineNumber: 21, key: "b" };
            review.setAnnotations(root, [a]);
            made.get("a").querySelector("input").focus();
            review.setAnnotations(root, [b, a]);
            const line = [rows()[3]];
            const kept = focused();
            review.setAnnotations(root, [a, b]);
            line.push(rows()[3]);
            return JSON.stringify({ added, removed, none, line: { rows: line, focused: kept }, again: { kept: again } });
            """)
        let rendered = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(result.utf8)) as? [String: [String: Any]], result)
        let added = try XCTUnwrap(rendered["added"])
        XCTAssertEqual(added["shown"] as? Bool, true, "the new element is in place on return")
        XCTAssertEqual(added["grew"] as? Double, 60)
        XCTAssertEqual(added["sameHost"] as? Bool, true)
        XCTAssertEqual(added["focused"] as? Bool, true, "the element that stays keeps its focus")
        XCTAssertEqual(added["calls"] as? [String], ["a", "x"], "the element that stays isn't asked for again")
        XCTAssertEqual(added["rows"] as? [String], ["func a() {", "  old()", "↳ x", "  new()", "↳ a", "}"])
        let removed = try XCTUnwrap(rendered["removed"])
        XCTAssertEqual(removed["xConnected"] as? Bool, false)
        XCTAssertEqual(removed["focused"] as? Bool, true)
        XCTAssertEqual(removed["grew"] as? Double, 0)
        XCTAssertEqual(removed["calls"] as? [String], ["a", "x"])
        let none = try XCTUnwrap(rendered["none"])
        XCTAssertEqual(none["aConnected"] as? Bool, false)
        XCTAssertEqual(none["grew"] as? Double, -60)
        XCTAssertEqual(none["rows"] as? [String], ["func a() {", "  old()", "  new()", "}"])
        XCTAssertEqual(rendered["line"]?["rows"] as? [String], ["↳ b | a", "↳ a | b"])
        XCTAssertEqual(rendered["line"]?["focused"] as? Bool, true, "one added before it on its line doesn't move it")
        XCTAssertEqual(rendered["again"]?["kept"] as? Bool, true, "the same annotations again render nothing")
    }

    /// pierre draws only the lines near the viewport, and keeps the height
    /// it measured of each. A file's offset reads the same right after a
    /// jump as once its scroll event came (pierre added the scroll position
    /// it read last: a frame between the two drew none of the file's lines
    /// until the next scroll); a jump far down the file draws the lines
    /// there; a line away from the drawn ones whose annotation goes gives
    /// its height back, and the file is as long as it was without.
    @MainActor
    func testFarLinesDrawAndGiveTheirHeightBackAfterAnnotationsChange() throws {
        let page = try BundlePage()
        defer { page.close() }
        let result = try page.run(Self.harness + """
            const review = window.NiruxPierreDiff.createReview(document, {
              renderAnnotation(annotation) {
                const card = document.createElement("div");
                card.style.height = "60px";
                card.textContent = annotation.key;
                return card;
              }
            });
            const lines = Array.from({ length: 400 }, (_, line) => ({ kind: "context", text: `let v${line} = 0` }));
            lines[0] = { kind: "added", text: "let first = true" };
            review.renderFile(root, { path: "Long.swift", hunks: [{ oldStart: 1, newStart: 1, section: "", lines }] });
            const drawn = (text) => [...(shadow()?.querySelectorAll("[data-line]") ?? [])].some((row) => row.textContent === text);
            const slotted = () => [...(shadow()?.querySelectorAll("slot") ?? [])].flatMap((slot) => slot.assignedElements()).length;
            const settle = async (condition) => {
              const deadline = Date.now() + 4000;
              while (!condition() && Date.now() < deadline) await new Promise((resolve) => setTimeout(resolve, 20));
              return condition();
            };
            await until(() => drawn("let first = true"));
            const height = () => root.getBoundingClientRect().height;
            const plain = height();
            const farAway = !drawn("let v350 = 0");
            review.setAnnotations(root, [{ side: "additions", lineNumber: 351, key: "far" }]);
            // pierre's own global: the review's virtualizer. Its scroll
            // position read, then a jump whose event hasn't come yet.
            const virtualizer = window.__INSTANCE;
            const host = root.querySelector("diffs-container");
            virtualizer.getScrollTop();
            window.scrollTo(0, root.getBoundingClientRect().top + window.scrollY + plain * 350 / 400 - 200);
            const offset = { read: virtualizer.getOffsetInScrollContainer(host), live: host.getBoundingClientRect().top + window.scrollY };
            const jumped = await settle(() => drawn("let v350 = 0") && slotted() === 1);
            const measured = height() - plain;
            window.scrollTo(0, 0);
            const back = await settle(() => drawn("let first = true") && !drawn("let v350 = 0"));
            review.setAnnotations(root, []);
            return JSON.stringify({ farAway, offset, jumped, measured, back, after: height() - plain });
            """)
        let rendered = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(result.utf8)) as? [String: Any], result)
        XCTAssertEqual(rendered["farAway"] as? Bool, true, "line 351 isn't drawn at first: \(result)")
        let offset = try XCTUnwrap(rendered["offset"] as? [String: Double], result)
        XCTAssertEqual(offset["read"], offset["live"], "the file's offset right after the jump: \(result)")
        XCTAssertEqual(rendered["jumped"] as? Bool, true, "the jump draws line 351 and its annotation: \(result)")
        XCTAssertEqual(rendered["measured"] as? Double, 60, result)
        XCTAssertEqual(rendered["back"] as? Bool, true, result)
        XCTAssertEqual(rendered["after"] as? Double, 0, "the far line gives its height back: \(result)")
    }

    /// Off screen, a file is a placeholder, and pierre drops what it is
    /// given to render: the annotations of a file far down, given when it
    /// renders again or set while it waits, show once it is scrolled to. A
    /// file whose annotations were set or removed on screen keeps, as a
    /// placeholder, the height it showed: the page doesn't jump.
    @MainActor
    func testAnnotationsHoldWhileTheirFileIsOffScreen() throws {
        let page = try BundlePage()
        defer { page.close() }
        let result = try page.run(Self.harness + """
            const review = window.NiruxPierreDiff.createReview(document, {
              renderAnnotation(annotation) {
                const card = document.createElement("div");
                card.style.height = "60px";
                card.textContent = annotation.key;
                return card;
              }
            });
            const containers = [];
            const fileLines = (index) => {
              // Short files first, so that the first two show at once. The
              // added line, 5, comes after a removed one: its row is the
              // sixth of the unified view, the fifth of a split one.
              const lines = Array.from({ length: index < 2 ? 10 : 60 }, (_, line) => ({ kind: "context", text: `let v${line} = ${index}` }));
              lines[4] = { kind: "removed", text: "let removed = true" };
              lines[5] = { kind: "added", text: "let added = true" };
              return [{ oldStart: 1, newStart: 1, section: "", lines }];
            };
            for (let index = 0; index < 30; index++) {
              const container = document.createElement("div");
              root.append(container);
              containers.push(container);
              review.renderFile(container, { path: `F${index}.swift`, hunks: fileLines(index) });
            }
            const rendered = (container) => container.querySelector("diffs-container").shadowRoot?.querySelectorAll("[data-line]").length > 0;
            const height = (container) => container.getBoundingClientRect().height;
            await until(() => rendered(containers[0]) && rendered(containers[1]) && !rendered(containers.at(-1)));
            const card = [{ side: "additions", lineNumber: 5, key: "card" }];
            const plain = [height(containers[0]), height(containers[1])];
            review.setAnnotations(containers[0], card);
            review.setAnnotations(containers[1], card);
            review.setAnnotations(containers[1], []);
            const shown = [height(containers[0]), height(containers[1])];
            // Rendered again while off screen, as when its diff reloads.
            review.renderFile(containers.at(-1), { path: "F29.swift", hunks: fileLines(29), annotations: [{ side: "additions", lineNumber: 5, key: "given" }] });
            review.setAnnotations(containers.at(-2), [{ side: "additions", lineNumber: 5, key: "set" }]);
            const offScreen = !rendered(containers.at(-2)) && !rendered(containers.at(-1));
            window.scrollTo(0, document.documentElement.scrollHeight);
            const slotted = (container) => [...(container.querySelector("diffs-container").shadowRoot?.querySelectorAll("slot") ?? [])]
              .flatMap((slot) => slot.assignedElements()).map((wrapper) => wrapper.textContent);
            // Each step on its own, so that a WebKit that differs says where.
            const settle = async (condition) => {
              const deadline = Date.now() + 6000;
              while (!condition() && Date.now() < deadline) await new Promise((resolve) => setTimeout(resolve, 20));
              return condition();
            };
            // pierre draws only the lines near the viewport, within a file
            // too: each file far down is brought to its top in turn.
            const firstAway = await settle(() => !rendered(containers[0]) && !rendered(containers[1]));
            containers.at(-2).scrollIntoView();
            const beforeLastShown = await settle(() => slotted(containers.at(-2)).length > 0);
            containers.at(-1).scrollIntoView();
            const lastShown = await settle(() => slotted(containers.at(-1)).length > 0);
            const shownDown = beforeLastShown && lastShown;
            return JSON.stringify({
              grew: shown.map((value, index) => value - plain[index]), offScreen, shownDown, firstAway,
              placeholders: [height(containers[0]) - shown[0], height(containers[1]) - shown[1]],
              last: slotted(containers.at(-1)), beforeLast: slotted(containers.at(-2)),
              scrolled: Math.round(window.scrollY), height: document.documentElement.scrollHeight
            });
            """)
        let rendered = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(result.utf8)) as? [String: Any], result)
        XCTAssertEqual(rendered["grew"] as? [Int], [60, 0], result)
        XCTAssertEqual(rendered["offScreen"] as? Bool, true, result)
        XCTAssertEqual(rendered["shownDown"] as? Bool, true, result)
        XCTAssertEqual(rendered["last"] as? [String], ["given"], result)
        XCTAssertEqual(rendered["beforeLast"] as? [String], ["set"], result)
        XCTAssertEqual(rendered["firstAway"] as? Bool, true, result)
        XCTAssertEqual(rendered["placeholders"] as? [Int], [0, 0], "a placeholder takes the height its file showed: \(result)")
    }

    /// Lines above the viewport that gain an annotation push nothing the
    /// user reads, even where WebKit doesn't keep it in place itself.
    @MainActor
    func testAnnotationAboveTheViewportLeavesWhatItShowsInPlace() throws {
        let page = try BundlePage()
        defer { page.close() }
        let result = try page.run(Self.harness + """
            document.documentElement.style.overflowAnchor = "none";
            document.body.style.overflowAnchor = "none";
            const review = window.NiruxPierreDiff.createReview(document, {
              renderAnnotation(annotation) {
                const card = document.createElement("div");
                card.style.height = "60px";
                return card;
              }
            });
            const lines = Array.from({ length: 60 }, (_, line) => ({ kind: "context", text: `let v${line} = 0` }));
            lines[5] = { kind: "added", text: "let added = true" };
            const containers = [0, 1, 2].map((index) => {
              const container = document.createElement("div");
              root.append(container);
              review.renderFile(container, { path: `F${index}.swift`, hunks: [{ oldStart: 1, newStart: 1, section: "", lines }] });
              return container;
            });
            const fileLines = (container) => [...(container.querySelector("diffs-container").shadowRoot?.querySelectorAll("[data-line]") ?? [])];
            await until(() => fileLines(containers[0]).length === 60);
            window.scrollTo(0, 600);
            await new Promise((resolve) => setTimeout(resolve, 100));
            // The first line in view; the render makes its row again.
            const first = () => containers.flatMap(fileLines).find((element) => element.getBoundingClientRect().top >= 0);
            const { lineIndex } = first().dataset;
            const top = first().getBoundingClientRect().top;
            review.setAnnotations(containers[0], [{ side: "additions", lineNumber: 6, key: "above" }]);
            const line = fileLines(containers[0]).find((element) => element.dataset.lineIndex === lineIndex);
            return JSON.stringify({ moved: line.getBoundingClientRect().top - top, scrolled: window.scrollY - 600 });
            """)
        XCTAssertEqual(result, #"{"moved":0,"scrolled":60}"#)
    }

    /// The gutter's button, clicked by a line, reports that line, once;
    /// numbers clicked or dragged over report the lines selected, from where
    /// the drag began. The page's own selection reports nothing, even made
    /// from a gutter click, and one off the diff's lines selects none. A
    /// callback that throws doesn't stop the next clicks.
    @MainActor
    func testGutterButtonAndLineNumbersReportTheirLines() throws {
        let page = try BundlePage()
        defer { page.close() }
        let result = try page.run(Self.harness + """
            const events = [];
            let gutterClicks = 0;
            const review = window.NiruxPierreDiff.createReview(document, {
              onGutterClick(range, container) {
                events.push(`gutter ${JSON.stringify(range)} ${container === root}`);
                gutterClicks += 1;
                if (gutterClicks === 1) throw new Error("a page that fails");
                review.setSelection(root, { start: 20, side: "additions", end: 22, endSide: "additions" });
              },
              onSelect(range, container) { events.push(`select ${JSON.stringify(range)} ${container === root}`); }
            });
            review.renderFile(root, { path: "A.swift", hunks });
            await until(() => numbers().length === 4);
            gutterClick(numbers()[2]);
            gutterClick(numbers()[1]);
            const selected = () => shadow().querySelectorAll("[data-line][data-selected-line]").length;
            await until(() => selected() === 4);
            // From the unchanged line above to the one below, and back up.
            drag(numbers()[0], numbers()[3]);
            drag(numbers()[3], numbers()[0]);
            await until(() => events.length === 4);
            const quiet = [];
            review.setSelection(root, { start: 11, side: "deletions", end: 21, endSide: "additions" });
            quiet.push(selected());
            // Ends past the hunk: pierre would count on and select its rows.
            review.setSelection(root, { start: 20, side: "additions", end: 40, endSide: "additions" });
            quiet.push(selected());
            review.setSelection(root, { start: 22, side: "additions", end: 22 });
            quiet.push(selected());
            // Unchanged lines by their numbers in the base; a number as text.
            review.setSelection(root, { start: 10, side: "deletions", end: 12, endSide: "deletions" });
            quiet.push(selected());
            review.setSelection(root, { start: "20", side: "additions", end: 22, endSide: "additions" });
            quiet.push(selected());
            review.setSelection(root, null);
            quiet.push(selected());
            return JSON.stringify({ events, quiet });
            """)
        let rendered = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(result.utf8)) as? [String: Any], result)
        XCTAssertEqual(rendered["events"] as? [String], [
            #"gutter {"start":21,"side":"additions","end":21,"endSide":"additions"} true"#,
            #"gutter {"start":11,"side":"deletions","end":11,"endSide":"deletions"} true"#,
            #"select {"start":20,"side":"additions","end":22,"endSide":"additions"} true"#,
            #"select {"start":22,"side":"additions","end":20,"endSide":"additions"} true"#
        ])
        XCTAssertEqual(rendered["quiet"] as? [Int], [2, 0, 1, 4, 0, 0])
    }

    /// A drag that goes on over another file reports only lines of the file
    /// it began in.
    @MainActor
    func testDragOntoAnotherFileReportsOnlyItsOwnLines() throws {
        let page = try BundlePage()
        defer { page.close() }
        let result = try page.run(Self.harness + """
            const events = [];
            const review = window.NiruxPierreDiff.createReview(document, {
              onGutterClick(range, container) { events.push(`gutter ${container.id} ${range.start}-${range.end}`); },
              onSelect(range, container) { events.push(`select ${container.id} ${range?.start}-${range?.end}`); }
            });
            const other = document.createElement("div");
            other.id = "other";
            document.body.append(other);
            review.renderFile(root, { path: "A.swift", hunks });
            review.renderFile(other, { path: "B.swift", hunks: [{ oldStart: 400, newStart: 700, section: "", lines: [
              { kind: "added", text: "b1()" }, { kind: "added", text: "b2()" }, { kind: "added", text: "b3()" }
            ] }] });
            const otherNumbers = () => [...(other.querySelector("diffs-container").shadowRoot?.querySelectorAll("[data-column-number]") ?? [])];
            await until(() => numbers().length === 4 && otherNumbers().length === 3);
            drag(numbers()[0], otherNumbers()[2]);
            gutterClick(numbers()[2], otherNumbers()[1]);
            return JSON.stringify(events);
            """)
        XCTAssertEqual(result, #"["select root 20-20","gutter root 21-21"]"#)
    }

    /// Without callbacks, as the page was before comments: no gutter
    /// button, and numbers select nothing.
    @MainActor
    func testWithoutCallbacksTheDiffTakesNoClicks() throws {
        let page = try BundlePage()
        defer { page.close() }
        let result = try page.run(Self.harness + """
            window.NiruxPierreDiff.createReview(document).renderFile(root, { path: "A.swift", hunks });
            await until(() => numbers().length === 4);
            pointer(numbers()[2], "pointermove");
            // Right after the hover, where pierre would put it.
            const button = shadow().querySelector("[data-utility-button]") != null;
            pointer(numbers()[2], "pointerdown");
            pointer(numbers()[2], "pointerup");
            await new Promise((resolve) => setTimeout(resolve, 100));
            return JSON.stringify({ button, selected: shadow().querySelectorAll("[data-selected-line]").length });
            """)
        XCTAssertEqual(result, #"{"button":false,"selected":0}"#)
    }

    /// What the annotation tests share: a file of one hunk, numbered apart
    /// in the base and the working tree (an unchanged line, 10 and 20, one
    /// removed, 11, one added, 21, an unchanged one, 12 and 22), its rows,
    /// and pointer events. The window is never shown, so animation frames
    /// don't fire: timers stand in.
    private static let harness = """
        window.requestAnimationFrame = (callback) => setTimeout(() => callback(performance.now()), 0);
        const root = document.getElementById("root");
        const hunks = [{ oldStart: 10, newStart: 20, section: "", lines: [
          { kind: "context", text: "func a() {" }, { kind: "removed", text: "  old()" },
          { kind: "added", text: "  new()" }, { kind: "context", text: "}" }
        ] }];
        const shadow = () => root.querySelector("diffs-container")?.shadowRoot;
        const until = async (condition, timeout = 10000) => {
          const deadline = Date.now() + timeout;
          while (!condition()) {
            if (Date.now() > deadline) throw new Error(`timed out waiting for ${condition}`);
            await new Promise((resolve) => setTimeout(resolve, 20));
          }
        };
        // Each line's text, and under it "↳ " and what is slotted there.
        const rows = () => [...(shadow()?.querySelectorAll("[data-line], [data-line-annotation]") ?? [])].map((row) =>
          row.hasAttribute("data-line") ? row.textContent
            : "↳ " + [...row.querySelectorAll("slot")].flatMap((slot) => slot.assignedElements()).map((wrapper) => wrapper.textContent).join(" | "));
        const numbers = () => [...(shadow()?.querySelectorAll("[data-column-number]") ?? [])];
        const pointer = (target, type) => target.dispatchEvent(new PointerEvent(type, {
          bubbles: true, composed: true, cancelable: true, pointerId: 1, pointerType: "mouse", button: 0, isPrimary: true
        }));
        const drag = (from, to) => {
          pointer(from, "pointerdown");
          pointer(to, "pointermove");
          pointer(to, "pointerup");
        };
        // The button by the number `at`, pressed, and let go over `to`.
        const gutterClick = (at, to = at) => {
          pointer(at, "pointermove");
          const button = at.getRootNode().querySelector("[data-utility-button]");
          pointer(button, "pointerdown");
          if (to !== at) pointer(to, "pointermove");
          pointer(to === at ? button : to, "pointerup");
        };

        """

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
