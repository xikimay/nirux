import AppKit
import Security
import XCTest
@testable import Nirux

/// The merge queue from the board, in a real window: a line's Merge station, Start,
/// the confirmation sheet read off the main thread and reordered, the
/// queue run by the real driver over the real `gh` client, whose scripted
/// GitHub answers on another queue (the #48 path), then Stop. Every queue
/// here is a dry run: nothing is ever merged. Clicks are hit-tested by
/// hand, since a window that is never shown (CI) drops events sent with
/// `sendEvent`.
final class MergeQueueBoardFlowTests: XCTestCase {
    private var root: String!

    override func setUpWithError() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("nirux-merge-queue-board-flow-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        root = try XCTUnwrap(base.path.realPath)
    }

    override func tearDown() {
        MergeQueueController.waitForFiles()
        if let root { try? FileManager.default.removeItem(atPath: root) }
        super.tearDown()
    }

    private static let a = MQ.sha("a")
    private static let b = MQ.sha("b")

    /// What the board reads: #12 on the login worktree, #14 with no worktree.
    private static let boardPullRequests = """
    [
      {"number": 12, "state": "OPEN", "headRefName": "feat/login", "headRefOid": "\(a)",
       "headRepository": {"name": "widgets"}, "headRepositoryOwner": {"login": "acme"}, "baseRefName": "main",
       "isDraft": false, "mergeable": "MERGEABLE", "url": "https://github.com/acme/widgets/pull/12",
       "statusCheckRollup": []},
      {"number": 14, "state": "OPEN", "headRefName": "feat/api", "headRefOid": "\(b)",
       "headRepository": {"name": "widgets"}, "headRepositoryOwner": {"login": "acme"}, "baseRefName": "main",
       "isDraft": false, "mergeable": "MERGEABLE", "url": "https://github.com/acme/widgets/pull/14",
       "statusCheckRollup": []}
    ]
    """

    /// #14 based on `feat/old`, whose #10 merged.
    private static let retargetPullRequests = """
    [
      {"number": 12, "state": "OPEN", "headRefName": "feat/login", "headRefOid": "\(a)",
       "headRepository": {"name": "widgets"}, "headRepositoryOwner": {"login": "acme"}, "baseRefName": "main",
       "isDraft": false, "mergeable": "MERGEABLE", "url": "https://github.com/acme/widgets/pull/12",
       "statusCheckRollup": []},
      {"number": 14, "state": "OPEN", "headRefName": "feat/api", "headRefOid": "\(b)",
       "headRepository": {"name": "widgets"}, "headRepositoryOwner": {"login": "acme"}, "baseRefName": "feat/old",
       "baseRefOid": "\(MQ.sha("c"))", "isDraft": false, "mergeable": "MERGEABLE", "url": "https://github.com/acme/widgets/pull/14",
       "statusCheckRollup": []}
    ]
    """
    private static let mergedBase = """
    [{"number": 10, "state": "MERGED", "headRefName": "feat/old", "headRefOid": "\(MQ.sha("c"))",
      "headRepository": {"name": "widgets"}, "headRepositoryOwner": {"login": "acme"}, "baseRefName": "main",
      "url": "https://github.com/acme/widgets/pull/10"}]
    """

    // MARK: - Flows

    @MainActor
    private func callQueueTool(
        _ arguments: String, tool: String = LeadTools.queueMerge, shell: NiruxShellView, duringRead: () throws -> Void = {}
    ) throws -> (text: String, isError: Bool) {
        let lead = try XCTUnwrap(shell.workspaces.first { $0.title == "widgets" })
        lead.isLead = true
        let request = LeadChannel.Request(id: UUID().uuidString, tool: tool, arguments: arguments,
                                          workspaceID: lead.id, agentUUID: try XCTUnwrap(lead.columns.compactMap(\.agentUUID).first),
                                          createdAt: Date().timeIntervalSince1970)
        var result: (String, Bool)?
        shell.handleLeadRequest(request) { result = ($0, $1) }
        try duringRead()
        waitUntil("\(tool) answered") { result != nil }
        return try XCTUnwrap(result)
    }

    @MainActor
    func testLeadRequiresConfirmationByDefaultAndAlwaysForDryRuns() throws {
        let world = MergeQueueFlowTests.GitHubWorld(pullRequests: [14: Self.b])
        try withBoard(world: world) { shell, board in
            for optIn in [false, true] {
                shell.changeSpaceDefaults(spaceID: board.projectID) { $0.leadStartsMergeQueue = optIn ? true : nil }
                let response = try callQueueTool(#"{"prs":[14],"cadence":"batch_post_merge"}"#, shell: shell)
                XCTAssertFalse(response.isError, response.text)
                let sheet = try XCTUnwrap(shell.mergeQueueConfirmation)
                waitUntil("proposed cadence is visible") { sheet.confirmation != nil }
                XCTAssertEqual(sheet.confirmation?.cadence, .batchPostMerge)
                XCTAssertNil(shell.boardQueue(board, section: nil)?.engine)
                sheet.dismiss()
            }
            XCTAssertTrue(world.mergedNumbers.isEmpty)
        }
    }

    @MainActor
    func testDeveloperLiveOverrideStillNeedsManualConfirmation() throws {
        let world = MergeQueueFlowTests.GitHubWorld(pullRequests: [14: Self.b])
        let override = MergeQueue.client(environment: ["NIRUX_MERGE_QUEUE_LIVE": "1"], bundleURL: Bundle.main.bundleURL,
                                         signature: .notRelease(errSecCSReqFailed), live: GitHubCLIQueueClient(gh: world.run))
        try withBoard(queueClient: override) { shell, board in
            shell.changeSpaceDefaults(spaceID: board.projectID) { $0.leadStartsMergeQueue = true }
            let result = try callQueueTool(#"{"prs":[14]}"#, shell: shell)
            XCTAssertFalse(result.isError, result.text)
            let sheet = try XCTUnwrap(shell.mergeQueueConfirmation)
            waitUntil("the live override is ready for the user") { sheet.startButton?.isEnabled == true }
            XCTAssertEqual(sheet.confirmation?.isDryRun, false)
            XCTAssertNil(shell.boardQueue(board, section: nil)?.engine)
            XCTAssertTrue(world.mergedNumbers.isEmpty)
        }
    }

    @MainActor
    func testLiveLeadStartChecksTheWholeProposalAndKeepsStopInReach() throws {
        let client = FakeQueueClient()
        try withBoard(queueClient: client) { shell, board in
            let queue = shell.mergeQueue(projectID: board.projectID, repository: MQ.widgets)
            var green = MQ.World()
            green.pullRequests[14] = MQ.pullRequest(14, head: Self.b)
            green.details[14] = MergeQueue.PullRequestDetails(title: "API", files: ["API.swift"], hasMoreFiles: false,
                                                             head: Self.b, baseBranch: "main", allPathsKnown: true)
            green.checks[Self.b] = MQ.checks(MQ.checkRun(id: 1))
            green.baseRuns = [MQ.run(1, head: Self.a)]
            client.update { $0 = green }
            let args = #"{"prs":[14]}"#
            queue.addToSelection(12, repository: MQ.widgets)
            let replacement = #"{"prs":[14],"cadence":"batch_post_merge","replace":true}"#
            let disabled = try callQueueTool(replacement, shell: shell)
            XCTAssertTrue(disabled.isError)
            XCTAssertEqual(queue.selection, [12])
            queue.removeFromSelection(12)
            let manual = try callQueueTool(args, shell: shell)
            XCTAssertFalse(manual.isError, manual.text)
            let sheet = try XCTUnwrap(shell.mergeQueueConfirmation)
            waitUntil("manual preflight completed") { sheet.confirmation != nil }
            shell.changeSpaceDefaults(spaceID: board.projectID) { $0.leadStartsMergeQueue = true }
            let sheetOpen = try callQueueTool(#"{"prs":[12],"replace":true}"#, shell: shell)
            XCTAssertTrue(sheetOpen.isError)
            XCTAssertTrue(sheetOpen.text.contains("sheet is already open"), sheetOpen.text)
            XCTAssertEqual(queue.selection, [14])
            XCTAssertNil(queue.engine)
            sheet.dismiss()
            queue.removeFromSelection(14)
            shell.changeSpaceDefaults(spaceID: board.projectID) { $0.leadStartsMergeQueue = true }

            @MainActor func refused(_ args: String, _ reason: String, duringRead: () throws -> Void = {}) throws {
                let reply = try callQueueTool(args, shell: shell, duringRead: duringRead)
                XCTAssertTrue(reply.isError, reply.text)
                XCTAssertTrue(reply.text.localizedCaseInsensitiveContains(reason), reply.text)
                XCTAssertNil(queue.engine)
                XCTAssertTrue(client.mutations.isEmpty)
            }
            try refused(#"{"prs":[14],"cadence":"fast"}"#, "cadence")
            try refused(#"{"prs":[14],"cadence":"express_disjoint"}"#, "at least two")
            client.update { $0.details[14] = .init(title: "CI", files: [".github/workflows/test.yml"], hasMoreFiles: false,
                                                    head: Self.b, baseBranch: "main", allPathsKnown: true) }
            try refused(args, ".github/workflows/")
            client.update { $0.details[14] = .init(title: "Big", files: [], hasMoreFiles: true, head: Self.b, baseBranch: "main") }
            try refused(args, "more than 100")
            client.update { $0 = green; $0.baseRuns = [MQ.run(1, head: Self.a, conclusion: "failure")] }
            try refused(args, "failed")
            client.update { $0 = green; $0.checks[Self.b] = MQ.checks(MQ.checkRun(id: 1, conclusion: "FAILURE")) }
            try refused(args, "green")
            client.update { $0 = green }
            try refused(args, "selection changed") { queue.addToSelection(12, repository: MQ.widgets) }
            try refused(args, "preparing")
            XCTAssertEqual(queue.selection, [12])
            queue.removeFromSelection(12)
            try refused(args, "permission") { shell.changeSpaceDefaults(spaceID: board.projectID) { $0.leadStartsMergeQueue = nil } }
            shell.changeSpaceDefaults(spaceID: board.projectID) { $0.leadStartsMergeQueue = true }

            queue.addToSelection(12, repository: MQ.widgets)
            try refused(replacement, "selection changed") { queue.addToSelection(90, repository: MQ.widgets) }
            XCTAssertEqual(queue.selection, [12, 90])
            client.update { $0.baseRuns = [MQ.run(1, head: Self.a, conclusion: "failure")] }
            let review = try callQueueTool(replacement, shell: shell)
            XCTAssertFalse(review.isError, review.text)
            XCTAssertTrue(review.text.contains("confirmation sheet"), review.text)
            XCTAssertNil(queue.engine)
            XCTAssertEqual(queue.selection, [14])
            try XCTUnwrap(shell.mergeQueueConfirmation).dismiss()
            client.update { $0 = green }
            queue.proposeSelection([12], repository: MQ.widgets)
            let started = try callQueueTool(replacement, shell: shell)
            XCTAssertFalse(started.isError, started.text)
            XCTAssertNil(shell.mergeQueueConfirmation)
            XCTAssertEqual(queue.saved?.startedByLead, true)
            XCTAssertEqual(queue.engine?.cadence, .batchPostMerge)
            XCTAssertEqual(queue.engine?.entries.map(\.number), [14])
            XCTAssertEqual(shell.statusBar.queueNotice?.isRunning, true)
            XCTAssertFalse(try header(of: board).stopButton.isHidden)
            shell.stopMergeQueue(board: board, section: nil)
            MergeQueueController.waitForFiles()
            let journal = try String(contentsOf: XCTUnwrap(queue.files).journal, encoding: .utf8)
            XCTAssertTrue(journal.contains("Started by Lead"), journal)
        }
    }

    @MainActor
    func testLeadStatusAndStopFollowAnInFlightMergeThroughItsJournal() throws {
        var world = MQ.World()
        world.pullRequests[14] = MQ.pullRequest(14, head: Self.b)
        world.checks[Self.b] = MQ.checks(MQ.checkRun(id: 1))
        let client = HeldMutationClient(world: world)
        try withBoard(queueClient: client) { shell, board in
            let queue = shell.mergeQueue(projectID: board.projectID, repository: MQ.widgets)
            let status = { try self.callQueueTool("{}", tool: LeadTools.mergeQueueStatus, shell: shell).text }
            let stop = { try self.callQueueTool("{}", tool: LeadTools.stopMergeQueue, shell: shell) }
            queue.addToSelection(90, repository: MQ.widgets)
            let idle = try status()
            XCTAssertTrue(idle.contains("Phase: idle"), idle)
            XCTAssertTrue(idle.contains("#90 (closed or stale)"), idle)
            XCTAssertTrue(idle.contains("Lead auto-start: disabled"), idle)
            shell.changeSpaceDefaults(spaceID: board.projectID) { $0.leadStartsMergeQueue = true }
            let noRun = try stop()
            XCTAssertTrue(noRun.isError)
            XCTAssertTrue(noRun.text.contains("No queue is running here"), noRun.text)
            XCTAssertNil(queue.start(settings: MQ.settings(), entries: [MQ.entry(14, head: Self.b), MQ.entry(12, head: Self.a)]))
            defer { client.release() }
            waitUntil("merge command in flight") { client.isHoldingMutation }
            let running = try status()
            for field in ["Phase: running", "Cadence: Standard", "Current PR: #14", "merging #14", "Remaining PRs: #12", "Started by: user"] {
                XCTAssertTrue(running.contains(field), running)
            }
            shell.changeSpaceDefaults(spaceID: board.projectID) { $0.leadStartsMergeQueue = nil }
            let disabled = try stop()
            XCTAssertTrue(disabled.isError)
            XCTAssertTrue(disabled.text.contains("Space Settings › Lead"), disabled.text)
            XCTAssertEqual(queue.engine?.phase, .running)
            shell.changeSpaceDefaults(spaceID: board.projectID) { $0.leadStartsMergeQueue = true }
            let accepted = try stop()
            XCTAssertFalse(accepted.isError, accepted.text)
            XCTAssertTrue(accepted.text.contains("next command"), accepted.text)
            XCTAssertTrue(try status().contains("Phase: stopping"))
            client.release()
            waitUntil("in-flight merge answered") { !queue.isRunning }
            let ended = try status()
            for field in ["Phase: ended", "Current PR: #14", "Stopped by Lead", "already sent, answered"] {
                XCTAssertTrue(ended.contains(field), ended)
            }
            let journal = try XCTUnwrap(ended.components(separatedBy: "Recent journal entries:\n").last)
            XCTAssertTrue(journal.contains("Stopped by Lead"), journal)
            XCTAssertLessThanOrEqual(journal.split(separator: "\n").count, 10)
        }
    }

    @MainActor
    func testLeadStatusReadsClosedBoardAndReportsMissingSettings() throws {
        let lines = (1...12).map { MergeQueue.Journal.Line(time: "now", pr: nil, step: "queue", result: "entry-\($0).") }
        try withBoard(previousJournal: lines) { shell, board in
            let location = try XCTUnwrap(shell.projectBoardLocation(projectID: board.projectID))
            location.workspace.closeColumn(at: try XCTUnwrap(location.workspace.columns.firstIndex { $0 === location.column }))
            XCTAssertNil(shell.projectBoardLocation(projectID: board.projectID))
            let status = try callQueueTool(#"{"repo":"ACME/WIDGETS"}"#, tool: LeadTools.mergeQueueStatus, shell: shell)
            XCTAssertFalse(status.isError, status.text)
            XCTAssertTrue(status.text.contains("Phase: idle"), status.text)
            XCTAssertTrue(status.text.contains("Build: dry run"), status.text)
            XCTAssertFalse(status.text.contains("entry-2."), status.text)
            XCTAssertTrue(status.text.contains("entry-3."), status.text)
            XCTAssertTrue(status.text.hasSuffix("entry-12."), status.text)
            try FileManager.default.removeItem(at: XCTUnwrap(BoardConfigStore(spaceID: board.projectID)).fileURL)
            let missing = try callQueueTool("{}", tool: LeadTools.mergeQueueStatus, shell: shell)
            XCTAssertTrue(missing.isError)
            XCTAssertTrue(missing.text.contains("Board Settings"), missing.text)
        }
    }

    @MainActor
    func testLeadRefusesToStopOrReplaceAQueueRunningElsewhere() throws {
        try withBoard(queueClient: FakeQueueClient()) { shell, board in
            let queue = shell.mergeQueue(projectID: board.projectID, repository: MQ.widgets)
            let lock = try XCTUnwrap(MergeQueueLock.acquire(repository: MQ.widgets, folder: shell.mergeQueueLockFolder))
            defer { lock.release() }
            let engine = MergeQueue.Engine(settings: MQ.settings(), entries: [MQ.entry(14, head: Self.b)])
            MergeQueue.SavedQueue(engine: engine, dryRun: false, savedAt: Date()).save(to: try XCTUnwrap(queue.files?.state))
            shell.changeSpaceDefaults(spaceID: board.projectID) { $0.leadStartsMergeQueue = true }
            let status = try callQueueTool("{}", tool: LeadTools.mergeQueueStatus, shell: shell)
            XCTAssertTrue(status.text.contains("Phase: running elsewhere"), status.text)
            let stop = try callQueueTool("{}", tool: LeadTools.stopMergeQueue, shell: shell)
            XCTAssertTrue(stop.isError)
            XCTAssertTrue(stop.text.contains("another Nirux"), stop.text)
            let replace = try callQueueTool(#"{"prs":[12],"replace":true}"#, shell: shell)
            XCTAssertTrue(replace.isError)
            XCTAssertTrue(queue.selection.isEmpty)
        }
    }

    @MainActor
    func testAQueueStartsFromTheBoardThroughTheSheetInTheUsersOrder() throws {
        let world = MergeQueueFlowTests.GitHubWorld(pullRequests: [12: Self.a, 14: Self.b])
        try withBoard(world: world) { shell, board in
            // A click on a line's Merge station, Add to Queue in another's menu: the list goes by number.
            try BoardStagesClicks.pressMerge(try line("feat/api", in: board))
            waitUntil("#14 is queued") { (BoardStagesClicks.shownLine("feat/api", in: board)?.line.offer?.change) == .remove }
            try BoardStagesClicks.choose("Add to Queue", in: try line("login", in: board).contextMenu())
            waitUntil("#12 is queued") { (BoardStagesClicks.shownLine("login", in: board)?.line.offer?.change) == .remove }
            let queue = shell.mergeQueue(projectID: board.projectID, repository: MQ.widgets)
            XCTAssertEqual(queue.selection, [12, 14])
            XCTAssertEqual(try line("login", in: board).line.tooltips.stations[.merge], "Remove from Queue")
            let header = try self.header(of: board)
            BoardStagesClicks.layOut(header)
            XCTAssertFalse(header.dryRunBadge.isHidden, "a dev build's queue is a dry run, and says so")
            XCTAssertTrue(header.dryRunBadge.toolTip?.hasSuffix("\nThis build: NIRUX_STATE_DIR is set.") == true,
                          "and why: \(header.dryRunBadge.toolTip ?? "")")
            XCTAssertEqual(header.startButton.title, "Start Dry Run… · 2")
            XCTAssertEqual(header.queueLabel.stringValue, "2 pull requests queued")

            XCTAssertTrue(header.journalButton.isHidden)
            try BoardStagesClicks.click(header.startButton)
            let sheet = try XCTUnwrap(shell.mergeQueueConfirmation)
            XCTAssertFalse(header.startButton.isEnabled, "one sheet at a time")
            waitUntil("the sheet read GitHub") { sheet.confirmation != nil }
            let confirmation = try XCTUnwrap(sheet.confirmation)
            XCTAssertEqual(confirmation.refusals, [])
            XCTAssertEqual(confirmation.entries.map(\.number), [12, 14])
            XCTAssertEqual(confirmation.entries.map(\.head), [Self.a, Self.b], "the heads GitHub has now")
            XCTAssertEqual(Array(sheet.lines.prefix(2)), [
                MergeQueueConfirmationPanel.dryRunExplanation, "This build: NIRUX_STATE_DIR is set."
            ])
            XCTAssertTrue(sheet.lines.contains("1. #12  Change 12"), "\(sheet.lines)")
            XCTAssertTrue(sheet.lines.contains("A real queue would publish 2 nightlies, one after each merge. This dry run publishes none."))
            XCTAssertEqual(sheet.startButton?.title, "Start Dry Run")
            XCTAssertTrue(world.answeredOffMain, "the sheet read GitHub off the main thread")

            // The user's order: #14 first.
            try click(try XCTUnwrap(sheet.moveButtons.first?.down))
            XCTAssertEqual(sheet.confirmation?.entries.map(\.number), [14, 12])
            XCTAssertTrue(sheet.lines.contains("1. #14  Change 14"))
            try click(try XCTUnwrap(sheet.startButton))
            XCTAssertNil(shell.mergeQueueConfirmation, "started: the sheet is gone")

            XCTAssertEqual(queue.engine?.entries.map(\.number), [14, 12])
            waitUntil("the dry run stops at its first mutation") { !queue.isRunning }
            guard case .stopped(let reason)? = queue.engine?.phase else { return XCTFail("not stopped") }
            XCTAssertEqual(reason.kind, .dryRun)
            XCTAssertTrue(reason.message.contains("gh pr merge 14"), reason.message)
            XCTAssertEqual(world.mergedNumbers, [], "a dry run merges nothing")
            XCTAssertEqual(world.forbiddenCalls, [])
            XCTAssertFalse(world.allCalls.contains { $0.first == "pr" && $0.dropFirst().first == "merge" })

            waitUntil("the board shows where it stopped") { header.queueLabel.stringValue.hasPrefix("Stopped: Dry run") }
            XCTAssertEqual(queue.selection, [14, 12], "both still in the next Start's list, in the user's order")
            XCTAssertEqual(header.startButton.title, "Start Dry Run… · 2")
            let notice = try XCTUnwrap(shell.statusBar.queueNotice)
            XCTAssertTrue(notice.text.hasPrefix("Queue (dry run) stopped: Dry run"), notice.text)
        }
    }

    @MainActor
    func testEverySheetOpensInStandardAndStartsOnlyTheSelectedCadenceAsADryRun() throws {
        let world = MergeQueueFlowTests.GitHubWorld(pullRequests: [12: Self.a, 14: Self.b])
        try withBoard(world: world) { shell, board in
            try BoardStagesClicks.pressMerge(try line("login", in: board))
            waitUntil("#12 is queued") { BoardStagesClicks.shownLine("login", in: board)?.line.offer?.change == .remove }
            try BoardStagesClicks.pressMerge(try line("feat/api", in: board))
            waitUntil("#14 is queued") { BoardStagesClicks.shownLine("feat/api", in: board)?.line.offer?.change == .remove }
            let header = try self.header(of: board)
            let queue = shell.mergeQueue(projectID: board.projectID, repository: MQ.widgets)
            for cadence in [MergeQueue.Cadence.batchPostMerge, .expressDisjoint] {
                try BoardStagesClicks.click(header.startButton)
                let sheet = try XCTUnwrap(shell.mergeQueueConfirmation)
                waitUntil("the cadence picker is ready") { sheet.cadencePicker != nil }
                let picker = try XCTUnwrap(sheet.cadencePicker)
                XCTAssertEqual(sheet.confirmation?.cadence, .standard)
                XCTAssertEqual(picker.titleOfSelectedItem, "Standard")
                XCTAssertTrue(sheet.lines.contains { $0.contains("publish 2 nightlies") })
                XCTAssertTrue(try XCTUnwrap(picker.item(withTitle: cadence.title)).isEnabled)
                picker.selectItem(withTitle: cadence.title)
                XCTAssertTrue(picker.sendAction(picker.action, to: picker.target))
                XCTAssertEqual(sheet.confirmation?.cadence, cadence)
                XCTAssertTrue(sheet.lines.contains("A real queue would verify nightly.yml once, on the final merge of 2 pull requests. This dry run publishes nothing."))
                try click(try XCTUnwrap(sheet.startButton))
                waitUntil("the dry run stops") { !queue.isRunning }
                guard case .stopped(let reason)? = queue.engine?.phase else { return XCTFail("queue did not stop") }
                XCTAssertEqual(reason.kind, .dryRun)
                XCTAssertEqual(queue.saved?.effectiveCadence, cadence)
                XCTAssertEqual(world.mergedNumbers, [])
                waitUntil("Start is ready again") { header.startButton.isEnabled && !header.startButton.isHidden }
            }
        }
    }

    @MainActor
    func testStopFromTheBoardEndsAWaitingQueue() throws {
        // Checks still running: the queue waits between looks.
        let world = MergeQueueFlowTests.GitHubWorld(pullRequests: [12: Self.a, 14: Self.b], testConclusion: nil)
        try withBoard(world: world) { shell, board in
            try BoardStagesClicks.pressMerge(try line("login", in: board))
            waitUntil("#12 is queued") { (BoardStagesClicks.shownLine("login", in: board)?.line.offer?.change) == .remove }
            let header = try self.header(of: board)
            try BoardStagesClicks.click(header.startButton)
            let sheet = try XCTUnwrap(shell.mergeQueueConfirmation)
            waitUntil("the sheet read GitHub") { sheet.startButton?.isEnabled == true }
            try click(try XCTUnwrap(sheet.startButton))

            let queue = shell.mergeQueue(projectID: board.projectID, repository: MQ.widgets)
            waitUntil("the queue waits for the checks") {
                if case .waitingForChecks? = queue.engine?.currentEntry?.step { return true }
                return false
            }
            waitUntil("the line says so") { (BoardStagesClicks.shownLine("login", in: board)?.line.phrase.text) == "Auto · Waiting for checks" }
            BoardStagesClicks.layOut(header)
            XCTAssertTrue(header.startButton.isHidden)
            XCTAssertFalse(header.stopButton.isHidden, "Stop is in reach while it runs")
            XCTAssertEqual(board.view.stages.runningQueueViews.map(\.queue.title), ["acme/widgets"], "and at the Board's foot")
            try BoardStagesClicks.click(header.stopButton)
            XCTAssertFalse(queue.isRunning)
            XCTAssertEqual(header.queueLabel.stringValue, "Stopped: Stopped by the user. · 1 pull request queued")
            BoardStagesClicks.layOut(header)
            XCTAssertTrue(header.stopButton.isHidden)
            XCTAssertEqual(header.startButton.isEnabled, true, "a new Start opens a new sheet")
            XCTAssertEqual(board.view.stages.runningQueueViews.count, 0)

            try BoardStagesClicks.click(header.journalButton)
            let journal = try XCTUnwrap(board.view.window?.attachedSheet as? MergeQueueJournalPanel)
            waitUntil("the journal includes Stop") { journal.snapshot?.entriesText.contains("Stopped by the user.") == true }
            let snapshot = try XCTUnwrap(journal.snapshot)
            XCTAssertEqual(snapshot.status, "Stopped: Stopped by the user.")
            XCTAssertTrue(snapshot.title.contains("Dry Run"))
            XCTAssertEqual(snapshot.link?.absoluteString, "https://github.com/acme/widgets/pull/12")
            journal.pasteboard = NSPasteboard.withUniqueName()
            defer { journal.pasteboard.releaseGlobally() }
            try click(journal.copyButton)
            XCTAssertEqual(journal.pasteboard.string(forType: .string), snapshot.copyText)

            let files = try XCTUnwrap(queue.files)
            MergeQueue.Journal(url: files.journal).append([.init(time: "later", pr: 12, step: "queue", result: "refreshed")])
            try click(journal.refreshButton)
            waitUntil("Refresh reads the latest line") { journal.snapshot?.entriesText.hasSuffix("refreshed") == true }
            try click(journal.doneButton)
            waitUntil("the journal closed") { board.view.window?.attachedSheet == nil }
        }
    }

    @MainActor
    func testJournalOpensFromItsRotatedFileWithoutSavedState() throws {
        let world = MergeQueueFlowTests.GitHubWorld(pullRequests: [12: Self.a])
        let last = MergeQueue.Journal.Line(time: "now", pr: 12, step: "preflight", result: "Stopped: draft")
        try withBoard(world: world, isDryRun: false, previousJournal: [last]) { shell, board in
            let header = try self.header(of: board)
            waitUntil("the Board found the rotated live journal") { !header.journalButton.isHidden }
            var opened: [URL] = []
            shell.sideEffects.openURL = { opened.append($0) }
            try BoardStagesClicks.click(header.journalButton)
            let panel = try XCTUnwrap(board.view.window?.attachedSheet as? MergeQueueJournalPanel)
            waitUntil("the stop is shown") { panel.copyButton.isEnabled }
            let snapshot = try XCTUnwrap(panel.snapshot)
            XCTAssertEqual(snapshot.status, last.result)
            XCTAssertFalse(snapshot.title.contains("Dry Run"))
            let scroll = try XCTUnwrap(panel.contentView?.subviews.compactMap { $0 as? NSScrollView }.first)
            let text = try XCTUnwrap(scroll.documentView as? NSTextView)
            XCTAssertTrue(text.string.hasPrefix("Stopped: draft\nOpen on GitHub"))
            XCTAssertTrue(text.string.hasSuffix("now · #12 · preflight · Stopped: draft"))
            let index = (text.string as NSString).range(of: "Open on GitHub").location
            let link = try XCTUnwrap(text.textStorage?.attribute(.link, at: index, effectiveRange: nil) as? URL)
            XCTAssertTrue(panel.textView(text, clickedOnLink: link, at: index))
            XCTAssertEqual(opened.map(\.absoluteString), ["https://github.com/acme/widgets/pull/12"])
            try click(panel.doneButton)
        }
    }

    /// #14 is based on #10's branch, merged: Retarget bases it on `main`
    /// off the main thread, then the board reads the pull requests again.
    /// No queue starts, so the live client is never called.
    @MainActor
    func testRetargetFromTheBoardChangesTheBaseThenReadsAgain() throws {
        let client = ProjectBoardFlowTests.FakeGitHub(
            openPullRequests: Self.retargetPullRequests, mergedPullRequests: Self.mergedBase,
            runs: ProjectBoardGitHubTests.postMergeRuns
        )
        let world = MergeQueueFlowTests.GitHubWorld(pullRequests: [12: Self.a, 14: Self.b])
        try withBoard(world: world, boardClient: client, isDryRun: false) { shell, board in
            waitUntil("#10 reads merged") {
                (BoardStagesClicks.shownLine("feat/api", in: board)?.line.phrase.link) == .retarget(number: 14, onto: "main")
            }
            XCTAssertEqual(try line("feat/api", in: board).line.phrase.text, "Base #10 merged · Retarget to main")
            // GitHub refuses: the repository's pill says why, until Refresh.
            client.retargetFailure = .refused(status: 422, message: "Validation Failed")
            try BoardStagesClicks.pressLink(try line("feat/api", in: board))
            let header = try self.header(of: board)
            waitUntil("the refusal shows") { header.pill.status?.toolTip?.contains("Retarget #14: Validation Failed (HTTP 422)") == true }
            XCTAssertEqual(header.pill.status?.tone, .error)
            XCTAssertTrue(board.view.refreshButton.toolTip?.contains("Retarget #14: Validation Failed (HTTP 422)") == true, "and under Refresh")
            client.retargetFailure = nil
            try BoardStagesClicks.click(board.view.refreshButton)
            waitUntil("Refresh clears it") { header.pill.status?.tone != .error && BoardStagesClicks.wasUpdated(board) }

            let reads = client.calls.filter { $0.what == "pr open acme/widgets" }.count
            try BoardStagesClicks.choose("Retarget to main", in: try line("feat/api", in: board).contextMenu())
            waitUntil("the pull requests are read again") {
                client.calls.filter { $0.what == "pr open acme/widgets" }.count > reads
            }
            XCTAssertEqual(client.calls.filter { $0.what.hasPrefix("retarget") }.map(\.what),
                           ["retarget acme/widgets #14 main", "retarget acme/widgets #14 main"])
            // A pull request none of the section's lines has: not retargeted.
            let section = try XCTUnwrap(board.view.stages.content?.sections.first?.id)
            shell.performBoardLink(.retarget(number: 99, onto: "main"), line: nil, section: section, board: board)
            RunLoop.main.run(until: Date().addingTimeInterval(1))
            XCTAssertFalse(client.calls.contains { $0.what.contains("#99") })

            // The confirmation sheet locks the list: the link held under the pointer, or the offer of a line held so,
            // changes nothing, and says why.
            try BoardStagesClicks.pressMerge(try line("login", in: board))
            waitUntil("#12 is queued") { (BoardStagesClicks.shownLine("login", in: board)?.line.offer?.change) == .remove }
            try BoardStagesClicks.click(header.startButton)
            XCTAssertNotNil(shell.mergeQueueConfirmation)
            waitUntil("the link goes") { (BoardStagesClicks.shownLine("feat/api", in: board)?.line.phrase.link) == nil }
            let locked = "The confirmation sheet is open: change the list once it closes."
            shell.performBoardLink(.retarget(number: 14, onto: "main"), line: nil, section: section, board: board)
            XCTAssertEqual(shell.toast?.message, locked)
            shell.toast?.removeFromSuperview()
            shell.toast = nil
            shell.performBoardOffer(BoardStages.QueueOffer(change: .remove, number: 12), section: section, board: board)
            XCTAssertEqual(shell.toast?.message, locked)
            XCTAssertEqual(shell.mergeQueue(projectID: board.projectID, repository: MQ.widgets).selection, [12])
            RunLoop.main.run(until: Date().addingTimeInterval(0.5))
            XCTAssertEqual(client.calls.filter { $0.what.hasPrefix("retarget") }.count, 2, "no third retarget")
            XCTAssertFalse(client.calls.contains(where: \.onMainThread), "gh never runs on the main thread")
        }
    }

    /// A dev build can't retarget: the words stay, as no link, the menu's
    /// item is disabled and says why.
    @MainActor
    func testADryRunBuildDoesNotRetarget() throws {
        let client = ProjectBoardFlowTests.FakeGitHub(
            openPullRequests: Self.retargetPullRequests, mergedPullRequests: Self.mergedBase,
            runs: ProjectBoardGitHubTests.postMergeRuns
        )
        let world = MergeQueueFlowTests.GitHubWorld(pullRequests: [12: Self.a, 14: Self.b])
        try withBoard(world: world, boardClient: client) { shell, board in
            waitUntil("#10 reads merged") {
                (BoardStagesClicks.shownLine("feat/api", in: board)?.line.phrase.text) == "Base #10 merged · Retarget to main"
            }
            let api = try line("feat/api", in: board)
            BoardStagesClicks.layOut(api)
            XCTAssertNil(api.line.phrase.link)
            XCTAssertTrue(api.linkLabel.isHidden)
            let item = try XCTUnwrap(api.contextMenu()?.items.first { $0.title == "Retarget to main" })
            XCTAssertFalse(item.isEnabled)
            XCTAssertNotNil(item.toolTip)
            // Even if it were clicked, the shell refuses.
            let section = try XCTUnwrap(board.view.stages.content?.sections.first?.id)
            shell.performBoardLink(.retarget(number: 14, onto: "main"), line: api.line.id, section: section, board: board)
            shell.performProjectBoardAction(.retarget(number: 14, base: "main"), board: board)
            RunLoop.main.run(until: Date().addingTimeInterval(0.2))
            XCTAssertFalse(client.calls.contains { $0.what.hasPrefix("retarget") })
        }
    }

    @MainActor
    func testRestoredTimeoutOpensConfirmationForOnlyTheRemainingPR() throws {
        let head = "8c757e0" + String(repeating: "a", count: 33)
        let timeout = MergeQueue.StopReason(kind: .checks, message:
            "After 30 minutes, required checks are still missing or running on 8c757e0: test. If runners are busy, raise the checks timeout in Board Settings.")
        let engine = MergeQueue.Engine(settings: MQ.settings(), entries: [
            MQ.entry(660, head: Self.a), MQ.entry(708, head: Self.b, branch: "feat/login")
        ])
        var saved = MergeQueue.SavedQueue(engine: engine, dryRun: false, savedAt: Date().addingTimeInterval(-3 * 3600))
        saved.status = .stopped
        saved.current = 1
        saved.stopReason = timeout
        saved.entries[0].step = .done
        saved.entries[0].mergeCommit = MQ.sha("c")
        saved.entries[1].heads.append(head)
        saved.entries[1].step = .stopped(timeout)
        let open = """
        [{"number":708,"state":"OPEN","headRefName":"feat/login","headRefOid":"\(head)","baseRefName":"main",
          "title":"Speed up macOS tests","headRepository":{"name":"widgets"},"headRepositoryOwner":{"login":"acme"},
          "isDraft":false,"mergeable":"MERGEABLE","url":"https://github.com/acme/widgets/pull/708",
          "statusCheckRollup":[{"name":"test","workflowName":"Tests","status":"COMPLETED","conclusion":"SUCCESS"}]},
         {"number":14,"state":"OPEN","headRefName":"feat/api","headRefOid":"\(Self.b)","baseRefName":"main",
          "title":"Update the API","headRepository":{"name":"widgets"},"headRepositoryOwner":{"login":"acme"},
          "isDraft":true,"mergeable":"MERGEABLE","url":"https://github.com/acme/widgets/pull/14","statusCheckRollup":[]}]
        """
        let client = ProjectBoardFlowTests.FakeGitHub(openPullRequests: open, runs: ProjectBoardGitHubTests.postMergeRuns)
        let world = MergeQueueFlowTests.GitHubWorld(pullRequests: [708: head])
        try withBoard(world: world, boardClient: client, isDryRun: false, saved: saved) { shell, board in
            let header = try self.header(of: board)
            XCTAssertTrue(header.queueLabel.stringValue.contains("#708 queue timed out"))
            XCTAssertTrue(header.queueLabel.stringValue.hasSuffix("test passed on 8c757e0"))
            XCTAssertEqual(header.startButton.title, "Retry #708…")
            let login = try line("login", in: board).line
            XCTAssertEqual(login.phrase.text, "Queued · awaiting Start")
            var inputs = try XCTUnwrap(board.builtStages.last?.key.inputs)
            let aged = board.keptStagesContent(inputs, now: Date().addingTimeInterval(3600))
            let stale = try XCTUnwrap(aged.sections.first)
            XCTAssertTrue(stale.queue?.status?.hasSuffix("Current checks unknown") == true)
            XCTAssertEqual(stale.queue?.start?.title, "Start… · 1")
            XCTAssertEqual(stale.lines.units.flatMap(\.lines).first { $0.id == login.id }?.phrase.text, "GitHub status outdated")

            inputs.readings[login.id, default: .init()].activity = .needsYou("Ship this version?", action: .decide)
            let asking = board.stagesContent(inputs).content
            XCTAssertEqual(asking.inputStatus, "1 needs you · login")
            let current = try XCTUnwrap(asking.sections.first)
            XCTAssertEqual(current.lines.units.flatMap(\.lines).first { $0.id == login.id }?.phrase.text, "Decide · Ship this version?")
            XCTAssertEqual(current.queue?.start?.title, "Retry #708…")
            XCTAssertEqual(world.callCount, 0)
            try BoardStagesClicks.click(header.startButton)
            let sheet = try XCTUnwrap(shell.mergeQueueConfirmation)
            waitUntil("the retry read #708") { sheet.confirmation != nil }
            let confirmation = try XCTUnwrap(sheet.confirmation)
            XCTAssertEqual(confirmation.entries.map(\.number), [708])
            XCTAssertEqual(confirmation.entries.map(\.head), [head])
            XCTAssertEqual(confirmation.settings.requiredChecks, ["test"])
            XCTAssertFalse(shell.mergeQueue(projectID: board.projectID, repository: MQ.widgets).isRunning)
            sheet.dismiss()
            XCTAssertEqual(world.mergedNumbers, [])
            XCTAssertEqual(world.forbiddenCalls, [])
        }
    }

    // MARK: - Helpers

    /// A shell in a window with the board of a project whose repository is
    /// acme/widgets, a workspace in its main checkout and one in the login
    /// worktree, the board read.
    @MainActor
    private func withBoard(
        world: MergeQueueFlowTests.GitHubWorld = .init(pullRequests: [:]),
        queueClient injectedClient: (any MergeQueueGitHub)? = nil,
        boardClient: ProjectBoardFlowTests.FakeGitHub? = nil,
        isDryRun: Bool = true,
        saved: MergeQueue.SavedQueue? = nil,
        previousJournal: [MergeQueue.Journal.Line] = [],
        _ body: (NiruxShellView, ProjectBoardController) throws -> Void
    ) throws {
        let stateDirectory = root + "/state"
        try FileManager.default.createDirectory(atPath: stateDirectory, withIntermediateDirectories: true)
        let previous = ProcessInfo.processInfo.environment["NIRUX_STATE_DIR"]
        setenv("NIRUX_STATE_DIR", stateDirectory, 1)
        defer {
            if let previous { setenv("NIRUX_STATE_DIR", previous, 1) } else { unsetenv("NIRUX_STATE_DIR") }
        }
        _ = NSApplication.shared
        let shell = NiruxShellView(frame: NSRect(x: 0, y: 0, width: 1600, height: 900))
        shell.stopHeartbeat()
        shell.projectBoardClient = boardClient ?? ProjectBoardFlowTests.FakeGitHub(
            openPullRequests: Self.boardPullRequests, runs: ProjectBoardGitHubTests.postMergeRuns
        )
        let queueClient = GitHubCLIQueueClient(gh: world.run)
        shell.mergeQueueClient = injectedClient ?? (isDryRun ? DryRunQueueClient(wrapped: queueClient, reason: "NIRUX_STATE_DIR is set") : queueClient)
        shell.mergeQueueLockFolder = URL(fileURLWithPath: root + "/locks")
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1600, height: 900),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = shell
        defer {
            for queue in shell.mergeQueues.values { queue.stop() }
            shell.mergeQueueConfirmation?.dismiss()
            window.close()
        }
        let space = shell.workspaceStore.createProfile(named: "Board")
        if saved != nil || !previousJournal.isEmpty {
            let files = try XCTUnwrap(MergeQueue.Files(projectID: space.id, repository: MQ.widgets,
                                                       stateDirectory: URL(fileURLWithPath: stateDirectory), dryRun: isDryRun))
            saved?.save(to: files.state)
            MergeQueue.Journal(url: files.journal.appendingPathExtension("1")).append(previousJournal)
        }
        let repo = root + "/widgets"
        try BoardConfigSuggestionsTests.makeRepository(at: repo, remote: "https://github.com/acme/widgets.git")
        let login = root + "/widgets.feat-login"
        try BoardConfigSuggestionsTests.git(["worktree", "add", "-q", "-b", "feat/login", login], at: repo)
        let store = try XCTUnwrap(BoardConfigStore(spaceID: space.id))
        let config = BoardConfig(
            repository: "acme/widgets", baseBranch: "main", requiredChecks: ["test"], postMergeWorkflow: .workflow("nightly.yml")
        )
        if case .failure(let error) = store.save(config) { XCTFail(error.message) }
        shell.addWorkspace(title: "widgets", cwd: repo, profileID: space.id)
        shell.addWorkspace(title: "login", cwd: login, profileID: space.id)
        shell.switchToWorkspace(try XCTUnwrap(shell.workspaces.firstIndex { $0.title == "widgets" }))
        shell.openProjectBoard()
        let board = try XCTUnwrap(shell.projectBoardLocation(projectID: space.id)?.board)
        waitUntil("the lines") {
            board.view.stages.content?.sections.first?.lines.withoutTask.flatMap(\.lines).contains { $0.pullRequest == "#14" } == true
        }
        // #14 has no worktree: under "Pull requests without a task", folded.
        let section = try XCTUnwrap(board.view.stages.content?.sections.first?.id)
        try BoardStagesClicks.click(try XCTUnwrap(board.view.stages.foldButton(section: section)))
        try body(shell, board)
    }

    @MainActor
    private func line(_ title: String, in board: ProjectBoardController) throws -> BoardStagesLineView {
        try BoardStagesClicks.line(title, in: board)
    }

    /// The repository's header.
    @MainActor
    private func header(of board: ProjectBoardController) throws -> BoardStagesSectionHeaderView {
        let section = try XCTUnwrap(board.view.stages.content?.sections.first?.id)
        return try XCTUnwrap(board.view.stages.sectionHeader(section: section))
    }

    /// The button must be what its window hit-tests under the pointer, as
    /// AppKit finds it for a real click; then `performClick`, since a
    /// button's own tracking never ends in a window that isn't shown.
    @MainActor
    private func click(_ button: NSButton) throws {
        let window = try XCTUnwrap(button.window)
        let contentView = try XCTUnwrap(window.contentView)
        let frameView = try XCTUnwrap(contentView.superview)
        let location = button.convert(NSPoint(x: button.bounds.midX, y: button.bounds.midY), to: nil)
        let hitView = try XCTUnwrap(frameView.hitTest(location))
        XCTAssertTrue(hitView === button, "\(hitView) is under the pointer, not \(button.title)")
        XCTAssertTrue(button.isEnabled, "\(button.title) is disabled")
        (hitView as? NSButton)?.performClick(nil)
    }
}
