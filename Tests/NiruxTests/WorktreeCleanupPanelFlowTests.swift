import AppKit
import XCTest
@testable import Nirux

/// Drives the palette's "Clean Up Merged Worktrees…" end to end: the panel
/// inspects each worktree on an OperationQueue and hops back to the main
/// actor. A block that inherits the view's main-actor isolation traps when
/// the queue runs it (Swift 6 checks isolation at run time), which crashed
/// the app on the SDK the nightly builds with.
final class WorktreeCleanupPanelFlowTests: XCTestCase {
    private var root: String!

    override func setUpWithError() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("nirux-cleanup-flow-\(UUID().uuidString)")
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        root = base.path
    }

    override func tearDown() {
        if let root { try? FileManager.default.removeItem(atPath: root) }
        super.tearDown()
    }

    @MainActor
    func testBulkPanelInspectsOpenAndUnopenedWorktreesWithoutTrapping() throws {
        let repo = root + "/repo"
        try FileManager.default.createDirectory(atPath: repo, withIntermediateDirectories: true)
        try UIFlowHarness.git(["init", "-q", "-b", "main"], at: repo)
        try UIFlowHarness.git(["-c", "user.name=Test", "-c", "user.email=test@example.com", "commit", "-q", "--allow-empty", "-m", "init"], at: repo)
        let opened = root + "/repo.feat-opened"
        let unopened = root + "/repo.feat-unopened"
        try UIFlowHarness.git(["worktree", "add", "-q", "-b", "feat/opened", opened], at: repo)
        try UIFlowHarness.git(["worktree", "add", "-q", "-b", "feat/unopened", unopened], at: repo)

        let stateDirectory = root + "/state"
        try FileManager.default.createDirectory(atPath: stateDirectory, withIntermediateDirectories: true)
        let previousStateDirectory = ProcessInfo.processInfo.environment["NIRUX_STATE_DIR"]
        setenv("NIRUX_STATE_DIR", stateDirectory, 1)
        defer {
            if let previousStateDirectory {
                setenv("NIRUX_STATE_DIR", previousStateDirectory, 1)
            } else {
                unsetenv("NIRUX_STATE_DIR")
            }
        }

        _ = NSApplication.shared
        let shell = NiruxShellView(frame: NSRect(x: 0, y: 0, width: 1200, height: 800))
        shell.stopHeartbeat()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = shell
        defer { window.close() }
        // One workspace inside a worktree (inspected directly), one in the
        // main checkout (its other worktree is found by listing, off main).
        shell.addWorkspace(title: "opened", cwd: opened)
        shell.addWorkspace(title: "main checkout", cwd: repo)

        shell.showWorktreeCleanupPanel()
        let panel = try XCTUnwrap(shell.worktreeCleanupPanel)
        defer { panel.dismiss() }

        let deadline = Date().addingTimeInterval(30)
        func inspectedPaths() -> Set<String> {
            Set(panel.candidates.filter { $0.inspection != nil }.map { NiruxShellView.comparablePath($0.path) })
        }
        let expected = Set([opened, unopened].map { NiruxShellView.comparablePath($0) })
        while !expected.isSubset(of: inspectedPaths()), Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        XCTAssertTrue(
            expected.isSubset(of: inspectedPaths()),
            "not inspected: \(expected.subtracting(inspectedPaths()))"
        )
    }
}
