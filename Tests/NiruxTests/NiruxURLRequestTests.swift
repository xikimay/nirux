import XCTest
@testable import Nirux

final class NiruxURLRequestTests: XCTestCase {

    private func parse(_ string: String) -> NiruxURLRequest? {
        guard let url = URL(string: string) else {
            XCTFail("unparseable URL: \(string)")
            return nil
        }
        return NiruxURLRequest(url: url)
    }

    private func worktree(_ string: String) -> NiruxURLRequest.NewWorktree? {
        guard case .newWorktree(let request)? = parse(string)?.action else { return nil }
        return request
    }

    // MARK: - Routing

    func testNewWorkspaceParsesParameters() {
        let request = parse(
            "nirux://new-workspace?cwd=/Users/me/project&title=Demo&agent=codex&profile=p1&launch=abc"
        )
        XCTAssertEqual(request?.action, .newWorkspace(cwd: "/Users/me/project", title: "Demo", agent: .codex))
        XCTAssertEqual(request?.profileID, "p1")
        XCTAssertEqual(request?.launchID, "abc")
        XCTAssertEqual(request?.requiresAuthorization, true)
    }

    func testNewWorkspaceTreatsEmptyValuesAsMissing() {
        let request = parse("nirux://new-workspace?cwd=&title=&agent=nope&launch=")
        XCTAssertEqual(request?.action, .newWorkspace(cwd: nil, title: nil, agent: nil))
        XCTAssertNil(request?.launchID)
    }

    func testNewWorkspaceRejectsRelativeCwd() {
        XCTAssertNil(parse("nirux://new-workspace?cwd=project"))
    }

    func testProfileAliases() {
        XCTAssertEqual(parse("nirux://new-workspace?profileID=a")?.profileID, "a")
        XCTAssertEqual(parse("nirux://new-workspace?space=b")?.profileID, "b")
        XCTAssertNil(parse("nirux://new-workspace")?.profileID)
    }

    func testNewWorktreeParsesParameters() {
        let request = worktree(
            "nirux://new-worktree?branch=feat%2Fx&repo=/Users/me/repo&agent=claude"
                + "&handover=%2Ftmp%2Fnirux-handover-claude-feat-x.md"
                + "&parentWorkspace=W&parentAgent=A"
        )
        XCTAssertEqual(request, NiruxURLRequest.NewWorktree(
            branch: "feat/x",
            repo: "/Users/me/repo",
            agent: .claude,
            handoverPath: "/tmp/nirux-handover-claude-feat-x.md",
            parentWorkspaceID: "W",
            parentAgentUUID: "A"
        ))
    }

    func testNewWorktreeRequiresBranchAndAbsoluteRepo() {
        XCTAssertNil(parse("nirux://new-worktree?repo=/Users/me/repo"))
        XCTAssertNil(parse("nirux://new-worktree?branch=x"))
        XCTAssertNil(parse("nirux://new-worktree?branch=x&repo=relative/repo"))
        XCTAssertNotNil(parse("nirux://new-worktree?branch=x&repo=/Users/me/repo"))
    }

    func testHandoverMustBeANiruxHandoverDirectlyInTmp() {
        let base = "nirux://new-worktree?branch=x&repo=/r&handover="
        XCTAssertNotNil(parse(base + "/tmp/nirux-handover-claude-x.md"))
        XCTAssertNotNil(parse(base + "/private/tmp/nirux-handover-codex-x.md"))
        for rejected in [
            "/Users/me/.ssh/id_ed25519",
            "/tmp/notes.md",
            "/tmp/nirux-handover-",
            "/tmp/sub/nirux-handover-x.md",
            "/tmp/../Users/me/nirux-handover-x.md",
            "/tmp/./nirux-handover-x.md",
            "/var/tmp/nirux-handover-x.md",
            "tmp/nirux-handover-x.md",
            "/tmp/nirux-handover-x.md/"
        ] {
            let encoded = rejected.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? rejected
            XCTAssertNil(parse(base + encoded), rejected)
        }
    }

    func testOpenEditorDoesNotRequireAuthorization() {
        let request = parse("nirux://open-editor?file=/tmp/a.swift")
        XCTAssertEqual(request?.action, .openEditor)
        XCTAssertEqual(request?.requiresAuthorization, false)
    }

    func testUnknownHostOrSchemeIsRejected() {
        XCTAssertNil(parse("nirux://run?cmd=ls"))
        XCTAssertNil(parse("nirux:new-workspace"))
        XCTAssertNil(parse("https://new-workspace?cwd=/tmp"))
    }

    // MARK: - Launch ID

    func testLaunchIDValidation() {
        XCTAssertTrue(NiruxLaunchAuthorization.isValid("abc123", expected: "abc123"))
        XCTAssertFalse(NiruxLaunchAuthorization.isValid(nil, expected: "abc123"))
        XCTAssertFalse(NiruxLaunchAuthorization.isValid("", expected: "abc123"))
        XCTAssertFalse(NiruxLaunchAuthorization.isValid("abc12", expected: "abc123"))
        XCTAssertFalse(NiruxLaunchAuthorization.isValid("abc1234", expected: "abc123"))
        XCTAssertFalse(NiruxLaunchAuthorization.isValid("abc124", expected: "abc123"))
        XCTAssertFalse(NiruxLaunchAuthorization.isValid("", expected: ""))
    }

    func testLaunchIDIsRandomHex() {
        let launchID = NiruxLaunchAuthorization.launchID
        XCTAssertEqual(launchID.count, 64)
        XCTAssertTrue(launchID.allSatisfy(\.isHexDigit))
        XCTAssertTrue(NiruxLaunchAuthorization.isValid(launchID))
        XCTAssertEqual(launchID, NiruxLaunchAuthorization.launchID, "stable for the whole launch")
    }

    // MARK: - Confirmation

    func testWorkspaceConfirmationSpellsOutFolderAgentAndMode() throws {
        let request = try XCTUnwrap(parse("nirux://new-workspace?cwd=/Users/me/project&agent=claude&title=Demo"))
        let text = try XCTUnwrap(request.confirmation(claudeMode: .auto, codexMode: .fullAuto))
        XCTAssertEqual(text.message, "Open a new workspace and start an agent?")
        XCTAssertTrue(text.details.contains("Folder: /Users/me/project"))
        XCTAssertTrue(text.details.contains("Claude Code — \(ClaudeLaunchMode.auto.displayName)"))
        XCTAssertTrue(text.details.contains("Title: Demo"))
    }

    func testWorkspaceConfirmationWithoutAgentSaysPlainShell() throws {
        let request = try XCTUnwrap(parse("nirux://new-workspace?cwd=/Users/me"))
        let text = try XCTUnwrap(request.confirmation(claudeMode: .auto, codexMode: .fullAuto))
        XCTAssertEqual(text.message, "Open a new workspace?")
        XCTAssertTrue(text.details.contains("Agent: none (plain shell)"))
    }

    func testWorktreeConfirmationSpellsOutRepoBranchModeAndHandover() throws {
        let request = try XCTUnwrap(parse(
            "nirux://new-worktree?branch=feat/x&repo=/Users/me/repo&agent=codex"
                + "&handover=/tmp/nirux-handover-codex-feat-x.md"
        ))
        let text = try XCTUnwrap(request.confirmation(claudeMode: .default, codexMode: .fullAuto))
        XCTAssertEqual(text.message, "Create a worktree and start an agent?")
        XCTAssertTrue(text.details.contains("Repository: /Users/me/repo"))
        XCTAssertTrue(text.details.contains("Branch: feat/x"))
        XCTAssertTrue(text.details.contains("Codex — \(CodexLaunchMode.fullAuto.displayName)"))
        XCTAssertTrue(text.details.contains("Handover: /tmp/nirux-handover-codex-feat-x.md"))
    }

    func testOpenEditorHasNoConfirmation() throws {
        let request = try XCTUnwrap(parse("nirux://open-editor?file=/tmp/a.swift"))
        XCTAssertNil(request.confirmation(claudeMode: .default, codexMode: .default))
    }

    func testConfirmationNeutralizesControlCharactersAndCapsLength() throws {
        let request = try XCTUnwrap(parse(
            "nirux://new-workspace?cwd=/tmp&title=Demo%0AAgent:%20none%20(plain%20shell)"
        ))
        let text = try XCTUnwrap(request.confirmation(claudeMode: .auto, codexMode: .fullAuto))
        XCTAssertFalse(text.details.contains("Demo\nAgent"))
        XCTAssertTrue(text.details.contains("Title: Demo\u{FFFD}Agent"))

        let long = String(repeating: "a", count: 500)
        XCTAssertEqual(NiruxURLRequest.displaySafe(long).count, 301)
    }

    // MARK: - Senders

    @MainActor
    func testWorktreeSkillPassesTheLaunchID() {
        let skill = NiruxShellView.worktreeSkillContent
        XCTAssertTrue(skill.contains("launch_query=\"&launch=${NIRUX_LAUNCH_ID}\""))
        XCTAssertTrue(skill.contains("${launch_query}${profile_query}${mission_query}"))
        XCTAssertEqual(NiruxLaunchAuthorization.environmentKey, "NIRUX_LAUNCH_ID")
        XCTAssertEqual(NiruxLaunchAuthorization.queryItemName, "launch")
    }
}
