import XCTest
@testable import Nirux

/// When the board reads what (docs/design/project-board.md, section 6), on an
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

    /// The Lead's queue goes by the last open list while it stands and no
    /// read failed since; else it reads it again first.
    @MainActor
    func testTheLeadsQueueGoesByAnOpenListReadWithinItsInterval() throws {
        var reads = try XCTUnwrap(ProjectBoardController.RepositoryReads(config: BoardConfig(repository: "acme/widgets", baseBranch: "main")))
        let now = Date()
        XCTAssertFalse(reads.openListHolds([12], now: now), "never read")
        reads.openPullRequests = [ProjectBoard.PullRequest(
            number: 12, state: .open, headRefName: "feat/login", headOid: String(repeating: "a", count: 40), baseRefName: "main",
            isDraft: false, mergeable: "MERGEABLE", checks: [], url: "https://github.com/acme/widgets/pull/12", isFromConfiguredRepository: true
        )]
        reads.completeOpenNumbers = [12]
        reads.pullRequestsReadAt = now.addingTimeInterval(-120)
        XCTAssertTrue(reads.openListHolds([12], now: now), "two intervals, as the Board counts a read current")
        XCTAssertFalse(reads.openListHolds([12], now: now.addingTimeInterval(1)), "older")
        XCTAssertFalse(reads.openListHolds([12], now: now.addingTimeInterval(-121)), "read after now: the clock was set back")
        reads.errors[.openPullRequests] = .noAnswer("timeout")
        XCTAssertFalse(reads.openListHolds([12], now: now), "a read failed since")
    }

    func testTheClockKeepsCountingWhileTheMacSleeps() {
        // CLOCK_MONOTONIC counts sleep; systemUptime doesn't. The two are
        // read apart, and on a virtual machine they don't start together:
        // a GitHub runner had them 1.1 s apart. A clock that starts with
        // the process would be minutes behind.
        XCTAssertGreaterThanOrEqual(ProjectBoard.clock(), ProcessInfo.processInfo.systemUptime - 60)
    }
}
