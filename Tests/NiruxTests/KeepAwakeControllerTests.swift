import AppKit
import IOKit.pwr_mgt
import XCTest
@testable import Nirux

/// Records the assertions the controller takes instead of touching the
/// Mac's real sleep settings.
final class FakeSleepAssertions: SleepAssertionAPI {
    private(set) var createdNames: [String] = []
    private(set) var released: [IOPMAssertionID] = []
    private(set) var held: Set<IOPMAssertionID> = []
    var refuses = false
    private var nextID: IOPMAssertionID = 1

    func create(name: String) -> IOPMAssertionID? {
        createdNames.append(name)
        guard !refuses else { return nil }
        let id = nextID
        nextID += 1
        held.insert(id)
        return id
    }

    func release(_ id: IOPMAssertionID) {
        released.append(id)
        held.remove(id)
    }
}

/// A clock the test advances by hand: scheduled actions run in due order.
@MainActor
final class ManualSchedule {
    private(set) var now: TimeInterval = 0
    private var tasks: [(due: TimeInterval, order: Int, action: @MainActor @Sendable () -> Void)] = []
    private var order = 0

    var schedule: KeepAwakeController.Schedule {
        { [weak self] delay, action in
            guard let self else { return }
            self.order += 1
            self.tasks.append((self.now + delay, self.order, action))
        }
    }

    func advance(by interval: TimeInterval) {
        let target = now + interval
        while let next = tasks.filter({ $0.due <= target }).min(by: { ($0.due, $0.order) < ($1.due, $1.order) }) {
            tasks.removeAll { $0.order == next.order }
            now = next.due
            next.action()
        }
        now = target
    }
}

/// A controller wired to fakes, counting its indicator updates.
@MainActor
final class KeepAwakeHarness {
    let assertions: FakeSleepAssertions
    let clock: ManualSchedule
    let controller: KeepAwakeController
    var changes = 0

    init(enabled: Bool = true) {
        let assertions = FakeSleepAssertions()
        let clock = ManualSchedule()
        self.assertions = assertions
        self.clock = clock
        controller = KeepAwakeController(enabled: enabled, assertions: assertions, schedule: clock.schedule)
        controller.onChange = { [weak self] in self?.changes += 1 }
    }
}

@MainActor
final class KeepAwakeControllerTests: XCTestCase {

    func testOneNamedAssertionWhileAgentsWork() {
        let harness = KeepAwakeHarness()
        let (controller, assertions, _) = (harness.controller, harness.assertions, harness.clock)
        XCTAssertFalse(controller.isActive)
        controller.update(workingAgentCount: 1)
        controller.update(workingAgentCount: 3)
        controller.update(workingAgentCount: 2)

        XCTAssertTrue(controller.isActive)
        XCTAssertEqual(assertions.createdNames, [KeepAwakeController.assertionName], "one global assertion")
        XCTAssertEqual(assertions.held.count, 1)
        XCTAssertEqual(controller.workingAgentCount, 2)
    }

    func testNoAgentWorkingTakesNothing() {
        let harness = KeepAwakeHarness()
        let (controller, assertions, clock) = (harness.controller, harness.assertions, harness.clock)
        controller.update(workingAgentCount: 0)
        clock.advance(by: 600)
        XCTAssertTrue(assertions.createdNames.isEmpty)
        XCTAssertFalse(controller.isActive)
    }

    func testReleasesOnlyAfterTheGracePeriod() {
        let harness = KeepAwakeHarness()
        let (controller, assertions, clock) = (harness.controller, harness.assertions, harness.clock)
        controller.update(workingAgentCount: 1)
        controller.update(workingAgentCount: 0)
        clock.advance(by: KeepAwakeController.gracePeriod - 1)
        XCTAssertTrue(controller.isActive, "still within the grace period")
        XCTAssertTrue(assertions.released.isEmpty)

        // More idle refreshes don't push the release back.
        controller.update(workingAgentCount: 0)
        clock.advance(by: 1)
        XCTAssertFalse(controller.isActive)
        XCTAssertEqual(assertions.released.count, 1)
        XCTAssertTrue(assertions.held.isEmpty)
    }

    func testWorkResumingWithinTheGracePeriodKeepsTheSameAssertion() {
        let harness = KeepAwakeHarness()
        let (controller, assertions, clock) = (harness.controller, harness.assertions, harness.clock)
        controller.update(workingAgentCount: 1)
        controller.update(workingAgentCount: 0)
        clock.advance(by: 30)
        controller.update(workingAgentCount: 1)
        clock.advance(by: KeepAwakeController.gracePeriod * 3)

        XCTAssertTrue(controller.isActive, "the voided release never fires")
        XCTAssertEqual(assertions.createdNames.count, 1, "no release and retake")
        XCTAssertTrue(assertions.released.isEmpty)

        // The next idle stretch gets a full grace period of its own.
        controller.update(workingAgentCount: 0)
        clock.advance(by: KeepAwakeController.gracePeriod - 1)
        XCTAssertTrue(controller.isActive)
        clock.advance(by: 1)
        XCTAssertFalse(controller.isActive)
    }

    func testTurningTheSettingOffReleasesAtOnce() {
        let harness = KeepAwakeHarness()
        let (controller, assertions, clock) = (harness.controller, harness.assertions, harness.clock)
        controller.update(workingAgentCount: 2)
        controller.setEnabled(false)

        XCTAssertFalse(controller.isActive)
        XCTAssertEqual(assertions.released.count, 1)
        controller.update(workingAgentCount: 2)
        clock.advance(by: 600)
        XCTAssertEqual(assertions.createdNames.count, 1, "nothing taken while off")

        controller.setEnabled(true)
        XCTAssertTrue(controller.isActive, "agents already working are protected")
        XCTAssertEqual(assertions.createdNames.count, 2)
    }

    func testTurningTheSettingOffDuringTheGracePeriodReleasesAtOnce() {
        let harness = KeepAwakeHarness()
        let (controller, assertions, clock) = (harness.controller, harness.assertions, harness.clock)
        controller.update(workingAgentCount: 1)
        controller.update(workingAgentCount: 0)
        controller.setEnabled(false)
        XCTAssertFalse(controller.isActive)

        controller.setEnabled(true)
        clock.advance(by: KeepAwakeController.gracePeriod)
        XCTAssertFalse(controller.isActive, "no agent works: turning it back on takes nothing")
        XCTAssertEqual(assertions.released.count, 1)
    }

    func testStartingDisabledNeverTakesAnAssertion() {
        let harness = KeepAwakeHarness(enabled: false)
        let (controller, assertions, _) = (harness.controller, harness.assertions, harness.clock)
        controller.update(workingAgentCount: 4)
        XCTAssertFalse(controller.isActive)
        XCTAssertTrue(assertions.createdNames.isEmpty)
        XCTAssertEqual(controller.workingAgentCount, 4, "still counted, for turning it on later")
    }

    func testShutdownReleasesForGood() {
        let harness = KeepAwakeHarness()
        let (controller, assertions, clock) = (harness.controller, harness.assertions, harness.clock)
        controller.update(workingAgentCount: 1)
        controller.shutdown()

        XCTAssertFalse(controller.isActive)
        XCTAssertTrue(assertions.held.isEmpty)
        controller.update(workingAgentCount: 1)
        controller.setEnabled(false)
        controller.setEnabled(true)
        clock.advance(by: 600)
        XCTAssertEqual(assertions.createdNames.count, 1, "nothing taken after shutdown")
        XCTAssertEqual(assertions.released.count, 1, "released exactly once")
    }

    func testShutdownDuringTheGracePeriodReleasesOnce() {
        let harness = KeepAwakeHarness()
        let (controller, assertions, clock) = (harness.controller, harness.assertions, harness.clock)
        controller.update(workingAgentCount: 1)
        controller.update(workingAgentCount: 0)
        controller.shutdown()
        clock.advance(by: KeepAwakeController.gracePeriod)
        XCTAssertEqual(assertions.released.count, 1)
    }

    func testRefusedAssertionIsRetriedOnTheNextUpdate() {
        let harness = KeepAwakeHarness()
        let (controller, assertions, _) = (harness.controller, harness.assertions, harness.clock)
        assertions.refuses = true
        controller.update(workingAgentCount: 1)
        XCTAssertFalse(controller.isActive)

        assertions.refuses = false
        controller.update(workingAgentCount: 1)
        XCTAssertTrue(controller.isActive)
        XCTAssertEqual(assertions.createdNames.count, 2)
    }

    func testPollsWhileEnabledOnly() {
        let harness = KeepAwakeHarness()
        let (controller, _, clock) = (harness.controller, harness.assertions, harness.clock)
        var polls = 0
        controller.onRefresh = { polls += 1 }
        clock.advance(by: KeepAwakeController.pollInterval * 3)
        XCTAssertEqual(polls, 3, "with no agent at work too: nothing else sees a turn start in the background")

        controller.setEnabled(false)
        clock.advance(by: KeepAwakeController.pollInterval * 5)
        XCTAssertEqual(polls, 3)
        controller.setEnabled(true)
        clock.advance(by: KeepAwakeController.pollInterval * 2)
        XCTAssertEqual(polls, 5, "a single poll loop again")

        controller.shutdown()
        clock.advance(by: KeepAwakeController.pollInterval * 5)
        XCTAssertEqual(polls, 5)
    }

    /// The count that started the grace period may have caught an agent
    /// without hooks in a quiet moment: one more look before letting go.
    func testGracePeriodEndsWithAFreshCount() {
        let harness = KeepAwakeHarness()
        let (controller, assertions, clock) = (harness.controller, harness.assertions, harness.clock)
        var reported = 0
        controller.onRefresh = { [weak controller] in controller?.update(workingAgentCount: reported) }
        controller.update(workingAgentCount: 1)
        controller.update(workingAgentCount: 0)
        clock.advance(by: KeepAwakeController.gracePeriod - 1)
        XCTAssertTrue(controller.isActive)

        reported = 1
        clock.advance(by: 1)
        XCTAssertTrue(controller.isActive, "the last look found the agent at work")
        XCTAssertTrue(assertions.released.isEmpty)

        reported = 0
        clock.advance(by: KeepAwakeController.pollInterval)
        XCTAssertTrue(controller.isActive, "a poll saw it stop: a new grace period")
        clock.advance(by: KeepAwakeController.gracePeriod)
        XCTAssertFalse(controller.isActive)
        XCTAssertEqual(assertions.createdNames.count, 1)
    }

    /// A Claude turn interrupted with Esc fires no Stop and stays
    /// "working"; its silence must not keep the Mac awake.
    func testSilentWorkingStatusStopsCounting() {
        let now: TimeInterval = 100_000
        let timeout = KeepAwakeController.activityTimeout
        XCTAssertTrue(KeepAwakeController.countsAsWorking(.working, lastActivityAt: now - 5, now: now))
        XCTAssertTrue(KeepAwakeController.countsAsWorking(.working, lastActivityAt: now - timeout + 1, now: now))
        XCTAssertFalse(KeepAwakeController.countsAsWorking(.working, lastActivityAt: now - timeout, now: now))
        XCTAssertFalse(KeepAwakeController.countsAsWorking(.working, lastActivityAt: 0, now: now))
        XCTAssertFalse(KeepAwakeController.countsAsWorking(.needsAttention, lastActivityAt: now, now: now))
        XCTAssertFalse(KeepAwakeController.countsAsWorking(.idle, lastActivityAt: now, now: now))
    }

    func testHookEventsCountAsAgentActivity() {
        let pty = PtySession()
        XCTAssertEqual(pty.lastAgentActivityAt, 0)
        _ = pty.applyAgentHook(
            AgentHookEvent(kind: .claude, name: .userPromptSubmit, timestamp: 1_234), isUserFocused: false
        )
        XCTAssertEqual(pty.cachedAgentState, .working)
        XCTAssertEqual(pty.lastAgentActivityAt, 1_234)
    }

    func testIndicatorIsToldAboutEveryVisibleChange() {
        let harness = KeepAwakeHarness()
        let (controller, _, clock) = (harness.controller, harness.assertions, harness.clock)
        controller.update(workingAgentCount: 1)
        XCTAssertEqual(harness.changes, 1, "taken")
        controller.update(workingAgentCount: 1)
        XCTAssertEqual(harness.changes, 1, "nothing changed")
        controller.update(workingAgentCount: 2)
        XCTAssertEqual(harness.changes, 2, "count changed")
        controller.update(workingAgentCount: 0)
        XCTAssertEqual(harness.changes, 3, "count changed, still held")
        clock.advance(by: KeepAwakeController.gracePeriod)
        XCTAssertEqual(harness.changes, 4, "released")
    }

    // MARK: - Indicator

    /// Its view hides: the controller's `isHidden` does nothing for a
    /// trailing title bar accessory.
    func testIndicatorShowsOnlyWhileActiveAndSaysWhy() {
        let indicator = KeepAwakeIndicator()
        XCTAssertTrue(indicator.view.isHidden)
        indicator.update(isActive: true, workingAgentCount: 2)
        XCTAssertFalse(indicator.view.isHidden)
        XCTAssertEqual(indicator.view.toolTip, "Keeping your Mac awake while 2 agents work.")
        indicator.update(isActive: true, workingAgentCount: 1)
        XCTAssertEqual(indicator.view.toolTip, "Keeping your Mac awake while 1 agent works.")
        indicator.update(isActive: true, workingAgentCount: 0)
        XCTAssertTrue(indicator.view.toolTip?.contains("no agent is working now") == true)
        indicator.update(isActive: false, workingAgentCount: 0)
        XCTAssertTrue(indicator.view.isHidden)
    }

    /// In a real title bar: hidden, the cup leaves its room to the
    /// accessory next to it; shown, it takes the trailing edge back.
    func testIndicatorTakesNoRoomInTheTitleBarWhenHidden() {
        _ = NSApplication.shared
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 300),
            styleMask: [.titled, .closable], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let indicator = KeepAwakeIndicator()
        let neighbour = NSTitlebarAccessoryViewController()
        neighbour.layoutAttribute = .trailing
        neighbour.view = NSView(frame: NSRect(x: 0, y: 0, width: 50, height: 22))
        window.addTitlebarAccessoryViewController(indicator)
        window.addTitlebarAccessoryViewController(neighbour)
        func frameInWindow(_ view: NSView) -> NSRect {
            window.contentView?.superview?.layoutSubtreeIfNeeded()
            return view.convert(view.bounds, to: nil)
        }

        // The cup hidden: the neighbour has the trailing edge.
        let edge = frameInWindow(neighbour.view).maxX
        indicator.update(isActive: true, workingAgentCount: 1)
        XCTAssertEqual(frameInWindow(indicator.view).maxX, edge)
        XCTAssertEqual(frameInWindow(indicator.view).width, 30)
        XCTAssertEqual(frameInWindow(neighbour.view).maxX, frameInWindow(indicator.view).minX)
        indicator.update(isActive: false, workingAgentCount: 0)
        XCTAssertEqual(frameInWindow(neighbour.view).maxX, edge, "the room is given back")
    }

    // MARK: - Setting

    func testSettingDefaultsToOnInOlderStateFiles() throws {
        let older = try JSONDecoder().decode(PersistedSettings.self, from: Data("{}".utf8))
        XCTAssertTrue(older.keepMacAwakeWhileAgentsWork)
        XCTAssertTrue(PersistedSettings().keepMacAwakeWhileAgentsWork)

        var off = PersistedSettings()
        off.keepMacAwakeWhileAgentsWork = false
        let decoded = try JSONDecoder().decode(PersistedSettings.self, from: JSONEncoder().encode(off))
        XCTAssertFalse(decoded.keepMacAwakeWhileAgentsWork)
    }
}

/// Keep-awake reads every column's status, other spaces included.
@MainActor
final class KeepAwakeShellTests: XCTestCase {
    private let side = WorkspaceProfile(id: "side", name: "side", colorHex: "#E0AF68")

    /// An agent left "working" in a space that is not on screen — its turn
    /// ended while nobody looked — stops counting at the next refresh
    /// instead of keeping the Mac awake for good.
    func testAgentInAnotherSpaceIsReReadAndReleased() throws {
        try withShell { shell in
            let assertions = FakeSleepAssertions()
            let clock = ManualSchedule()
            let controller = KeepAwakeController(enabled: true, assertions: assertions, schedule: clock.schedule)
            shell.keepAwake = controller

            shell.workspaceStore.replaceProfiles(
                [WorkspaceProfile.defaultProfile, side], activeProfileID: WorkspaceProfile.defaultID
            )
            let hidden = WorkspaceState(id: "hidden", title: "hidden", cwd: NSTemporaryDirectory(), profileID: side.id)
            shell.workspaceStore.appendWorkspace(hidden, activate: false)
            XCTAssertFalse(shell.visibleWorkspaceIndices.contains { shell.workspaces[$0] === hidden })

            let pty = try XCTUnwrap(hidden.columns.first?.pty)
            _ = pty.applyAgentHook(
                AgentHookEvent(kind: .claude, name: .userPromptSubmit, timestamp: Date().timeIntervalSince1970),
                isUserFocused: false
            )
            XCTAssertEqual(pty.cachedAgentState, .working)
            shell.updateKeepAwake()
            XCTAssertEqual(shell.workingAgentCount, 1)
            XCTAssertTrue(controller.isActive)

            // No claude in that terminal: a refresh sees the turn is over.
            shell.updateSidebar()
            XCTAssertEqual(pty.cachedAgentState, .idle)
            XCTAssertEqual(shell.workingAgentCount, 0)
            clock.advance(by: KeepAwakeController.gracePeriod)
            XCTAssertFalse(controller.isActive)
            XCTAssertTrue(assertions.held.isEmpty)
        }
    }

    /// Once the heartbeat has gone quiet (Nirux in the background, or a
    /// modal alert holding its timer), the poll re-reads the agents; while
    /// it beats, the poll leaves that to it.
    func testPollRefreshesOnlyOnceTheHeartbeatIsQuiet() throws {
        try withShell { shell in
            let pty = try XCTUnwrap(shell.workspaces.first?.columns.first?.pty)
            _ = pty.applyAgentHook(
                AgentHookEvent(kind: .claude, name: .userPromptSubmit, timestamp: Date().timeIntervalSince1970),
                isUserFocused: false
            )
            let uptime = ProcessInfo.processInfo.systemUptime
            shell.lastMetadataRefreshAt = uptime - 1
            shell.refreshAgentStatusInBackground()
            XCTAssertEqual(pty.cachedAgentState, .working, "left to the heartbeat")
            shell.lastMetadataRefreshAt = uptime - NiruxShellView.heartbeatStaleAfter - 1
            shell.refreshAgentStatusInBackground()
            XCTAssertEqual(pty.cachedAgentState, .idle, "no claude in that terminal: the turn is over")
        }
    }

    /// Through the shell's count: a "working" column silent for longer
    /// than the timeout (a Claude turn interrupted with Esc) is dropped.
    func testShellCountDropsSilentWorkingColumns() {
        let now = Date()
        let prompt = { (secondsAgo: TimeInterval) -> PtySession in
            let pty = PtySession()
            _ = pty.applyAgentHook(
                AgentHookEvent(kind: .claude, name: .userPromptSubmit, timestamp: now.timeIntervalSince1970 - secondsAgo),
                isUserFocused: false
            )
            return pty
        }
        let fresh = prompt(5)
        let silent = prompt(KeepAwakeController.activityTimeout + 1)
        XCTAssertEqual(silent.cachedAgentState, .working)
        XCTAssertEqual(NiruxShellView.workingAgentCount(of: [fresh, silent, PtySession()], now: now), 1)
    }

    /// The background poll skips an idle Claude with hooks (its hook
    /// events refresh), not an agent without them, a turn in progress, or
    /// a dialog whose approved tool no hook will report.
    func testBackgroundPollSkipsOnlyIdleClaudeWithHooks() {
        let now = Date().timeIntervalSince1970
        let claudeEvent = { (name: AgentHookEvent.Name, at: TimeInterval) in
            AgentHookEvent(kind: .claude, name: name, toolName: "Bash", toolKey: "k", timestamp: at)
        }
        let idle = PtySession()
        XCTAssertFalse(NiruxShellView.needsBackgroundRefresh(idle))

        let claude = PtySession()
        _ = claude.applyAgentHook(claudeEvent(.userPromptSubmit, now), isUserFocused: false)
        XCTAssertTrue(NiruxShellView.needsBackgroundRefresh(claude), "to see the turn end")
        _ = claude.applyAgentHook(claudeEvent(.permissionRequest, now), isUserFocused: false)
        XCTAssertNotEqual(claude.cachedAgentState, .working)
        XCTAssertTrue(NiruxShellView.needsBackgroundRefresh(claude), "an answered dialog runs its tool unseen")
        _ = claude.applyAgentHook(claudeEvent(.postToolUse, now), isUserFocused: false)
        _ = claude.applyAgentHook(claudeEvent(.stop, now), isUserFocused: false)
        XCTAssertFalse(NiruxShellView.needsBackgroundRefresh(claude))

        // An Esc-interrupted turn, "working" for good: polled no longer
        // than it counts.
        let stuck = PtySession()
        _ = stuck.applyAgentHook(claudeEvent(.userPromptSubmit, now - KeepAwakeController.activityTimeout), isUserFocused: false)
        XCTAssertEqual(stuck.cachedAgentState, .working)
        XCTAssertFalse(NiruxShellView.needsBackgroundRefresh(stuck))

        var ticked: [(PtySession, String)] = []
        for name in ["claude", "codex", "gemini"] {
            let pty = PtySession()
            _ = pty.agentStatus(foregroundProcess: ForegroundProcess(
                instance: ProcessInstance(pid: 1, startedAt: 0), name: name, arguments: [name]
            ), isUserFocused: false)
            ticked.append((pty, name))
        }
        for (pty, name) in ticked {
            XCTAssertTrue(NiruxShellView.needsBackgroundRefresh(pty), "\(name): its turn would start unseen")
        }
        let hookedClaude = ticked[0].0
        _ = hookedClaude.applyAgentHook(AgentHookEvent(kind: .claude, name: .stop, timestamp: 2), isUserFocused: false)
        XCTAssertEqual(hookedClaude.agentHookKind, "claude")
        XCTAssertFalse(NiruxShellView.needsBackgroundRefresh(hookedClaude))
    }

    private func withShell(_ body: (NiruxShellView) throws -> Void) throws {
        let stateDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("nirux-keep-awake-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: stateDirectory, withIntermediateDirectories: true)
        let previousStateDirectory = ProcessInfo.processInfo.environment["NIRUX_STATE_DIR"]
        setenv("NIRUX_STATE_DIR", stateDirectory.path, 1)
        defer {
            if let previousStateDirectory {
                setenv("NIRUX_STATE_DIR", previousStateDirectory, 1)
            } else {
                unsetenv("NIRUX_STATE_DIR")
            }
            try? FileManager.default.removeItem(at: stateDirectory)
        }

        _ = NSApplication.shared
        let shell = NiruxShellView(frame: NSRect(x: 0, y: 0, width: 1200, height: 800))
        shell.stopHeartbeat()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = shell
        defer { window.close() }
        try body(shell)
    }
}
