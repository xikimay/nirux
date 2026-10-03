import XCTest
@testable import Nirux

final class OnboardingChecklistTests: XCTestCase {
    private func workspace(_ id: String) -> PersistedWorkspace {
        PersistedWorkspace(
            id: id, title: id, cwd: "/tmp", columns: [], focusedColumnIndex: 0,
            profileID: nil, isInactive: false
        )
    }

    private func state(
        workspaces: [PersistedWorkspace],
        onboarding: OnboardingChecklistState? = nil,
        sidebarExpanded: Bool? = nil
    ) -> PersistedState {
        PersistedState(
            workspaces: workspaces,
            activeWorkspaceIndex: 0,
            settings: PersistedSettings(sidebarExpanded: sidebarExpanded, onboardingChecklist: onboarding)
        )
    }

    private func checklist(
        claude: Bool = true, codex: Bool = false,
        skills: AgentSkillsStatus = .installed,
        hooksClaude: Bool = true, hooksCodex: Bool = true, installsHooks: Bool = true
    ) -> OnboardingChecklist {
        OnboardingChecklist(
            agents: AgentCLIAvailability(
                claudePath: claude ? "/opt/homebrew/bin/claude" : nil,
                codexPath: codex ? "/opt/homebrew/bin/codex" : nil
            ),
            skills: skills,
            hooks: AgentHooksStatus(claude: hooksClaude, codex: hooksCodex, installsHooks: installsHooks)
        )
    }

    // MARK: - Launch decision

    func testFreshInstallShowsChecklistAndOpensSidebar() {
        XCTAssertEqual(OnboardingChecklist.launchState(persisted: nil), .pending)
        XCTAssertTrue(OnboardingChecklist.shouldExpandSidebarAtLaunch(persisted: nil))
    }

    func testExistingUserWithWorkspacesNeverSeesChecklist() {
        let existing = state(workspaces: [workspace("main"), workspace("feature")])
        XCTAssertNil(OnboardingChecklist.launchState(persisted: existing))
        XCTAssertFalse(OnboardingChecklist.shouldExpandSidebarAtLaunch(persisted: existing))

        let collapsedSidebar = state(workspaces: [workspace("main")], sidebarExpanded: false)
        XCTAssertNil(OnboardingChecklist.launchState(persisted: collapsedSidebar))
    }

    func testUnreadableStateIsNotAFreshInstall() {
        // state.json and every backup exist but none decodes (a newer
        // build's format): the user isn't new, so no card, no forced sidebar.
        XCTAssertNil(OnboardingChecklist.launchState(persisted: nil, hasUnreadableState: true))
        XCTAssertFalse(OnboardingChecklist.shouldExpandSidebarAtLaunch(persisted: nil, hasUnreadableState: true))
    }

    func testStateFileWithoutWorkspacesCountsAsFreshInstall() {
        // Settings saved before the first workspace save (Settings window,
        // Telegram) write a state with no workspaces.
        let settingsOnly = state(workspaces: [])
        XCTAssertEqual(OnboardingChecklist.launchState(persisted: settingsOnly), .pending)
        XCTAssertTrue(OnboardingChecklist.shouldExpandSidebarAtLaunch(persisted: settingsOnly))
    }

    func testSavedStateWinsOverWorkspaceHeuristic() {
        let pending = state(workspaces: [workspace("ws 1")], onboarding: .pending, sidebarExpanded: true)
        XCTAssertEqual(OnboardingChecklist.launchState(persisted: pending), .pending)

        let completed = state(workspaces: [], onboarding: .completed)
        XCTAssertEqual(OnboardingChecklist.launchState(persisted: completed), .completed)
        XCTAssertFalse(OnboardingChecklist.shouldExpandSidebarAtLaunch(persisted: completed))

        let dismissed = state(workspaces: [workspace("ws 1")], onboarding: .dismissed)
        XCTAssertEqual(OnboardingChecklist.launchState(persisted: dismissed), .dismissed)
    }

    func testPendingChecklistKeepsTheUsersSidebarPreference() {
        let collapsed = state(workspaces: [workspace("ws 1")], onboarding: .pending, sidebarExpanded: false)
        XCTAssertEqual(OnboardingChecklist.launchState(persisted: collapsed), .pending)
        XCTAssertFalse(OnboardingChecklist.shouldExpandSidebarAtLaunch(persisted: collapsed))

        let noPreference = state(workspaces: [workspace("ws 1")], onboarding: .pending)
        XCTAssertTrue(OnboardingChecklist.shouldExpandSidebarAtLaunch(persisted: noPreference))
    }

    // MARK: - Persistence

    func testOnboardingStateRoundTripsThroughSettings() throws {
        for value in [OnboardingChecklistState.pending, .completed, .dismissed] {
            let data = try JSONEncoder().encode(PersistedSettings(onboardingChecklist: value))
            XCTAssertEqual(try JSONDecoder().decode(PersistedSettings.self, from: data).onboardingChecklist, value)
        }
    }

    func testLegacySettingsDecodeWithoutOnboardingState() throws {
        let data = Data(#"{"sidebarExpanded": true}"#.utf8)
        let settings = try JSONDecoder().decode(PersistedSettings.self, from: data)
        XCTAssertNil(settings.onboardingChecklist)
        XCTAssertEqual(settings.sidebarExpanded, true)
        let encoded = try XCTUnwrap(String(bytes: try JSONEncoder().encode(settings), encoding: .utf8))
        XCTAssertFalse(encoded.contains("onboardingChecklist"))
    }

    func testUnknownOnboardingStateDoesNotBreakTheStateFile() throws {
        let data = Data(#"{"sidebarExpanded": false, "onboardingChecklist": "snoozed"}"#.utf8)
        var settings = try JSONDecoder().decode(PersistedSettings.self, from: data)
        XCTAssertNil(settings.onboardingChecklist)
        XCTAssertEqual(settings.sidebarExpanded, false)

        // Saved back untouched, so a newer build finds its value again...
        let reencoded = try XCTUnwrap(String(bytes: try JSONEncoder().encode(settings), encoding: .utf8))
        XCTAssertTrue(reencoded.contains(#""onboardingChecklist":"snoozed""#))
        // ...unless this build records its own.
        settings.onboardingChecklist = .dismissed
        let replaced = try XCTUnwrap(String(bytes: try JSONEncoder().encode(settings), encoding: .utf8))
        XCTAssertTrue(replaced.contains(#""onboardingChecklist":"dismissed""#))
    }

    func testSavingNeverAddsTheKeyForExistingUsers() {
        let saved = PersistedSettings(sidebarExpanded: true)
        XCTAssertNil(OnboardingChecklist.settings(saved, recording: nil).onboardingChecklist)
        XCTAssertEqual(OnboardingChecklist.settings(saved, recording: .pending).onboardingChecklist, .pending)

        let closed = PersistedSettings(onboardingChecklist: .completed)
        XCTAssertEqual(OnboardingChecklist.settings(closed, recording: nil).onboardingChecklist, .completed)
        XCTAssertEqual(OnboardingChecklist.settings(closed, recording: .pending).onboardingChecklist, .pending)
    }

    // MARK: - Completion

    func testCompletionNeedsAnAgentAndCurrentSkills() {
        XCTAssertTrue(checklist().isComplete)
        XCTAssertTrue(checklist(claude: false, codex: true).isComplete)
        XCTAssertFalse(checklist(claude: false, codex: false).isComplete)
        XCTAssertFalse(checklist(skills: .missing).isComplete)
        XCTAssertFalse(checklist(skills: .outdated).isComplete)
        // Hooks never hold completion back: the user can't act on them here.
        XCTAssertTrue(checklist(hooksClaude: false, hooksCodex: false, installsHooks: false).isComplete)
    }

    func testClosingRecordsCompletedOrDismissed() {
        XCTAssertEqual(checklist().closedState, .completed)
        XCTAssertEqual(checklist(skills: .missing).closedState, .dismissed)
        XCTAssertEqual(checklist(claude: false).closedState, .dismissed)
    }

    // MARK: - Rows

    func testMissingAgentsOfferInstallCommandsAndRecheck() {
        let row = checklist(claude: false, codex: false).agentRow
        XCTAssertEqual(row.mark, .todo)
        XCTAssertTrue(row.detail?.contains("close this if you already have it") == true)
        XCTAssertEqual(row.controls, [
            .copyCommand("curl -fsSL https://claude.ai/install.sh | bash"),
            .copyCommand("brew install --cask codex"),
            .link("Claude Code ↗", OnboardingChecklist.claudeProjectURL),
            .link("Codex ↗", OnboardingChecklist.codexProjectURL),
            .action("Check again", .checkAgain)
        ])
    }

    func testFoundAgentsNameWhatWasFound() {
        XCTAssertEqual(checklist(claude: true, codex: false).agentRow.title, "Claude Code found")
        XCTAssertEqual(checklist(claude: false, codex: true).agentRow.title, "Codex found")
        XCTAssertEqual(checklist(claude: true, codex: true).agentRow.title, "Claude Code and Codex found")
        // Where it was found, since the lookup can't run shell startup files.
        XCTAssertTrue(checklist(claude: true).agentRow.detail?.hasPrefix("At /opt/homebrew/bin/claude.") == true)
        XCTAssertTrue(checklist(claude: false, codex: true).agentRow.detail?.hasPrefix("At /opt/homebrew/bin/codex.") == true)
        for row in [checklist(claude: true).agentRow, checklist(claude: false, codex: true).agentRow] {
            XCTAssertEqual(row.mark, .done)
            XCTAssertTrue(row.controls.isEmpty)
        }
    }

    func testSkillsRowOffersInstallOrUpdate() {
        XCTAssertEqual(checklist(skills: .missing).skillsRow.controls, [.button("Install", .installSkills)])
        XCTAssertEqual(checklist(skills: .outdated).skillsRow.controls, [.button("Update", .installSkills)])
        XCTAssertTrue(checklist(skills: .outdated).skillsRow.detail?.contains("Update replaces them") == true)
        let installed = checklist(skills: .installed).skillsRow
        XCTAssertEqual(installed.mark, .done)
        XCTAssertTrue(installed.controls.isEmpty)
    }

    func testHooksRowExplainsWhatIsWrittenAndLinksTheReadme() {
        let learnMore = OnboardingChecklistRow.Control.link(
            "How status hooks work ↗", OnboardingChecklist.hooksDocumentationURL
        )
        let installed = checklist().hooksRow
        XCTAssertEqual(installed.mark, .done)
        XCTAssertEqual(installed.title, "Status hooks installed")
        XCTAssertTrue(installed.detail?.contains("~/.claude/settings.json") == true)
        XCTAssertTrue(installed.detail?.contains("~/.codex/config.toml") == true)
        XCTAssertEqual(installed.controls, [learnMore])

        XCTAssertEqual(checklist(hooksCodex: false).hooksRow.title, "Status hooks installed for Claude Code")
        XCTAssertEqual(checklist(hooksClaude: false).hooksRow.title, "Status hooks installed for Codex")

        let failed = checklist(hooksClaude: false, hooksCodex: false).hooksRow
        XCTAssertEqual(failed.mark, .off)
        XCTAssertEqual(failed.title, "Status hooks not installed")

        let devBuild = checklist(hooksClaude: false, hooksCodex: false, installsHooks: false).hooksRow
        XCTAssertEqual(devBuild.title, "Status hooks off in this build")
        XCTAssertTrue(devBuild.detail?.contains("NIRUX_SKIP_HOOK_INSTALL") == true)
        XCTAssertEqual(devBuild.controls, [learnMore])
    }

    func testShortcutsUseAppVocabulary() {
        XCTAssertEqual(OnboardingChecklist.shortcuts.map(\.key), ["⌘P", "⌘T", "⌘N"])
        XCTAssertEqual(OnboardingChecklist.shortcuts.map(\.label), ["palette", "column", "workspace"])
    }

    @MainActor
    func testSidebarHintSaysColumnNotPane() {
        XCTAssertEqual(SidebarView.shortcutHints.map(\.label), ["workspace", "column"])
        XCTAssertEqual(SidebarView.shortcutHints.map(\.key), ["⌘N", "⌘T"])
    }
}
