import AppKit
import XCTest
@testable import Nirux

/// docs/design/ci-failure-triage.md, in the shell: a pull request whose checks
/// failed says "likely flaky" on its row, in its menu and in its
/// notification once the triage says so, and stays a failure like any
/// other until then, without it, or when it is off. Reading the run is a
/// double: no test reaches GitHub or a model.
@MainActor
final class CITriageFlowTests: XCTestCase {
    private nonisolated static let reason = "The tests drive gears; the changes edit an axle."
    private nonisolated static let gear = "GearTests.testStops"

    private static func pullRequest(_ checks: [[String: Any]]) -> PRInfo {
        PRDetect.pullRequestInfo(from: [
            "number": 52, "state": "OPEN", "url": "https://github.com/acme/widgets/pull/52", "statusCheckRollup": checks
        ])
    }

    private static func check(
        _ conclusion: String, run: Int = 7, job: Int = 11, startedAt: String = "2026-10-02T10:00:00Z", status: String = "COMPLETED"
    ) -> [String: Any] {
        ["__typename": "CheckRun", "name": "test", "workflowName": "Tests", "status": status, "conclusion": conclusion,
         "startedAt": startedAt, "detailsUrl": "https://github.com/acme/widgets/actions/runs/\(run)/job/\(job)"]
    }

    private static let red = pullRequest([check("FAILURE")])
    private static let rerunRed = pullRequest([check("FAILURE", job: 12, startedAt: "2026-10-02T11:00:00Z")])

    private nonisolated static func flaky() -> CITriageInvestigation.Outcome {
        CITriageInvestigation.Outcome(verdict: .flaky(reason: reason), tests: [gear], wasRead: true)
    }

    /// The double that reads a run. Each read waits until released (all of
    /// them at once with `releasesAll`) and answers what was set for it.
    private final class Reader: @unchecked Sendable {
        private let lock = NSLock()
        private var releasesAll: Bool
        private var released = Set<Int>()
        private var waiting: [Int: CheckedContinuation<Void, Never>] = [:]
        private var seen: [CITriageInvestigation.Request] = []
        private var answers: [Int: CITriageInvestigation.Outcome] = [:]
        private var fallback = CITriageFlowTests.flaky()
        private var wantedAnswers: [Bool] = []

        init(releasesAll: Bool) {
            self.releasesAll = releasesAll
        }

        var requests: [CITriageInvestigation.Request] { lock.withLock { seen } }
        /// What each read was told when it asked whether it was still wanted.
        var wanted: [Bool] { lock.withLock { wantedAnswers } }

        func answers(_ outcome: CITriageInvestigation.Outcome, forRead index: Int? = nil) {
            lock.withLock {
                if let index { answers[index] = outcome } else { fallback = outcome }
            }
        }

        func release(_ index: Int) {
            let continuation = lock.withLock { () -> CheckedContinuation<Void, Never>? in
                released.insert(index)
                return waiting.removeValue(forKey: index)
            }
            continuation?.resume()
        }

        func read(_ request: CITriageInvestigation.Request, isStillWanted: @Sendable () async -> Bool) async -> CITriageInvestigation.Outcome {
            let index = lock.withLock { () -> Int in
                seen.append(request)
                return seen.count - 1
            }
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let goes = lock.withLock { () -> Bool in
                    if releasesAll || released.contains(index) { return true }
                    waiting[index] = continuation
                    return false
                }
                if goes { continuation.resume() }
            }
            let isWanted = await isStillWanted()
            return lock.withLock {
                wantedAnswers.append(isWanted)
                return answers[index] ?? fallback
            }
        }
    }

    /// A shell with the triage on and its reader replaced. (The harness
    /// stops the heartbeat: no git context comes to clear a pull request a
    /// test sets.)
    private func triaging(_ harness: UIFlowHarness, releasesAll: Bool = true) throws -> (WorkspaceState, Reader) {
        let reader = Reader(releasesAll: releasesAll)
        harness.shell.sideEffects.investigateCIFailure = { await reader.read($0, isStillWanted: $1) }
        harness.shell.setCITriage(enabled: true)
        return (try XCTUnwrap(harness.shell.activeWorkspace), reader)
    }

    /// Gives the workspace its repository, as a git read would. Before a
    /// pull request is set: a new context clears it.
    private func giveRepository(_ root: String, to workspace: WorkspaceState) throws {
        let observation = try XCTUnwrap(workspace.beginGitContextObservation(at: root))
        _ = workspace.applyGitContextObservation(
            .observed(GitContext(branch: "main", identity: GitIdentity(repositoryRoot: root, head: nil))), observation: observation
        )
        XCTAssertEqual(workspace.gitContext?.identity.repositoryRoot, root)
    }

    private func rowText(of workspace: WorkspaceState, in shell: NiruxShellView) throws -> String {
        shell.updateSidebar()
        return try XCTUnwrap(shell.sidebar.displayedWorkspaceInfos.first { $0.id == workspace.id }).rowSummary.status.text
    }

    /// Lets work the shell may have started (a `Task`, a timer) run: what
    /// follows checks that it didn't do anything.
    private func settle(_ seconds: TimeInterval = 0.3) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    private let widgetsRun = CIFailure.Run(repository: "github.com/acme/widgets", id: 7)

    func testALikelyFlakeSaysSoOnItsRowAndPutsTheRerunFirst() throws {
        try UIFlowHarness.run { harness in
            let shell = harness.shell
            let (workspace, reader) = try triaging(harness, releasesAll: false)
            let index = try XCTUnwrap(shell.workspaces.firstIndex { $0 === workspace })
            workspace.prInfo = Self.red
            shell.reportNewRedChecks(in: workspace)
            harness.waitUntil("the run to be read") { reader.requests.count == 1 }
            XCTAssertEqual(reader.requests.first?.run, widgetsRun)
            XCTAssertEqual(reader.requests.first?.pullRequest, 52)
            XCTAssertEqual(reader.requests.first?.isModelAllowed, false, "no Claude Code of Nirux's account in this workspace")
            XCTAssertEqual(try rowText(of: workspace, in: shell), "#52 · checks failed", "a failure like any other until the verdict")
            // Read again meanwhile: the triage on its way is the only one.
            shell.reportNewRedChecks(in: workspace)
            settle()
            XCTAssertEqual(reader.requests.count, 1)

            reader.release(0)
            harness.waitUntil("the verdict") { workspace.ciFlakyReason != nil }
            XCTAssertEqual(try rowText(of: workspace, in: shell), "#52 · checks failed · likely flaky")
            let menu = shell.sidebar.workspaceActionMenu(workspaceIndex: index, columnIndex: nil)
            let titles = menu.items.map(\.title)
            let why = try XCTUnwrap(titles.firstIndex(of: "Likely flaky: " + Self.reason))
            XCTAssertEqual(Array(titles[why...].prefix(3)), ["Likely flaky: " + Self.reason, "Rerun Failed CI Jobs…", "Ask Agent Why CI Failed"])
            XCTAssertFalse(menu.items[why].isEnabled, "it says why; it does nothing")

            // Nirux never reruns by itself: the rerun is the user's, and asks first.
            harness.alertResponses = [.alertSecondButtonReturn]
            harness.perform(["Rerun Failed CI Jobs…"], in: menu)
            XCTAssertEqual(harness.alerts, ["Rerun the failed jobs of #52?"])

            shell.reportNewRedChecks(in: workspace)
            settle()
            XCTAssertEqual(reader.requests.count, 1, "a verdict is asked once")
        }
    }

    /// From the pull request read to the notification: it waits for the
    /// verdict, but not for long.
    func testTheNotificationWaitsForTheVerdictButNotForLong() throws {
        try UIFlowHarness.run { harness in
            let shell = harness.shell
            let (workspace, reader) = try triaging(harness, releasesAll: false)
            shell.ciTriageCenter.notificationHold = 3
            // The first read after launch only records what is red.
            shell.reportNewRedChecks(in: workspace, isAppActive: false)
            workspace.prInfo = Self.red
            shell.reportNewRedChecks(in: workspace, isAppActive: false)
            harness.waitUntil("the run to be read") { reader.requests.count == 1 }
            XCTAssertEqual(harness.ciFailureNotices.count, 0, "held: the verdict is on its way")
            reader.release(0)
            harness.waitUntil("the notification") { harness.ciFailureNotices.count == 1 }
            XCTAssertEqual(harness.ciFailureNotices.last?.flakyReason, Self.reason)
            XCTAssertEqual(harness.ciFailureNotices.last?.banner.pullRequest, 52)
            XCTAssertEqual(harness.ciFailureNotices.last?.banner.checkNames, ["test"])
            // The hold's end finds nothing left to send.
            settle(3.5)
            XCTAssertEqual(harness.ciFailureNotices.count, 1)

            // A new failure whose verdict takes too long: the notification
            // goes out without it, once; the row still gets it later.
            shell.ciTriageCenter.notificationHold = 0.2
            workspace.prInfo = Self.pullRequest([Self.check("FAILURE", run: 8, job: 12)])
            shell.reportNewRedChecks(in: workspace, isAppActive: false)
            harness.waitUntil("the second run to be read") { reader.requests.count == 2 }
            harness.waitUntil("the hold to end") { harness.ciFailureNotices.count == 2 }
            XCTAssertNil(harness.ciFailureNotices.last?.flakyReason)
            reader.release(1)
            harness.waitUntil("the late verdict") { workspace.ciFlakyReason != nil }
            settle()
            XCTAssertEqual(harness.ciFailureNotices.count, 2, "no second notification")
        }
    }

    /// One notification waits at a time: a second failure meanwhile sends
    /// the first's as it is, and neither is lost.
    func testANewFailureDuringTheHoldSendsTheFirstAsItIs() throws {
        try UIFlowHarness.run { harness in
            let shell = harness.shell
            let (workspace, reader) = try triaging(harness, releasesAll: false)
            shell.reportNewRedChecks(in: workspace, isAppActive: false)
            workspace.prInfo = Self.red
            shell.reportNewRedChecks(in: workspace, isAppActive: false)
            harness.waitUntil("the run to be read") { reader.requests.count == 1 }
            workspace.prInfo = Self.pullRequest([Self.check("FAILURE"), Self.check("FAILURE", run: 8, job: 12)])
            shell.reportNewRedChecks(in: workspace, isAppActive: false)
            harness.waitUntil("the first notification") { harness.ciFailureNotices.count == 1 }
            XCTAssertNil(harness.ciFailureNotices.first?.flakyReason, "sent as it is")
            harness.waitUntil("the second failure to be read") { reader.requests.count == 2 }
            reader.release(0)
            reader.release(1)
            harness.waitUntil("the second notification") { harness.ciFailureNotices.count == 2 }
            XCTAssertEqual(harness.ciFailureNotices.last?.banner.checkNames, ["test"])
            XCTAssertEqual(harness.ciFailureNotices.last?.flakyReason, Self.reason)
        }
    }

    /// A verdict on a failure the pull request has moved on from is
    /// dropped: it never shows, nor replaces what the later one kept.
    func testAVerdictIsOfTheFailureItReadOnly() throws {
        try UIFlowHarness.run { harness in
            let shell = harness.shell
            let (workspace, reader) = try triaging(harness, releasesAll: false)
            reader.answers(CITriageInvestigation.Outcome(verdict: .real, tests: [Self.gear], wasRead: true), forRead: 1)
            workspace.prInfo = Self.red
            shell.triageRedChecks(in: workspace)
            harness.waitUntil("the run to be read") { reader.requests.count == 1 }
            // The rerun failed too before the first verdict came.
            workspace.prInfo = Self.rerunRed
            shell.triageRedChecks(in: workspace)
            harness.waitUntil("the rerun to be read") { reader.requests.count == 2 }
            reader.release(1)
            harness.waitUntil("the rerun's verdict") { workspace.ciTriage?.verdict == .real }
            // The first read ends last, and said flaky.
            reader.release(0)
            harness.waitUntil("the first read to end") { reader.wanted.count == 2 }
            settle()
            XCTAssertEqual(workspace.ciTriage?.verdict, .real)
            XCTAssertNil(workspace.ciFlakyReason)
            XCTAssertEqual(try rowText(of: workspace, in: shell), "#52 · checks failed")
            XCTAssertEqual(shell.ciTriageCenter.store.record(of: widgetsRun)?.verdict, "real", "the store keeps the rerun's")

            // A check that is no run of this repository can't be read: no
            // verdict, and nothing asked.
            workspace.prInfo = Self.pullRequest([
                Self.check("FAILURE", run: 9, job: 13),
                ["__typename": "StatusContext", "context": "codecov/patch", "state": "FAILURE",
                 "targetUrl": "https://codecov.example/x", "startedAt": "2026-10-02T12:00:00Z"]
            ])
            shell.triageRedChecks(in: workspace)
            XCTAssertEqual(workspace.ciTriage?.verdict, .unsure)
            settle()
            XCTAssertEqual(reader.requests.count, 2)
        }
    }

    /// What a run said is kept: a relaunch reads it there. And a run that
    /// passes on a rerun teaches its tests, which the next failure made of
    /// them is told with.
    func testNiruxRemembersVerdictsAndLearnsFromReruns() throws {
        try UIFlowHarness.run { harness in
            let shell = harness.shell
            let (workspace, reader) = try triaging(harness)
            workspace.prInfo = Self.red
            shell.triageRedChecks(in: workspace)
            harness.waitUntil("the verdict") { workspace.ciFlakyReason != nil }

            // As after a relaunch: nothing in memory but the store.
            workspace.ciTriage = nil
            shell.triageRedChecks(in: workspace)
            XCTAssertEqual(workspace.ciFlakyReason, Self.reason, "read from the store, at once")
            settle()
            XCTAssertEqual(reader.requests.count, 1)
            XCTAssertEqual(reader.requests.first?.knownFlaky, [])

            // The rerun passes: the test failed, then passed, on one commit.
            workspace.prInfo = Self.pullRequest([Self.check("SUCCESS", job: 13, startedAt: "2026-10-02T12:00:00Z")])
            shell.triageRedChecks(in: workspace)
            XCTAssertNil(shell.ciTriageCenter.store.record(of: widgetsRun), "learned from, and gone")
            workspace.prInfo = Self.pullRequest([Self.check("FAILURE", run: 8, job: 14, startedAt: "2026-10-02T13:00:00Z")])
            shell.triageRedChecks(in: workspace)
            harness.waitUntil("the next failure to be read") { reader.requests.count == 2 }
            XCTAssertEqual(reader.requests.last?.knownFlaky, [Self.gear])
            harness.waitUntil("the store to be written") {
                shell.ciTriageCenter.store.record(of: CIFailure.Run(repository: "github.com/acme/widgets", id: 8)) != nil
            }
        }
    }

    /// A run `gh` couldn't read is neither remembered nor read at every
    /// poll: once more, later.
    func testARunThatCouldNotBeReadIsReadOnceMoreLater() throws {
        try UIFlowHarness.run { harness in
            let shell = harness.shell
            let (workspace, reader) = try triaging(harness)
            shell.ciTriageCenter.retryDelay = 0.3
            reader.answers(CITriageInvestigation.Outcome())
            workspace.prInfo = Self.red
            shell.triageRedChecks(in: workspace)
            harness.waitUntil("the verdict") { workspace.ciTriage != nil }
            XCTAssertEqual(workspace.ciTriage?.verdict, .unsure)
            XCTAssertNil(shell.ciTriageCenter.store.record(of: widgetsRun))
            shell.triageRedChecks(in: workspace)
            settle(0.1)
            XCTAssertEqual(reader.requests.count, 1, "not at every read of the pull request")

            settle(0.3)
            shell.triageRedChecks(in: workspace)
            harness.waitUntil("the second read") { reader.requests.count == 2 }
            harness.waitUntil("its end") { reader.wanted.count == 2 }
            settle(0.4)
            shell.triageRedChecks(in: workspace)
            settle(0.1)
            XCTAssertEqual(reader.requests.count, 2, "once more, not forever")
        }
    }

    /// The model couldn't answer (it rested, the agent wasn't running):
    /// the run is kept, the answer is asked for again.
    func testAnAnswerTheModelStillOwesIsAskedForAgain() throws {
        try UIFlowHarness.run { harness in
            let shell = harness.shell
            let (workspace, reader) = try triaging(harness)
            shell.ciTriageCenter.retryDelay = 0.3
            reader.answers(CITriageInvestigation.Outcome(verdict: .unsure, tests: [Self.gear], wasRead: true, isUnanswered: true), forRead: 0)
            workspace.prInfo = Self.red
            shell.triageRedChecks(in: workspace)
            harness.waitUntil("the first answer") { workspace.ciTriage != nil }
            XCTAssertEqual(shell.ciTriageCenter.store.record(of: widgetsRun)?.isFinal, false)
            // As after a relaunch: the store doesn't settle it.
            workspace.ciTriage = nil
            shell.triageRedChecks(in: workspace)
            harness.waitUntil("asked again") { workspace.ciFlakyReason != nil }
            XCTAssertEqual(reader.requests.count, 2)
            XCTAssertEqual(shell.ciTriageCenter.store.record(of: widgetsRun)?.isFinal, true)
        }
    }

    func testOffNothingIsReadAndNothingSaysFlaky() throws {
        try UIFlowHarness.run { harness in
            let shell = harness.shell
            let workspace = try XCTUnwrap(shell.activeWorkspace)
            let reader = Reader(releasesAll: false)
            shell.sideEffects.investigateCIFailure = { await reader.read($0, isStillWanted: $1) }
            workspace.prInfo = Self.red
            shell.reportNewRedChecks(in: workspace)
            settle()
            XCTAssertEqual(reader.requests.count, 0, "a shell starts with the triage off")

            // Turned off while a run is read: nothing goes to the model,
            // nothing is kept or shown.
            shell.setCITriage(enabled: true)
            shell.triageRedChecks(in: workspace)
            harness.waitUntil("the run to be read") { reader.requests.count == 1 }
            shell.setCITriage(enabled: false)
            reader.release(0)
            harness.waitUntil("the read to end") { reader.wanted == [false] }
            settle()
            XCTAssertNil(workspace.ciTriage)
            XCTAssertNil(shell.ciTriageCenter.store.record(of: widgetsRun))
            XCTAssertEqual(try rowText(of: workspace, in: shell), "#52 · checks failed")

            // On, then off: what it said goes.
            shell.setCITriage(enabled: true)
            reader.release(1)
            shell.triageRedChecks(in: workspace)
            harness.waitUntil("the verdict") { workspace.ciFlakyReason != nil }
            shell.setCITriage(enabled: false)
            XCTAssertNil(workspace.ciFlakyReason)
            shell.triageRedChecks(in: workspace)
            XCTAssertNil(workspace.ciTriage)
        }
    }

    func testAWorkspaceClosedMeanwhileLeavesNothingWaiting() throws {
        try UIFlowHarness.run { harness in
            let shell = harness.shell
            let (_, reader) = try triaging(harness, releasesAll: false)
            shell.addWorkspace(title: "closing", cwd: harness.repo)
            let closing = try XCTUnwrap(shell.workspaces.first { $0.title == "closing" })
            let id = closing.id
            closing.prInfo = Self.red
            shell.triageRedChecks(in: closing)
            harness.waitUntil("the run to be read") { reader.requests.count == 1 }
            XCTAssertNotNil(shell.ciTriageCenter.inFlight[id])
            shell.closeWorkspace(at: try XCTUnwrap(shell.workspaces.firstIndex { $0 === closing }))
            reader.release(0)
            harness.waitUntil("the triage to end") { shell.ciTriageCenter.inFlight[id] == nil }
            XCTAssertNil(shell.ciTriageCenter.heldBanners[id])
        }
    }

    /// Only a Claude Code of the pull request's repository that said it
    /// runs on Nirux's account lets a model read its failure.
    func testTheModelIsForAgentsOfThePullRequestsRepository() throws {
        try UIFlowHarness.run { harness in
            let shell = harness.shell
            let (workspace, reader) = try triaging(harness, releasesAll: false)
            let column = try XCTUnwrap(workspace.columns.first)
            XCTAssertFalse(shell.isCITriageModelAllowed(in: workspace), "no repository known")
            try giveRepository(harness.repo, to: workspace)
            // The shell at its prompt: the process in front stays the same.
            var foreground: ForegroundProcess?
            harness.waitUntil("the column's shell at its prompt") {
                foreground = column.pty?.foregroundProcess(snapshot: ProcessSnapshot())
                return foreground != nil && foreground?.instance.pid == column.pty?.shellPID
            }
            let process = try XCTUnwrap(foreground).instance
            XCTAssertFalse(shell.isCITriageModelAllowed(in: workspace), "nothing said so")
            column.noteClaudeAccount(onNiruxAccount: true, of: process, cwd: harness.home)
            XCTAssertFalse(shell.isCITriageModelAllowed(in: workspace), "a claude of another folder")
            column.noteClaudeAccount(onNiruxAccount: true, of: process, cwd: harness.repo + "/docs")
            XCTAssertTrue(shell.isCITriageModelAllowed(in: workspace))
            workspace.prInfo = Self.red
            shell.triageRedChecks(in: workspace)
            harness.waitUntil("the run to be read") { reader.requests.count == 1 }
            XCTAssertEqual(reader.requests.first?.isModelAllowed, true)
            // What another process said says nothing of the one in front.
            column.noteClaudeAccount(onNiruxAccount: true, of: ProcessInstance(pid: process.pid, startedAt: process.startedAt + 1), cwd: harness.repo)
            XCTAssertFalse(shell.isCITriageModelAllowed(in: workspace))
            column.noteClaudeAccount(onNiruxAccount: false, of: process, cwd: harness.repo)
            XCTAssertFalse(shell.isCITriageModelAllowed(in: workspace), "on an API key, or a cloud provider")
            reader.release(0)
        }
    }
}
