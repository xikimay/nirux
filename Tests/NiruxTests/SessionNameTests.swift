import XCTest
@testable import Nirux

final class SessionNameTests: XCTestCase {
    private func name(branch: String? = "feat/projects", space: String? = "Nirux", isDefaultSpace: Bool = false) -> String? {
        SessionName.make(worktreeBranch: branch, spaceName: space, isDefaultSpace: isDefaultSpace)
    }

    func testWorktreeBranchComesFirstThenSpace() {
        XCTAssertEqual(name(), "feat/projects · Nirux")
    }

    func testNoWorktreeBranchMeansNoName() {
        // A main checkout's branch changes; Claude's prompt-based title stays.
        XCTAssertNil(name(branch: nil))
        XCTAssertNil(name(branch: " \n"))
    }

    func testDefaultSpaceWithItsDefaultNameIsLeftOut() {
        XCTAssertEqual(name(space: "main", isDefaultSpace: true), "feat/projects")
    }

    func testRenamedDefaultSpaceIsKept() {
        XCTAssertEqual(name(space: "Personal", isDefaultSpace: true), "feat/projects · Personal")
    }

    func testSpaceCalledMainThatIsNotTheDefaultIsKept() {
        XCTAssertEqual(name(space: "main", isDefaultSpace: false), "feat/projects · main")
    }

    func testSpaceEqualToBranchIsLeftOut() {
        XCTAssertEqual(name(branch: "nirux", space: "Nirux"), "nirux")
    }

    func testMissingSpaceGivesBranchOnly() {
        XCTAssertEqual(name(space: nil), "feat/projects")
        XCTAssertEqual(name(space: "  "), "feat/projects")
    }

    func testWhitespaceAndControlCharactersAreCollapsed() {
        XCTAssertEqual(name(space: "  Two\nlines\t here\u{1B} "), "feat/projects · Two lines here")
    }

    func testCharactersThatBreakShellQuotingAreDropped() {
        // `\` leaves fish's single quotes open; `!` is tcsh history expansion.
        XCTAssertEqual(name(space: "Ship it!\\"), "feat/projects · Ship it")
    }

    func testJoinersAreKeptAndBidiControlsDropped() {
        XCTAssertEqual(name(space: "\u{1F469}\u{200D}\u{1F4BB} team"), "feat/projects · \u{1F469}\u{200D}\u{1F4BB} team")
        XCTAssertEqual(name(space: "abc\u{202E}def"), "feat/projects · abcdef")
    }

    func testLongBranchAndSpaceAreTruncated() {
        let result = name(branch: String(repeating: "b", count: 100), space: String(repeating: "s", count: 50))

        XCTAssertEqual(
            result,
            String(repeating: "b", count: SessionName.maxLabelLength - 1) + "… · "
                + String(repeating: "s", count: SessionName.maxSpaceLength - 1) + "…"
        )
    }

    @MainActor
    func testFreshClaudeCommandPassesTheNameAsOneQuotedArgument() {
        let command = NiruxShellView.claudeCommand(
            mode: .acceptEdits,
            sessionName: "it's feat/x · Nirux",
            handoverPrompt: "Read .claude-handover.md"
        )

        XCTAssertEqual(
            command,
            "command claude --permission-mode acceptEdits '--name=it'\\''s feat/x · Nirux' 'Read .claude-handover.md'"
        )
    }

    @MainActor
    func testClaudeCommandWithoutNameHasNoNameFlag() {
        XCTAssertEqual(NiruxShellView.claudeCommand(mode: .default), "command claude")
        XCTAssertEqual(NiruxShellView.claudeCommand(resume: .picker, mode: .default), "command claude --resume")
    }

    @MainActor
    func testRestoredClaudeSessionIsNeverRenamed() {
        // A restore keeps the name the user may have set with /rename or from claude.ai.
        XCTAssertEqual(
            NiruxShellView.claudeCommand(resume: .session("abc"), mode: .default, sessionName: "feat/x · Nirux"),
            "command claude --resume 'abc'"
        )
        XCTAssertEqual(
            NiruxShellView.claudeCommand(resume: .picker, mode: .default, sessionName: "feat/x · Nirux"),
            "command claude --resume"
        )
    }
}
