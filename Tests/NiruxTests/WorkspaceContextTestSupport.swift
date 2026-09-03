import Foundation
@testable import Nirux

extension WorkspaceContextTests {
    func makeWorkspaceInfo(
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

    func makePullRequest() -> PRInfo {
        PRInfo(
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
    }

    func initializeGitRepository(at directory: URL) throws {
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

    func runGit(_ arguments: [String], at directory: URL) throws {
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
