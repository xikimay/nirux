import AppKit
import XCTest
@testable import Nirux

extension WorkspaceContextTests {
    func testGitObservationFailurePreservesCacheWhileNonRepositoryClearsIt() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let fakeGit = directory.appendingPathComponent("git")
        let script = #"""
        #!/bin/sh
        case "$1 $2" in
            "rev-parse --show-toplevel")
                printf '%s\n' "$PWD"
                ;;
            "symbolic-ref --quiet")
                printf '%s\n' "feature/task"
                ;;
            "rev-parse --verify")
                printf '%s\n' "head-a"
                ;;
            "status --porcelain=v1")
                exit 75
                ;;
            *)
                exit 1
                ;;
        esac
        """#
        try script.write(to: fakeGit, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: fakeGit.path
        )

        let statusFailure = GitDetect.observe(at: directory.path, gitPath: fakeGit.path)
        XCTAssertEqual(statusFailure, .failure)
        XCTAssertEqual(
            GitDetect.observe(
                at: directory.path,
                gitPath: directory.appendingPathComponent("missing-git").path
            ),
            .failure
        )
        XCTAssertEqual(GitDetect.observe(at: directory.path), .notRepository)

        let workspace = WorkspaceState(title: "context", cwd: directory.path)
        let context = GitContext(
            branch: "feature/task",
            identity: GitIdentity(repositoryRoot: directory.path, head: "head-a")
        )
        let pullRequest = makePullRequest()
        XCTAssertTrue(workspace.updateGitContext(context))
        XCTAssertTrue(workspace.applyPullRequestInfo(pullRequest, for: context))

        let failedObservation = try XCTUnwrap(
            workspace.beginGitContextObservation(at: directory.path)
        )
        XCTAssertEqual(
            workspace.applyGitContextObservation(
                statusFailure,
                observation: failedObservation
            ),
            .unchanged
        )
        XCTAssertEqual(workspace.gitContext, context)
        XCTAssertEqual(workspace.prInfo, pullRequest)

        let nonRepositoryObservation = try XCTUnwrap(
            workspace.beginGitContextObservation(at: directory.path)
        )
        XCTAssertEqual(
            workspace.applyGitContextObservation(
                .notRepository,
                observation: nonRepositoryObservation
            ),
            .changed
        )
        XCTAssertNil(workspace.gitContext)
        XCTAssertNil(workspace.prInfo)
    }

    func testUnbornRepositoryInvalidatesPreviousRepositoryContext() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let committedRepository = root.appendingPathComponent("committed", isDirectory: true)
        let unbornRepository = root.appendingPathComponent("unborn", isDirectory: true)
        try FileManager.default.createDirectory(
            at: committedRepository,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: unbornRepository,
            withIntermediateDirectories: true
        )
        try initializeGitRepository(at: committedRepository)
        try runGit(["init", "-q"], at: unbornRepository)
        defer { try? FileManager.default.removeItem(at: root) }

        let previousContext = try XCTUnwrap(GitDetect.context(at: committedRepository.path))
        guard case .observed(let unbornContext) = GitDetect.observe(at: unbornRepository.path)
        else { return XCTFail("Expected an observed unborn repository") }
        XCTAssertNil(unbornContext.identity.head)
        XCTAssertEqual(
            URL(fileURLWithPath: unbornContext.identity.repositoryRoot).resolvingSymlinksInPath(),
            unbornRepository.resolvingSymlinksInPath()
        )

        let workspace = WorkspaceState(title: "context", cwd: committedRepository.path)
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
        XCTAssertTrue(workspace.updateGitContext(previousContext))
        XCTAssertTrue(workspace.applyPullRequestInfo(pullRequest, for: previousContext))
        workspace.diffStats = "1 file changed"
        let observation = try XCTUnwrap(
            workspace.beginGitContextObservation(at: unbornRepository.path)
        )

        XCTAssertEqual(
            workspace.applyGitContextObservation(
                .observed(unbornContext),
                observation: observation
            ),
            .changed
        )
        XCTAssertEqual(workspace.gitContext, unbornContext)
        XCTAssertNil(workspace.prInfo)
        XCTAssertNil(workspace.diffStats)
    }

    func testAuthoritativeNonGitHubPushRemoteClearsCachedPullRequest() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try initializeGitRepository(at: directory)
        defer { try? FileManager.default.removeItem(at: directory) }

        let initial = try XCTUnwrap(GitDetect.context(at: directory.path))
        let branch = initial.branch
        try runGit(["remote", "add", "origin", "git@github.com:owner/repo.git"], at: directory)
        try runGit(["update-ref", "refs/remotes/origin/\(branch)", "HEAD"], at: directory)
        try runGit(["branch", "--set-upstream-to=origin/\(branch)"], at: directory)
        let repositoryContext = try XCTUnwrap(GitDetect.context(at: directory.path))
        XCTAssertEqual(
            repositoryContext.upstreamRepository,
            GitHubRepository(owner: "owner", name: "repo")
        )

        let workspace = WorkspaceState(title: "context", cwd: directory.path)
        let pullRequest = PRInfo(
            number: 42,
            state: "OPEN",
            isDraft: false,
            ciStatus: nil,
            failedCheckUrl: nil,
            reviewDecision: nil,
            mergeable: nil,
            url: "https://github.com/owner/repo/pull/42",
            additions: nil,
            deletions: nil,
            changedFiles: nil
        )
        XCTAssertTrue(workspace.updateGitContext(repositoryContext))
        XCTAssertTrue(workspace.applyPullRequestInfo(pullRequest, for: repositoryContext))

        try runGit(
            ["remote", "set-url", "--push", "origin", directory.path],
            at: directory
        )
        let absentContext = try XCTUnwrap(GitDetect.context(at: directory.path))
        XCTAssertEqual(absentContext.upstreamRepositoryObservation, .absent)

        XCTAssertTrue(workspace.updateGitContext(absentContext))
        XCTAssertNil(workspace.prInfo)
    }

    func testPullRequestIdentityPrefersConfiguredPushRemote() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try initializeGitRepository(at: directory)
        defer { try? FileManager.default.removeItem(at: directory) }

        let branch = try XCTUnwrap(GitDetect.context(at: directory.path)).branch
        try runGit(
            ["remote", "add", "company", "git@github.com:company/repo.git"],
            at: directory
        )
        try runGit(
            ["update-ref", "refs/remotes/company/\(branch)", "HEAD"],
            at: directory
        )
        try runGit(
            ["branch", "--set-upstream-to=company/\(branch)"],
            at: directory
        )
        try runGit(
            ["remote", "add", "fork", "git@github.com:developer/repo.git"],
            at: directory
        )
        try runGit(["config", "branch.\(branch).pushRemote", "fork"], at: directory)

        XCTAssertEqual(
            try XCTUnwrap(GitDetect.context(at: directory.path)).upstreamRepository,
            GitHubRepository(owner: "developer", name: "repo")
        )
    }

    func testHungGitObservationTimesOutAndAllowsRetry() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try initializeGitRepository(at: directory)
        defer { try? FileManager.default.removeItem(at: directory) }

        let fakeGit = directory.appendingPathComponent("hung-git")
        let script = #"""
        #!/bin/sh
        trap '' TERM
        while :; do :; done
        """#
        try script.write(to: fakeGit, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: fakeGit.path
        )
        let context = try XCTUnwrap(GitDetect.context(at: directory.path))
        let workspace = WorkspaceState(title: "context", cwd: directory.path)
        XCTAssertTrue(workspace.updateGitContext(context))

        let startedAt = Date()
        let failure = GitDetect.observe(
            at: directory.path,
            gitPath: fakeGit.path,
            timeout: 0.1
        )
        XCTAssertLessThan(Date().timeIntervalSince(startedAt), 2)
        XCTAssertEqual(failure, .failure)

        let failedObservation = try XCTUnwrap(
            workspace.beginGitContextObservation(at: directory.path)
        )
        XCTAssertEqual(
            workspace.applyGitContextObservation(
                failure,
                observation: failedObservation
            ),
            .unchanged
        )
        let retryObservation = try XCTUnwrap(
            workspace.beginGitContextObservation(at: directory.path)
        )
        XCTAssertEqual(
            workspace.applyGitContextObservation(
                GitDetect.observe(at: directory.path),
                observation: retryObservation
            ),
            .unchanged
        )
        XCTAssertEqual(workspace.gitContext, context)
    }

    func testInaccessibleFocusedEditorDiffFailurePreservesCachedStats() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try initializeGitRepository(at: directory)
        defer { try? FileManager.default.removeItem(at: directory) }

        let workspace = WorkspaceState(title: "context", cwd: directory.path)
        let context = try XCTUnwrap(GitDetect.context(at: directory.path))
        XCTAssertTrue(workspace.updateGitContext(context))
        workspace.diffStats = "1 file changed"

        let inaccessibleEditorRoot = directory.appendingPathComponent(
            "missing-editor-root",
            isDirectory: true
        )
        workspace.addEditorColumn(workspaceCwd: inaccessibleEditorRoot.path)
        let observation = try XCTUnwrap(workspace.beginDiffStatsObservation(
            at: workspace.focusedWorkingDirectory,
            for: context
        ))
        let result = PRDetect.diffStats(cwd: inaccessibleEditorRoot.path)

        XCTAssertEqual(result, .failure)
        XCTAssertFalse(workspace.applyDiffStatsObservation(result, observation: observation))
        XCTAssertEqual(workspace.diffStats, "1 file changed")
    }

    func testSuccessfulCleanDiffClearsCachedStats() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try initializeGitRepository(at: directory)
        defer { try? FileManager.default.removeItem(at: directory) }

        let workspace = WorkspaceState(title: "context", cwd: directory.path)
        workspace.addEditorColumn(workspaceCwd: directory.path)
        let context = try XCTUnwrap(GitDetect.context(at: directory.path))
        XCTAssertTrue(workspace.updateGitContext(context))
        workspace.diffStats = "1 file changed"
        let observation = try XCTUnwrap(workspace.beginDiffStatsObservation(
            at: workspace.focusedWorkingDirectory,
            for: context
        ))
        let result = PRDetect.diffStats(cwd: directory.path)

        XCTAssertEqual(result, .observed(context: context, stats: nil))
        let editorRoot = directory.appendingPathComponent("editor", isDirectory: true)
        try FileManager.default.createDirectory(at: editorRoot, withIntermediateDirectories: true)
        workspace.addEditorColumn(workspaceCwd: editorRoot.path)
        XCTAssertFalse(workspace.applyDiffStatsObservation(result, observation: observation))
        XCTAssertEqual(workspace.diffStats, "1 file changed")

        workspace.focusedIndex = 1
        let currentObservation = try XCTUnwrap(workspace.beginDiffStatsObservation(
            at: workspace.focusedWorkingDirectory,
            for: context
        ))
        XCTAssertTrue(workspace.applyDiffStatsObservation(
            result,
            observation: currentObservation
        ))
        XCTAssertNil(workspace.diffStats)
    }

    func testNonRepositoryDiffIsConfirmedNotApplicable() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        XCTAssertEqual(PRDetect.diffStats(cwd: directory.path), .notApplicable)
    }

    func testDiffFromStaleGitIdentityPreservesCachedStats() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try initializeGitRepository(at: directory)
        defer { try? FileManager.default.removeItem(at: directory) }

        let workspace = WorkspaceState(title: "context", cwd: directory.path)
        let currentContext = try XCTUnwrap(GitDetect.context(at: directory.path))
        let staleContext = GitContext(
            branch: currentContext.branch,
            identity: GitIdentity(
                repositoryRoot: currentContext.identity.repositoryRoot,
                head: "stale-head",
                isDirty: currentContext.identity.isDirty
            ),
            upstreamRepository: currentContext.upstreamRepository
        )
        XCTAssertTrue(workspace.updateGitContext(staleContext))
        workspace.diffStats = "1 file changed"
        let observation = try XCTUnwrap(workspace.beginDiffStatsObservation(
            at: workspace.focusedWorkingDirectory,
            for: staleContext
        ))

        XCTAssertFalse(workspace.applyDiffStatsObservation(
            PRDetect.diffStats(cwd: directory.path),
            observation: observation
        ))
        XCTAssertEqual(workspace.diffStats, "1 file changed")
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
            upstreamRepository: GitHubRepository(
                host: "ghe.example.com",
                owner: "owner",
                name: "repo"
            )
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

    func testUnknownUpstreamPreservesLastKnownPullRequestIdentity() throws {
        let workspace = WorkspaceState(title: "context", cwd: "/tmp")
        let upstream = GitHubRepository(owner: "owner", name: "repo")
        let originalIdentity = GitIdentity(repositoryRoot: "/repo", head: "head-a")
        let original = GitContext(
            branch: "feature/task",
            identity: originalIdentity,
            upstreamRepository: upstream
        )
        let unknownUpstream = GitContext(
            branch: "feature/task",
            identity: originalIdentity,
            upstreamRepositoryObservation: .failure
        )
        let pullRequest = makePullRequest()

        XCTAssertTrue(workspace.updateGitContext(original))
        XCTAssertTrue(workspace.applyPullRequestInfo(pullRequest, for: original))
        let pullRequestObservation = try XCTUnwrap(
            workspace.beginPullRequestObservation(for: original)
        )
        let unknownObservation = try XCTUnwrap(
            workspace.beginGitContextObservation(at: "/repo")
        )

        XCTAssertEqual(
            workspace.applyGitContextObservation(
                .observed(unknownUpstream),
                observation: unknownObservation
            ),
            .unchanged
        )
        XCTAssertEqual(workspace.gitContext, original)
        XCTAssertEqual(workspace.prInfo, pullRequest)
        XCTAssertTrue(workspace.isCurrentPullRequestObservation(
            pullRequestObservation,
            for: original
        ))

        let changedHead = GitContext(
            branch: "feature/task",
            identity: GitIdentity(repositoryRoot: "/repo", head: "head-b"),
            upstreamRepositoryObservation: .failure
        )
        let changedHeadObservation = try XCTUnwrap(
            workspace.beginGitContextObservation(at: "/repo")
        )
        XCTAssertEqual(
            workspace.applyGitContextObservation(
                .observed(changedHead),
                observation: changedHeadObservation
            ),
            .changed
        )
        let retainedIdentity = try XCTUnwrap(workspace.gitContext)
        XCTAssertEqual(retainedIdentity.upstreamRepository, upstream)
        XCTAssertNil(workspace.prInfo)
        XCTAssertTrue(workspace.applyPullRequestInfo(pullRequest, for: retainedIdentity))

        let confirmedReassignment = GitContext(
            branch: "feature/task",
            identity: retainedIdentity.identity,
            upstreamRepository: GitHubRepository(
                host: "ghe.example.com",
                owner: "owner",
                name: "repo"
            )
        )
        let reassignmentObservation = try XCTUnwrap(
            workspace.beginGitContextObservation(at: "/repo")
        )
        XCTAssertEqual(
            workspace.applyGitContextObservation(
                .observed(confirmedReassignment),
                observation: reassignmentObservation
            ),
            .changed
        )
        XCTAssertEqual(workspace.gitContext, confirmedReassignment)
        XCTAssertNil(workspace.prInfo)
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

    func testSidebarRendererShowsMissingActivityState() {
        let result = SidebarWorkspaceCardRenderer(
            workspace: makeWorkspaceInfo(),
            sidebarWidth: 260,
            padding: 20,
            yOffset: 400
        ).render()
        let labels = result.views.compactMap { ($0 as? NSTextField)?.stringValue }

        XCTAssertTrue(labels.contains("No activity yet"))
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
}
