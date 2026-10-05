import AppKit
import XCTest
@testable import Nirux

/// A Branch Review column is saved with its worktree and branch, and comes
/// back once per worktree; an older build restores it as a terminal there.
final class BranchReviewPersistenceTests: XCTestCase {
    private var root: String!

    override func setUpWithError() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("nirux-review-state-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        root = try XCTUnwrap(base.path.realPath)
    }

    override func tearDown() {
        if let root { try? FileManager.default.removeItem(atPath: root) }
    }

    func testOlderBuildsReadTheColumnAsATerminalInTheWorktree() throws {
        let column = PersistedColumn(
            widthPreset: 2.0 / 3.0, cwd: "/p/widgets", columnType: .branchReview, webViewURL: nil,
            claudeLaunchMode: nil, codexLaunchMode: nil, reviewBranch: "feat/x"
        )
        let data = try JSONEncoder().encode(column)
        let decoded = try JSONDecoder().decode(PersistedColumn.self, from: data)
        XCTAssertEqual(decoded.resolvedType, .branchReview)
        XCTAssertEqual(decoded.reviewBranch, "feat/x")
        // An older build knows no `branchReview` kind.
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object["columnType"] = "somethingNewer"
        let older = try JSONDecoder().decode(PersistedColumn.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertEqual(older.resolvedType, .terminal)
        XCTAssertEqual(older.cwd, "/p/widgets")
    }

    @MainActor
    func testTheReviewIsSavedAndRestoredOncePerWorktree() throws {
        let worktree = root + "/widgets"
        try FileManager.default.createDirectory(atPath: worktree, withIntermediateDirectories: true)
        var state: PersistedState?
        try withShell { shell in
            shell.addWorkspace(title: "widgets", cwd: worktree)
            shell.openBranchReview(in: shell.activeWorkspace)
            let review = try XCTUnwrap(shell.branchReviewLocation(worktree: worktree)?.review)
            waitUntil("the read") { review.snapshot != nil }
            state = shell.persistedState()
        }
        var saved = try XCTUnwrap(state)
        let index = try XCTUnwrap(saved.workspaces.firstIndex { $0.title == "widgets" })
        let column = try XCTUnwrap(saved.workspaces[index].columns.first { $0.columnType == .branchReview })
        XCTAssertEqual(column.cwd, worktree)
        XCTAssertEqual(column.reviewBranch, "feat/keep-awake")
        XCTAssertEqual(column.widthPreset, 2.0 / 3.0, accuracy: 0.0001)
        // A hand-edited state with a second review of the worktree.
        saved.workspaces[index].columns.append(column)

        // Another workspace in front: the review waits for its own.
        let widgets = saved.workspaces[index].id
        saved.activeWorkspaceID = saved.workspaces.first { $0.id != widgets }?.id
        XCTAssertNotNil(saved.activeWorkspaceID)
        try withShell(restoring: saved) { shell in
            XCTAssertEqual(shell.branchReviewLocations.count, 1)
            let workspace = try XCTUnwrap(shell.workspaces.first { $0.title == "widgets" })
            XCTAssertEqual(workspace.columns.filter(\.isBranchReview).count, 1)
            XCTAssertNotNil(workspace.columns.last?.pty, "the second review came back as a terminal")
            let review = try XCTUnwrap(shell.branchReviewLocation(worktree: worktree)?.review)
            XCTAssertEqual(review.branch, "feat/keep-awake")
            shell.relayout(animated: false)
            RunLoop.main.run(until: Date().addingTimeInterval(NiruxShellView.onScreenResumeDelay + 0.2))
            XCTAssertFalse(review.isStarted, "read before its workspace showed")
            XCTAssertFalse(review.view.isLoaded)

            // Once its workspace has stayed on screen a moment.
            shell.focusWorkspace(id: workspace.id)
            XCTAssertFalse(review.isStarted)
            waitUntil("the restored review to start") { review.isStarted }
            waitUntil("the restored review to read") { review.snapshot != nil }
        }
    }

    // MARK: - Helpers

    @MainActor
    private func withShell(restoring state: PersistedState? = nil, _ body: (NiruxShellView) throws -> Void) throws {
        let stateDirectory = root + "/state"
        try FileManager.default.createDirectory(atPath: stateDirectory, withIntermediateDirectories: true)
        let previous = ProcessInfo.processInfo.environment["NIRUX_STATE_DIR"]
        setenv("NIRUX_STATE_DIR", stateDirectory, 1)
        defer {
            if let previous { setenv("NIRUX_STATE_DIR", previous, 1) } else { unsetenv("NIRUX_STATE_DIR") }
        }
        _ = NSApplication.shared
        let shell = NiruxShellView(frame: NSRect(x: 0, y: 0, width: 1400, height: 900))
        shell.stopHeartbeat()
        shell.branchReviewReader = BranchReviewPageTests.reader
        shell.sideEffects.checkExplain = { .unavailable("No claude in tests.") }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1400, height: 900),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = shell
        defer { window.close() }
        if let state {
            XCTAssertTrue(Persistence.save(state))
            shell.restoreState()
        }
        try body(shell)
    }

    @MainActor
    private func waitUntil(_ description: String, _ condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(30)
        while !condition() {
            guard Date() < deadline else { return XCTFail("timed out waiting for \(description)") }
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
    }
}
