import XCTest
@testable import Nirux

/// Clean Up Worktree… from a workspace's ⋯ menu, in a real window on
/// throwaway state (see UIFlowHarness). The Project Board's Clean Up… and
/// the bulk panel run the same way.
@MainActor
final class WorktreeCleanupFlowTests: XCTestCase {
    /// git deletes the ignored files it finds with the folder: nothing of
    /// the worktree's workspaces may still write there when it runs (F1 of
    /// the 2026-11-19 evaluation). They close first, and git waits for
    /// their terminals' processes to end; a change made while the
    /// confirmation was up stops it before they close.
    func testGitRunsOnceTheWorkspacesProcessesEnded() throws {
        try UIFlowHarness.run { harness in
            let shell = harness.shell
            _ = try harness.stubCleanupTools()
            try UIFlowHarness.git(["remote", "add", "acme", "https://github.com/acme/widgets.git"], at: harness.repo)
            let folder = harness.root + "/repo.feat-merged"
            try harness.mergedWorktree("feat/merged", in: folder, number: 7)
            shell.addWorkspace(title: "Merged work", cwd: folder)
            let workspace = try XCTUnwrap(shell.workspaces.first { $0.title == "Merged work" })
            let pty = try XCTUnwrap(workspace.columns.first?.pty)
            harness.waitUntil("its shell") { pty.shellPID != nil }
            let shellPID = try XCTUnwrap(pty.shellPID)
            // A dev server, say, that takes a few seconds to stop.
            pty.sendRaw("perl -e '$SIG{HUP} = sub { $SIG{HUP} = \"IGNORE\"; sleep 1 for 1 .. 3; exit }; sleep 600'\r")
            harness.waitUntil("the job") { ProcessSnapshot().tree(of: shellPID).contains { $0.name == "perl" } }
            let job = try XCTUnwrap(ProcessSnapshot().tree(of: shellPID).first { $0.name == "perl" }).process
            defer { if ProcessInstance.running(pid: job.pid) == job { kill(job.pid, SIGKILL) } }
            // git notes whether the job still runs as it deletes the folder.
            let gitPath = harness.root + "/git-wrapper"
            let ran = harness.root + "/job-ran"
            try """
            #!/bin/sh
            if [ "$1 $2" = "worktree remove" ]; then
              case "$(ps -o stat= -p \(job.pid))" in ""|Z*) ;; *) touch '\(ran)' ;; esac
            fi
            exec /usr/bin/git "$@"
            """.write(toFile: gitPath, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: gitPath)
            var tools = shell.worktreeCleanupTools()
            tools.gitPath = gitPath
            let wrapped = tools
            shell.worktreeCleanupTools = { wrapped }
            var (alerts, writesDraft) = ([String](), true)
            shell.sideEffects.runModal = { alert in
                alerts.append(alert.messageText)
                if writesDraft { try? "draft\n".write(toFile: folder + "/draft.txt", atomically: true, encoding: .utf8) }
                writesDraft = false
                return .alertSecondButtonReturn
            }

            shell.requestWorktreeCleanup(path: folder)
            harness.waitUntil("the clean-up to stop", timeout: 120) { shell.worktreeCleanupsInFlight.isEmpty }
            XCTAssertEqual(alerts, ["Clean up worktree “feat/merged”?", "Clean-up of feat/merged stopped"])
            XCTAssertFalse(workspace.isClosing, "a draft written during the confirmation keeps the workspace open")

            try FileManager.default.removeItem(atPath: folder + "/draft.txt")
            alerts = []
            shell.requestWorktreeCleanup(path: folder)
            harness.waitUntil("the clean-up", timeout: 120) { shell.worktreeCleanupsInFlight.isEmpty }
            XCTAssertEqual(alerts, ["Clean up worktree “feat/merged”?"])
            XCTAssertFalse(FileManager.default.fileExists(atPath: folder))
            XCTAssertFalse(FileManager.default.fileExists(atPath: ran), "the job still ran as git deleted the folder")
        }
    }
}
