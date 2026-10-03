import AppKit
import XCTest
@testable import Nirux

/// A restored layout brings its agent columns back without their agents:
/// each starts when its column shows, gets the focus, or the user asks
/// (see NiruxShellView+LazyRestore.swift). No agent runs here: the launch
/// goes to a recorder.
@MainActor
final class LazyRestoreTests: XCTestCase {
    private struct Launch: Equatable {
        let column: ObjectIdentifier
        let command: String
    }

    private final class Recorder {
        var launches: [Launch] = []
        var commands: [String] { launches.map(\.command) }
    }

    private static let sessionA = "5f0c8a52-6a0e-4d7c-9f0e-2b1f6d1c9a11"
    private static let sessionB = "0b7e3c1d-2a44-4f5e-8c6b-7d9e0f1a2b3c"
    private static let sessionC = "9a8b7c6d-5e4f-4a3b-9c2d-1e0f9a8b7c6d"
    private static let sessionD = "6e5d4c3b-2a19-4f8e-a7d6-c5b4a3928170"
    private static let thread = "3c2b1a09-8f7e-4d6c-9b5a-493827160504"

    /// One per test: XCTest makes a test case instance per test method.
    private nonisolated let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("nirux-lazy-restore-\(UUID().uuidString)").path

    override func setUpWithError() throws {
        try FileManager.default.createDirectory(atPath: root + "/state", withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(atPath: root)
    }

    private static func claude(_ sessionID: String?, title: String? = nil, status: PersistedAgentStatus? = nil,
                               cwd: String, width: Double = 0.5) -> PersistedColumn {
        PersistedColumn(
            widthPreset: width, cwd: cwd, columnType: .claudeCode, webViewURL: nil,
            claudeLaunchMode: .auto, codexLaunchMode: nil,
            claudeSessionID: sessionID, claudeSessionIsUnprompted: sessionID == nil ? true : nil,
            agentUUID: UUID().uuidString, lastAgentTitle: title, lastAgentStatus: status
        )
    }

    private static func codex(_ threadID: String, cwd: String) -> PersistedColumn {
        PersistedColumn(
            widthPreset: 1, cwd: cwd, columnType: .codex, webViewURL: nil,
            claudeLaunchMode: nil, codexLaunchMode: .default, codexSessionID: threadID, agentUUID: UUID().uuidString
        )
    }

    private func workspace(_ title: String, _ columns: [PersistedColumn], focused: Int = 0) -> PersistedWorkspace {
        PersistedWorkspace(id: title, title: title, cwd: root, columns: columns, focusedColumnIndex: focused)
    }

    private static func resume(_ sessionID: String) -> String {
        "command claude --resume '\(sessionID)' --permission-mode auto"
    }

    /// Three half-width agents in the workspace on screen (the third only
    /// shows a sliver at the edge), a Codex column and a fresh Claude in
    /// the two others.
    private func layout(resumeOnLaunch: AgentResumeOnLaunch? = nil) -> PersistedState {
        var state = PersistedState(
            workspaces: [
                workspace("a", [
                    Self.claude(Self.sessionA, cwd: root),
                    Self.claude(Self.sessionB, cwd: root),
                    Self.claude(Self.sessionC, title: "✳ Fix the login form", status: .working, cwd: root)
                ]),
                workspace("b", [Self.codex(Self.thread, cwd: root)]),
                workspace("c", [Self.claude(nil, cwd: root, width: 1)])
            ],
            activeWorkspaceIndex: 0
        )
        var settings = PersistedSettings()
        settings.agentResumeOnLaunch = resumeOnLaunch
        state.settings = settings
        return state
    }

    /// Restores `state` into a shell on throwaway state whose agent
    /// launches go to the recorder.
    private func withRestoredShell(
        _ state: PersistedState, _ body: @MainActor (NiruxShellView, Recorder) throws -> Void
    ) throws {
        let previous = ProcessInfo.processInfo.environment["NIRUX_STATE_DIR"]
        setenv("NIRUX_STATE_DIR", root + "/state", 1)
        defer {
            if let previous { setenv("NIRUX_STATE_DIR", previous, 1) } else { unsetenv("NIRUX_STATE_DIR") }
        }
        _ = NSApplication.shared
        let recorder = Recorder()
        let shell = NiruxShellView(frame: NSRect(x: 0, y: 0, width: 1400, height: 900))
        shell.stopHeartbeat()
        shell.sideEffects.startRestoredAgent = { column, command in
            recorder.launches.append(Launch(column: ObjectIdentifier(column), command: command))
        }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1400, height: 900),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = shell
        defer {
            // What the shell deferred (a metadata refresh) runs on the
            // throwaway state.
            settle()
            window.close()
        }
        XCTAssertTrue(Persistence.save(state))
        shell.restoreState()
        settle()
        try body(shell, recorder)
    }

    /// Long enough for the columns on screen to resume.
    private func settle() {
        RunLoop.main.run(until: Date().addingTimeInterval(NiruxShellView.onScreenResumeDelay + 0.15))
    }

    private func column(_ shell: NiruxShellView, _ workspace: Int, _ column: Int) throws -> ColumnState {
        try XCTUnwrap(shell.workspaces[safe: workspace]?.columns[safe: column])
    }

    // MARK: - When agents resume

    func testOnlyTheAgentsOnScreenResumeAtLaunch() throws {
        try withRestoredShell(layout()) { shell, recorder in
            XCTAssertEqual(recorder.commands, [Self.resume(Self.sessionA), Self.resume(Self.sessionB)])
            XCTAssertTrue(try column(shell, 0, 2).isAwaitingResume, "an edge sliver doesn't show the agent")
            XCTAssertEqual(shell.deferredAgentCount, 3)

            // Every column keeps its session until its agent runs.
            let saved = shell.persistedState()
            XCTAssertEqual(saved.workspaces.map { $0.columns.map(\.claudeSessionID) }, [
                [Self.sessionA, Self.sessionB, Self.sessionC], [nil], [nil]
            ])
            XCTAssertEqual(saved.workspaces[1].columns[0].codexSessionID, Self.thread)
            XCTAssertEqual(saved.workspaces[2].columns[0].claudeSessionIsUnprompted, true)
            XCTAssertEqual(saved.workspaces[0].columns[2].lastAgentTitle, "✳ Fix the login form")
            XCTAssertEqual(saved.workspaces[0].columns[2].lastAgentStatus, .working)

            shell.switchToWorkspace(1)
            settle()
            XCTAssertEqual(recorder.commands.last, "command codex resume '\(Self.thread)'")

            shell.switchToWorkspace(0)
            settle()
            XCTAssertEqual(recorder.launches.count, 3, "agents resume once")
            shell.focusColumnByIndex(2)
            settle()
            XCTAssertEqual(recorder.launches.last, Launch(
                column: ObjectIdentifier(try column(shell, 0, 2)), command: Self.resume(Self.sessionC)
            ))
            XCTAssertTrue(try column(shell, 2, 0).isAwaitingResume)
            XCTAssertEqual(shell.deferredAgentCount, 1)
        }
    }

    /// Moving through workspaces starts only the agents of the one the
    /// user stops at.
    func testPassingThroughAWorkspaceDoesntResumeItsAgents() throws {
        try withRestoredShell(layout()) { shell, recorder in
            shell.switchToWorkspace(1)
            shell.switchToWorkspace(2)
            XCTAssertEqual(recorder.launches.count, 2, "not before the column stayed on screen")
            settle()
            XCTAssertEqual(recorder.commands.last, "command claude --permission-mode auto")
            XCTAssertTrue(try column(shell, 1, 0).isAwaitingResume, "the workspace passed through")
        }
    }

    /// A working agent's title spinner refreshes the metadata several
    /// times a second: that must not hold back the column on screen.
    func testBusyAgentsElsewhereDontHoldBackTheColumnOnScreen() throws {
        try withRestoredShell(layout()) { shell, recorder in
            shell.switchToWorkspace(1)
            let deadline = Date().addingTimeInterval(NiruxShellView.onScreenResumeDelay * 3)
            while Date() < deadline {
                shell.refreshMetadata()
                RunLoop.main.run(until: Date().addingTimeInterval(0.1))
            }
            XCTAssertEqual(recorder.commands.last, "command codex resume '\(Self.thread)'")
        }
    }

    /// Typing into a waiting column asks for its agent at once.
    func testTypingIntoAWaitingColumnResumesItAtOnce() throws {
        try withRestoredShell(layout()) { shell, recorder in
            let codex = try column(shell, 1, 0)
            func key(_ characters: String) throws -> NSEvent {
                try XCTUnwrap(NSEvent.keyEvent(
                    with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
                    characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: 0
                ))
            }
            let shift = try XCTUnwrap(NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: .shift, timestamp: 0, windowNumber: 0, context: nil,
                characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 56
            ))
            XCTAssertTrue(NiruxApp.resumeAwaitingAgentOnTyping(shift, in: codex), "swallowed: no shell to take it")
            XCTAssertEqual(recorder.launches.count, 2, "a modifier alone asks for nothing")
            XCTAssertTrue(NiruxApp.resumeAwaitingAgentOnTyping(try key("a"), in: codex))
            XCTAssertEqual(recorder.commands.last, "command codex resume '\(Self.thread)'")
            XCTAssertFalse(NiruxApp.resumeAwaitingAgentOnTyping(try key("a"), in: codex), "keys go to its shell now")
        }
    }

    func testOnlyAPartWorthShowingCountsAsOnScreen() {
        let shows = { NiruxShellView.showsColumn(left: $0, width: $1, cameraX: 0, viewportWidth: 1_000) }
        XCTAssertTrue(shows(0, 500))
        XCTAssertTrue(shows(880, 500), "120 pt in view")
        XCTAssertFalse(shows(881, 500), "119 pt in view")
        XCTAssertTrue(shows(900, 100), "a narrow column, all in view")
        XCTAssertFalse(shows(901, 100))
        XCTAssertFalse(shows(1_000, 500))
        XCTAssertTrue(NiruxShellView.showsColumn(left: 400, width: 500, cameraX: 780, viewportWidth: 1_000))
        XCTAssertFalse(NiruxShellView.showsColumn(left: 400, width: 500, cameraX: 781, viewportWidth: 1_000))
    }

    func testResumeAllAgentsStartsEveryOneLeftOnce() throws {
        try withRestoredShell(layout()) { shell, recorder in
            XCTAssertTrue(shell.resumeAllDeferredAgents())
            XCTAssertEqual(Set(recorder.commands.dropFirst(2)), [
                Self.resume(Self.sessionC),
                "command codex resume '\(Self.thread)'",
                "command claude --permission-mode auto"
            ])
            XCTAssertEqual(shell.deferredAgentCount, 0)
            XCTAssertFalse(shell.resumeAllDeferredAgents())
            XCTAssertEqual(recorder.launches.count, 5)
        }
    }

    func testAllAtOnceResumesEveryAgentWithTheWindow() throws {
        try withRestoredShell(layout(resumeOnLaunch: .allAtOnce)) { shell, recorder in
            XCTAssertEqual(recorder.launches.count, 5)
            XCTAssertEqual(shell.deferredAgentCount, 0)
        }
    }

    /// Sessions are claimed when the layout is restored, in its order: two
    /// columns holding one session never both resume it, whichever starts
    /// first.
    func testADuplicateSessionResumesOnceWhateverColumnStartsFirst() throws {
        var state = PersistedState(
            workspaces: [
                workspace("a", [Self.claude(Self.sessionA, cwd: root, width: 1)]),
                workspace("b", [Self.claude(Self.sessionA, cwd: root, width: 1)])
            ],
            activeWorkspaceIndex: 1
        )
        state.activeWorkspaceID = "b"
        try withRestoredShell(state) { shell, recorder in
            XCTAssertEqual(recorder.commands, ["command claude --resume --permission-mode auto"])
            shell.switchToWorkspace(0)
            settle()
            XCTAssertEqual(recorder.commands.last, Self.resume(Self.sessionA))
        }
    }

    /// A session the user resumed in another column while this one waited
    /// is theirs: this one opens the picker.
    func testASessionResumedElsewhereMeanwhileOpensThePicker() throws {
        var state = layout()
        state.workspaces[1].columns = [Self.claude(Self.sessionD, cwd: root, width: 1)]
        try withRestoredShell(state) { shell, recorder in
            let elsewhere = try XCTUnwrap(shell.activeWorkspace)
            // perl keeps its arguments once running; a shell would exec
            // them away.
            elsewhere.addColumn(command: "exec /usr/bin/perl -e 'sleep 30' \(Self.sessionD)")
            let running = try column(shell, 0, elsewhere.focusedIndex)
            @MainActor func runsSession() -> Bool {
                let foreground = running.pty?.foregroundProcess(snapshot: ProcessSnapshot())
                return foreground?.name == "perl" && foreground?.arguments.contains(Self.sessionD) == true
            }
            let deadline = Date().addingTimeInterval(5)
            while !runsSession(), Date() < deadline {
                RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            }
            XCTAssertTrue(runsSession(), "the other column's shell didn't start")

            XCTAssertTrue(shell.resumeAllDeferredAgents())
            XCTAssertTrue(recorder.commands.contains("command claude --resume --permission-mode auto"), "\(recorder.commands)")
            XCTAssertFalse(recorder.commands.contains(Self.resume(Self.sessionD)))
        }
        XCTAssertEqual(
            DeferredAgentLaunch.Agent.codex(resume: .session(Self.thread), mode: .default)
                .openingElsewhere(["codex", "resume", Self.thread.uppercased()]),
            .codex(resume: .picker, mode: .default)
        )
        XCTAssertEqual(
            DeferredAgentLaunch.Agent.claude(resume: .session(Self.sessionA), mode: .plan).openingElsewhere([Self.thread]),
            .claude(resume: .session(Self.sessionA), mode: .plan)
        )
    }

    /// The same, for an agent that isn't in front of its terminal (a job
    /// in the background or stopped with ^Z): a stand-in `claude` runs as a
    /// background job of the other column's shell.
    func testASessionRunningBehindAnotherColumnsShellOpensThePicker() throws {
        let agent = root + "/claude"
        try FileManager.default.createSymbolicLink(atPath: agent, withDestinationPath: "/usr/bin/perl")
        var state = layout()
        state.workspaces[1].columns = [Self.claude(Self.sessionD, cwd: root, width: 1)]
        try withRestoredShell(state) { shell, recorder in
            let elsewhere = try XCTUnwrap(shell.activeWorkspace)
            // The shell in front names no session; its background job does.
            elsewhere.addColumn(command: "S=\(Self.sessionD) exec /bin/sh -c '\(agent) -e \"sleep 30\" \"$S\" & wait'")
            let running = try column(shell, 0, elsewhere.focusedIndex)
            @MainActor func runsInBackground() -> Bool {
                let snapshot = ProcessSnapshot()
                guard let shellPID = running.pty?.shellPID,
                      running.pty?.foregroundProcess(snapshot: snapshot)?.name == "sh" else { return false }
                return snapshot.descendantArguments(of: shellPID, named: ["claude"]).contains { $0.contains(Self.sessionD) }
            }
            let deadline = Date().addingTimeInterval(5)
            while !runsInBackground(), Date() < deadline {
                RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            }
            XCTAssertTrue(runsInBackground(), "the stand-in didn't start behind the shell")

            XCTAssertTrue(shell.resumeDeferredAgent(try column(shell, 1, 0), in: shell.workspaces[1]))
            XCTAssertEqual(recorder.commands.last, "command claude --resume --permission-mode auto")
        }
    }

    // MARK: - Asking for it

    func testSidebarResumeStartsTheAgentWhereItIs() throws {
        try withRestoredShell(layout()) { shell, recorder in
            let codex = try column(shell, 1, 0)
            let info = try XCTUnwrap(shell.sidebar.lastInfos.first { $0.index == 1 }?.columns.first)
            XCTAssertEqual(info.deferredAgent, SidebarDeferredAgent(
                processName: "codex", summary: "codex session", columnID: codex.id
            ))

            // A click aimed at another column that moved there does nothing.
            let resume = try XCTUnwrap(shell.sidebar.onDeferredAgentResume)
            resume(1, 0, UUID())
            XCTAssertEqual(recorder.launches.count, 2)

            resume(1, 0, codex.id)
            XCTAssertEqual(recorder.launches.last, Launch(
                column: ObjectIdentifier(codex), command: "command codex resume '\(Self.thread)'"
            ))
            XCTAssertEqual(shell.activeWSIndex, 0, "the workspace on screen stays")
            XCTAssertNil(shell.sidebar.lastInfos.first { $0.index == 1 }?.columns.first?.deferredAgent)
        }
    }

    func testClickingTheNoticeResumes() throws {
        var state = layout()
        state.workspaces[1].columns = [Self.claude(Self.sessionD, title: "Fix the login form", status: .needsAttention,
                                                   cwd: root, width: 1)]
        try withRestoredShell(state) { shell, recorder in
            // Out of view: the notice stays until asked.
            let waiting = try column(shell, 1, 0)
            let notice = try XCTUnwrap(waiting.deferredAgentOverlay)
            XCTAssertEqual(notice.content, .notResumed(
                processName: "claude", summary: "Fix the login form · last seen waiting for you"
            ))
            XCTAssertEqual(notice.subviews.compactMap { ($0 as? NSTextField)?.stringValue }, [
                "Not resumed yet — click or focus to resume",
                "claude · Fix the login form · last seen waiting for you"
            ])
            let drops = try XCTUnwrap(waiting.view as? DropTargetView)
            XCTAssertFalse(drops.acceptsFileDrops(), "no shell to take a dropped path")
            notice.mouseDown(with: try XCTUnwrap(NSEvent.mouseEvent(
                with: .leftMouseDown, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1
            )))
            XCTAssertEqual(recorder.commands.last, Self.resume(Self.sessionD))
            XCTAssertNil(waiting.deferredAgentOverlay)
            XCTAssertNil(notice.superview)
            XCTAssertTrue(drops.acceptsFileDrops())
        }
    }

    /// A folder removed since the restore (a cleaned-up worktree): the
    /// agent resumes in the workspace's, as a restore does. Its environment
    /// is the one of its workspace now.
    func testAnAgentWhoseFolderWentResumesInTheWorkspaceFolder() throws {
        let worktree = root + "/worktree"
        try FileManager.default.createDirectory(atPath: worktree, withIntermediateDirectories: true)
        var state = layout()
        state.workspaces[1].columns = [Self.codex(Self.thread, cwd: worktree)]
        try withRestoredShell(state) { shell, recorder in
            let codex = try column(shell, 1, 0)
            XCTAssertEqual(codex.launchDirectory, worktree)
            try FileManager.default.removeItem(atPath: worktree)
            shell.workspaces[1].profileID = "moved-space"
            XCTAssertTrue(shell.resumeDeferredAgent(codex, in: shell.workspaces[1]))
            XCTAssertEqual(recorder.commands.last, "command codex resume '\(Self.thread)'")
            XCTAssertEqual(codex.launchDirectory, root)
            XCTAssertEqual(codex.launchEnvironment?["NIRUX_PROFILE_ID"], "moved-space")
            XCTAssertEqual(codex.launchEnvironment?["NIRUX_AGENT_UUID"], codex.agentUUID)
        }
    }

    // MARK: - What a waiting column says

    func testSessionTitleComesFromTheAgentsTerminalTitle() {
        let title = DeferredAgentLaunch.sessionTitle(fromTerminalTitle:)
        XCTAssertEqual(title("✳ Fix the login form"), "Fix the login form")
        XCTAssertEqual(title("⠂ Fix the login form"), "Fix the login form", "a spinner frame")
        XCTAssertEqual(title("· Fix\nthe   login form"), "Fix the login form")
        XCTAssertEqual(title("[WIP] login"), "[WIP] login")
        for generic in [nil, "", "✳ Claude Code", "zsh", "codex", "command claude --resume 'x'", "claude --resume"] {
            XCTAssertNil(title(generic), generic ?? "nil")
        }
        XCTAssertEqual(title(String(repeating: "a", count: 200))?.count, DeferredAgentLaunch.maxTitleLength)
    }

    func testRowAndNoticeSayWhatTheColumnHolds() {
        let agent = SidebarDeferredAgent(processName: "claude", summary: "claude session", columnID: UUID())
        let info = ColumnInfo(
            index: 1, processName: nil, abbreviatedCwd: nil, isFocused: false, isWebView: false, webTitle: nil,
            terminalTitle: nil, agentStatus: .idle, isEditor: false, editorFileName: nil, deferredAgent: agent
        )
        XCTAssertEqual(SidebarColumnChip(info).text.string.replacingOccurrences(of: "\u{FFFC}", with: ""), "paused")
        XCTAssertTrue(SidebarColumnChip(info).toolTip.hasPrefix("claude · paused"))
        let workspace = WorkspaceInfo(
            id: "ws", index: 2, title: "t", profileID: WorkspaceProfile.defaultID, isInactive: false, columnCount: 1,
            focusedColumn: 0, gitBranch: nil, notification: nil, isActive: false, columns: [info], prInfo: nil,
            diffStats: nil, purpose: nil, nextStep: nil, blocker: nil, phase: .active, lastSummary: nil,
            lastActivityAt: nil
        )
        let card = SidebarWorkspaceCardRenderer(workspace: workspace, sidebarWidth: 260, yOffset: 800).render()
        let regions = card.hitAreas.map(\.region)
        let resume = regions.firstIndex {
            if case .deferredAgentResume(2, 1, agent.columnID) = $0 { return true }
            return false
        }
        let chip = regions.firstIndex {
            if case .column(2, 1) = $0 { return true }
            return false
        }
        let cardHit = regions.firstIndex {
            if case .workspace(2) = $0 { return true }
            return false
        }
        XCTAssertNotNil(chip, "its chip still focuses the column")
        XCTAssertLessThan(try XCTUnwrap(resume), try XCTUnwrap(cardHit), "the button takes the click before its card")
        XCTAssertEqual(Array(card.approvalButtons.keys), [SidebarHoverTarget.deferredResumeButtonKey(columnID: agent.columnID)])

        let pressed = SidebarHitRegion.deferredAgentResume(workspaceIndex: 2, columnIndex: 1, columnID: agent.columnID)
        let other = SidebarHitRegion.deferredAgentResume(workspaceIndex: 2, columnIndex: 1, columnID: UUID())
        func click(_ released: SidebarHitRegion?) -> SidebarDeferredResumeClick? {
            SidebarView.deferredResumeClick(
                pressed: pressed, released: released, clickCount: 1, armedAtPress: true, armedAtRelease: true
            )
        }
        XCTAssertEqual(click(pressed), SidebarDeferredResumeClick(workspaceIndex: 2, columnIndex: 1, columnID: agent.columnID))
        XCTAssertNil(click(other), "released on another column's button")
        XCTAssertNil(click(.column(workspaceIndex: 2, columnIndex: 1)))
    }

    // MARK: - Around a waiting agent

    func testResumeAllAgentsMenuItemOnlyWhileAnAgentWaits() throws {
        try withRestoredShell(layout()) { shell, recorder in
            let app = NiruxApp()
            app.shell = shell
            let item = NSMenuItem(title: "Resume All Agents", action: #selector(NiruxApp.resumeAllAgents(_:)), keyEquivalent: "")
            XCTAssertTrue(app.validateMenuItem(item))
            app.resumeAllAgents(item)
            XCTAssertEqual(recorder.launches.count, 5)
            XCTAssertFalse(app.validateMenuItem(item))
        }
    }

    /// Closing a paused agent's column asks first, as for a running one:
    /// its session leaves the layout. A worktree clean-up sees it in the
    /// folder it resumes in.
    func testAPausedAgentCountsWhenClosingOrCleaningUp() throws {
        let worktree = root + "/worktree"
        try FileManager.default.createDirectory(atPath: worktree, withIntermediateDirectories: true)
        var state = layout()
        state.workspaces[1].columns = [Self.codex(Self.thread, cwd: worktree)]
        try withRestoredShell(state) { shell, _ in
            let paused = try column(shell, 1, 0).liveAgent(snapshot: ProcessSnapshot())
            XCTAssertEqual(paused, WorkspaceClosePolicy.LiveAgent(processName: "codex", status: .idle, isPaused: true))
            XCTAssertEqual(
                WorkspaceClosePolicy.columnConfirmation(for: paused),
                ["Codex is paused — closing the column ends its session."]
            )
            XCTAssertEqual(
                shell.worktreeCleanupCandidate(path: worktree).foreignAgents, ["Codex (paused) in “b”"]
            )
        }
    }

    func testSavedStateKeepsTheLastAgentStatusAndAnUnknownResumeChoice() throws {
        let column = Self.claude(Self.sessionA, title: "Fix the login form", status: .needsAttention, cwd: "/tmp")
        let decoded = try JSONDecoder().decode(PersistedColumn.self, from: JSONEncoder().encode(column))
        XCTAssertEqual(decoded.lastAgentTitle, "Fix the login form")
        XCTAssertEqual(decoded.lastAgentStatus, .needsAttention)

        let missing = try JSONDecoder().decode(PersistedSettings.self, from: Data("{}".utf8))
        XCTAssertNil(missing.agentResumeOnLaunch)
        let newer = try JSONDecoder().decode(PersistedSettings.self, from: Data(#"{"agentResumeOnLaunch":"onIdle"}"#.utf8))
        XCTAssertNil(newer.agentResumeOnLaunch)
        let written = try XCTUnwrap(String(data: JSONEncoder().encode(newer), encoding: .utf8))
        XCTAssertTrue(written.contains(#""agentResumeOnLaunch":"onIdle""#), "a newer build's choice survives a save")
    }
}
