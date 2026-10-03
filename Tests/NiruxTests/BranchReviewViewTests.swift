import AppKit
import WebKit
import XCTest
@testable import Nirux

/// The Branch Review column with its real page (`review.html`, its CSP and
/// its bridge) in a window that is never shown, fed a crafted branch by a
/// fake reader that answers on a background queue, as git does
/// (docs/branch-review.md, sections 1.1 and 9.1).
final class BranchReviewViewTests: XCTestCase {
    /// The text a fork controls, written to run if the page ever made
    /// markup of it.
    static let craftedPath = "Sources/\u{1B}[31m<img src=x onerror=\"window.pwned='path'\">evil\u{202E}tfiws.exe"

    @MainActor
    func testBranchTextIsShownAsTextAndNothingInItRuns() throws {
        let page = try ReviewPage(snapshot: Self.craftedSnapshot(), handover: .init(
            name: ".claude-handover.md", text: "<iframe src=\"https://x.test\"></iframe> **notes**", isCut: false
        ))
        defer { page.close() }
        let result = try page.run("""
            return JSON.stringify({
              injected: document.querySelectorAll("img, script:not([src]), iframe").length,
              pwned: window.pwned ?? null,
              title: document.querySelector(".block-title")?.textContent,
              body: document.querySelector(".block .markdown p")?.textContent,
              handover: [...document.querySelectorAll(".block .markdown p")].map((p) => p.textContent),
              path: document.querySelector(".file .path")?.textContent,
              subjects: [...document.querySelectorAll(".commits li")].map((li) => li.textContent)
            });
            """)
        let rendered = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(result.utf8)) as? [String: Any])
        XCTAssertEqual(rendered["injected"] as? Int, 0)
        XCTAssertTrue(rendered["pwned"] is NSNull)
        XCTAssertEqual(rendered["title"] as? String, "<script>window.pwned='title'</script>")
        XCTAssertEqual(rendered["body"] as? String, #"Body <img src=x onerror="window.pwned='body'">"#)
        XCTAssertEqual(rendered["handover"] as? [String], [
            #"Body <img src=x onerror="window.pwned='body'">"#, #"<iframe src="https://x.test"></iframe> notes"#
        ])
        // The bidi control shows as its code point: it can't flip the
        // extension around.
        XCTAssertEqual(rendered["path"] as? String, "Sources/\u{1B}[31m<img src=x onerror=\"window.pwned='path'\">evil⟨U+202E⟩tfiws.exe")
        XCTAssertEqual(rendered["subjects"] as? [String], ["aaaaaaa<b>bold</b>"])
    }

    /// `script-src 'self'`: markup that reached the page still couldn't run
    /// a script of its own, while the bundled scripts load.
    @MainActor
    func testThePolicyBlocksInlineScriptsAndLoadsTheBundle() throws {
        let page = try ReviewPage(snapshot: Self.craftedSnapshot(), handover: nil)
        defer { page.close() }
        let result = try page.run("""
            const inline = document.createElement("script");
            inline.textContent = "window.inlineRan = true";
            document.body.append(inline);
            const frame = document.createElement("iframe");
            frame.src = "https://example.com";
            document.body.append(frame);
            await new Promise((resolve) => setTimeout(resolve, 200));
            return JSON.stringify({ inline: window.inlineRan ?? false, bundle: typeof window.NiruxPierreDiff });
            """)
        XCTAssertEqual(result, #"{"inline":false,"bundle":"object"}"#)
    }

    @MainActor
    func testRiskChipDimsTheFilesThatDontRaiseIt() throws {
        let page = try ReviewPage(snapshot: BranchReviewPageTests.snapshot(), handover: nil)
        defer { page.close() }
        let result = try page.run("""
            const dimmed = () => [...document.querySelectorAll(".file.dim")].map((row) => Number(row.dataset.id)).sort();
            const lockfile = () => document.querySelector('.file[data-id="1"]');
            const before = lockfile() !== null && !lockfile().closest(".group-body").hidden;
            const chip = document.querySelector('button.chip[data-risk="dependencies"]');
            chip.click();
            const filtered = dimmed();
            const pressed = chip.getAttribute("aria-pressed");
            const opened = !lockfile().closest(".group-body").hidden;
            chip.click();
            return JSON.stringify({ before, filtered, pressed, opened, after: dimmed(), security: document.querySelector('button.chip[data-risk="security"]').disabled });
            """)
        // The lockfile's folded group opens to show it.
        XCTAssertEqual(result, #"{"before":false,"filtered":[0,2],"pressed":"true","opened":true,"after":[],"security":true}"#)
    }

    /// A row asks Swift for its diff: from the snapshot, or read then for a
    /// file the snapshot left out, off the main thread.
    @MainActor
    func testOpeningARowShowsItsDiff() throws {
        var lockfile = BranchReviewPageTests.snapshot().files[1]
        lockfile.omission = nil
        lockfile.hunks = [.init(oldStart: 3, oldCount: 1, newStart: 3, newCount: 1, section: "", lines: [
            .init(kind: .removed, text: "\"version\": \"1.0\""), .init(kind: .added, text: "\"version\": \"2.0\"")
        ])]
        let read = lockfile
        let page = try ReviewPage(snapshot: BranchReviewPageTests.snapshot(), handover: nil, patchReader: { file, _ in
            XCTAssertFalse(Thread.isMainThread)
            return file.path == read.path ? read : nil
        })
        defer { page.close() }
        let result = try page.run("""
            const open = async (id) => {
              document.querySelector(`.file[data-id="${id}"] .file-row`).click();
              const deadline = Date.now() + 10000;
              const lines = () => [...(document.querySelector(`.file[data-id="${id}"] diffs-container`)?.shadowRoot?.querySelectorAll("[data-line]") ?? [])];
              while (lines().length === 0 && Date.now() < deadline) await new Promise((resolve) => setTimeout(resolve, 20));
              return lines().map((line) => line.textContent);
            };
            // The lockfile is folded: its group opens first.
            document.querySelector(".group.folded .group-header").click();
            return JSON.stringify({ swift: await open(0), lockfile: await open(1) });
            """)
        XCTAssertEqual(result, #"{"swift":["import IOKit","let a = 1","let a = 2"],"lockfile":["\"version\": \"1.0\"","\"version\": \"2.0\""]}"#)
    }

    /// A link in the pull request opens in the browser, through Swift; a
    /// link to anything but the web opens nothing.
    @MainActor
    func testLinksOpenInTheBrowserOnlyForTheWeb() throws {
        var opened: [URL] = []
        let snapshot = BranchReviewPageTests.snapshot(pullRequest: .found(BranchReview.PullRequest(
            number: 9, title: "Links", body: "[docs](https://example.com/docs) [bad](javascript:alert(1))",
            url: "https://github.com/o/r/pull/9", baseRefName: "main", headRefOid: "", isDraft: true
        )))
        let page = try ReviewPage(snapshot: snapshot, handover: nil, openLink: { opened.append($0) })
        defer { page.close() }
        _ = try page.run("""
            for (const anchor of document.querySelectorAll(".markdown a, a.chip")) anchor.click();
            return String(document.querySelectorAll(".markdown .dead-link").length);
            """)
        page.waitUntil("the links") { opened.count == 2 }
        // The header's pull request chip, then the body's link.
        XCTAssertEqual(opened.map(\.absoluteString), ["https://github.com/o/r/pull/9", "https://example.com/docs"])
    }

    /// Its keyboard is a web view's: Cmd-chords go to the menu first, as
    /// for a browser column. Checked on the predicate the key monitor uses:
    /// in a window that isn't key, AppKit gives a returned key to the menu
    /// anyway, so a flow test couldn't tell.
    @MainActor
    func testCommandKeysGoToTheMenuBeforeThePage() {
        let review = ColumnState(branchReview: BranchReviewController(worktree: "/repo", branch: nil, reader: BranchReviewPageTests.reader))
        XCTAssertTrue(NiruxApp.takesWebContentKeys(review))
        XCTAssertFalse(NiruxApp.takesWebContentKeys(ColumnState(cwd: NSTemporaryDirectory())))
    }

    /// A group shows its first rows, and a button for the next: a branch
    /// can list thousands of untracked files.
    @MainActor
    func testALargeGroupShowsItsRowsInSteps() throws {
        let base = BranchReviewPageTests.snapshot()
        let files = (0..<650).map { index -> BranchReview.FileChange in
            var file = BranchReview.FileChange(path: String(format: "Sources/F%04d.swift", index), status: .modified)
            file.additions = 1
            file.patchHash = "h\(index)"
            return file
        }
        let page = try ReviewPage(snapshot: BranchReviewControllerTests.snapshot(base, files: files), handover: nil)
        defer { page.close() }
        let result = try page.run("""
            const rows = () => document.querySelectorAll(".file").length;
            const more = document.querySelector(".rows-more");
            const first = [rows(), more.textContent];
            more.click();
            const second = [rows(), more.textContent];
            more.click();
            return JSON.stringify({ first, second, last: [rows(), more.hidden] });
            """)
        XCTAssertEqual(result, #"{"first":[300,"Show 300 more files"],"second":[600,"Show 50 more files"],"last":[650,true]}"#)
    }

    /// The page keeps its own copy of the visual system's colors (the
    /// theme guard reads Swift only): it must not drift from Theme.
    func testPageColorsAreTheThemeTokens() throws {
        let css = try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/Nirux/EditorAssets/review.css"), encoding: .utf8)
        let tokens: [(String, NSColor)] = [
            ("canvas", Theme.Color.canvas), ("base", Theme.Color.base), ("surface", Theme.Color.surface),
            ("raised", Theme.Color.raised), ("text-primary", Theme.Color.textPrimary),
            ("text-secondary", Theme.Color.textSecondary), ("text-tertiary", Theme.Color.textTertiary),
            ("text-disabled", Theme.Color.textDisabled), ("accent", Theme.Color.accent),
            ("added", Theme.Color.working), ("removed", Theme.Color.error)
        ]
        for (name, color) in tokens {
            let srgb = try XCTUnwrap(color.usingColorSpace(.sRGB))
            let hex = String(
                format: "#%02x%02x%02x", Int((srgb.redComponent * 255).rounded()),
                Int((srgb.greenComponent * 255).rounded()), Int((srgb.blueComponent * 255).rounded())
            )
            XCTAssertTrue(css.contains("--\(name): \(hex);"), "--\(name) isn't \(hex)")
        }
        XCTAssertFalse(css.lowercased().contains("f5a623"), "amber means an agent waits for the user")
    }

    func testOnlyTheBundledPageLoadsAndOnlyWebLinksOpen() {
        let page = URL(fileURLWithPath: "/app/EditorAssets/review.html")
        XCTAssertTrue(BranchReviewView.isPage(URL(fileURLWithPath: "/app/EditorAssets/review.html"), page))
        XCTAssertTrue(BranchReviewView.isPage(URL(string: "file:///app/EditorAssets/review.html#top"), page))
        XCTAssertFalse(BranchReviewView.isPage(URL(fileURLWithPath: "/app/EditorAssets/index.html"), page))
        XCTAssertFalse(BranchReviewView.isPage(URL(string: "https://app/EditorAssets/review.html"), page))
        XCTAssertFalse(BranchReviewView.isPage(nil, page))
        XCTAssertEqual(BranchReviewView.webLink("https://github.com/o/r")?.host, "github.com")
        XCTAssertNotNil(BranchReviewView.webLink("http://x.test/a?b#c"))
        for refused in ["javascript:alert(1)", "file:///etc/passwd", "nirux://open", "https://", "data:text/html,x"] {
            XCTAssertNil(BranchReviewView.webLink(refused), refused)
        }
    }

    // MARK: - Fixtures

    static func craftedSnapshot() -> BranchReview.Snapshot {
        let base = BranchReviewPageTests.snapshot(pullRequest: .found(BranchReview.PullRequest(
            number: 7, title: "<script>window.pwned='title'</script>",
            body: #"Body <img src=x onerror="window.pwned='body'">"#,
            url: "https://github.com/o/r/pull/7", baseRefName: "main", headRefOid: "", isDraft: false
        )))
        var file = base.files[0]
        file.path = craftedPath
        return BranchReview.Snapshot(
            root: base.root, branch: base.branch, head: base.head, base: base.base, pullRequest: base.pullRequest,
            fetchProblem: nil, upstream: nil, pullRequestHead: nil, hasUncommittedChanges: false,
            commits: [.init(oid: String(repeating: "a", count: 40), parents: [], subject: "<b>bold</b>", body: "", isMergeFromBase: false)],
            files: [file], testsAgainstCode: base.testsAgainstCode
        )
    }
}
