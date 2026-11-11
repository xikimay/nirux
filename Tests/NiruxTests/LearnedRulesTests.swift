import XCTest
@testable import Nirux

/// How a learned rule goes into a space's brief (LearnedRules): at the end
/// of its "## Rules learned" section, or in a new one at its end, with
/// every byte of the user's text kept; never inside a comment or a code
/// block; never past what sessions get.
final class LearnedRulesTests: XCTestCase {
    private let bullet = "- Tests wait on state, never on a fixed sleep. (learned 2026-11-11, #395, #417)"
    private var folder: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("nirux-learned-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: folder)
        super.tearDown()
    }

    /// The bullet an add wrote; a failure when it wrote nothing.
    private func written(_ outcome: LearnedRules.AddOutcome, file: StaticString = #filePath, line: UInt = #line) throws -> String {
        guard case .added(let bullet) = outcome else {
            XCTFail("nothing written: \(outcome)", file: file, line: line)
            throw XCTSkip("nothing written")
        }
        return bullet
    }

    /// `text` with `inserted` at `offset` characters: the only change a
    /// write may make.
    private func expected(_ text: String, inserting inserted: String, at marker: String) throws -> String {
        let range = try XCTUnwrap(text.range(of: marker))
        return String(text[..<range.upperBound]) + inserted + String(text[range.upperBound...])
    }

    // MARK: - No section yet

    /// A brief without the section gets one at its end, a blank line
    /// before it; what was there stays, byte for byte, its own blank lines
    /// and missing final break included.
    func testANewSectionGoesAtTheEndOfTheBrief() throws {
        let section = "## Rules learned\n\n\(bullet)\n"
        XCTAssertEqual(try LearnedRules.inserting(bullet, into: "Ship v2.\n"), "Ship v2.\n\n" + section)
        XCTAssertEqual(try LearnedRules.inserting(bullet, into: "Ship v2.\n\n"), "Ship v2.\n\n" + section)
        XCTAssertEqual(try LearnedRules.inserting(bullet, into: "Ship v2.\n  \n"), "Ship v2.\n  \n" + section)
        XCTAssertEqual(try LearnedRules.inserting(bullet, into: "Ship v2."), "Ship v2.\n\n" + section)
        XCTAssertEqual(try LearnedRules.inserting(bullet, into: ""), section)
        // The template's comment stays; the rule is text sessions get.
        let template = SpaceBrief.template(spaceName: "Nirux")
        let written = try LearnedRules.inserting(bullet, into: template)
        XCTAssertTrue(written.hasPrefix(template))
        XCTAssertEqual(SpaceBrief.body(of: written), "## Rules learned\n\n\(bullet)")
    }

    /// A heading that only looks like it doesn't hold rules: inside a
    /// comment or a code block, or of another level.
    func testOnlyALiveSecondLevelHeadingIsTheSection() throws {
        for brief in [
            "<!--\n## Rules learned\n-->\n",
            "```\n## Rules learned\n```\n",
            "### Rules learned\n- old\n",
            "## Rules learned later\n- old\n"
        ] {
            XCTAssertEqual(try LearnedRules.inserting(bullet, into: brief), brief + "\n## Rules learned\n\n\(bullet)\n", brief)
        }
        // In any case, with a closing run or a comment on its line.
        for heading in ["## rules LEARNED", "## Rules learned ##", "## Rules learned <!-- auto -->"] {
            let brief = heading + "\n- old\n"
            XCTAssertEqual(try LearnedRules.inserting(bullet, into: brief), brief + bullet + "\n", heading)
        }
    }

    // MARK: - The section

    /// After the section's last line, before the blank lines and the
    /// heading that follow; the text around it unchanged.
    func testTheRuleGoesAtTheEndOfTheSection() throws {
        let brief = """
            # Nirux
            Ship v2 first.

            ## Rules learned

            - Never show a model's words next to a Yes button. (learned 2026-11-09, #345)
              Show the message's own words.

            ## Workflow
            - Draft PRs only.

            """
        XCTAssertEqual(
            try LearnedRules.inserting(bullet, into: brief),
            try expected(brief, inserting: bullet + "\n", at: "Show the message's own words.\n")
        )
        // A sub-heading belongs to the section; a first-level one ends it.
        let nested = "## Rules learned\n- a\n### Tests\n- b\n# Next\n- c\n"
        XCTAssertEqual(try LearnedRules.inserting(bullet, into: nested), try expected(nested, inserting: bullet + "\n", at: "- b\n"))
        // Last in the file, with no final break.
        XCTAssertEqual(try LearnedRules.inserting(bullet, into: "## Rules learned\n- a"), "## Rules learned\n- a\n\(bullet)\n")
        // A setext heading ends it too; a line across after a list doesn't.
        let setext = "## Rules learned\n- a\n\nWorkflow\n--------\nShip daily.\n"
        XCTAssertEqual(try LearnedRules.inserting(bullet, into: setext), try expected(setext, inserting: bullet + "\n", at: "- a\n"))
        for across in ["## Rules learned\n- a\n---\n", "## Rules learned\n- a\n  more\n---\n", "## Rules learned\n- a\n\n  Details\n  ---\n"] {
            XCTAssertEqual(try LearnedRules.inserting(bullet, into: across), across + bullet + "\n", across)
        }
        // A setext heading right under it: a blank line keeps it off the rule.
        let under = "## Rules learned\nWorkflow\n--------\n"
        XCTAssertEqual(try LearnedRules.inserting(bullet, into: under), "## Rules learned\n\n\(bullet)\n\nWorkflow\n--------\n")
        // The first section, when there are two.
        let twice = "## Rules learned\n- a\n\n## Rules learned\n- b\n"
        XCTAssertEqual(try LearnedRules.inserting(bullet, into: twice), try expected(twice, inserting: bullet + "\n", at: "- a\n"))
    }

    /// An empty section gets the rule under its heading, a blank line
    /// between.
    func testAnEmptySectionGetsTheRuleUnderItsHeading() throws {
        let brief = "Goals.\n\n## Rules learned\n\n## Workflow\n- Draft PRs.\n"
        XCTAssertEqual(
            try LearnedRules.inserting(bullet, into: brief),
            try expected(brief, inserting: "\n\(bullet)\n", at: "## Rules learned\n")
        )
        XCTAssertEqual(try LearnedRules.inserting(bullet, into: "## Rules learned"), "## Rules learned\n\n\(bullet)\n")
    }

    /// A brief written with CRLF gets CRLF lines; its own bytes stay.
    func testACRLFBriefKeepsItsLineBreaks() throws {
        let brief = "Goals.\r\n\r\n## Rules learned\r\n- a\r\n\r\n## Next\r\n"
        XCTAssertEqual(
            try LearnedRules.inserting(bullet, into: brief),
            try expected(brief, inserting: bullet + "\r\n", at: "- a\r\n")
        )
        XCTAssertEqual(try LearnedRules.inserting(bullet, into: "Goals.\r\n"), "Goals.\r\n\r\n## Rules learned\r\n\r\n\(bullet)\r\n")
    }

    /// A place inside a code block or a comment would hide the rule from
    /// sessions, or show it as code: refused, the brief left alone.
    func testAPlaceInsideACodeBlockOrACommentIsRefused() {
        for brief in ["Goals.\n```\nnot closed\n", "## Rules learned\n- a\n```\nopen\n## Next\n"] {
            XCTAssertThrowsError(try LearnedRules.inserting(bullet, into: brief), brief)
        }
        // An unclosed `<!--` hides nothing from sessions (SpaceBrief.body
        // keeps it as text): a literal one in prose refuses nothing.
        let prose = "Never write `<!--` in prompts.\n"
        XCTAssertEqual(try LearnedRules.inserting(bullet, into: prose), prose + "\n## Rules learned\n\n\(bullet)\n")
        let opened = "<!-- not closed\n## Rules learned\n- a\n"
        XCTAssertEqual(try LearnedRules.inserting(bullet, into: opened), opened + bullet + "\n")

        // The same rule shown above doesn't make a hidden copy pass.
        XCTAssertThrowsError(try LearnedRules.inserting(bullet, into: "\(bullet)\n## Rules learned\n- a\n<!-- off\n- b\n--> ## Next\n"))
        // The next heading shares its line with a comment's end: the rule
        // would be inside the comment.
        XCTAssertThrowsError(try LearnedRules.inserting(bullet, into: "## Rules learned\n- a\n<!-- off\n- b\n--> ## Next\n"))
        // A comment that ends on the section's last line is fine.
        let closed = "## Rules learned\n- a <!-- a note\nthat ends here -->\n"
        XCTAssertEqual(try LearnedRules.inserting(bullet, into: closed), closed + bullet + "\n")
    }

    // MARK: - Rules

    func testTheRuleLineSaysWhenAndFromWhat() throws {
        let utc = try XCTUnwrap(TimeZone(identifier: "UTC"))
        let date = Date(timeIntervalSince1970: 1_762_819_200) // 2025-11-11 00:00 UTC
        XCTAssertEqual(LearnedRules.line(rule: "Wait on state.", evidence: "#395", date: date, timeZone: utc),
                       "- Wait on state. (learned 2025-11-11, #395)")
        XCTAssertEqual(LearnedRules.line(rule: "Wait on state.", evidence: "", date: date, timeZone: utc),
                       "- Wait on state. (learned 2025-11-11)")
        XCTAssertEqual(LearnedRules.splitLearned("Wait on state. (learned 2025-11-11, #395)").day, "2025-11-11")
        XCTAssertEqual(LearnedRules.splitLearned("Wait on state. (learned 2025-11-11, #395)").rule, "Wait on state.")
        XCTAssertNil(LearnedRules.splitLearned("Wait (learned the hard way)").day)
        // The evidence may say "learned" too.
        let tricky = LearnedRules.splitLearned("Wait on state. (learned 2025-11-11, #395 (learned the hard way))")
        XCTAssertEqual(tricky.rule, "Wait on state.")
        XCTAssertEqual(tricky.day, "2025-11-11")
    }

    /// A rule is one paragraph: whitespace folds; empty, too long, or
    /// holding a comment mark, it is refused.
    func testWhatARuleMayHold() {
        XCTAssertEqual(LearnedRules.cleaned("  Wait\non\tstate. ", limit: 300), "Wait on state.")
        XCTAssertNotNil(LearnedRules.problem(rule: "", evidence: "#1"))
        XCTAssertNotNil(LearnedRules.problem(rule: String(repeating: "a", count: 301), evidence: "#1"))
        XCTAssertNil(LearnedRules.problem(rule: String(repeating: "a", count: 300), evidence: ""))
        XCTAssertNotNil(LearnedRules.problem(rule: "Wait", evidence: String(repeating: "1", count: 201)))
        XCTAssertNotNil(LearnedRules.problem(rule: "Wait <!-- on state", evidence: "#1"))
        XCTAssertNotNil(LearnedRules.problem(rule: "Wait", evidence: "#1 -->"))
    }

    /// The same rule in other words' case, spacing or final punctuation,
    /// with or without its "(learned …)", hand-written or not.
    func testTheBriefSaysARuleAlready() {
        let brief = "Goals.\n\n## Rules learned\n\n- Tests wait on STATE,  never on a fixed sleep (learned 2026-11-11, #395)\n"
            + "- Check who owns the screen first.\n<!-- - Hidden rule. -->\n"
        XCTAssertEqual(LearnedRules.existingRule(matching: "tests wait on state, never on a fixed sleep.", in: brief)?.day, "2026-11-11")
        let handWritten = LearnedRules.existingRule(matching: "Check who owns the screen first", in: brief)
        XCTAssertNotNil(handWritten)
        XCTAssertNil(handWritten?.day)
        XCTAssertNil(LearnedRules.existingRule(matching: "Hidden rule.", in: brief), "sessions don't get a comment")
        XCTAssertNil(LearnedRules.existingRule(matching: "Tests wait on state.", in: brief))
    }

    // MARK: - Writing the file

    /// No brief yet: the template, then the section; its folder made.
    func testAddingToAMissingBriefStartsFromTheTemplate() throws {
        let url = folder.appendingPathComponent("space/brief.md")
        let written = try written(LearnedRules.add(rule: "Wait on state.", evidence: "#395", to: url, spaceName: "Nirux"))
        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(text.hasPrefix(SpaceBrief.template(spaceName: "Nirux")))
        XCTAssertTrue(text.hasSuffix("## Rules learned\n\n\(written)\n"))
        XCTAssertTrue(written.hasPrefix("- Wait on state. (learned "))
    }

    /// The user edited the brief after the sheet read it: the write starts
    /// from the file as it is, so their edit stays.
    func testAnEditMadeWhileTheSheetIsOpenStays() throws {
        let url = folder.appendingPathComponent("brief.md")
        try Data("Goals.\n\n## Rules learned\n- a\n".utf8).write(to: url)
        let shown = LearnedRules.briefText(at: url)
        try Data("Goals, edited.\n\n## Rules learned\n- a\n\n## Workflow\n- Draft PRs.\n".utf8).write(to: url)
        let written = try written(LearnedRules.add(rule: "b", evidence: "", to: url, spaceName: "Nirux"))
        XCTAssertNotEqual(shown, LearnedRules.briefText(at: url))
        XCTAssertEqual(
            try String(contentsOf: url, encoding: .utf8), "Goals, edited.\n\n## Rules learned\n- a\n\(written)\n\n## Workflow\n- Draft PRs.\n"
        )
    }

    /// An edit that lands while the write is under way: the write starts
    /// over from it rather than replacing it.
    func testAnEditDuringTheWriteIsKept() throws {
        let url = folder.appendingPathComponent("brief.md")
        try Data("Goals.\n".utf8).write(to: url)
        var reads: [String] = []
        let written = try written(LearnedRules.add(rule: "b", evidence: "#1", to: url, spaceName: "Nirux") { text in
            reads.append(text)
            if reads.count == 1 { try? Data("Goals, by hand.\n".utf8).write(to: url) }
        })
        XCTAssertEqual(reads, ["Goals.\n", "Goals, by hand.\n"])
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "Goals, by hand.\n\n## Rules learned\n\n\(written)\n")
    }

    /// The brief says it already, in the user's words or the proposal's,
    /// when the write reads it: nothing is written, even when it got there
    /// after the sheet looked (by hand, or an Add whose decision wasn't
    /// recorded).
    func testARuleTheBriefSaysIsNotWrittenAgain() throws {
        let url = folder.appendingPathComponent("brief.md")
        try Data("Goals.\n".utf8).write(to: url)
        let byHand = "Goals.\n\n## Rules learned\n\n- Wait on state (learned 2026-11-11, #395)\n"
        let outcome = try LearnedRules.add(rule: "wait on STATE.", evidence: "", to: url, spaceName: "N") { text in
            if text == "Goals.\n" { try? Data(byHand.utf8).write(to: url) }
        }
        XCTAssertEqual(outcome, .alreadyThere("Wait on state (learned 2026-11-11, #395)"))
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), byHand)
        let edited = try LearnedRules.add(rule: "Tests wait on state, never on a sleep.", evidence: "", alsoMatching: ["Wait on state"],
                                          to: url, spaceName: "N")
        XCTAssertEqual(edited, .alreadyThere("Wait on state (learned 2026-11-11, #395)"))
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), byHand)
    }

    /// Sessions don't read a brief file past 1 MB: no rule goes into one,
    /// nor makes one pass it.
    func testABriefFileSessionsDontReadIsRefused() throws {
        let url = folder.appendingPathComponent("brief.md")
        let comment = "<!--\n" + String(repeating: "x", count: SpaceBrief.maxFileBytes) + "\n-->\n"
        try Data(comment.utf8).write(to: url)
        XCTAssertNotNil(LearnedRules.readForAdding(at: url).problem)
        XCTAssertThrowsError(try LearnedRules.add(rule: "Wait on state.", evidence: "", to: url, spaceName: "N"))
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), comment)
        // Nor counts as saying it: sessions don't read that file.
        try Data((comment + "- Wait on state.\n").utf8).write(to: url)
        XCTAssertThrowsError(try LearnedRules.add(rule: "Wait on state.", evidence: "", to: url, spaceName: "N"))
        let near = "<!--\n" + String(repeating: "x", count: SpaceBrief.maxFileBytes - 30) + "\n-->\n"
        try Data(near.utf8).write(to: url)
        XCTAssertNil(LearnedRules.readForAdding(at: url).problem)
        XCTAssertThrowsError(try LearnedRules.add(rule: "Wait on state, never on a fixed sleep.", evidence: "#395", to: url, spaceName: "N"))
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), near)
    }

    /// Past what sessions get, nothing is written.
    func testARuleThatWouldPassTheLimitIsRefused() throws {
        let url = folder.appendingPathComponent("brief.md")
        let brief = String(repeating: "x", count: 100) + "\n"
        try Data(brief.utf8).write(to: url)
        XCTAssertThrowsError(try LearnedRules.add(rule: "Wait on state.", evidence: "", to: url, spaceName: "N", maxCharacters: 130)) { error in
            XCTAssertEqual(error as? ProjectMemory.WriteError, .tooLong(130))
        }
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), brief)
        XCTAssertThrowsError(try LearnedRules.add(rule: "Wait <!--", evidence: "", to: url, spaceName: "N"))
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), brief)
    }

    /// A UTF-8 byte order mark stays where it was.
    func testAByteOrderMarkStays() throws {
        let url = folder.appendingPathComponent("brief.md")
        let mark = Data([0xEF, 0xBB, 0xBF])
        try (mark + Data("Goals.\n".utf8)).write(to: url)
        let written = try written(LearnedRules.add(rule: "b", evidence: "", to: url, spaceName: "N"))
        XCTAssertEqual(try Data(contentsOf: url), mark + Data("Goals.\n\n## Rules learned\n\n\(written)\n".utf8))
    }

    /// Few characters, many bytes: Codex would get it cut, the rule first.
    func testABriefPastItsBytesIsRefused() throws {
        let url = folder.appendingPathComponent("brief.md")
        let brief = String(repeating: "👨‍👩‍👧", count: SpaceBrief.maxBytes / 18) + "\n"
        try Data(brief.utf8).write(to: url)
        XCTAssertLessThan(brief.count, SpaceBrief.maxCharacters)
        XCTAssertThrowsError(try LearnedRules.add(rule: "Wait on state, never on a fixed sleep.", evidence: "#395", to: url, spaceName: "N"))
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), brief)
    }

    /// A brief kept elsewhere through a link: the link stays, its target
    /// gets the rule.
    func testALinkedBriefIsWrittenWhereItPoints() throws {
        let target = folder.appendingPathComponent("elsewhere.md")
        try Data("Goals.\n".utf8).write(to: target)
        let link = folder.appendingPathComponent("brief.md")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        _ = try written(LearnedRules.add(rule: "b", evidence: "", to: link, spaceName: "N"))
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: link.path), target.path)
        XCTAssertTrue(try String(contentsOf: target, encoding: .utf8).hasPrefix("Goals.\n\n## Rules learned\n\n- b (learned "))
    }
}
