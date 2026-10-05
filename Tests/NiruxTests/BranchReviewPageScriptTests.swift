import JavaScriptCore
import XCTest

/// The review page's pure functions (`EditorAssets/review-page.js`) under
/// JavaScriptCore, on crafted strings: a pull request body is a branch's
/// text, a fork's included (docs/branch-review.md, sections 1.1 and 9.1).
final class BranchReviewPageScriptTests: XCTestCase {
    private static let script = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Sources/Nirux/EditorAssets/review-page.js")

    private var context: JSContext!

    override func setUpWithError() throws {
        context = try XCTUnwrap(JSContext())
        var exception: String?
        context.exceptionHandler = { _, value in exception = value?.toString() }
        context.evaluateScript(try String(contentsOf: Self.script, encoding: .utf8))
        XCTAssertNil(exception)
    }

    /// `ReviewPage.<function>(arguments)` as JSON.
    private func call(_ function: String, _ arguments: Any...) throws -> String {
        let json = String(decoding: try JSONSerialization.data(withJSONObject: arguments, options: [.fragmentsAllowed]), as: UTF8.self)
        let result = context.evaluateScript("JSON.stringify(ReviewPage.\(function)(...\(json)))")
        return try XCTUnwrap(result?.toString())
    }

    func testMarkdownKeepsRawHTMLAsText() throws {
        XCTAssertEqual(
            try call("parseMarkdown", "Hi <img src=x onerror=\"alert(1)\"> <script>alert(2)</script>"),
            #"[{"type":"paragraph","spans":[{"type":"text","text":"Hi <img src=x onerror=\"alert(1)\"> <script>alert(2)</script>"}]}]"#
        )
    }

    /// Only web links open, in the browser: a `javascript:` or `file:`
    /// link is shown as text.
    func testLinksOpenOnlyOnTheWeb() throws {
        XCTAssertEqual(
            try call("parseInline", "[a](https://github.com/o/r) [b](javascript:alert) [c](file:///etc/passwd) <http://x.test/p>"),
            #"[{"type":"link","text":"a","url":"https://github.com/o/r"},{"type":"text","text":" "},"#
                + #"{"type":"link","text":"b","url":null},{"type":"text","text":" "},"#
                + #"{"type":"link","text":"c","url":null},{"type":"text","text":" "},"#
                + #"{"type":"link","text":"http://x.test/p","url":"http://x.test/p"}]"#
        )
    }

    /// Text a fork controls can't stall the page: every expression stays
    /// linear, every loop moves on, and quotes and lists nest only so deep.
    func testCraftedMarkdownParsesQuickly() throws {
        let crafted = [
            "# a\u{2028}b",
            "# a" + String(repeating: " ", count: 64_000) + "x",
            String(repeating: ">", count: 64_000) + " deep",
            String(repeating: "[", count: 64_000),
            String(repeating: "[](", count: 21_333),
            String(repeating: "<https://", count: 7_111),
            "-" + String(repeating: " ", count: 64_000) + "a\u{2028}b",
            (0..<4_000).map { String(repeating: " ", count: $0) + "- item" }.joined(separator: "\n")
        ]
        for text in crafted {
            let start = Date()
            _ = try call("parseMarkdown", text)
            XCTAssertLessThan(Date().timeIntervalSince(start), 1, String(text.prefix(20)))
        }
        // A line separator ends the heading's line.
        XCTAssertEqual(try call("parseMarkdown", "# a\u{2028}b"), #"[{"type":"heading","level":1,"spans":[{"type":"text","text":"a"}]},"#
            + #"{"type":"paragraph","spans":[{"type":"text","text":"b"}]}]"#)
        let depth = context.evaluateScript("""
            (function depth(blocks) {
              return Math.max(0, ...blocks.map((block) => block.type === "quote" ? 1 + depth(block.blocks) : 0));
            })(ReviewPage.parseMarkdown(">".repeat(30) + " deep"))
            """)?.toInt32()
        XCTAssertEqual(depth, 8)
    }

    /// The closing run of "#" goes only after a space, as in CommonMark.
    func testHeadingKeepsAHashThatEndsAWord() throws {
        XCTAssertEqual(try call("parseMarkdown", "## Port to C#\n## Title ##"),
            #"[{"type":"heading","level":2,"spans":[{"type":"text","text":"Port to C#"}]},"#
                + #"{"type":"heading","level":2,"spans":[{"type":"text","text":"Title"}]}]"#)
    }

    func testMarkdownBlocks() throws {
        let text = "# Title\n\nSome **bold**, *em* and `code`.\n\n- one\n  - nested\n- two\n\n1. first\n\n> quoted\n\n```\nlet a = \"<b>\"\n```\n\n---"
        XCTAssertEqual(try call("parseMarkdown", text), #"["#
            + #"{"type":"heading","level":1,"spans":[{"type":"text","text":"Title"}]},"#
            + #"{"type":"paragraph","spans":[{"type":"text","text":"Some "},{"type":"strong","text":"bold"},"#
            + #"{"type":"text","text":", "},{"type":"em","text":"em"},{"type":"text","text":" and "},"#
            + #"{"type":"code","text":"code"},{"type":"text","text":"."}]},"#
            + #"{"type":"list","ordered":false,"start":1,"items":[{"spans":[{"type":"text","text":"one"}],"checked":null,"lists":["#
            + #"{"type":"list","ordered":false,"start":1,"items":[{"spans":[{"type":"text","text":"nested"}],"checked":null,"lists":[]}]}]},"#
            + #"{"spans":[{"type":"text","text":"two"}],"checked":null,"lists":[]}]},"#
            + #"{"type":"list","ordered":true,"start":1,"items":[{"spans":[{"type":"text","text":"first"}],"checked":null,"lists":[]}]},"#
            + #"{"type":"quote","blocks":[{"type":"paragraph","spans":[{"type":"text","text":"quoted"}]}]},"#
            + #"{"type":"code","text":"let a = \"<b>\""},{"type":"rule"}]"#)
    }

    /// A heading that starts with "Decisions" is shown apart, up to the
    /// next heading of its level.
    func testDecisionsAreSplitOut() throws {
        let blocks = context.evaluateScript(
            "JSON.stringify(ReviewPage.splitDecisions(ReviewPage.parseMarkdown('## Summary\\nWhat.\\n## Decisions taken\\n- A\\n### Detail\\nB\\n## Tests\\nC')))"
        )?.toString()
        XCTAssertEqual(blocks, #"{"blocks":["#
            + #"{"type":"heading","level":2,"spans":[{"type":"text","text":"Summary"}]},"#
            + #"{"type":"paragraph","spans":[{"type":"text","text":"What."}]},"#
            + #"{"type":"heading","level":2,"spans":[{"type":"text","text":"Tests"}]},"#
            + #"{"type":"paragraph","spans":[{"type":"text","text":"C"}]}],"#
            + #""decisions":{"title":"Decisions taken","blocks":["#
            + #"{"type":"list","ordered":false,"start":1,"items":[{"spans":[{"type":"text","text":"A"}],"checked":null,"lists":[]}]},"#
            + #"{"type":"heading","level":3,"spans":[{"type":"text","text":"Detail"}]},"#
            + #"{"type":"paragraph","spans":[{"type":"text","text":"B"}]}]}}"#)
    }

    /// A test plan's checked steps stay told apart; a list keeps its
    /// first number; "```js" opens a block, it doesn't close one.
    func testTaskListsNumbersAndFences() throws {
        XCTAssertEqual(try call("parseMarkdown", "- [x] swift test\n- [ ] nightly\n\n3. third\n4. fourth"), #"["#
            + #"{"type":"list","ordered":false,"start":1,"items":["#
            + #"{"spans":[{"type":"text","text":"swift test"}],"checked":true,"lists":[]},"#
            + #"{"spans":[{"type":"text","text":"nightly"}],"checked":false,"lists":[]}]},"#
            + #"{"type":"list","ordered":true,"start":3,"items":["#
            + #"{"spans":[{"type":"text","text":"third"}],"checked":null,"lists":[]},"#
            + #"{"spans":[{"type":"text","text":"fourth"}],"checked":null,"lists":[]}]}]"#)
        XCTAssertEqual(try call("parseMarkdown", "```\nshell\n```js\nmore\n```\nafter"), #"["#
            + #"{"type":"code","text":"shell\n```js\nmore"},{"type":"paragraph","spans":[{"type":"text","text":"after"}]}]"#)
    }

    func testLabels() throws {
        XCTAssertEqual(try call("commitsLabel", ["commits": 3, "mergesFromBase": 1, "base": "main"]), #""3 commits (1 merge from main)""#)
        XCTAssertEqual(try call("commitsLabel", ["commits": 1, "mergesFromBase": 0, "base": "main"]), #""1 commit""#)
        XCTAssertEqual(try call("splitPath", "Sources/Nirux/App.swift"), #"{"folder":"Sources/Nirux/","name":"App.swift"}"#)
        XCTAssertEqual(try call("statusLetter", "renamed"), #""R""#)
        XCTAssertEqual(try call("fileTag", ["isBinary": true, "isUntracked": true, "omission": NSNull()]), #""binary""#)
        XCTAssertEqual(try call("fileTag", ["isBinary": false, "isUntracked": true, "omission": "notRead"]), #""not read""#)
        XCTAssertEqual(try call("fileTag", ["isBinary": false, "isUntracked": true, "omission": NSNull()]), #""new""#)
        XCTAssertEqual(try call("fileTag", ["isBinary": false, "isUntracked": false, "omission": NSNull()]), "null")
        XCTAssertEqual(try call("clockTime", "not a date"), #""""#)
    }

    /// "mentions", never "tested": a mention isn't coverage.
    func testTestsSummary() throws {
        let tests: [String: Any] = [
            "testLines": 578, "codeLines": 458, "declared": 44, "unreadTestFiles": 2, "testFilesUnlisted": false,
            "unmentioned": ["a", "B.c", "d", "e"].map { ["name": $0, "path": "A.swift", "line": 1] },
            "unscannedFiles": ["Big.swift"]
        ]
        XCTAssertEqual(try call("testsSummary", tests), #"{"lines":"Tests +578 for code +458","notes":["#
            + #""4 of 44 new names in no test: a, B.c, d, +1.","Names unknown in Big.swift.","2 test files not read."]}"#)
    }
    /// Reviewed (section 6.3): a mark that can't be checked still counts,
    /// and a group's checkbox marks what isn't, or clears all once all is.
    func testReviewedStatesMakeTheProgressAndTheGroupCheckbox() throws {
        let states = ["reviewed", "changed", "unverified", "none", "unmarkable"]
        XCTAssertEqual(try call("reviewProgress", states), #""Reviewed 2 of 5 files""#)
        XCTAssertEqual(try call("groupReviewState", [0, 2], states), #""all""#)
        XCTAssertEqual(try call("groupReviewState", [0, 1], states), #""some""#)
        XCTAssertEqual(try call("groupReviewState", [3, 4], states), #""none""#)
        XCTAssertEqual(try call("groupReviewState", [4], states), #""disabled""#)
        XCTAssertEqual(try call("groupReviewAction", [0, 1, 3, 4], states), #"{"reviewed":true,"ids":[1,3]}"#)
        XCTAssertEqual(try call("groupReviewAction", [0, 2, 4], states), #"{"reviewed":false,"ids":[0,2]}"#)
        XCTAssertEqual(try call("reviewTitle", "changed"), #""Changed since you reviewed it""#)
    }

    /// What Explain's bar offers in each state: the changed files once
    /// something was explained, every file again on "Explain All Again";
    /// nothing when there is nothing to send.
    func testExplainActions() throws {
        func actions(_ bar: [String: Any]) throws -> String {
            var full: [String: Any] = [
                "state": "ready", "explained": false, "changed": 0, "unexplained": 0, "sendable": 3, "account": "claude.ai, Max"
            ]
            full.merge(bar) { $1 }
            let json = try call("explainActions", full)
            let decoded = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
            let buttons = (decoded["buttons"] as? [[String: Any]] ?? []).map { button in
                let fresh = (button["fresh"] as? Bool).map { $0 ? " fresh" : "" } ?? ""
                let disabled = (button["disabled"] as? Bool) == true ? " disabled" : ""
                return "\(button["label"] ?? "")\(fresh)\(disabled)"
            }
            return ((decoded["text"] as? String).map { [$0] } ?? []).joined() + " | " + buttons.joined(separator: ", ")
        }
        XCTAssertEqual(
            try actions([:]),
            "Claude can read this branch and its repository, read-only, and explain it file by file: about a minute or two, "
                + "on claude.ai, Max. | Explain"
        )
        XCTAssertEqual(
            try actions(["explained": true, "changed": 2]), "2 files changed since | Explain 2 Changed Files, Explain All Again fresh"
        )
        XCTAssertEqual(
            try actions(["explained": true, "changed": 1, "unexplained": 2]),
            "1 file changed since · 2 files not explained yet | Explain 3 Files, Explain All Again fresh"
        )
        XCTAssertEqual(try actions(["explained": true]), " | Explain Again fresh")
        XCTAssertEqual(
            try actions(["sendable": 0]),
            "Nothing for Claude to read: only folded, binary, secret or untracked files changed. | Explain disabled"
        )
        XCTAssertEqual(try actions(["state": "unavailable"]), " | Explain disabled")
        XCTAssertEqual(try actions(["state": "queued"]), "Waiting for another Explain to end… | Cancel")
        XCTAssertEqual(try actions(["state": "stopping"]), "Stopping… | Cancel disabled")
    }

    func testExplainProgressAndUsage() throws {
        let progress: [String: Any] = ["part": 2, "parts": 3, "reads": 1, "retries": 0, "startedAt": 1_000]
        XCTAssertEqual(try call("explainProgress", progress, 66_500), #""Explaining · part 2 of 3 · 1 read · 1:05""#)
        let single: [String: Any] = ["part": 1, "parts": 1, "reads": 0, "retries": 2, "startedAt": 0]
        XCTAssertEqual(try call("explainProgress", single, 4_000), #""Explaining · 2 retries (servers busy) · 0:04""#)
        XCTAssertEqual(
            try call("usageLine", ["runs": 2, "tokens": 412_400, "costUSD": 1.1234, "isComplete": false]),
            #""Explain today on this branch: 2 runs · 412k tokens · at least $1.12 at API prices""#
        )
        XCTAssertEqual(try call("usageLine", NSNull()), "null")
        XCTAssertEqual(try call("tokens", 1_250_000), #""1.3M""#)
        XCTAssertEqual(try call("intentLabel", "behaviorChange"), #""Behavior change""#)
        XCTAssertEqual(try call("intentLabel", "<b>"), #""Other""#)
        XCTAssertEqual(try call("verdictLabel", "notInDiff"), #""Not in diff""#)
    }
}
