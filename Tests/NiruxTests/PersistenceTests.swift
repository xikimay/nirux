import XCTest
@testable import Nirux

/// Smoke tests for the Codable types backing Persistence. The actual
/// file I/O is tied to ~/Library/Application Support/nirux so we exercise
/// the encode/decode round-trip directly instead of routing through the
/// on-disk store.
final class PersistedStateCodingTests: XCTestCase {

    func testPersistedStateRoundTripsThroughJSON() throws {
        let original = PersistedState(
            workspaces: [
                PersistedWorkspace(
                    id: "workspace-main",
                    title: "main",
                    cwd: "/tmp/project",
                    columns: [
                        PersistedColumn(
                            widthPreset: 0.5, cwd: "/tmp/project",
                            columnType: .terminal, webViewURL: nil,
                            claudeLaunchMode: nil, codexLaunchMode: nil
                        ),
                        PersistedColumn(
                            widthPreset: 0.5, cwd: "/tmp/project",
                            columnType: .claudeCode, webViewURL: nil,
                            claudeLaunchMode: .skipPermissions, codexLaunchMode: nil
                        ),
                        PersistedColumn(
                            widthPreset: 0.5, cwd: "/tmp/project",
                            columnType: .codex, webViewURL: nil,
                            claudeLaunchMode: nil, codexLaunchMode: .fullAuto,
                            codexSessionID: "01999999-1111-7222-8333-444444444444"
                        )
                    ],
                    focusedColumnIndex: 1
                )
            ],
            activeWorkspaceIndex: 0,
            settings: PersistedSettings(
                claudeLaunchMode: .acceptEdits,
                claudeNoFlicker: false,
                codexLaunchMode: .readOnly
            ),
            activeWorkspaceID: "workspace-main"
        )

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(PersistedState.self, from: data)

        XCTAssertEqual(decoded.workspaces.count, 1)
        XCTAssertEqual(decoded.workspaces[0].id, "workspace-main")
        XCTAssertEqual(decoded.workspaces[0].title, "main")
        XCTAssertEqual(decoded.workspaces[0].focusedColumnIndex, 1)
        XCTAssertEqual(decoded.workspaces[0].columns.count, 3)
        XCTAssertEqual(decoded.workspaces[0].columns[1].columnType, .claudeCode)
        XCTAssertEqual(decoded.workspaces[0].columns[1].claudeLaunchMode, .skipPermissions)
        XCTAssertEqual(decoded.workspaces[0].columns[2].codexLaunchMode, .fullAuto)
        XCTAssertEqual(
            decoded.workspaces[0].columns[2].codexSessionID,
            "01999999-1111-7222-8333-444444444444"
        )
        XCTAssertEqual(decoded.settings?.claudeLaunchMode, .acceptEdits)
        XCTAssertEqual(decoded.settings?.codexLaunchMode, .readOnly)
        XCTAssertEqual(decoded.settings?.claudeNoFlicker, false)
        XCTAssertEqual(decoded.activeWorkspaceID, "workspace-main")
    }

    func testWorkspaceProfileStateRoundTripsThroughJSON() throws {
        let profile = WorkspaceProfile(id: "repo-a", name: "repo-a", colorHex: "#9ECE6A")
        let original = PersistedState(
            workspaces: [
                PersistedWorkspace(
                    id: "workspace-feature",
                    title: "feature",
                    cwd: "/tmp/repo-a",
                    columns: [
                        PersistedColumn(
                            widthPreset: 0.5, cwd: "/tmp/repo-a",
                            columnType: .terminal, webViewURL: nil,
                            claudeLaunchMode: nil, codexLaunchMode: nil
                        )
                    ],
                    focusedColumnIndex: 0,
                    profileID: profile.id,
                    isInactive: true
                )
            ],
            activeWorkspaceIndex: 0,
            settings: nil,
            workspaceProfiles: [WorkspaceProfile.defaultProfile, profile],
            activeProfileID: profile.id,
            activeWorkspaceID: "workspace-feature"
        )

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(PersistedState.self, from: data)

        XCTAssertEqual(decoded.workspaceProfiles, [WorkspaceProfile.defaultProfile, profile])
        XCTAssertEqual(decoded.activeProfileID, profile.id)
        XCTAssertEqual(decoded.activeWorkspaceID, "workspace-feature")
        XCTAssertEqual(decoded.workspaces[0].id, "workspace-feature")
        XCTAssertEqual(decoded.workspaces[0].profileID, profile.id)
        XCTAssertEqual(decoded.workspaces[0].isInactive, true)
    }

    func testLegacyWorkspaceWithoutProfileFieldsDecodesAsActiveDefaultProfile() throws {
        let json = Data("""
        {
          "title": "main",
          "cwd": "/tmp/project",
          "columns": [
            {
              "widthPreset": 0.5,
              "cwd": "/tmp/project",
              "columnType": "terminal",
              "webViewURL": null
            }
          ],
          "focusedColumnIndex": 0
        }
        """.utf8)

        let decoded = try JSONDecoder().decode(PersistedWorkspace.self, from: json)

        XCTAssertNil(decoded.id)
        XCTAssertNil(decoded.profileID)
        XCTAssertEqual(decoded.isInactive, false)
    }

    @MainActor
    func testWorkspaceStoreKeepsActiveWorkspaceByIDWhenReordered() {
        let store = WorkspaceStore()
        let first = WorkspaceState(id: "first", title: "first", cwd: "/tmp/first")
        let second = WorkspaceState(id: "second", title: "second", cwd: "/tmp/second")

        store.appendWorkspace(first)
        store.appendWorkspace(second)
        XCTAssertEqual(store.activeWorkspace?.id, "second")

        XCTAssertTrue(store.moveWorkspace(at: 1, delta: -1))

        XCTAssertEqual(store.activeWorkspace?.id, "second")
        XCTAssertEqual(store.activeWorkspaceIndex, 0)
    }

    @MainActor
    func testWorkspaceStoreGroupsActiveBeforeInactiveWithinProfile() {
        let store = WorkspaceStore()
        let profile = WorkspaceProfile(id: "repo", name: "repo", colorHex: "#9ECE6A")
        store.replaceProfiles([WorkspaceProfile.defaultProfile, profile], activeProfileID: profile.id)

        let active = WorkspaceState(id: "active", title: "active", cwd: "/tmp/active")
        active.profileID = profile.id
        let inactive = WorkspaceState(id: "inactive", title: "inactive", cwd: "/tmp/inactive")
        inactive.profileID = profile.id
        inactive.isInactive = true

        store.appendWorkspace(inactive, activate: false)
        store.appendWorkspace(active, activate: false)
        store.selectProfile(profile.id)

        XCTAssertEqual(store.visibleWorkspaceIndices.map { store.workspaces[$0].id }, ["active", "inactive"])
    }

    @MainActor
    func testWorkspaceStoreDoesNotNavigateToEmptyProfiles() {
        let store = WorkspaceStore()
        let empty = WorkspaceProfile(id: "empty", name: "empty", colorHex: "#E0AF68")
        store.replaceProfiles([WorkspaceProfile.defaultProfile, empty], activeProfileID: empty.id)

        let workspace = WorkspaceState(id: "main", title: "main", cwd: "/tmp/main")
        workspace.profileID = WorkspaceProfile.defaultID
        store.appendWorkspace(workspace)

        XCTAssertEqual(store.navigableProfiles.map(\.id), [WorkspaceProfile.defaultID])
        XCTAssertFalse(store.selectProfile(empty.id))
        XCTAssertEqual(store.activeProfileID, WorkspaceProfile.defaultID)
        XCTAssertEqual(store.visibleWorkspaceIndices.map { store.workspaces[$0].id }, ["main"])
    }

    @MainActor
    func testWorkspaceStoreResolvesExplicitTargetProfile() {
        let store = WorkspaceStore()
        let first = WorkspaceProfile(id: "first", name: "first", colorHex: "#9ECE6A")
        let second = WorkspaceProfile(id: "second", name: "second", colorHex: "#E0AF68")
        store.replaceProfiles([WorkspaceProfile.defaultProfile, first, second], activeProfileID: first.id)

        let workspace = WorkspaceState(id: "main", title: "main", cwd: "/tmp/main", profileID: first.id)
        store.appendWorkspace(workspace)

        XCTAssertEqual(store.activeProfileID, first.id)
        XCTAssertEqual(store.targetProfileID(for: second.id), second.id)
        XCTAssertEqual(store.targetProfileID(for: "missing"), first.id)
        XCTAssertEqual(store.targetProfileID(for: "   "), first.id)
        XCTAssertEqual(store.targetProfileID(for: nil), first.id)
    }

    @MainActor
    func testWorkspaceStoreRenamesProfilesUniquely() {
        let store = WorkspaceStore()
        let profile = WorkspaceProfile(id: "repo", name: "repo", colorHex: "#9ECE6A")
        store.replaceProfiles([WorkspaceProfile.defaultProfile, profile], activeProfileID: profile.id)

        XCTAssertTrue(store.renameProfile(id: profile.id, to: " main "))
        XCTAssertEqual(store.profiles.first { $0.id == profile.id }?.name, "main 2")

        XCTAssertTrue(store.renameProfile(id: profile.id, to: "main 2"))
        XCTAssertEqual(store.profiles.first { $0.id == profile.id }?.name, "main 2")
    }

    @MainActor
    func testWorkspaceStoreRejectsBlankProfileRename() {
        let store = WorkspaceStore()
        let profile = WorkspaceProfile(id: "repo", name: "repo", colorHex: "#9ECE6A")
        store.replaceProfiles([WorkspaceProfile.defaultProfile, profile], activeProfileID: profile.id)

        XCTAssertFalse(store.renameProfile(id: profile.id, to: "   "))
        XCTAssertEqual(store.profiles.first { $0.id == profile.id }?.name, "repo")
    }

    func testResolvedTypeFallsBackToTerminalWhenNil() {
        let missing = PersistedColumn(
            widthPreset: 0.5, cwd: "/tmp",
            columnType: nil, webViewURL: nil,
            claudeLaunchMode: nil, codexLaunchMode: nil
        )
        XCTAssertEqual(missing.resolvedType, .terminal)
    }

    func testColumnKindRawValuesMatchOnDiskFormat() {
        XCTAssertEqual(ColumnKind.terminal.rawValue, "terminal")
        XCTAssertEqual(ColumnKind.webView.rawValue, "webView")
        XCTAssertEqual(ColumnKind.claudeCode.rawValue, "claudeCode")
        XCTAssertEqual(ColumnKind.codex.rawValue, "codex")
    }

    /// State files written by older builds (or hand-edited) might contain
    /// a `columnType` string this build doesn't recognize. Decode must
    /// succeed and fall back to `.terminal` rather than throwing.
    func testPersistedColumnDecodesUnknownColumnTypeAsTerminal() throws {
        let json = Data("""
        {
          "widthPreset": 0.5,
          "cwd": "/tmp",
          "columnType": "somethingNew",
          "webViewURL": null
        }
        """.utf8)

        let decoded = try JSONDecoder().decode(PersistedColumn.self, from: json)
        XCTAssertNil(decoded.columnType)
        XCTAssertEqual(decoded.resolvedType, .terminal)
    }

    // MARK: - Legacy migration

    /// Old state.json format: `claudeBypassPermissions: true` was emitted as
    /// `--dangerously-skip-permissions`, so it must decode to `.skipPermissions`
    /// (the more aggressive bypass), not the milder `.bypassPermissions`.
    func testLegacyClaudeBypassPermissionsTrueMigratesToSkipPermissions() throws {
        let settingsJSON = Data("""
        { "claudeBypassPermissions": true, "claudeNoFlicker": true }
        """.utf8)
        let settings = try JSONDecoder().decode(PersistedSettings.self, from: settingsJSON)
        XCTAssertEqual(settings.claudeLaunchMode, .skipPermissions)

        let columnJSON = Data("""
        {
          "widthPreset": 0.5,
          "cwd": "/tmp",
          "columnType": "claudeCode",
          "claudeBypassPermissions": true
        }
        """.utf8)
        let column = try JSONDecoder().decode(PersistedColumn.self, from: columnJSON)
        XCTAssertEqual(column.claudeLaunchMode, .skipPermissions)
    }

    func testLegacyClaudeBypassPermissionsFalseMigratesToDefault() throws {
        let json = Data("""
        { "claudeBypassPermissions": false }
        """.utf8)
        let settings = try JSONDecoder().decode(PersistedSettings.self, from: json)
        XCTAssertEqual(settings.claudeLaunchMode, .default)
    }

    // MARK: - Sidebar state

    func testSidebarExpandedRoundTripsThroughSettings() throws {
        let original = PersistedSettings(
            sidebarExpanded: true,
            inactiveWorkspacesCollapsed: false
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(original)
        let decoded = try JSONDecoder().decode(PersistedSettings.self, from: data)
        XCTAssertEqual(decoded.sidebarExpanded, true)
        XCTAssertEqual(decoded.inactiveWorkspacesCollapsed, false)
        // Other fields keep their defaults.
        XCTAssertEqual(decoded.claudeNoFlicker, true)
        XCTAssertNil(decoded.claudeLaunchMode)

        if let evidenceDirectory = ProcessInfo.processInfo.environment["NO_MISTAKES_EVIDENCE_DIR"],
           !evidenceDirectory.isEmpty {
            let directoryURL = URL(fileURLWithPath: evidenceDirectory, isDirectory: true)
            try FileManager.default.createDirectory(
                at: directoryURL,
                withIntermediateDirectories: true
            )
            try data.write(
                to: directoryURL.appendingPathComponent("persisted-sidebar-settings.json"),
                options: .atomic
            )
        }
    }

    func testSettingsWithoutSidebarFieldDecodeToNil() throws {
        // States written before sidebar persistence existed have no key.
        let json = Data("""
        { "claudeLaunchMode": "plan", "claudeNoFlicker": false }
        """.utf8)
        let settings = try JSONDecoder().decode(PersistedSettings.self, from: json)
        XCTAssertNil(settings.sidebarExpanded)
        XCTAssertNil(settings.inactiveWorkspacesCollapsed)
        XCTAssertEqual(settings.claudeLaunchMode, .plan)
        XCTAssertEqual(settings.claudeNoFlicker, false)
    }

    // MARK: - cliArgs wire format

    /// Lock down the CLI flag mapping so a future rename in the enum doesn't
    /// silently change what we send to the `claude` subprocess.
    func testClaudeLaunchModeCLIArgs() {
        XCTAssertEqual(ClaudeLaunchMode.default.cliArgs, [])
        XCTAssertEqual(ClaudeLaunchMode.acceptEdits.cliArgs, ["--permission-mode", "acceptEdits"])
        XCTAssertEqual(ClaudeLaunchMode.auto.cliArgs, ["--permission-mode", "auto"])
        XCTAssertEqual(ClaudeLaunchMode.plan.cliArgs, ["--permission-mode", "plan"])
        XCTAssertEqual(ClaudeLaunchMode.dontAsk.cliArgs, ["--permission-mode", "dontAsk"])
        XCTAssertEqual(ClaudeLaunchMode.bypassPermissions.cliArgs, ["--permission-mode", "bypassPermissions"])
        XCTAssertEqual(ClaudeLaunchMode.skipPermissions.cliArgs, ["--dangerously-skip-permissions"])
    }

    func testCodexLaunchModeCLIArgs() {
        XCTAssertEqual(CodexLaunchMode.default.cliArgs, [])
        XCTAssertEqual(CodexLaunchMode.fullAccess.cliArgs, ["--sandbox", "danger-full-access"])
        XCTAssertEqual(CodexLaunchMode.workspaceWrite.cliArgs, ["--sandbox", "workspace-write", "--ask-for-approval", "on-request"])
        XCTAssertEqual(CodexLaunchMode.readOnly.cliArgs, ["--sandbox", "read-only"])
        XCTAssertEqual(CodexLaunchMode.fullAuto.cliArgs, ["--sandbox", "danger-full-access", "--ask-for-approval", "never", "--search"])
        XCTAssertEqual(CodexLaunchMode.bypass.cliArgs, ["--dangerously-bypass-approvals-and-sandbox"])
    }

    @MainActor
    func testCodexRestoreCommandsNeverGuessTheLastSession() {
        let first = NiruxShellView.codexCommand(
            resume: .session("01999999-1111-7222-8333-444444444444"),
            mode: .default
        )
        let second = NiruxShellView.codexCommand(
            resume: .session("01999999-5555-7666-8777-888888888888"),
            mode: .readOnly
        )
        let legacy = NiruxShellView.codexCommand(resume: .picker, mode: .default)

        XCTAssertEqual(first, "command codex resume '01999999-1111-7222-8333-444444444444'")
        XCTAssertEqual(
            second,
            "command codex resume '01999999-5555-7666-8777-888888888888' --sandbox read-only"
        )
        XCTAssertEqual(legacy, "command codex resume")
        XCTAssertFalse(first.contains("--last"))
        XCTAssertFalse(second.contains("--last"))
        XCTAssertFalse(legacy.contains("--last"))
    }

    @MainActor
    func testCodexRestoreClaimsEachExactSessionOnlyOnce() {
        var claimed = Set<String>()

        XCTAssertEqual(
            NiruxShellView.codexRestoreTarget(sessionID: "thread-a", claimedSessionIDs: &claimed),
            .session("thread-a")
        )
        XCTAssertEqual(
            NiruxShellView.codexRestoreTarget(sessionID: "thread-b", claimedSessionIDs: &claimed),
            .session("thread-b")
        )
        XCTAssertEqual(
            NiruxShellView.codexRestoreTarget(sessionID: "thread-a", claimedSessionIDs: &claimed),
            .picker
        )
        XCTAssertEqual(
            NiruxShellView.codexRestoreTarget(sessionID: nil, claimedSessionIDs: &claimed),
            .picker
        )
        XCTAssertEqual(
            NiruxShellView.codexRestoreTarget(sessionID: "", claimedSessionIDs: &claimed),
            .picker
        )
    }
}
