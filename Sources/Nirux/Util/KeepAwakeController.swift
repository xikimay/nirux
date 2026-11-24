import Foundation
import IOKit.ps
import IOKit.pwr_mgt

/// The power-management calls `KeepAwakeController` makes; tests inject a
/// fake so they never touch the Mac's real sleep settings.
protocol SleepAssertionAPI {
    /// Nil when the system refused the assertion.
    func create(name: String) -> IOPMAssertionID?
    func release(_ id: IOPMAssertionID)
}

/// Prevents idle sleep only: the display still sleeps, and closing a
/// MacBook's lid still sleeps it (outside clamshell mode).
struct IOKitSleepAssertions: SleepAssertionAPI {
    func create(name: String) -> IOPMAssertionID? {
        var id = IOPMAssertionID(0)
        let result = IOPMAssertionCreateWithName(
            kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            name as CFString,
            &id
        )
        return result == kIOReturnSuccess ? id : nil
    }

    func release(_ id: IOPMAssertionID) {
        IOPMAssertionRelease(id)
    }
}

/// On the power adapter: a desktop Mac, or a laptop plugged in. Unknown
/// counts as plugged in, as a desktop reports no source.
func isOnPowerAdapter() -> Bool {
    guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
          let source = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue()
    else { return true }
    return source as String == kIOPMACPowerKey
}

/// Keeps the Mac from idle-sleeping while at least one agent works, or a
/// merge queue runs, or (on the power adapter, under its own setting) the
/// checks of a pull request Nirux follows run: one global assertion, taken
/// when the first reason starts and released a grace period after the last
/// one stops, so back-to-back turns don't toggle it. An agent waiting on the
/// user makes no progress and doesn't count. The system also drops the
/// assertion if Nirux crashes.
@MainActor
final class KeepAwakeController {
    static let assertionName = "Nirux: agents working, a merge queue running or pull request checks running"
    static let gracePeriod: TimeInterval = 60
    /// While enabled, how often to ask for a fresh count (`onRefresh`). With
    /// Nirux in the background the heartbeat stops, and nothing else sees
    /// an agent without hooks start or end a turn.
    static let pollInterval: TimeInterval = 30
    /// A "working" agent with neither terminal output nor a hook event for
    /// this long doesn't count: a Claude turn interrupted with Esc fires no
    /// Stop and stays "working" until the next prompt, while a turn in
    /// progress redraws its spinner every second.
    static let activityTimeout: TimeInterval = 600

    typealias Schedule = MainActorSchedule

    private let assertions: SleepAssertionAPI
    private let schedule: Schedule
    private let isOnACPower: () -> Bool
    /// The setting for agents and merge queues.
    private(set) var isEnabled: Bool
    /// The setting for checks (`isAwaitingChecks`).
    private(set) var waitsForChecks: Bool
    private(set) var workingAgentCount = 0
    /// A merge queue runs (docs/design/project-board.md, section 3.4): it polls
    /// GitHub for an hour or more with no agent at work.
    private(set) var isMergeQueueRunning = false
    /// Checks run on a pull request whose result Nirux acts on (a follow-up
    /// round, a merge wait, the Lead): asleep, nothing reads it.
    private(set) var isAwaitingChecks = false
    private var assertionID: IOPMAssertionID?
    /// Bumped by every release and every called-off release: a scheduled
    /// release from before does nothing.
    private var releaseGeneration: UInt = 0
    private var releaseIsPending = false
    /// Bumped when polling starts or stops: an older poll loop ends.
    private var pollGeneration: UInt = 0
    private var isShutDown = false
    private var loggedCreateFailure = false

    /// The indicator's state changed: `isActive` or one of its reasons.
    var onChange: (() -> Void)?
    /// Asked every `pollInterval` while enabled, and once more before the
    /// grace period ends; answers with `update(workingAgentCount:)`.
    var onRefresh: (() -> Void)?

    /// The assertion is held — a reason holds, or the last one stopped less
    /// than `gracePeriod` ago.
    var isActive: Bool { assertionID != nil }

    /// What wants the Mac awake now, as the settings allow.
    private var isNeeded: Bool {
        (isEnabled && (workingAgentCount > 0 || isMergeQueueRunning))
            || (waitsForChecks && isAwaitingChecks && isOnACPower())
    }

    private var isPolling: Bool { isEnabled || waitsForChecks }

    /// What holds the Mac awake now, as the settings allow: the indicator's words.
    var heldFor: (agents: Int, queue: Bool, checks: Bool) {
        (isEnabled ? workingAgentCount : 0, isEnabled && isMergeQueueRunning, waitsForChecks && isAwaitingChecks && isOnACPower())
    }

    init(
        enabled: Bool,
        waitsForChecks: Bool = false,
        assertions: SleepAssertionAPI = IOKitSleepAssertions(),
        schedule: @escaping Schedule = mainQueueSchedule,
        isOnACPower: @escaping () -> Bool = isOnPowerAdapter
    ) {
        self.isEnabled = enabled
        self.waitsForChecks = waitsForChecks
        self.assertions = assertions
        self.schedule = schedule
        self.isOnACPower = isOnACPower
        if isPolling { startPolling() }
    }

    /// Whether a column's agent counts as working: see `activityTimeout`.
    static func countsAsWorking(_ status: AgentStatus, lastActivityAt: TimeInterval, now: TimeInterval) -> Bool {
        status == .working && now - lastActivityAt < activityTimeout
    }

    /// Agents mid-turn right now, every workspace and space included.
    func update(workingAgentCount count: Int) {
        change { $0.workingAgentCount = max(0, count) }
    }

    /// Whether a merge queue runs, in any project.
    func update(mergeQueueRunning running: Bool) {
        change { $0.isMergeQueueRunning = running }
    }

    /// Whether checks run on a pull request Nirux acts on.
    func update(awaitingChecks awaiting: Bool) {
        change { $0.isAwaitingChecks = awaiting }
    }

    private var reasons: [AnyHashable] { [isActive, workingAgentCount, isMergeQueueRunning, isAwaitingChecks] }

    private func change(_ body: (KeepAwakeController) -> Void) {
        guard !isShutDown else { return }
        let previous = reasons
        body(self)
        if isNeeded {
            cancelPendingRelease()
            acquire()
        } else if isActive, !releaseIsPending {
            scheduleRelease()
        }
        if reasons != previous { onChange?() }
    }

    /// Off releases at once, unless the other setting still wants the Mac
    /// awake; on protects what already runs.
    func setEnabled(_ enabled: Bool) {
        setSetting(\.isEnabled, enabled)
    }

    func setWaitsForChecks(_ waits: Bool) {
        setSetting(\.waitsForChecks, waits)
    }

    private func setSetting(_ setting: ReferenceWritableKeyPath<KeepAwakeController, Bool>, _ value: Bool) {
        guard !isShutDown, self[keyPath: setting] != value else { return }
        let wasActive = isActive
        let wasPolling = isPolling
        self[keyPath: setting] = value
        if isPolling != wasPolling {
            if isPolling { startPolling() } else { pollGeneration &+= 1 }
        }
        if isNeeded {
            cancelPendingRelease()
            acquire()
        } else if !value {
            release()
        }
        if isActive != wasActive { onChange?() }
    }

    /// App termination: release for good; later updates are ignored.
    func shutdown() {
        guard !isShutDown else { return }
        let wasActive = isActive
        pollGeneration &+= 1
        release()
        isShutDown = true
        if wasActive { onChange?() }
    }

    private func acquire() {
        guard assertionID == nil else { return }
        guard let id = assertions.create(name: Self.assertionName) else {
            // Retried on the next update; logged once per failure streak.
            if !loggedCreateFailure {
                NSLog("[KeepAwake] the system refused the sleep assertion")
                loggedCreateFailure = true
            }
            return
        }
        loggedCreateFailure = false
        assertionID = id
    }

    private func release() {
        cancelPendingRelease()
        guard let id = assertionID else { return }
        assertionID = nil
        assertions.release(id)
    }

    private func scheduleRelease() {
        releaseIsPending = true
        let scheduled = releaseGeneration
        schedule(Self.gracePeriod) { [weak self] in
            guard let self, self.releaseGeneration == scheduled else { return }
            // One last look: the count that started the grace period may
            // have caught an agent without hooks in a quiet moment.
            self.onRefresh?()
            guard self.releaseGeneration == scheduled else { return }
            let wasActive = self.isActive
            self.release()
            if wasActive { self.onChange?() }
        }
    }

    private func cancelPendingRelease() {
        releaseIsPending = false
        releaseGeneration &+= 1
    }

    private func startPolling() {
        pollGeneration &+= 1
        schedulePoll(generation: pollGeneration)
    }

    private func schedulePoll(generation scheduled: UInt) {
        schedule(Self.pollInterval) { [weak self] in
            guard let self, self.pollGeneration == scheduled else { return }
            self.onRefresh?()
            guard self.pollGeneration == scheduled else { return }
            self.schedulePoll(generation: scheduled)
        }
    }
}
