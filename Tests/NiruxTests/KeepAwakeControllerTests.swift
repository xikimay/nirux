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
    let power = Power()
    var changes = 0

    final class Power { var onAdapter = true }

    init(enabled: Bool = true, waitsForChecks: Bool = false) {
        let assertions = FakeSleepAssertions()
        let clock = ManualSchedule()
        self.assertions = assertions
        self.clock = clock
        let power = power
        controller = KeepAwakeController(
            enabled: enabled, waitsForChecks: waitsForChecks, assertions: assertions, schedule: clock.schedule,
            isOnACPower: { power.onAdapter }
        )
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

    /// Checks Nirux waits on keep the Mac awake on the power adapter only,
    /// under their own setting, whatever the agents' one says.
    func testRunningChecksKeepTheMacAwakeOnThePowerAdapter() {
        let harness = KeepAwakeHarness(enabled: false, waitsForChecks: true)
        let (controller, assertions, clock) = (harness.controller, harness.assertions, harness.clock)
        controller.update(workingAgentCount: 2)
        XCTAssertFalse(controller.isActive, "agents count under their own setting")
        controller.update(awaitingChecks: true)
        XCTAssertTrue(controller.isActive)

        harness.power.onAdapter = false
        clock.advance(by: KeepAwakeController.pollInterval)
        controller.update(awaitingChecks: true)
        clock.advance(by: KeepAwakeController.gracePeriod)
        XCTAssertFalse(controller.isActive, "not on battery")
        harness.power.onAdapter = true
        controller.update(awaitingChecks: true)
        XCTAssertTrue(controller.isActive)

        var refreshes = 0
        controller.onRefresh = { refreshes += 1 }
        clock.advance(by: KeepAwakeController.pollInterval)
        XCTAssertEqual(refreshes, 1, "polls under the checks' setting alone: a stale read must end")
        XCTAssertTrue(controller.heldFor == (0, false, true), "the agents' setting off: their count isn't a reason")

        let shown = harness.changes
        controller.setEnabled(true)
        XCTAssertGreaterThan(harness.changes, shown, "the indicator names the agents again")
        controller.setEnabled(false)
        XCTAssertTrue(controller.isActive, "the agents' setting off leaves the checks' reason")
        controller.setWaitsForChecks(false)
        XCTAssertFalse(controller.isActive, "off releases at once")
        XCTAssertTrue(assertions.held.isEmpty)
        controller.setWaitsForChecks(true)
        XCTAssertTrue(controller.isActive)
        controller.update(awaitingChecks: false)
        clock.advance(by: KeepAwakeController.gracePeriod)
        XCTAssertFalse(controller.isActive)
        XCTAssertEqual(
            KeepAwakeIndicator.toolTip(workingAgentCount: 2, isMergeQueueRunning: true, isAwaitingChecks: true),
            "Keeping your Mac awake while a merge queue runs, 2 agents work and pull request checks run."
        )
    }

    /// A pull request holds a result Nirux waits for: a push not read yet,
    /// checks running (a while per head: some never end), a red read for the
    /// time a follow-up round takes. Not a stale read, nor a closed one.
    func testChecksWatchCountsEachHeadForAWhile() {
        func pr(_ status: String?, head: String = "a", state: GitHub.PullRequestState = .open) -> PRInfo {
            var info = PRInfo(number: 7, state: state, isDraft: false, ciStatus: status, checks: [], reviewDecision: nil,
                              mergeable: nil, url: "u", additions: nil, deletions: nil, changedFiles: nil)
            info.headRefOid = head
            return info
        }
        var watch = ChecksWatch()
        func awaits(_ pullRequest: PRInfo?, readAt: TimeInterval = 0, push: ChecksWatch.Push? = nil, now: TimeInterval) -> Bool {
            watch.awaits([ChecksWatch.Read(id: "t", pullRequest: pullRequest, readAt: readAt, push: push)], now: now)
        }
        XCTAssertTrue(awaits(nil, push: .init(headBefore: nil), now: 1), "a push before any read")
        XCTAssertFalse(awaits(pr("SUCCESS"), now: 1))
        XCTAssertTrue(awaits(pr("PENDING"), readAt: 100, now: 100))
        XCTAssertFalse(awaits(pr("PENDING"), readAt: 100, now: 100 + ChecksWatch.readWindow), "a stale read")
        XCTAssertFalse(awaits(pr("PENDING", state: .closed), readAt: 100, now: 100))
        let late = 100 + ChecksWatch.pendingLimit
        XCTAssertTrue(awaits(pr("PENDING"), readAt: 200, now: 200))
        XCTAssertFalse(awaits(pr("PENDING"), readAt: late + 100, now: late + 100), "checks that never end")
        XCTAssertTrue(awaits(pr("PENDING", head: "b"), readAt: late + 200, now: late + 200), "a new head")
        XCTAssertTrue(awaits(pr("FAILURE", head: "b"), readAt: late + 300, now: late + 300))
        XCTAssertFalse(awaits(pr("FAILURE", head: "b"), readAt: late + 300 + ChecksWatch.failureLimit,
                              now: late + 300 + ChecksWatch.failureLimit), "red long enough for its round")
        XCTAssertFalse(awaits(pr("SUCCESS", head: "d"), readAt: late + 2_000, push: .init(headBefore: "c"), now: late + 2_000),
                       "a fetch of a branch whose checks settled")
        XCTAssertTrue(awaits(pr("SUCCESS", head: "d"), readAt: late + 2_000, push: .init(headBefore: "d"), now: late + 2_000),
                      "green, but read before the push")

        // A red pull request in the background is read every 10 minutes: the
        // stale moment between two reads keeps its clock.
        var red = ChecksWatch()
        func redAwaits(readAt: TimeInterval, now: TimeInterval) -> Bool {
            red.awaits([ChecksWatch.Read(id: "r", pullRequest: pr("FAILURE", head: "c"), readAt: readAt, push: nil)], now: now)
        }
        XCTAssertTrue(redAwaits(readAt: 0, now: 0))
        XCTAssertFalse(redAwaits(readAt: 0, now: ChecksWatch.readWindow), "stale")
        XCTAssertTrue(redAwaits(readAt: ChecksWatch.readWindow + 5, now: ChecksWatch.readWindow + 5))
        XCTAssertFalse(redAwaits(readAt: ChecksWatch.failureLimit, now: ChecksWatch.failureLimit), "its 15 minutes, from its first read")
    }

    func testSettingDefaultsToOnInOlderStateFiles() throws {
        let older = try JSONDecoder().decode(PersistedSettings.self, from: Data("{}".utf8))
        XCTAssertTrue(older.keepMacAwakeWhileAgentsWork)
        XCTAssertTrue(older.keepMacAwakeWhileChecksRun)
        XCTAssertTrue(PersistedSettings().keepMacAwakeWhileAgentsWork)
        let agentsOff = try JSONDecoder().decode(PersistedSettings.self, from: Data(#"{"keepMacAwakeWhileAgentsWork":false}"#.utf8))
        XCTAssertFalse(agentsOff.keepMacAwakeWhileChecksRun, "a user who turned keep-awake off isn't opted back in")
        var checksOff = PersistedSettings()
        checksOff.keepMacAwakeWhileChecksRun = false
        XCTAssertFalse(try JSONDecoder().decode(PersistedSettings.self, from: JSONEncoder().encode(checksOff)).keepMacAwakeWhileChecksRun)

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

    /// A process table that could not be read tells nothing: the refresh
    /// leaves every agent as its hooks left it, on screen or in another
    /// space. Read as "no agent", it dropped their hook authority.
    func testUnreadProcessTableLeavesAgentsAsTheyWere() throws {
        try withShell { shell in
            shell.workspaceStore.replaceProfiles(
                [WorkspaceProfile.defaultProfile, side], activeProfileID: WorkspaceProfile.defaultID
            )
            let hidden = WorkspaceState(id: "hidden", title: "hidden", cwd: NSTemporaryDirectory(), profileID: side.id)
            shell.workspaceStore.appendWorkspace(hidden, activate: false)
            let ptys = try [shell.workspaces.first, hidden].map { try XCTUnwrap($0?.columns.first?.pty) }
            for pty in ptys {
                _ = pty.applyAgentHook(
                    AgentHookEvent(kind: .claude, name: .userPromptSubmit, timestamp: Date().timeIntervalSince1970),
                    isUserFocused: false
                )
            }
            shell.updateSidebar(snapshot: ProcessSnapshot(entries: []))
            for pty in ptys {
                XCTAssertEqual(pty.cachedAgentState, .working)
                XCTAssertEqual(pty.hookAgent, .claude)
            }
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

    /// A Claude turn interrupted with Esc stays "working", with no hook to
    /// end it. Once it has been silent past the timeout the poll has nothing
    /// left to re-read, and must still let the controller drop it, or the
    /// Mac stays awake until Nirux comes back to the front.
    func testPollReleasesATurnGoneSilentInTheBackground() throws {
        try withShell { shell in
            let assertions = FakeSleepAssertions()
            let clock = ManualSchedule()
            let controller = KeepAwakeController(enabled: true, assertions: assertions, schedule: clock.schedule)
            shell.keepAwake = controller
            let pty = try XCTUnwrap(shell.workspaces.first?.columns.first?.pty)
            _ = pty.applyAgentHook(
                AgentHookEvent(
                    kind: .claude, name: .userPromptSubmit,
                    timestamp: Date().timeIntervalSince1970 - KeepAwakeController.activityTimeout - 1
                ),
                isUserFocused: false
            )
            XCTAssertEqual(pty.cachedAgentState, .working)
            XCTAssertFalse(NiruxShellView.needsBackgroundRefresh(pty))
            // What the controller saw while the turn still counted.
            controller.update(workingAgentCount: 1)
            XCTAssertTrue(controller.isActive)

            shell.lastMetadataRefreshAt = ProcessInfo.processInfo.systemUptime - NiruxShellView.heartbeatStaleAfter - 1
            shell.refreshAgentStatusInBackground()
            clock.advance(by: KeepAwakeController.gracePeriod)
            XCTAssertFalse(controller.isActive)
            XCTAssertTrue(assertions.held.isEmpty)
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
            ), isUserFocused: false, processTableRead: true, claudeFiredHooks: false)
            ticked.append((pty, name))
        }
        for (pty, name) in ticked {
            XCTAssertTrue(NiruxShellView.needsBackgroundRefresh(pty), "\(name): its turn would start unseen")
        }
        let hookedClaude = ticked[0].0
        _ = hookedClaude.applyAgentHook(AgentHookEvent(kind: .claude, name: .stop, timestamp: 2), isUserFocused: false)
        XCTAssertEqual(hookedClaude.hookAgent, .claude)
        XCTAssertFalse(NiruxShellView.needsBackgroundRefresh(hookedClaude))
    }

    /// Away from Nirux the heartbeat stops; the background pass still reads
    /// a task's pull request, though no merge wait follows it (a follow-up
    /// round or the Lead acts on its checks), and checks it reads running
    /// keep the Mac awake, until a read says they ended.
    func testPullRequestsAreReadAwayAndTheirRunningChecksKeepTheMacAwake() throws {
        try withShell { shell in
            let controller = KeepAwakeController(
                enabled: true, waitsForChecks: true, assertions: FakeSleepAssertions(), schedule: ManualSchedule().schedule,
                isOnACPower: { true }
            )
            shell.keepAwake = controller
            let repo = FileManager.default.temporaryDirectory.appendingPathComponent("nirux-away-\(UUID().uuidString)").path
            try FileManager.default.createDirectory(atPath: repo, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(atPath: repo) }
            try UIFlowHarness.git(["init", "-q", "-b", "feat/task"], at: repo)
            try UIFlowHarness.git(["-c", "user.name=Test", "-c", "user.email=test@example.com", "commit", "-q", "--allow-empty", "-m", "init"], at: repo)
            guard case .observed(let context) = GitDetect.observe(at: repo) else { return XCTFail("no repository") }
            let task = WorkspaceState(id: "task", title: "task", cwd: repo)
            shell.workspaceStore.appendWorkspace(task, activate: false)
            XCTAssertTrue(task.updateGitContext(context))
            final class Answer { var ciStatus = "PENDING"; var head = "a"; var reads = 0 }
            let answer = Answer()
            shell.fetchPullRequest = { _, _, _, done in
                answer.reads += 1
                var info = PRInfo(
                    number: 7, state: .open, isDraft: false, ciStatus: answer.ciStatus, checks: [], reviewDecision: nil,
                    mergeable: "MERGEABLE", url: "https://example.invalid/o/r/pull/7", additions: nil, deletions: nil, changedFiles: nil
                )
                info.headRefOid = answer.head
                done(.success(context: context, info: info))
            }
            shell.isOnACPower = { false }
            shell.refreshStuckAgents(appIsActive: false)
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
            XCTAssertEqual(answer.reads, 0, "on battery, only the pull requests a merge wait follows")
            shell.isOnACPower = { true }
            shell.refreshStuckAgents(appIsActive: false)
            XCTAssertTrue(waitUntil("the read") { task.prInfo?.number == 7 && controller.isActive })
            XCTAssertTrue(controller.isAwaitingChecks)

            answer.ciStatus = "SUCCESS"
            XCTAssertTrue(waitUntil("a read of the ended checks") {
                shell.refreshPRInfo(for: [task])
                return task.prInfo?.ciStatus == "SUCCESS" && !controller.isAwaitingChecks
            })

            // A push: the green read of the head before it says nothing of the pushed one's checks.
            shell.gitRefresh.noteChange(.remoteBranch, for: task)
            shell.updateKeepAwake()
            XCTAssertTrue(controller.isAwaitingChecks, "the read is from before the push")
            answer.head = "b"
            XCTAssertTrue(waitUntil("a read of the pushed head") {
                shell.refreshPRInfo(for: [task])
                return task.prInfo?.headRefOid == "b" && !controller.isAwaitingChecks
            })
        }
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
