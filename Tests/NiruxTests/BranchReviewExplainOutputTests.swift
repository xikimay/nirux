import XCTest
@testable import Nirux

/// Explain's answer is checked against its input (docs/branch-review.md,
/// section 4.3): unknown files and hunks are dropped, strings capped and
/// shown as text, values kept to the schema's.
final class BranchReviewExplainOutputTests: XCTestCase {
    func testTheAnswerKeepsOnlyWhatTheInputNamed() throws {
        let input = try BranchReviewExplainRunTests.input()
        let answer = Self.answer([
            "groups": .array([
                Self.group("feature", "Keep awake", ["f0", "f9"]),
                // A path in one group at most; a group left empty goes.
                Self.group("refactor", "Again", ["f0"]),
                Self.group("security", "Not an intent", ["f1"]),
                Self.group("docs", "Lockfile", ["f1"])
            ]),
            "files": .array([
                Self.file("f0", "Adds the controller.", 7),
                Self.file("f0", "Twice.", 1),
                // Its diff wasn't sent: no summary from the model.
                Self.file("f1", "A lockfile.", 1),
                Self.file("f9", "Unknown.", 2)
            ]),
            "notes": .array([
                .object(["hunk": .string("f0h0"), "text": .string("Changes a."), "check": .string("  ")]),
                .object(["hunk": .string("f0h7"), "text": .string("No such hunk.")]),
                .object(["hunk": .string("f2h0"), "text": .string("Not sent.")])
            ]),
            "claims": .array([
                .object(["claim": .string("Keeps awake"), "verdict": .string("matches"), "evidence": .string("Read it.")]),
                .object(["claim": .string("Safe"), "verdict": .string("approved"), "evidence": .string("")])
            ]),
            "questions": .array((1...7).map { .string("Question \($0)?") })
        ])

        let output = try XCTUnwrap(BranchReview.ExplainOutput.checked(answer, against: input))

        XCTAssertEqual(output.groups, [
            .init(intent: .feature, title: "Keep awake", paths: ["Sources/KeepAwake.swift"]),
            .init(intent: .docs, title: "Lockfile", paths: ["Package.resolved"])
        ])
        XCTAssertEqual(output.files, [.init(path: "Sources/KeepAwake.swift", summary: "Adds the controller.", importance: 3)])
        let hunk = BranchReview.HunkReference(
            path: "Sources/KeepAwake.swift", index: 0, anchor: BranchReview.hunkAnchor(BranchReviewPageTests.snapshot().files[0].hunks[0])
        )
        XCTAssertEqual(output.notes, [.init(hunk: hunk, text: "Changes a.", check: nil)])
        XCTAssertEqual(output.claims, [.init(claim: "Keeps awake", verdict: .matches, evidence: "Read it.")])
        XCTAssertEqual(output.questions, (1...5).map { "Question \($0)?" })
        // f9 twice, and the hunk f0h7: the unsent f2h0 isn't an id either.
        XCTAssertEqual(output.dropped, 4)
    }

    /// A model that names files by their paths still gets its answer
    /// kept: the path stands for its id.
    func testAPathStandsForItsID() throws {
        let input = try BranchReviewExplainRunTests.input()
        let output = try XCTUnwrap(BranchReview.ExplainOutput.checked(Self.answer([
            "groups": .array([Self.group("feature", "Keep awake", ["Sources/KeepAwake.swift"])]),
            "files": .array([Self.file("Sources/KeepAwake.swift", "Adds the controller.", 2)])
        ]), against: input))
        XCTAssertEqual(output.groups.first?.paths, ["Sources/KeepAwake.swift"])
        XCTAssertEqual(output.files.first?.path, "Sources/KeepAwake.swift")
        XCTAssertEqual(output.dropped, 0)
    }

    /// Strings are capped, and shown as text: bidi controls and invisible
    /// characters as code points, line breaks kept. An answer without an
    /// overview isn't one.
    func testStringsAreCappedAndShownAsText() throws {
        let input = try BranchReviewExplainRunTests.input()
        let long = String(repeating: "x", count: BranchReview.ExplainOutput.Limits.overview + 10)
        let output = try XCTUnwrap(BranchReview.ExplainOutput.checked(
            Self.answer(["overview": .string(long)]), against: input
        ))
        XCTAssertEqual(output.overview.count, BranchReview.ExplainOutput.Limits.overview)
        XCTAssertTrue(output.overview.hasSuffix("…"))

        let shown = try XCTUnwrap(BranchReview.ExplainOutput.checked(
            Self.answer(["overview": .string("  Line one.\r\nsafe\u{202E}txt\u{200B}.exe\n")]), against: input
        ))
        XCTAssertEqual(shown.overview, "Line one.\nsafe⟨U+202E⟩txt⟨U+200B⟩.exe")

        // One character with thousands of combining marks counts as many.
        let zalgo = try XCTUnwrap(BranchReview.ExplainOutput.checked(
            Self.answer(["overview": .string("a" + String(repeating: "\u{0301}", count: 10_000))]), against: input
        ))
        XCTAssertEqual(zalgo.overview.unicodeScalars.count, BranchReview.ExplainOutput.Limits.overview)

        XCTAssertNil(BranchReview.ExplainOutput.checked(Self.answer(["overview": .string(" ")]), against: input))
        XCTAssertNil(BranchReview.ExplainOutput.checked(.array([]), against: input))
    }

    /// The schema passed to `--json-schema` is JSON, asks for every part
    /// of the answer, at most 5 questions, and names files and hunks by the
    /// input's ids only: summaries for the files whose diff was sent.
    func testTheSchemaAsksForTheWholeAnswer() throws {
        let input = try BranchReviewExplainRunTests.input()
        let schema = try JSONDecoder().decode(JSONValue.self, from: Data(BranchReview.ExplainOutput.schema(for: input).utf8))
        let fields = try XCTUnwrap(schema.objectValue)
        func items(_ key: String) -> [String: JSONValue]? {
            fields["properties"]?.objectValue?[key]?.objectValue?["items"]?.objectValue?["properties"]?.objectValue
        }
        XCTAssertEqual(items("groups")?["files"]?.objectValue?["items"]?.objectValue?["enum"], .array(["f0", "f1", "f2"].map(JSONValue.string)))
        XCTAssertEqual(items("files")?["file"]?.objectValue?["enum"], .array([.string("f0")]))
        XCTAssertEqual(items("notes")?["hunk"]?.objectValue?["enum"], .array([.string("f0h0")]))
        XCTAssertEqual(fields["required"], .array(["overview", "groups", "files", "notes", "claims", "questions"].map(JSONValue.string)))
        XCTAssertEqual(fields["properties"]?.objectValue?["questions"]?.objectValue?["maxItems"], .int(5))
        let verdicts = fields["properties"]?.objectValue?["claims"]?.objectValue?["items"]?.objectValue?["properties"]?
            .objectValue?["verdict"]?.objectValue?["enum"]
        XCTAssertEqual(verdicts, .array(["matches", "partly", "contradicts", "notInDiff"].map(JSONValue.string)))
    }

    // MARK: - Helpers

    static func answer(_ fields: [String: JSONValue]) -> JSONValue {
        .object([
            "overview": .string("Keeps the Mac awake."), "groups": .array([]), "files": .array([]), "notes": .array([]),
            "claims": .array([]), "questions": .array([])
        ].merging(fields) { _, new in new })
    }

    static func group(_ intent: String, _ title: String, _ files: [String]) -> JSONValue {
        .object(["intent": .string(intent), "title": .string(title), "files": .array(files.map(JSONValue.string))])
    }

    static func file(_ id: String, _ summary: String, _ importance: Int) -> JSONValue {
        .object(["file": .string(id), "summary": .string(summary), "importance": .int(Int64(importance))])
    }
}
