import AppKit
import XCTest
@testable import Nirux

@MainActor
final class WorkspaceContextTests: XCTestCase {
    func testPhaseLabelsAreHumanReadableAndNotColorOnly() {
        XCTAssertEqual(WorkspacePhase.active.displayName, "Active")
        XCTAssertEqual(WorkspacePhase.waiting.displayName, "Waiting")
        XCTAssertEqual(WorkspacePhase.blocked.symbol, "!")
        XCTAssertEqual(WorkspacePhase.done.symbol, "✓")
    }

    func testAutomaticPhaseDerivationUsesAttentionPriority() {
        XCTAssertEqual(
            WorkspacePhase.derived(
                isInactive: false,
                hasBlocker: false,
                agentStatuses: [.working, .needsAttention],
                pullRequestState: "OPEN"
            ),
            .waiting
        )
        XCTAssertEqual(
            WorkspacePhase.derived(
                isInactive: false,
                hasBlocker: true,
                agentStatuses: [.working],
                pullRequestState: nil
            ),
            .blocked
        )
        XCTAssertEqual(
            WorkspacePhase.derived(
                isInactive: true,
                hasBlocker: false,
                agentStatuses: [],
                pullRequestState: nil
            ),
            .parked
        )
        XCTAssertEqual(
            WorkspacePhase.derived(
                isInactive: true,
                hasBlocker: false,
                agentStatuses: [.needsAttention],
                pullRequestState: nil
            ),
            .waiting,
            "live attention must remain visible even in the inactive group"
        )
        XCTAssertEqual(
            WorkspacePhase.derived(
                isInactive: false,
                hasBlocker: false,
                agentStatuses: [],
                pullRequestState: "OPEN"
            ),
            .review
        )
    }

    func testAutomaticSummaryCompactsWhitespaceAndPreservesManualContent() {
        let workspace = WorkspaceState(title: "context", cwd: "/tmp")

        XCTAssertTrue(workspace.recordAgentActivity(
            at: 20,
            automaticSummary: "  Implemented the panel.\n\nTests are next.  "
        ))
        XCTAssertEqual(workspace.lastSummary, "Implemented the panel. Tests are next.")
        XCTAssertEqual(workspace.lastActivityAt, 20)

        workspace.lastSummary = "Keep my summary"
        workspace.lastSummaryIsManual = true
        XCTAssertTrue(workspace.recordAgentActivity(at: 30, automaticSummary: "Agent replacement"))
        XCTAssertEqual(workspace.lastSummary, "Keep my summary")
        XCTAssertEqual(workspace.lastActivityAt, 30)

        XCTAssertFalse(workspace.recordAgentActivity(at: 10, automaticSummary: "Stale replacement"))
        XCTAssertEqual(workspace.lastSummary, "Keep my summary")
        XCTAssertEqual(workspace.lastActivityAt, 30)
    }

    func testUserPromptUpdatesActivityWithoutReplacingSummaryOrCountingToolUse() throws {
        let workspace = WorkspaceState(title: "context", cwd: "/tmp")
        workspace.lastSummary = "Keep the completed work summary"

        let prompt = try XCTUnwrap(AgentHookEvent(
            kind: .claude,
            payload: ["hook_event_name": "UserPromptSubmit"],
            env: [:],
            now: 20
        ))
        XCTAssertTrue(workspace.recordAgentHookActivity(prompt))
        XCTAssertEqual(workspace.lastActivityAt, 20)
        XCTAssertEqual(workspace.lastSummary, "Keep the completed work summary")

        let toolUse = try XCTUnwrap(AgentHookEvent(
            kind: .claude,
            payload: ["hook_event_name": "PreToolUse", "tool_name": "Bash"],
            env: [:],
            now: 30
        ))
        XCTAssertFalse(workspace.recordAgentHookActivity(toolUse))
        XCTAssertEqual(workspace.lastActivityAt, 20)
        XCTAssertEqual(workspace.lastSummary, "Keep the completed work summary")
    }

    func testGitContextChangesRejectStalePRMetadata() {
        let workspace = WorkspaceState(title: "context", cwd: "/tmp")
        let pullRequest = PRInfo(
            number: 42,
            state: "MERGED",
            isDraft: false,
            ciStatus: "SUCCESS",
            failedCheckUrl: nil,
            reviewDecision: "APPROVED",
            mergeable: "MERGEABLE",
            url: "https://example.test/pull/42",
            additions: 5,
            deletions: 2,
            changedFiles: 1
        )

        let original = GitContext(
            branch: "feature/task",
            identity: GitIdentity(repositoryRoot: "/repo/one", head: "head-a")
        )
        let newCommit = GitContext(
            branch: "feature/task",
            identity: GitIdentity(repositoryRoot: "/repo/one", head: "head-b")
        )
        let otherRepository = GitContext(
            branch: "feature/task",
            identity: GitIdentity(repositoryRoot: "/repo/two", head: "head-b")
        )

        XCTAssertTrue(workspace.updateGitContext(original))
        XCTAssertTrue(workspace.applyPullRequestInfo(pullRequest, for: original))
        workspace.diffStats = "1 file changed"
        XCTAssertEqual(workspace.effectivePhase, .done)

        XCTAssertFalse(workspace.updateGitContext(original))
        XCTAssertEqual(workspace.prInfo, pullRequest)
        XCTAssertEqual(workspace.diffStats, "1 file changed")

        XCTAssertTrue(workspace.updateGitContext(newCommit))
        XCTAssertNil(workspace.prInfo)
        XCTAssertNil(workspace.diffStats)
        XCTAssertEqual(workspace.effectivePhase, .active)
        XCTAssertFalse(workspace.applyPullRequestInfo(pullRequest, for: original))
        XCTAssertNil(workspace.prInfo)

        XCTAssertTrue(workspace.applyPullRequestInfo(pullRequest, for: newCommit))
        workspace.diffStats = "1 file changed"
        XCTAssertTrue(workspace.updateGitContext(otherRepository))
        XCTAssertNil(workspace.prInfo)
        XCTAssertNil(workspace.diffStats)

        workspace.prInfo = pullRequest
        workspace.diffStats = "1 file changed"
        XCTAssertTrue(workspace.updateGitContext(nil))
        XCTAssertNil(workspace.prInfo)
        XCTAssertNil(workspace.diffStats)
    }

    func testOlderGitObservationCannotReplaceNewerContext() throws {
        let workspace = WorkspaceState(title: "context", cwd: "/tmp")
        let oldContext = GitContext(
            branch: "feature/task",
            identity: GitIdentity(repositoryRoot: "/repo", head: "head-a")
        )
        let newContext = GitContext(
            branch: "feature/task",
            identity: GitIdentity(repositoryRoot: "/repo", head: "head-b")
        )
        let olderObservation = try XCTUnwrap(
            workspace.beginGitContextObservation(at: "/repo/old")
        )
        let newerObservation = try XCTUnwrap(
            workspace.beginGitContextObservation(at: "/repo/new")
        )

        XCTAssertEqual(
            workspace.applyGitContextObservation(newContext, observation: newerObservation),
            .changed
        )
        workspace.prInfo = PRInfo(
            number: 42,
            state: "OPEN",
            isDraft: false,
            ciStatus: nil,
            failedCheckUrl: nil,
            reviewDecision: nil,
            mergeable: nil,
            url: "https://example.test/pull/42",
            additions: nil,
            deletions: nil,
            changedFiles: nil
        )
        XCTAssertEqual(
            workspace.applyGitContextObservation(oldContext, observation: olderObservation),
            .stale
        )
        XCTAssertEqual(workspace.gitContext, newContext)
        XCTAssertEqual(workspace.prInfo?.number, 42)
    }

    func testOlderPullRequestObservationCannotReplaceNewerResult() throws {
        let workspace = WorkspaceState(title: "context", cwd: "/tmp")
        let oldContext = GitContext(
            branch: "feature/task",
            identity: GitIdentity(repositoryRoot: "/repo", head: "head-a"),
            upstreamRepository: GitHubRepository(owner: "owner", name: "repo")
        )
        let newContext = GitContext(
            branch: "feature/task",
            identity: GitIdentity(repositoryRoot: "/repo", head: "head-b"),
            upstreamRepository: GitHubRepository(owner: "owner", name: "repo")
        )
        let open = PRInfo(
            number: 41,
            state: "OPEN",
            isDraft: false,
            ciStatus: nil,
            failedCheckUrl: nil,
            reviewDecision: nil,
            mergeable: nil,
            url: "https://example.test/pull/41",
            additions: nil,
            deletions: nil,
            changedFiles: nil
        )
        let merged = PRInfo(
            number: 41,
            state: "MERGED",
            isDraft: false,
            ciStatus: "SUCCESS",
            failedCheckUrl: nil,
            reviewDecision: "APPROVED",
            mergeable: "MERGEABLE",
            url: "https://example.test/pull/41",
            additions: nil,
            deletions: nil,
            changedFiles: nil
        )

        XCTAssertTrue(workspace.updateGitContext(oldContext))
        let olderObservation = try XCTUnwrap(
            workspace.beginPullRequestObservation(for: oldContext)
        )
        XCTAssertTrue(workspace.updateGitContext(newContext))
        let newerObservation = try XCTUnwrap(
            workspace.beginPullRequestObservation(for: newContext)
        )
        XCTAssertTrue(workspace.applyPullRequestInfo(
            merged,
            for: newContext,
            observation: newerObservation
        ))
        XCTAssertFalse(workspace.applyPullRequestInfo(
            open,
            for: oldContext,
            observation: olderObservation
        ))
        XCTAssertEqual(workspace.prInfo, merged)
        XCTAssertEqual(workspace.effectivePhase, .done)
    }

    func testGitCleanlinessChangeClearsTerminalStateButRetainsOpenReview() {
        let workspace = WorkspaceState(title: "context", cwd: "/tmp")
        let cleanContext = GitContext(
            branch: "feature/task",
            identity: GitIdentity(repositoryRoot: "/repo", head: "head-a", isDirty: false)
        )
        let dirtyContext = GitContext(
            branch: "feature/task",
            identity: GitIdentity(repositoryRoot: "/repo", head: "head-a", isDirty: true)
        )
        let merged = PRInfo(
            number: 41,
            state: "MERGED",
            isDraft: false,
            ciStatus: nil,
            failedCheckUrl: nil,
            reviewDecision: nil,
            mergeable: nil,
            url: "https://example.test/pull/41",
            additions: nil,
            deletions: nil,
            changedFiles: nil
        )
        let open = PRInfo(
            number: 42,
            state: "OPEN",
            isDraft: false,
            ciStatus: nil,
            failedCheckUrl: nil,
            reviewDecision: nil,
            mergeable: nil,
            url: "https://example.test/pull/42",
            additions: nil,
            deletions: nil,
            changedFiles: nil
        )

        XCTAssertTrue(workspace.updateGitContext(cleanContext))
        XCTAssertTrue(workspace.applyPullRequestInfo(merged, for: cleanContext))
        XCTAssertEqual(workspace.effectivePhase, .done)
        XCTAssertTrue(workspace.updateGitContext(dirtyContext))
        XCTAssertNil(workspace.prInfo)
        XCTAssertEqual(workspace.effectivePhase, .active)

        XCTAssertTrue(workspace.updateGitContext(cleanContext))
        XCTAssertTrue(workspace.applyPullRequestInfo(open, for: cleanContext))
        XCTAssertTrue(workspace.updateGitContext(dirtyContext))
        XCTAssertEqual(workspace.prInfo, open)
        XCTAssertEqual(workspace.effectivePhase, .review)
        XCTAssertFalse(workspace.applyPullRequestInfo(merged, for: dirtyContext))
        XCTAssertEqual(workspace.prInfo, open)
    }

    func testChangedGitObservationSchedulesRefreshAndRejectsStaleRequest() throws {
        let workspace = WorkspaceState(title: "context", cwd: "/tmp")
        let staleContext = GitContext(
            branch: "feature/task",
            identity: GitIdentity(repositoryRoot: "/repo", head: "head-a")
        )
        let currentContext = GitContext(
            branch: "feature/task",
            identity: GitIdentity(repositoryRoot: "/repo", head: "head-b")
        )
        var refreshContexts: [GitContext?] = []
        workspace.onGitContextChanged = { refreshContexts.append(workspace.gitContext) }
        let staleObservation = try XCTUnwrap(
            workspace.beginGitContextObservation(at: "/repo/stale")
        )
        let currentObservation = try XCTUnwrap(
            workspace.beginGitContextObservation(at: "/repo/current")
        )

        XCTAssertEqual(
            workspace.applyGitContextObservation(currentContext, observation: currentObservation),
            .changed
        )
        XCTAssertEqual(refreshContexts, [currentContext])
        XCTAssertEqual(
            workspace.applyGitContextObservation(staleContext, observation: staleObservation),
            .stale
        )
        XCTAssertEqual(refreshContexts, [currentContext])

        let unchangedObservation = try XCTUnwrap(
            workspace.beginGitContextObservation(at: "/repo/current")
        )
        XCTAssertEqual(
            workspace.applyGitContextObservation(currentContext, observation: unchangedObservation),
            .unchanged
        )
        XCTAssertEqual(refreshContexts, [currentContext])
    }

    func testFocusedEditorRootReplacesTerminalRootAndSchedulesRefresh() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let terminalRoot = directory.appendingPathComponent("terminal", isDirectory: true)
        let editorRoot = directory.appendingPathComponent("editor", isDirectory: true)
        try FileManager.default.createDirectory(at: terminalRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: editorRoot, withIntermediateDirectories: true)
        try initializeGitRepository(at: terminalRoot)
        try initializeGitRepository(at: editorRoot)
        defer { try? FileManager.default.removeItem(at: directory) }
        let canonicalPath: (String) -> String = {
            URL(fileURLWithPath: $0).resolvingSymlinksInPath().path
        }

        do {
            let workspace = WorkspaceState(title: "context", cwd: terminalRoot.path)
            var focusedRepositoryRoots: [String] = []
            workspace.onFocusedColumnChanged = { [weak workspace] in
                guard let root = workspace?.focusedWorkingDirectory,
                      let context = GitDetect.context(at: root)
                else { return XCTFail("Expected focused column Git context") }
                focusedRepositoryRoots.append(context.identity.repositoryRoot)
            }

            workspace.addEditorColumn(workspaceCwd: editorRoot.path)
            XCTAssertEqual(
                canonicalPath(workspace.focusedWorkingDirectory),
                canonicalPath(editorRoot.path)
            )
            XCTAssertEqual(
                focusedRepositoryRoots.map(canonicalPath),
                [canonicalPath(editorRoot.path)]
            )

            workspace.focusedIndex = 0
            XCTAssertEqual(
                canonicalPath(workspace.focusedWorkingDirectory),
                canonicalPath(terminalRoot.path)
            )
            XCTAssertEqual(
                focusedRepositoryRoots.map(canonicalPath),
                [canonicalPath(editorRoot.path), canonicalPath(terminalRoot.path)]
            )
        }
    }

    func testBackgroundTerminalCwdEventDoesNotClaimGitObservation() throws {
        let workspace = WorkspaceState(title: "context", cwd: "/tmp")
        let backgroundTerminal = workspace.columns[0]
        workspace.addEditorColumn(workspaceCwd: "/tmp/editor")
        let editorContext = GitContext(
            branch: "editor/task",
            identity: GitIdentity(repositoryRoot: "/repo/editor", head: "editor-head")
        )
        XCTAssertTrue(workspace.updateGitContext(editorContext))
        let pendingFocusedObservation = try XCTUnwrap(
            workspace.beginGitContextObservation(at: workspace.focusedWorkingDirectory)
        )

        backgroundTerminal.onCwdChanged?("/repo/terminal")

        XCTAssertEqual(
            workspace.applyGitContextObservation(
                editorContext,
                observation: pendingFocusedObservation
            ),
            .unchanged
        )
        XCTAssertEqual(workspace.gitContext, editorContext)
    }

    func testRepeatedSlowPollsCoalesceUntilObservationsFinish() throws {
        let workspace = WorkspaceState(title: "context", cwd: "/tmp")
        let context = GitContext(
            branch: "feature/task",
            identity: GitIdentity(repositoryRoot: "/repo", head: "head-a"),
            upstreamRepository: GitHubRepository(owner: "owner", name: "repo")
        )

        let gitObservation = try XCTUnwrap(
            workspace.beginGitContextObservation(at: "/repo")
        )
        XCTAssertNil(workspace.beginGitContextObservation(at: "/repo"))
        XCTAssertEqual(
            workspace.applyGitContextObservation(context, observation: gitObservation),
            .changed
        )
        XCTAssertNotNil(workspace.beginGitContextObservation(at: "/repo"))

        let pullRequestObservation = try XCTUnwrap(
            workspace.beginPullRequestObservation(for: context)
        )
        XCTAssertNil(workspace.beginPullRequestObservation(for: context))
        XCTAssertTrue(workspace.finishPullRequestObservation(pullRequestObservation))
        XCTAssertNotNil(workspace.beginPullRequestObservation(for: context))
    }

    func testUpstreamReassignmentInvalidatesCachedAndInFlightPullRequest() throws {
        let workspace = WorkspaceState(title: "context", cwd: "/tmp")
        let identity = GitIdentity(repositoryRoot: "/repo", head: "head-a")
        let original = GitContext(
            branch: "feature/task",
            identity: identity,
            upstreamRepository: GitHubRepository(owner: "owner", name: "repo")
        )
        let reassigned = GitContext(
            branch: "feature/task",
            identity: identity,
            upstreamRepository: GitHubRepository(owner: "other", name: "repo")
        )
        let pullRequest = PRInfo(
            number: 42,
            state: "OPEN",
            isDraft: false,
            ciStatus: nil,
            failedCheckUrl: nil,
            reviewDecision: nil,
            mergeable: nil,
            url: "https://example.test/pull/42",
            additions: nil,
            deletions: nil,
            changedFiles: nil
        )

        XCTAssertTrue(workspace.updateGitContext(original))
        XCTAssertTrue(workspace.applyPullRequestInfo(pullRequest, for: original))
        let staleObservation = try XCTUnwrap(
            workspace.beginPullRequestObservation(for: original)
        )

        XCTAssertTrue(workspace.updateGitContext(reassigned))
        XCTAssertNil(workspace.prInfo)
        XCTAssertFalse(workspace.applyPullRequestInfo(
            pullRequest,
            for: original,
            observation: staleObservation
        ))
        XCTAssertNotNil(workspace.beginPullRequestObservation(for: reassigned))
    }

    func testWorkspaceContextShortcutsIgnoreOtherWindows() {
        let panel = NSObject()
        let otherWindow = NSObject()

        XCTAssertEqual(
            WorkspaceContextPanel.shortcutAction(
                keyCode: 0x35,
                modifierFlags: [],
                eventWindow: panel,
                panel: panel
            ),
            .cancel
        )
        XCTAssertNil(WorkspaceContextPanel.shortcutAction(
            keyCode: 0x35,
            modifierFlags: [],
            eventWindow: otherWindow,
            panel: panel
        ))
        XCTAssertEqual(
            WorkspaceContextPanel.shortcutAction(
                keyCode: 0x24,
                modifierFlags: .command,
                eventWindow: panel,
                panel: panel
            ),
            .save
        )
        XCTAssertNil(WorkspaceContextPanel.shortcutAction(
            keyCode: 0x24,
            modifierFlags: .command,
            eventWindow: otherWindow,
            panel: panel
        ))
    }

    func testContextTextNormalizationDropsBlankOptionalRows() {
        XCTAssertNil(WorkspaceState.normalizedContextText(" \n "))
        XCTAssertEqual(WorkspaceState.normalizedContextText("  Ship it  "), "Ship it")
    }

    func testSidebarHeightAddsOnlyPopulatedOptionalContextRows() {
        let baseline = makeWorkspaceInfo()
        let populated = makeWorkspaceInfo(
            purpose: "Explain why this exists",
            summary: "Persistence is complete"
        )

        XCTAssertEqual(
            SidebarExpandedMetrics.workspaceHeight(for: populated)
                - SidebarExpandedMetrics.workspaceHeight(for: baseline),
            SidebarExpandedMetrics.purposeAdvance + SidebarExpandedMetrics.summaryAdvance
        )
    }

    func testSidebarRendererIncludesExplicitPhaseAndOptionalText() {
        let workspace = makeWorkspaceInfo(
            purpose: "Explain why this exists",
            summary: "Persistence is complete"
        )
        let result = SidebarWorkspaceCardRenderer(
            workspace: workspace,
            sidebarWidth: 260,
            padding: 20,
            yOffset: 400
        ).render()
        let labels = result.views.compactMap { ($0 as? NSTextField)?.stringValue }

        XCTAssertTrue(labels.contains("▶ Active"))
        XCTAssertTrue(labels.contains("Explain why this exists"))
        XCTAssertTrue(labels.contains("Persistence is complete"))
    }

    func testSidebarContextRowPrioritizesBlocker() throws {
        let workspace = makeWorkspaceInfo(
            nextStep: "Retry the deployment",
            blocker: "Waiting for API access"
        )
        let result = SidebarWorkspaceCardRenderer(
            workspace: workspace,
            sidebarWidth: 260,
            padding: 20,
            yOffset: 400
        ).render()
        let labels = result.views.compactMap { $0 as? NSTextField }
        let blockerLabel = try XCTUnwrap(labels.first {
            $0.stringValue == "Blocker: Waiting for API access"
        })

        XCTAssertEqual(blockerLabel.lineBreakMode, .byTruncatingTail)
        XCTAssertFalse(labels.contains { $0.stringValue == "Next: Retry the deployment" })
    }

    func testSidebarContextRowFallsBackToNextStep() {
        let workspace = makeWorkspaceInfo(nextStep: "Retry the deployment")
        let result = SidebarWorkspaceCardRenderer(
            workspace: workspace,
            sidebarWidth: 260,
            padding: 20,
            yOffset: 400
        ).render()
        let labels = result.views.compactMap { ($0 as? NSTextField)?.stringValue }

        XCTAssertTrue(labels.contains("Next: Retry the deployment"))
        XCTAssertEqual(
            SidebarExpandedMetrics.workspaceHeight(for: workspace)
                - SidebarExpandedMetrics.workspaceHeight(for: makeWorkspaceInfo()),
            SidebarExpandedMetrics.actionAdvance
        )
    }

    func testSidebarContextRowIsOmittedWhenActionFieldsAreBlank() {
        let workspace = makeWorkspaceInfo(nextStep: "  ", blocker: "\n")
        let result = SidebarWorkspaceCardRenderer(
            workspace: workspace,
            sidebarWidth: 260,
            padding: 20,
            yOffset: 400
        ).render()
        let labels = result.views.compactMap { ($0 as? NSTextField)?.stringValue }

        XCTAssertFalse(labels.contains { $0.hasPrefix("Blocker:") || $0.hasPrefix("Next:") })
        XCTAssertEqual(
            SidebarExpandedMetrics.workspaceHeight(for: workspace),
            SidebarExpandedMetrics.workspaceHeight(for: makeWorkspaceInfo())
        )
    }

    private func makeWorkspaceInfo(
        purpose: String? = nil,
        summary: String? = nil,
        nextStep: String? = nil,
        blocker: String? = nil
    ) -> WorkspaceInfo {
        WorkspaceInfo(
            id: "workspace",
            index: 0,
            title: "context",
            profileID: WorkspaceProfile.defaultID,
            isInactive: false,
            columnCount: 0,
            focusedColumn: 0,
            gitBranch: nil,
            hasNotification: false,
            isActive: true,
            columns: [],
            prInfo: nil,
            diffStats: nil,
            purpose: purpose,
            nextStep: nextStep,
            blocker: blocker,
            phase: .active,
            lastSummary: summary,
            lastActivityAt: nil
        )
    }

    private func initializeGitRepository(at directory: URL) throws {
        try runGit(["init", "-q"], at: directory)
        let trackedFile = directory.appendingPathComponent("tracked.txt")
        try "context\n".write(to: trackedFile, atomically: true, encoding: .utf8)
        try runGit(["add", "tracked.txt"], at: directory)
        try runGit([
            "-c", "user.name=Nirux Tests",
            "-c", "user.email=nirux@example.test",
            "commit", "-qm", "initial"
        ], at: directory)
    }

    private func runGit(_ arguments: [String], at directory: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.currentDirectoryURL = directory
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw NSError(domain: "WorkspaceContextTests.Git", code: Int(process.terminationStatus))
        }
    }
}
