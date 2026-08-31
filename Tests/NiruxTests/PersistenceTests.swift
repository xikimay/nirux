import XCTest
@testable import Nirux

/// Smoke tests for the Codable types backing Persistence. The actual
/// file I/O is tied to ~/Library/Application Support/nirux so we exercise
/// the encode/decode round-trip directly instead of routing through the
/// on-disk store.
final class PersistedStateCodingTests: XCTestCase {

    func testPersistenceSaveReportsWriteFailure() throws {
        let invalidDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("nirux-persistence-\(UUID().uuidString)")
        try Data("not a directory".utf8).write(to: invalidDirectory)
        let previousDirectory = ProcessInfo.processInfo.environment["NIRUX_STATE_DIR"]
        setenv("NIRUX_STATE_DIR", invalidDirectory.path, 1)
        defer {
            if let previousDirectory {
                setenv("NIRUX_STATE_DIR", previousDirectory, 1)
            } else {
                unsetenv("NIRUX_STATE_DIR")
            }
            try? FileManager.default.removeItem(at: invalidDirectory)
        }

        let state = PersistedState(workspaces: [], activeWorkspaceIndex: 0)

        XCTAssertFalse(Persistence.save(state))
    }

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
        XCTAssertEqual(decoded.settings?.missionHandoffsEnabled, false)
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
        XCTAssertFalse(settings.missionHandoffsEnabled)
    }

    func testMissionHandoffSettingAndWorkspaceLinkRoundTrip() throws {
        let settings = PersistedSettings(missionHandoffsEnabled: true)
        let decodedSettings = try JSONDecoder().decode(
            PersistedSettings.self,
            from: JSONEncoder().encode(settings)
        )
        XCTAssertTrue(decodedSettings.missionHandoffsEnabled)

        let missionID = "11111111-1111-4111-8111-111111111111"
        let workspace = PersistedWorkspace(
            title: "child",
            cwd: "/tmp/child",
            columns: [],
            focusedColumnIndex: 0,
            missionID: missionID
        )
        let decodedWorkspace = try JSONDecoder().decode(
            PersistedWorkspace.self,
            from: JSONEncoder().encode(workspace)
        )
        XCTAssertEqual(decodedWorkspace.missionID, missionID)
    }
}

extension PersistedStateCodingTests {
    func testTelegramRemoteAccessSettingsRoundTripWithoutToken() throws {
        let original = PersistedSettings(
            telegramRemoteAccessEnabled: true,
            telegramPairedUserID: 123_456,
            telegramPairedChatID: 654_321,
            telegramNotifyOnCompletion: false,
            telegramNotifyOnAttention: true,
            telegramLastUpdateID: 88
        )
        let data = try JSONEncoder().encode(original)
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))
        let decoded = try JSONDecoder().decode(PersistedSettings.self, from: data)

        XCTAssertTrue(decoded.telegramRemoteAccessEnabled)
        XCTAssertEqual(decoded.telegramPairedUserID, 123_456)
        XCTAssertEqual(decoded.telegramPairedChatID, 654_321)
        XCTAssertFalse(decoded.telegramNotifyOnCompletion)
        XCTAssertTrue(decoded.telegramNotifyOnAttention)
        XCTAssertEqual(decoded.telegramLastUpdateID, 88)
        XCTAssertFalse(json.localizedCaseInsensitiveContains("token"))
    }

    func testLegacySettingsDefaultTelegramRemoteAccessOff() throws {
        let json = Data("""
        { "claudeLaunchMode": "plan", "claudeNoFlicker": true }
        """.utf8)
        let settings = try JSONDecoder().decode(PersistedSettings.self, from: json)
        XCTAssertFalse(settings.telegramRemoteAccessEnabled)
        XCTAssertNil(settings.telegramPairedUserID)
        XCTAssertNil(settings.telegramPairedChatID)
        XCTAssertTrue(settings.telegramNotifyOnCompletion)
        XCTAssertTrue(settings.telegramNotifyOnAttention)
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

    func testCodexLaunchModesRoundTripThroughArguments() {
        for mode in CodexLaunchMode.allCases where mode != .default {
            XCTAssertEqual(
                CodexLaunchMode.detect(arguments: ["codex"] + mode.cliArgs),
                mode
            )
        }
        XCTAssertNil(CodexLaunchMode.detect(arguments: ["codex"]))
        XCTAssertEqual(
            CodexLaunchMode.detect(arguments: [
                "codex", "--sandbox", "danger-full-access",
                "--ask-for-approval", "never"
            ]),
            .fullAccess
        )
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

    func testCodexSessionTrackerInvalidatesReplacementBeforeQuit() {
        let first = ForegroundProcess(
            instance: ProcessInstance(pid: 101, startedAt: 100),
            name: "codex",
            arguments: ["codex"]
        )
        let second = ForegroundProcess(
            instance: ProcessInstance(pid: 101, startedAt: 120),
            name: "codex",
            arguments: ["codex"]
        )
        var tracker = CodexSessionTracker()

        XCTAssertTrue(tracker.capture(
            sessionID: "thread-a",
            emitterBelongsToForegroundJob: true,
            foregroundProcess: first
        ))
        XCTAssertEqual(tracker.sessionID(for: first), "thread-a")
        XCTAssertTrue(tracker.invalidateBinding(ifProcessChangedTo: second))
        XCTAssertNil(tracker.sessionID(for: second))
    }

    func testCodexSessionTrackerRejectsBackgroundEmitter() {
        let foreground = ForegroundProcess(
            instance: ProcessInstance(pid: 102, startedAt: 120),
            name: "codex",
            arguments: ["codex"]
        )
        var tracker = CodexSessionTracker()

        XCTAssertFalse(tracker.capture(
            sessionID: "stale-thread",
            emitterBelongsToForegroundJob: false,
            foregroundProcess: foreground
        ))
        XCTAssertNil(tracker.sessionID(for: foreground))
    }

    func testCodexSessionTrackerBindsARestoredThreadOnce() {
        let restored = ForegroundProcess(
            instance: ProcessInstance(pid: 201, startedAt: 200),
            name: "codex",
            arguments: ["codex", "resume", "restored-thread"]
        )
        let fresh = ForegroundProcess(
            instance: ProcessInstance(pid: 202, startedAt: 220),
            name: "codex",
            arguments: ["codex"]
        )
        var tracker = CodexSessionTracker()
        tracker.prepareResume(sessionID: "restored-thread")

        XCTAssertEqual(tracker.sessionID(for: restored), "restored-thread")
        XCTAssertNil(tracker.sessionID(for: fresh))
    }

    func testCodexSessionTrackerDoesNotBindAFailedRestoreToAFreshProcess() {
        let fresh = ForegroundProcess(
            instance: ProcessInstance(pid: 202, startedAt: 220),
            name: "codex",
            arguments: ["codex"]
        )
        var tracker = CodexSessionTracker()
        tracker.prepareResume(sessionID: "failed-restore")

        XCTAssertNil(tracker.sessionID(for: fresh))
    }

    func testCodexSessionTrackerIgnoresReplayWithoutARunningProcess() {
        var tracker = CodexSessionTracker()

        XCTAssertFalse(tracker.capture(
            sessionID: "queued-thread",
            emitterBelongsToForegroundJob: false,
            foregroundProcess: nil
        ))
        XCTAssertNil(tracker.sessionID(for: nil))
    }

    func testCodexSessionTrackerRejectsLegacyEventForRunningProcess() {
        let foreground = ForegroundProcess(
            instance: ProcessInstance(pid: 301, startedAt: 90),
            name: "codex",
            arguments: ["codex"]
        )
        var tracker = CodexSessionTracker()

        XCTAssertFalse(tracker.capture(
            sessionID: "legacy-thread",
            emitterBelongsToForegroundJob: false,
            foregroundProcess: foreground
        ))
        XCTAssertNil(tracker.sessionID(for: foreground))
    }
}
