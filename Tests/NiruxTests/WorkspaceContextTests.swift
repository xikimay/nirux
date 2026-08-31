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

    private func makeWorkspaceInfo(
        purpose: String? = nil,
        summary: String? = nil
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
            phase: .active,
            lastSummary: summary,
            lastActivityAt: nil
        )
    }
}
