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

    func testHandoverSourceRules() {
        XCTAssertTrue(HandoverFile.isAllowedSourcePath("/tmp/nirux-handover-claude-x.md"))
        XCTAssertTrue(HandoverFile.isAllowedSourcePath("/private/tmp/nirux-handover-codex-Ab12Cd"))
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
            XCTAssertFalse(HandoverFile.isAllowedSourcePath(rejected), rejected)
        }
    }

    func testDisallowedHandoverKeepsTheRequestButIsAnnounced() throws {
        let request = try XCTUnwrap(parse(
            "nirux://new-worktree?branch=x&repo=/r&agent=claude&handover=%2FUsers%2Fme%2F.ssh%2Fid_ed25519"
        ))
        XCTAssertEqual(worktree("nirux://new-worktree?branch=x&repo=/r&handover=/etc/hosts")?.handoverPath, "/etc/hosts")
        let text = try XCTUnwrap(request.confirmation(claudeMode: .auto, codexMode: .fullAuto))
        XCTAssertTrue(text.details.contains("/Users/me/.ssh/id_ed25519 — will be ignored"))
    }

    // MARK: - Gate

    func testActionsRunOnlyWithTheLaunchIDOtherwiseConfirm() throws {
        let expected = "abc123"
        for url in [
            "nirux://new-workspace?cwd=/tmp",
            "nirux://new-workspace",
            "nirux://new-worktree?branch=x&repo=/r"
        ] {
            let withID = try XCTUnwrap(parse(url + (url.contains("?") ? "&" : "?") + "launch=abc123"))
            XCTAssertEqual(withID.disposition(expectedLaunchID: expected), .perform, url)
            let wrongID = try XCTUnwrap(parse(url + (url.contains("?") ? "&" : "?") + "launch=abc124"))
            XCTAssertEqual(wrongID.disposition(expectedLaunchID: expected), .confirm, url)
            let noID = try XCTUnwrap(parse(url))
            XCTAssertEqual(noID.disposition(expectedLaunchID: expected), .confirm, url)
        }
    }

    func testFirstLaunchParameterWins() throws {
        let request = try XCTUnwrap(parse("nirux://new-workspace?launch=wrong&launch=abc123"))
        XCTAssertEqual(request.disposition(expectedLaunchID: "abc123"), .confirm)
    }

    func testOpenEditorIsRoutedWithoutConfirmation() {
        let request = parse("nirux://open-editor?file=/tmp/a.swift")
        XCTAssertEqual(request?.action, .openEditor)
        XCTAssertEqual(request?.disposition(expectedLaunchID: "abc123"), .openEditor)
        XCTAssertEqual(request?.hasValidLaunchID(expected: "abc123"), false)
        XCTAssertEqual(parse("nirux://open-editor?file=/tmp/a.swift&launch=abc123")?.hasValidLaunchID(expected: "abc123"), true)
    }

    // MARK: - Path resolution

    func testResolvingPathsUsesTheRealFolderAndRejectsMissingOnes() throws {
        let request = try XCTUnwrap(parse("nirux://new-workspace?cwd=/link/./x&launch=id"))
        let resolved = request.resolvingPaths(
            realPath: { $0 == "/link/./x" ? "/real/x" : nil },
            isDirectory: { $0 == "/real/x" }
        )
        XCTAssertEqual(resolved?.action, .newWorkspace(cwd: "/real/x", title: nil, agent: nil))
        XCTAssertEqual(resolved?.launchID, "id")

        XCTAssertNil(request.resolvingPaths(realPath: { _ in nil }, isDirectory: { _ in true }))
        XCTAssertNil(request.resolvingPaths(realPath: { $0 }, isDirectory: { _ in false }))

        let noCwd = try XCTUnwrap(parse("nirux://new-workspace"))
        XCTAssertEqual(noCwd.resolvingPaths(realPath: { _ in nil }, isDirectory: { _ in false }), noCwd)
    }

    func testResolvingPathsCollapsesPaddingOnTheRealFileSystem() throws {
        let base = try XCTUnwrap(FileManager.default.temporaryDirectory.path.realPath)
        let padded = base + String(repeating: "/.", count: 150)
        let request = try XCTUnwrap(parse("nirux://new-worktree?branch=x&repo=\(padded)"))
        guard case .newWorktree(let resolved)? = request.resolvingPaths()?.action else {
            return XCTFail("padded path should resolve")
        }
        XCTAssertEqual(resolved.repo, base)
        XCTAssertNil(try XCTUnwrap(parse("nirux://new-workspace?cwd=/nonexistent-\(UUID().uuidString)")).resolvingPaths())
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

    func testConfirmationExplainsMissingVersusExpiredLaunchID() throws {
        let missing = try XCTUnwrap(parse("nirux://new-workspace?cwd=/tmp")?.confirmation(claudeMode: .auto, codexMode: .default))
        XCTAssertTrue(missing.details.contains("outdated Nirux skill"))
        XCTAssertTrue(missing.details.contains("Install Agent Skills"))
        let expired = try XCTUnwrap(parse("nirux://new-workspace?cwd=/tmp&launch=old")?
            .confirmation(claudeMode: .auto, codexMode: .default))
        XCTAssertTrue(expired.details.contains("expired Nirux launch ID"))
    }

    func testWorktreeWithoutAgentDoesNotClaimAnAgentFollowsTheHandover() throws {
        let text = try XCTUnwrap(parse(
            "nirux://new-worktree?branch=x&repo=/r&handover=/tmp/nirux-handover-claude-Ab12Cd"
        )?.confirmation(claudeMode: .auto, codexMode: .default))
        XCTAssertEqual(text.message, "Create a worktree?")
        XCTAssertTrue(text.details.contains("Agent: none (plain shell)"))
        XCTAssertFalse(text.details.contains("the agent is told"))
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

    func testDisplaySafeNeutralizesUnicodeLineBreaksAndSpaces() {
        XCTAssertEqual(NiruxURLRequest.displaySafe("a\u{2028}b\u{2029}c\u{85}d"), "a\u{FFFD}b\u{FFFD}c\u{FFFD}d")
        XCTAssertEqual(NiruxURLRequest.displaySafe("a\u{202E}b\u{200B}c"), "a\u{FFFD}b\u{FFFD}c")
        XCTAssertEqual(NiruxURLRequest.displaySafe("a\u{00A0}b\u{3000}c"), "a b c")
    }

    func testDisplaySafeKeepsBothEndsOfLongValues() {
        let value = "/Users/me/trusted" + String(repeating: "x", count: 400) + "/Downloads/evil"
        let shown = NiruxURLRequest.displaySafe(value, limit: 100)
        XCTAssertTrue(shown.hasPrefix("/Users/me/trusted"))
        XCTAssertTrue(shown.hasSuffix("/Downloads/evil"))
        XCTAssertTrue(shown.contains("…"))
        XCTAssertEqual(shown.count, 101)
    }

    // MARK: - Confirmation queue

    func testConfirmationQueueIsBoundedSerialAndCoolsDownAfterCancel() throws {
        let request = try XCTUnwrap(parse("nirux://new-workspace"))
        var queue = URLConfirmationQueue()
        for _ in 0..<URLConfirmationQueue.capacity {
            XCTAssertTrue(queue.enqueue(request, now: 0))
        }
        XCTAssertFalse(queue.enqueue(request, now: 0), "bounded")

        XCTAssertNotNil(queue.startNext())
        XCTAssertNil(queue.startNext(), "one sheet at a time")
        queue.finish(confirmed: false, now: 10)
        XCTAssertFalse(queue.enqueue(request, now: 12), "cooling down after a Cancel")
        XCTAssertNotNil(queue.startNext(), "already-queued requests still get asked")
        queue.finish(confirmed: true, now: 20)
        XCTAssertTrue(queue.enqueue(request, now: 10 + URLConfirmationQueue.cooldown))
    }

    // MARK: - Senders

    @MainActor
    func testSkillsPassTheLaunchIDAndCreateHandoversWithMktemp() {
        let worktree = NiruxShellView.worktreeSkillContent
        XCTAssertTrue(worktree.contains("launch_query=\"&launch=${NIRUX_LAUNCH_ID}\""))
        XCTAssertTrue(worktree.contains("${launch_query}${profile_query}${mission_query}"))
        XCTAssertTrue(worktree.contains("mktemp /tmp/nirux-handover-<agent>-XXXXXX"))
        XCTAssertFalse(worktree.contains("cat > /tmp/"), "never write to a guessable /tmp name")
        XCTAssertTrue(NiruxShellView.showCodeSkillContent.contains("&launch=${NIRUX_LAUNCH_ID:-}"))
    }

    func testInAppWorktreeURLIsAcceptedOnceTheShellExpandsTheLaunchID() throws {
        let branch = "feat/a&agent=codex+x$(touch${IFS}/tmp/pwn)`id`\"'"
        let sent = NiruxURLRequest.NewWorktree(
            branch: branch,
            repo: "/Users/me/My Repo",
            agent: .claude,
            handoverPath: "/tmp/nirux-handover-claude-1234.md",
            parentWorkspaceID: "W",
            parentAgentUUID: "A"
        )
        let raw = NiruxShellView.inAppWorktreeURL(for: sent, profileID: "p 1")
        // Inert inside `open "…"`: the only shell syntax left is the launch placeholder.
        let placeholder = "${NIRUX_LAUNCH_ID}"
        XCTAssertTrue(raw.hasSuffix("&launch=" + placeholder))
        let body = raw.replacingOccurrences(of: placeholder, with: "")
        for character in ["$", "`", "\"", "\\", "'", "(", ")", ";", " "] {
            XCTAssertFalse(body.contains(character), character)
        }

        let expanded = raw.replacingOccurrences(of: placeholder, with: "abc123")
        let request = try XCTUnwrap(NiruxURLRequest(url: try XCTUnwrap(URL(string: expanded))))
        XCTAssertEqual(request.disposition(expectedLaunchID: "abc123"), .perform)
        XCTAssertEqual(request.profileID, "p 1")
        XCTAssertEqual(request.action, .newWorktree(sent))
    }

    func testAgentIsOnlyToldToReadAHandoverThisRequestDelivered() {
        XCTAssertNil(NiruxShellView.agentStartupPrompt(agent: .claude, deliveredHandover: false, isMission: false))
        let prompt = NiruxShellView.agentStartupPrompt(agent: .codex, deliveredHandover: true, isMission: false)
        XCTAssertEqual(prompt, "Read .codex-handover.md for full context, then proceed with the next steps described there.")
        let mission = NiruxShellView.agentStartupPrompt(agent: .claude, deliveredHandover: false, isMission: true)
        XCTAssertFalse(mission?.contains("handover") ?? true)
    }
}
