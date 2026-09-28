import XCTest
@testable import Nirux

/// When the board reads what (docs/project-board.md, section 6), on an
/// injected clock.
final class ProjectBoardScheduleTests: XCTestCase {
    private let everything = Set(ProjectBoard.Source.allCases)

    private func due(
        _ schedule: ProjectBoard.RefreshSchedule, at now: TimeInterval, onScreen: Bool = true,
        pending: Bool = false, available: Set<ProjectBoard.Source>? = nil
    ) -> Set<ProjectBoard.Source> {
        Set(schedule.due(now: now, onScreen: onScreen, hasPendingChecks: pending, available: available ?? everything))
    }

    private func started(_ sources: Set<ProjectBoard.Source>, at now: TimeInterval) -> ProjectBoard.RefreshSchedule {
        var schedule = ProjectBoard.RefreshSchedule()
        for source in sources {
            schedule.start(source, now: now)
            schedule.finish(source)
        }
        return schedule
    }

    func testEverythingIsReadWhenTheBoardFirstShows() {
        XCTAssertEqual(due(ProjectBoard.RefreshSchedule(), at: 100), everything)
    }

    func testNothingIsReadWhileTheBoardIsHidden() {
        XCTAssertEqual(due(ProjectBoard.RefreshSchedule(), at: 100, onScreen: false), [])
        XCTAssertEqual(due(started(everything, at: 0), at: 10_000, onScreen: false), [])
    }

    func testEachSourceHasItsOwnCadence() {
        let schedule = started(everything, at: 1_000)
        XCTAssertEqual(due(schedule, at: 1_059), [])
        XCTAssertEqual(due(schedule, at: 1_060), [.worktrees, .openPullRequests])
        XCTAssertEqual(due(schedule, at: 1_299), [.worktrees, .openPullRequests])
        XCTAssertEqual(due(schedule, at: 1_300), [.worktrees, .openPullRequests, .postMergeRun])
        XCTAssertEqual(due(schedule, at: 1_600), everything, "merged pull requests every 10 minutes")
    }

    func testARunningCheckHalvesThePullRequestInterval() {
        let schedule = started(everything, at: 1_000)
        XCTAssertEqual(due(schedule, at: 1_030, pending: true), [.openPullRequests])
        XCTAssertEqual(due(schedule, at: 1_030, pending: false), [])
    }

    func testAReadInFlightIsNotStartedAgain() {
        var schedule = ProjectBoard.RefreshSchedule()
        schedule.start(.openPullRequests, now: 0)
        XCTAssertFalse(due(schedule, at: 500).contains(.openPullRequests))
        schedule.finish(.openPullRequests)
        XCTAssertTrue(due(schedule, at: 500).contains(.openPullRequests))
    }

    func testOnlyAvailableSourcesAreRead() {
        XCTAssertEqual(due(ProjectBoard.RefreshSchedule(), at: 0, available: [.worktrees]), [.worktrees],
                       "without a repository, gh is never called")
    }

    func testRefreshMakesEverythingDueAtOnce() {
        var schedule = started(everything, at: 1_000)
        schedule.start(.postMergeRun, now: 1_001)
        schedule.reset()
        XCTAssertEqual(due(schedule, at: 1_002), everything, "a read still running answers for the old project")
    }

    func testAnExpiredSourceIsReadAtTheNextTick() {
        var schedule = started(everything, at: 1_000)
        schedule.expire(.worktrees)
        XCTAssertEqual(due(schedule, at: 1_001), [.worktrees])
        schedule.start(.worktrees, now: 1_001)
        schedule.expire(.worktrees)
        XCTAssertEqual(due(schedule, at: 1_002), [], "not while it is being read")
        schedule.finish(.worktrees)
        XCTAssertEqual(due(schedule, at: 1_003), [.worktrees], "that read may predate the change: again")
        schedule.start(.worktrees, now: 1_003)
        schedule.finish(.worktrees)
        XCTAssertEqual(due(schedule, at: 1_004), [])
    }

    func testTheClockKeepsCountingWhileTheMacSleeps() {
        // CLOCK_MONOTONIC counts sleep; systemUptime doesn't.
        XCTAssertGreaterThanOrEqual(ProjectBoard.clock(), ProcessInfo.processInfo.systemUptime - 1)
    }
}
