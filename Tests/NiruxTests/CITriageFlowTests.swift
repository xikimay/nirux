import AppKit
import XCTest
@testable import Nirux

/// docs/ci-failure-triage.md, in the shell: a pull request whose checks
/// failed says "likely flaky" on its row, in its menu and in its
/// notification once the triage says so, and stays a failure like any
/// other until then, without it, or when it is off. Reading the run is a
/// double: no test reaches GitHub or a model.
@MainActor
final class CITriageFlowTests: XCTestCase {
    private nonisolated static let reason = "The tests drive gears; the changes edit an axle."

    private static func pullRequest(_ checks: [[String: Any]]) -> PRInfo {
        PRDetect.pullRequestInfo(from: [
            "number": 52, "state": "OPEN", "url": "https://github.com/acme/widgets/pull/52", "statusCheckRollup": checks
        ])
    }

    private static func check(
        _ conclusion: String, run: Int = 7, job: Int = 11, startedAt: String = "2026-10-02T10:00:00Z", status: String = "COMPLETED"
    ) -> [String: Any] {
        ["__typename": "CheckRun", "name": "test", "workflowName": "Tests", "status": status, "conclusion": conclusion, "startedAt": startedAt,
         "detailsUrl": "https://github.com/acme/widgets/actions/runs/\(run)/job/\(job)"]
    }

    private static let red = pullRequest([check("FAILURE")])

    /// The double that reads a run: it answers once `open()` is called.
    private final class Reader: @unchecked Sendable {
        private let lock = NSLock()
        private var isOpen = false
        private var waiters: [CheckedContinuation<Void, Never>] = []
        private var seen: [CITriageInvestigation.Request] = []
        private var answer = CITriageInvestigation.Outcome(
            verdict: .flaky(reason: CITriageFlowTests.reason), tests: ["GearTests.testStops"], wasRead: true
        )

        var requests: [CITriageInvestigation.Request] { lock.withLock { seen } }

        func answers(_ outcome: CITriageInvestigation.Outcome) { lock.withLock { answer = outcome } }

        func open() {
            let waiting = lock.withLock {
                isOpen = true
                defer { waiters = [] }
                return waiters
            }
            waiting.forEach { $0.resume() }
        }

        func close() { lock.withLock { isOpen = false } }

        func read(_ request: CITriageInvestigation.Request) async -> CITriageInvestigation.Outcome {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let goes = lock.withLock {
                    seen.append(request)
                    if !isOpen { waiters.append(continuation) }
                    return isOpen
                }
                if goes { continuation.resume() }
            }
            return lock.withLock { answer }
        }
    }

    /// A shell with the triage on and its reader replaced.
    private func triaging(_ harness: UIFlowHarness, isOpen: Bool = true) throws -> (WorkspaceState, Reader) {
        let reader = Reader()
        if isOpen { reader.open() }
        harness.shell.sideEffects.investigateCIFailure = { await reader.read($0) }
        harness.shell.setCITriage(enabled: true)
        return (try XCTUnwrap(harness.shell.activeWorkspace), reader)
    }

    private func rowText(of workspace: WorkspaceState, in shell: NiruxShellView) throws -> String {
        shell.updateSidebar()
        return try XCTUnwrap(shell.sidebar.displayedWorkspaceInfos.first { $0.id == workspace.id }).rowSummary.status.text
    }

    private func banner(for workspace: WorkspaceState) throws -> CIFailureBanner {
        let pullRequest = try XCTUnwrap(workspace.prInfo)
        return CIFailureBanner(
            workspaceID: workspace.id, workspaceTitle: workspace.title, pullRequest: pullRequest.number, checkNames: ["test"],
            signature: CITriage.signature(of: CIFailure.redChecks(pullRequest))
        )
    }

    func testALikelyFlakeSaysSoOnItsRowAndPutsTheRerunFirst() throws {
        try UIFlowHarness.run { harness in
            let shell = harness.shell
            let (workspace, reader) = try triaging(harness, isOpen: false)
            let index = try XCTUnwrap(shell.workspaces.firstIndex { $0 === workspace })
            workspace.prInfo = Self.red
            shell.reportNewRedChecks(in: workspace)
            harness.waitUntil("the run to be read") { reader.requests.count == 1 }
            XCTAssertEqual(reader.requests.first?.run, CIFailure.Run(repository: "github.com/acme/widgets", id: 7))
            XCTAssertEqual(reader.requests.first?.pullRequest, 52)
            XCTAssertEqual(reader.requests.first?.isModelAllowed, false, "no Claude Code of Nirux's account in this workspace")
            XCTAssertEqual(try rowText(of: workspace, in: shell), "#52 · checks failed", "a failure like any other until the verdict")
            // Read again meanwhile: the triage on its way is the only one.
            shell.reportNewRedChecks(in: workspace)

            reader.open()
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
            XCTAssertEqual(reader.requests.count, 1, "a verdict is asked once")
        }
    }

    func testTheNotificationWaitsForTheVerdictButNotForLong() throws {
        try UIFlowHarness.run { harness in
            let shell = harness.shell
            let (workspace, reader) = try triaging(harness, isOpen: false)
            workspace.prInfo = Self.red
            shell.triageRedChecks(in: workspace)
            harness.waitUntil("the run to be read") { reader.requests.count == 1 }
            let before = harness.ciFailureNotices.count
            shell.postCIFailureBanner(try banner(for: workspace), for: workspace)
            XCTAssertEqual(harness.ciFailureNotices.count, before, "held: the verdict is on its way")
            reader.open()
            harness.waitUntil("the notification") { harness.ciFailureNotices.count == before + 1 }
            XCTAssertEqual(harness.ciFailureNotices.last?.flakyReason, Self.reason)
            XCTAssertEqual(harness.ciFailureNotices.last?.banner.pullRequest, 52)

            // The same failure again (the verdict is known): at once, with it.
            shell.postCIFailureBanner(try banner(for: workspace), for: workspace)
            XCTAssertEqual(harness.ciFailureNotices.count, before + 2)
            XCTAssertEqual(harness.ciFailureNotices.last?.flakyReason, Self.reason)

            // A new failure whose verdict takes too long: the notification
            // goes out without it, once; the row still gets it later.
            reader.close()
            shell.ciTriageCenter.notificationHold = 0.2
            workspace.prInfo = Self.pullRequest([Self.check("FAILURE", run: 8, job: 12)])
            shell.triageRedChecks(in: workspace)
            harness.waitUntil("the second run to be read") { reader.requests.count == 2 }
            shell.postCIFailureBanner(try banner(for: workspace), for: workspace)
            harness.waitUntil("the hold to end") { harness.ciFailureNotices.count == before + 3 }
            XCTAssertNil(harness.ciFailureNotices.last?.flakyReason)
            reader.open()
            harness.waitUntil("the late verdict") { workspace.ciFlakyReason != nil }
            XCTAssertEqual(harness.ciFailureNotices.count, before + 3, "no second notification")
        }
    }

    func testAVerdictIsOfTheFailureItReadOnly() throws {
        try UIFlowHarness.run { harness in
            let shell = harness.shell
            let (workspace, reader) = try triaging(harness, isOpen: false)
            workspace.prInfo = Self.red
            shell.triageRedChecks(in: workspace)
            harness.waitUntil("the run to be read") { reader.requests.count == 1 }
            // The rerun failed too before the first verdict came.
            reader.answers(CITriageInvestigation.Outcome(verdict: .real, tests: ["GearTests.testStops"], wasRead: true))
            workspace.prInfo = Self.pullRequest([Self.check("FAILURE", job: 12, startedAt: "2026-10-02T11:00:00Z")])
            shell.triageRedChecks(in: workspace)
            harness.waitUntil("the rerun to be read") { reader.requests.count == 2 }
            reader.open()
            harness.waitUntil("both verdicts") { workspace.ciTriage?.verdict == .real }
            XCTAssertNil(workspace.ciFlakyReason)
            XCTAssertEqual(try rowText(of: workspace, in: shell), "#52 · checks failed")

            // A check that is no run of this repository can't be read: no
            // verdict, and nothing asked.
            workspace.prInfo = Self.pullRequest([
                Self.check("FAILURE", run: 9, job: 13),
                ["__typename": "StatusContext", "context": "codecov/patch", "state": "FAILURE",
                 "targetUrl": "https://codecov.example/x", "startedAt": "2026-10-02T12:00:00Z"]
            ])
            shell.triageRedChecks(in: workspace)
            XCTAssertEqual(workspace.ciTriage?.verdict, .unsure)
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
            XCTAssertEqual(reader.requests.count, 1)

            // The rerun fails: its request says what failed the first time.
            reader.answers(CITriageInvestigation.Outcome(verdict: .real, tests: ["GearTests.testStops"], wasRead: true))
            workspace.prInfo = Self.pullRequest([Self.check("FAILURE", job: 12, startedAt: "2026-10-02T11:00:00Z")])
            shell.triageRedChecks(in: workspace)
            harness.waitUntil("the rerun to be read") { reader.requests.count == 2 }
            XCTAssertEqual(reader.requests.last?.previousAttemptTests, ["GearTests.testStops"])
            XCTAssertEqual(reader.requests.last?.knownFlaky, [])
            harness.waitUntil("its verdict") { workspace.ciTriage?.verdict == .real }

            // The next rerun passes: the test failed, then passed, on one commit.
            workspace.prInfo = Self.pullRequest([Self.check("SUCCESS", job: 13, startedAt: "2026-10-02T12:00:00Z")])
            shell.triageRedChecks(in: workspace)
            XCTAssertEqual(reader.requests.count, 2, "nothing red to read")
            workspace.prInfo = Self.pullRequest([Self.check("FAILURE", run: 8, job: 14, startedAt: "2026-10-02T13:00:00Z")])
            shell.triageRedChecks(in: workspace)
            harness.waitUntil("the next failure to be read") { reader.requests.count == 3 }
            XCTAssertEqual(reader.requests.last?.knownFlaky, ["GearTests.testStops"])
            XCTAssertEqual(reader.requests.last?.previousAttemptTests, [], "another run")
            harness.waitUntil("the store to be written") {
                CITriageStore.load(from: shell.ciTriageCenter.storeURL).record(of: CIFailure.Run(repository: "github.com/acme/widgets", id: 8)) != nil
            }
        }
    }

    func testARunThatCouldNotBeReadIsNotRemembered() throws {
        try UIFlowHarness.run { harness in
            let shell = harness.shell
            let (workspace, reader) = try triaging(harness)
            reader.answers(CITriageInvestigation.Outcome())
            workspace.prInfo = Self.red
            shell.triageRedChecks(in: workspace)
            harness.waitUntil("the verdict") { workspace.ciTriage != nil }
            XCTAssertEqual(workspace.ciTriage?.verdict, .unsure)
            XCTAssertNil(shell.ciTriageCenter.store.record(of: CIFailure.Run(repository: "github.com/acme/widgets", id: 7)))
            shell.triageRedChecks(in: workspace)
            XCTAssertEqual(reader.requests.count, 1, "not asked at every read of the pull request either")
        }
    }

    func testOffNothingIsReadAndNothingSaysFlaky() throws {
        try UIFlowHarness.run { harness in
            let shell = harness.shell
            let workspace = try XCTUnwrap(shell.activeWorkspace)
            let reader = Reader()
            reader.open()
            shell.sideEffects.investigateCIFailure = { await reader.read($0) }
            workspace.prInfo = Self.red
            shell.reportNewRedChecks(in: workspace)
            XCTAssertEqual(reader.requests.count, 0, "a shell starts with the triage off")

            shell.setCITriage(enabled: true)
            shell.triageRedChecks(in: workspace)
            harness.waitUntil("the verdict") { workspace.ciFlakyReason != nil }
            shell.setCITriage(enabled: false)
            XCTAssertNil(workspace.ciFlakyReason)
            XCTAssertEqual(try rowText(of: workspace, in: shell), "#52 · checks failed")
            shell.triageRedChecks(in: workspace)
            XCTAssertNil(workspace.ciTriage)
        }
    }

    /// Only a workspace whose Claude Code said it runs on Nirux's account
    /// lets a model read its failure.
    func testTheModelIsForWorkspacesOnNiruxsAccount() throws {
        try UIFlowHarness.run { harness in
            let shell = harness.shell
            let workspace = try XCTUnwrap(shell.activeWorkspace)
            let column = try XCTUnwrap(workspace.columns.first)
            // The shell at its prompt: the process in front stays the same.
            var foreground: ForegroundProcess?
            harness.waitUntil("the column's shell at its prompt") {
                foreground = column.pty?.foregroundProcess(snapshot: ProcessSnapshot())
                return foreground != nil && foreground?.instance.pid == column.pty?.shellPID
            }
            let process = try XCTUnwrap(foreground).instance
            XCTAssertFalse(shell.isCITriageModelAllowed(in: workspace), "nothing said so")
            column.noteClaudeAccount(onNiruxAccount: true, of: process)
            XCTAssertTrue(shell.isCITriageModelAllowed(in: workspace))
            // What another process said says nothing of the one in front.
            column.noteClaudeAccount(onNiruxAccount: true, of: ProcessInstance(pid: process.pid, startedAt: process.startedAt + 1))
            XCTAssertFalse(shell.isCITriageModelAllowed(in: workspace))
            column.noteClaudeAccount(onNiruxAccount: false, of: process)
            XCTAssertFalse(shell.isCITriageModelAllowed(in: workspace), "on an API key, or a cloud provider")
        }
    }
}
