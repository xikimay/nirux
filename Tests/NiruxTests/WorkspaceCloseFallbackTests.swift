import AppKit
import XCTest
@testable import Nirux

/// Which workspace takes over when the selected one closes (⌘W on its last
/// column, sidebar Close, worktree clean-up): the nearest active card in the
/// sidebar — below it, then above — and an inactive one only when no active
/// workspace is left in any space.
@MainActor
final class WorkspaceCloseFallbackTests: XCTestCase {
    private let work = WorkspaceProfile(id: "work", name: "work", colorHex: "#9ECE6A")
    private let side = WorkspaceProfile(id: "side", name: "side", colorHex: "#E0AF68")

    /// Workspaces in store order, each "id" or "id:space", ending in "~"
    /// when inactive.
    private func makeStore(_ specs: [String]) -> WorkspaceStore {
        let store = WorkspaceStore()
        store.replaceProfiles([WorkspaceProfile.defaultProfile, work, side], activeProfileID: nil)
        for spec in specs {
            let isInactive = spec.hasSuffix("~")
            let parts = spec.dropLast(isInactive ? 1 : 0).split(separator: ":").map(String.init)
            let workspace = WorkspaceState(
                id: parts[0], title: parts[0], cwd: "/tmp/\(parts[0])",
                profileID: parts.count > 1 ? parts[1] : WorkspaceProfile.defaultID
            )
            workspace.isInactive = isInactive
            store.appendWorkspace(workspace, activate: false)
        }
        return store
    }

    private func fallbackID(closing id: String, in store: WorkspaceStore) -> String? {
        let index = store.workspaces.firstIndex { $0.id == id }!
        return store.fallbackIndexAfterClosingWorkspace(at: index).map { store.workspaces[$0].id }
    }

    func testTakesTheNextActiveCardThenThePreviousOne() {
        let store = makeStore(["a", "b", "c"])
        XCTAssertEqual(fallbackID(closing: "b", in: store), "c")
        XCTAssertEqual(fallbackID(closing: "a", in: store), "b")
        XCTAssertEqual(fallbackID(closing: "c", in: store), "b")
    }

    func testPassesOverAnInactiveWorkspaceTheStoreHoldsBetweenActiveOnes() {
        // The sidebar lists a, b, then the folded x: x sits before b in the
        // store only.
        let store = makeStore(["a", "x~", "b"])
        XCTAssertEqual(fallbackID(closing: "b", in: store), "a")
        XCTAssertEqual(fallbackID(closing: "a", in: store), "b")

        let parkedFirst = makeStore(["x~", "a", "b"])
        XCTAssertEqual(fallbackID(closing: "b", in: parkedFirst), "a")
    }

    func testClosingTheSelectedInactiveWorkspaceGoesToTheLastActiveCard() {
        // Even with the section unfolded: the active cards are listed first,
        // and the last one is the nearest — wherever the store holds them.
        let store = makeStore(["a", "b", "x~", "y~"])
        XCTAssertEqual(fallbackID(closing: "x", in: store), "b")
        XCTAssertEqual(fallbackID(closing: "y", in: store), "b")
        XCTAssertEqual(fallbackID(closing: "x", in: makeStore(["x~", "a", "b"])), "b")
        XCTAssertEqual(fallbackID(closing: "x", in: makeStore(["a", "x~", "b", "c"])), "c")
    }

    func testStaysInTheSpaceWhileItHasAnActiveWorkspace() {
        // w sits between a and b in the store, but in another space.
        let store = makeStore(["a", "w:work", "b"])
        XCTAssertEqual(fallbackID(closing: "a", in: store), "b")
        XCTAssertEqual(fallbackID(closing: "b", in: store), "a")
    }

    func testLastActiveCardOfASpaceGoesToAnotherSpaceBeforeAnInactiveOne() {
        // The default space keeps only the folded x; work's first active
        // card is w2 (w1 is inactive).
        let store = makeStore(["a", "x~", "w1:work~", "w2:work"])
        XCTAssertEqual(fallbackID(closing: "a", in: store), "w2")
    }

    func testAnotherSpaceIsTheFirstInTheSpaceListWithAnActiveWorkspace() {
        // The space list's order, as reconcileSelection's, not the store's.
        let store = makeStore(["s:side", "p:work~", "w:work", "a"])
        XCTAssertEqual(fallbackID(closing: "a", in: store), "w")
        XCTAssertEqual(fallbackID(closing: "a", in: makeStore(["s:side", "a"])), "s")
        // A space with only inactive workspaces is passed over.
        XCTAssertEqual(fallbackID(closing: "a", in: makeStore(["a", "w:work~", "s:side"])), "s")
    }

    func testFallsBackToAnInactiveWorkspaceOnlyWhenNoActiveOneIsLeft() {
        // Its own space's folded section first, top card first.
        let store = makeStore(["a", "x~", "y~", "w:work~"])
        XCTAssertEqual(fallbackID(closing: "a", in: store), "x")
        // From an inactive card: the next one, then the previous one.
        let parked = makeStore(["x~", "y~", "w:work~"])
        XCTAssertEqual(fallbackID(closing: "x", in: parked), "y")
        XCTAssertEqual(fallbackID(closing: "y", in: parked), "x")

        let otherSpace = makeStore(["a", "w:work~"])
        XCTAssertEqual(fallbackID(closing: "a", in: otherSpace), "w")
    }

    func testSkipsWorkspacesAlreadyClosing() {
        let store = makeStore(["a", "b", "c", "x~", "w:work"])
        store.workspaces[2].isClosing = true  // c
        XCTAssertEqual(fallbackID(closing: "b", in: store), "a")
        store.workspaces[0].isClosing = true  // a
        XCTAssertEqual(fallbackID(closing: "b", in: store), "w")
        store.workspaces[4].isClosing = true  // w
        XCTAssertEqual(fallbackID(closing: "b", in: store), "x")
        store.workspaces[3].isClosing = true  // x
        XCTAssertNil(fallbackID(closing: "b", in: store))
    }

    func testIndexOutOfRangeHasNoFallback() {
        XCTAssertNil(makeStore(["a", "b"]).fallbackIndexAfterClosingWorkspace(at: 2))
    }

    // MARK: - Through the shell

    /// A shell saving to a scratch state folder, with its first workspace
    /// open in the home folder; `body` gets a folder to open workspaces in,
    /// and the state folder.
    private func withShell(_ body: (NiruxShellView, String, String) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("nirux-close-fallback-\(UUID().uuidString)").path
        let stateDirectory = root + "/state"
        let folder = root + "/work"
        for path in [stateDirectory, folder] {
            try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        }
        let previousStateDirectory = ProcessInfo.processInfo.environment["NIRUX_STATE_DIR"]
        setenv("NIRUX_STATE_DIR", stateDirectory, 1)
        defer {
            if let previousStateDirectory {
                setenv("NIRUX_STATE_DIR", previousStateDirectory, 1)
            } else {
                unsetenv("NIRUX_STATE_DIR")
            }
            try? FileManager.default.removeItem(atPath: root)
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
        try body(shell, folder, stateDirectory)
    }

    private func workspace(_ title: String, in shell: NiruxShellView) -> WorkspaceState {
        shell.workspaces.first { $0.title == title }!
    }

    private func index(of workspace: WorkspaceState, in shell: NiruxShellView) -> Int {
        shell.workspaces.firstIndex { $0 === workspace }!
    }

    private func waitForClosesToEnd(in shell: NiruxShellView) {
        waitUntil { !shell.workspaces.contains(where: \.isClosing) }
        XCTAssertFalse(shell.workspaces.contains(where: \.isClosing), "a close never ended")
    }

    private func waitUntil(_ condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(30)
        while !condition(), Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
    }

    func testCommandWAndSidebarCloseSelectTheNeighbourInTheSidebar() throws {
        try withShell { shell, folder, _ in
            for title in ["parked", "c", "a", "b"] { shell.addWorkspace(title: title, cwd: folder) }
            let parked = workspace("parked", in: shell)
            shell.handleWorkspaceSidebarAction(.markInactive, workspaceIndex: index(of: parked, in: shell))
            // The sidebar lists home, c, a, b, then the folded parked, which
            // the store holds before them.

            // ⌘W on b's only column.
            shell.switchToWorkspace(index(of: workspace("b", in: shell), in: shell))
            shell.closeActiveColumn()
            XCTAssertEqual(shell.activeWorkspace?.title, "a")

            // Closing another card leaves the selection alone.
            shell.handleWorkspaceSidebarAction(.close, workspaceIndex: index(of: workspace("c", in: shell), in: shell))
            XCTAssertEqual(shell.activeWorkspace?.title, "a")
            waitForClosesToEnd(in: shell)
            XCTAssertEqual(shell.activeWorkspace?.title, "a")

            // Sidebar Close on the inactive workspace on screen, with the
            // section unfolded: back to the active cards all the same.
            shell.switchToWorkspace(index(of: parked, in: shell))
            shell.sidebar.toggleInactiveSection()
            XCTAssertFalse(shell.sidebar.isInactiveSectionCollapsed)
            shell.handleWorkspaceSidebarAction(.close, workspaceIndex: index(of: parked, in: shell))
            XCTAssertEqual(shell.activeWorkspace?.title, "a")
            waitForClosesToEnd(in: shell)
        }
    }

    func testClosingASpacesLastActiveCardSwitchesSpaceLikeAnySwitch() throws {
        try withShell { shell, folder, _ in
            let home = try XCTUnwrap(shell.activeWorkspace)
            let side = shell.workspaceStore.createProfile(named: "side")
            for title in ["a", "x"] { shell.addWorkspace(title: title, cwd: folder, profileID: side.id) }
            shell.handleWorkspaceSidebarAction(.markInactive, workspaceIndex: index(of: workspace("x", in: shell), in: shell))
            shell.switchToWorkspace(index(of: workspace("a", in: shell), in: shell))
            home.hasNotification = true

            let strip = try XCTUnwrap(shell.verticalStrip.layer)
            strip.removeAllAnimations()  // selecting a slid the strip

            // side keeps only the parked x: the main space's home takes over,
            // its badge cleared as when switching to it, and shown at once,
            // not slid in from side's strip.
            shell.closeActiveColumn()
            XCTAssertTrue(shell.activeWorkspace === home)
            XCTAssertEqual(shell.activeProfileID, WorkspaceProfile.defaultID)
            XCTAssertFalse(home.hasNotification)
            XCTAssertNil(strip.animation(forKey: "wsSlide"))
            waitForClosesToEnd(in: shell)
            XCTAssertTrue(shell.activeWorkspace === home)
        }
    }

    func testWorktreeCleanUpHandsOverOnceFromTheSelectedWorkspace() throws {
        try withShell { shell, folder, stateDirectory in
            // main: home (parked); side: a (selected), x (parked);
            // work: w, y (parked). The clean-up closes a and w.
            let worktree = folder + "/feat-x"
            try FileManager.default.createDirectory(atPath: worktree, withIntermediateDirectories: true)
            let home = try XCTUnwrap(shell.activeWorkspace)
            let side = shell.workspaceStore.createProfile(named: "side")
            shell.addWorkspace(title: "a", cwd: worktree, profileID: side.id)
            shell.addWorkspace(title: "x", cwd: folder, profileID: side.id)
            let work = shell.workspaceStore.createProfile(named: "work")
            shell.addWorkspace(title: "w", cwd: worktree, profileID: work.id)
            shell.addWorkspace(title: "y", cwd: folder, profileID: work.id)
            for parked in [home, workspace("x", in: shell), workspace("y", in: shell)] {
                shell.handleWorkspaceSidebarAction(.markInactive, workspaceIndex: index(of: parked, in: shell))
            }
            let closedIDs = [workspace("a", in: shell).id, workspace("w", in: shell).id]
            func savedClosedWorkspace() -> Bool {
                let saved = (try? String(contentsOfFile: stateDirectory + "/state.json", encoding: .utf8)) ?? ""
                return closedIDs.contains { saved.contains($0) }
            }
            XCTAssertTrue(savedClosedWorkspace(), "parking saves the state")
            shell.switchToWorkspace(index(of: workspace("a", in: shell), in: shell))

            shell.closeWorkspacesAfterCleanup(of: shell.worktreeCleanupCandidate(path: worktree))
            // w, closing too, never takes over (it would hand over to its
            // own space's y): a's own space's parked x does, its section
            // left folded.
            XCTAssertEqual(shell.activeWorkspace?.title, "x")
            XCTAssertTrue(shell.sidebar.isInactiveSectionCollapsed)
            waitForClosesToEnd(in: shell)
            XCTAssertEqual(shell.activeWorkspace?.title, "x")
            XCTAssertEqual(shell.workspaces.map(\.title).sorted(), [home.title, "x", "y"].sorted())

            // The clean-up saves once they're gone: it must land before
            // NIRUX_STATE_DIR is restored, or it would write the real state.
            waitUntil { !savedClosedWorkspace() }
            XCTAssertFalse(savedClosedWorkspace(), "the clean-up's save never landed")
        }
    }
}
