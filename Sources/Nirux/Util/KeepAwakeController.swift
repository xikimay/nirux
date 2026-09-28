import Foundation
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

/// Keeps the Mac from idle-sleeping while at least one agent works, or a
/// merge queue runs: one global assertion, taken when the first agent
/// starts a turn (or a queue starts) and released a grace period after the
/// last one stops, so back-to-back turns don't toggle it. An agent waiting
/// on the user makes no progress and doesn't count. The system also drops
/// the assertion if Nirux crashes.
@MainActor
final class KeepAwakeController {
    static let assertionName = "Nirux: agents working or a merge queue running"
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
    private(set) var isEnabled: Bool
    private(set) var workingAgentCount = 0
    /// A merge queue runs (docs/project-board.md, section 3.4): it polls
    /// GitHub for an hour or more with no agent at work.
    private(set) var isMergeQueueRunning = false
    private var assertionID: IOPMAssertionID?
    /// Bumped by every release and every called-off release: a scheduled
    /// release from before does nothing.
    private var releaseGeneration: UInt = 0
    private var releaseIsPending = false
    /// Bumped when polling starts or stops: an older poll loop ends.
    private var pollGeneration: UInt = 0
    private var isShutDown = false
    private var loggedCreateFailure = false

    /// The indicator's state changed: `isActive`, `workingAgentCount` or
    /// `isMergeQueueRunning`.
    var onChange: (() -> Void)?
    /// Asked every `pollInterval` while enabled, and once more before the
    /// grace period ends; answers with `update(workingAgentCount:)`.
    var onRefresh: (() -> Void)?

    /// The assertion is held — agents are working or a queue runs, or they
    /// stopped less than `gracePeriod` ago.
    var isActive: Bool { assertionID != nil }

    /// What wants the Mac awake now.
    private var isNeeded: Bool { workingAgentCount > 0 || isMergeQueueRunning }

    init(
        enabled: Bool,
        assertions: SleepAssertionAPI = IOKitSleepAssertions(),
        schedule: @escaping Schedule = mainQueueSchedule
    ) {
        self.isEnabled = enabled
        self.assertions = assertions
        self.schedule = schedule
        if enabled { startPolling() }
    }

    /// Whether a column's agent counts as working: see `activityTimeout`.
    static func countsAsWorking(_ status: AgentStatus, lastActivityAt: TimeInterval, now: TimeInterval) -> Bool {
        status == .working && now - lastActivityAt < activityTimeout
    }

    /// Agents mid-turn right now, every workspace and space included.
    func update(workingAgentCount count: Int) {
        guard !isShutDown else { return }
        let previous = (isActive, workingAgentCount, isMergeQueueRunning)
        workingAgentCount = max(0, count)
        apply(since: previous)
    }

    /// Whether a merge queue runs, in any project.
    func update(mergeQueueRunning running: Bool) {
        guard !isShutDown else { return }
        let previous = (isActive, workingAgentCount, isMergeQueueRunning)
        isMergeQueueRunning = running
        apply(since: previous)
    }

    private func apply(since previous: (isActive: Bool, count: Int, queue: Bool)) {
        if isNeeded {
            cancelPendingRelease()
            if isEnabled { acquire() }
        } else if isActive, !releaseIsPending {
            scheduleRelease()
        }
        if isActive != previous.isActive || workingAgentCount != previous.count || isMergeQueueRunning != previous.queue {
            onChange?()
        }
    }

    /// Off releases at once; on protects agents already working.
    func setEnabled(_ enabled: Bool) {
        guard !isShutDown, enabled != isEnabled else { return }
        isEnabled = enabled
        let wasActive = isActive
        if enabled {
            startPolling()
            if isNeeded { acquire() }
        } else {
            pollGeneration &+= 1
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
