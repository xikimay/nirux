import AppKit
import XCTest
@testable import Nirux

/// docs/spaces.md, "Interface": selecting an empty space shows what to do
/// instead of opening a workspace. The view has the keyboard, so no key
/// reaches a workspace it hides; it stays while workspaces elsewhere close,
/// and comes back at launch.
@MainActor
final class EmptySpaceFlowTests: XCTestCase {
    func testAnEmptySpaceSaysWhatToDoAndReturnPressesNew() throws {
        try UIFlowHarness.run { harness in
            let shell = harness.shell
            shell.addWorkspace(title: "second", cwd: harness.repo)
            let count = shell.workspaces.count
            let empty = shell.workspaceStore.createProfile(named: "Empty", select: false)

            shell.selectProfile(empty.id)
            XCTAssertEqual(shell.activeProfileID, empty.id)
            XCTAssertEqual(shell.workspaces.count, count, "no workspace opens")
            XCTAssertNil(shell.activeWorkspace)
            // The key interceptor hands keys to AppKit, not to a terminal of
            // the space left behind.
            XCTAssertNil(shell.activeWorkspaceForKeyIntercept)
            XCTAssertEqual(shell.columnIndicator.columnCount, 0)
            let view = shell.emptySpaceView
            XCTAssertFalse(view.isHidden)
            XCTAssertEqual(view.frame, shell.viewport.bounds)
            XCTAssertEqual(view.titleLabel.stringValue, "Empty")
            XCTAssertEqual(view.accessibilityLabel(), "Empty")
            XCTAssertFalse(view.addRepositoryButton.isHidden)
            XCTAssertIdentical(harness.window.firstResponder, view)

            // A workspace closing in another space leaves it on screen.
            shell.closeWorkspace(at: try XCTUnwrap(shell.workspaces.firstIndex { $0.title == "second" }))
            harness.waitUntil("the other space's workspace to close") {
                !shell.workspaces.contains { $0.title == "second" }
            }
            XCTAssertEqual(shell.activeProfileID, empty.id)
            XCTAssertFalse(view.isHidden)

            // Return presses New…, which asks for the workspace's name. It
            // opens in this space, even after another one opened elsewhere
            // meanwhile.
            pressReturn(in: harness.window)
            let field = try XCTUnwrap(harness.waitForField(placeholder: "Name this workspace for the task"))
            shell.addWorkspace(title: "arrived", cwd: harness.repo, profileID: WorkspaceProfile.defaultID)
            harness.submit("first", into: field)
            let first = try XCTUnwrap(shell.activeWorkspace)
            XCTAssertEqual(first.title, "first")
            XCTAssertEqual(first.profileID, empty.id)
            XCTAssertTrue(view.isHidden)
        }
    }

    /// A space's brief and task templates need an editor: on an empty
    /// space, they open in a new workspace there.
    func testTheBriefAndTemplatesOfAnEmptySpaceOpenInANewWorkspace() throws {
        try UIFlowHarness.run { harness in
            let shell = harness.shell
            let briefSpace = shell.workspaceStore.createProfile(named: "Brief", select: false)
            shell.selectProfile(briefSpace.id)
            harness.perform(["Edit Space Brief…"], in: shell.sidebar.spaceOptionsMenu())
            let briefWorkspace = try XCTUnwrap(shell.activeWorkspace)
            XCTAssertEqual(briefWorkspace.profileID, briefSpace.id)
            XCTAssertEqual(briefWorkspace.title, "Brief")
            let brief = try XCTUnwrap(SpaceBrief.briefURL(spaceID: briefSpace.id)).path
            let briefEditor = try XCTUnwrap(briefWorkspace.columns.compactMap(\.editorColumn).first)
            harness.waitUntil("the brief in the editor") { briefEditor.activePath == brief }

            let templatesSpace = shell.workspaceStore.createProfile(named: "Templates", select: false)
            shell.selectProfile(templatesSpace.id)
            harness.perform(["Edit Task Templates…"], in: shell.sidebar.spaceOptionsMenu())
            let templatesWorkspace = try XCTUnwrap(shell.activeWorkspace)
            XCTAssertEqual(templatesWorkspace.profileID, templatesSpace.id)
            let templates = try XCTUnwrap(TaskTemplates.fileURL(spaceID: templatesSpace.id)).path
            let templatesEditor = try XCTUnwrap(templatesWorkspace.columns.compactMap(\.editorColumn).first)
            harness.waitUntil("the templates in the editor") { templatesEditor.activePath == templates }
        }
    }

    /// Quit on an empty space, Nirux opens on it again; on the workspace at
    /// the saved position once that space is gone, not on an empty General.
    func testAnEmptySpaceComesBackAtLaunch() throws {
        try UIFlowHarness.run { harness in
            let shell = harness.shell
            let work = shell.workspaceStore.createProfile(named: "Work", select: false)
            let repoWorkspace = try XCTUnwrap(shell.activeWorkspace)
            shell.moveWorkspaceToSpace(workspaceID: repoWorkspace.id, profileID: work.id)
            let empty = shell.workspaceStore.createProfile(named: "Empty", select: false)
            shell.selectProfile(empty.id)
            var state = shell.persistedState()
            XCTAssertEqual(state.activeProfileID, empty.id)
            XCTAssertNil(state.activeWorkspaceID)

            let back = relaunch(state, in: harness)
            XCTAssertEqual(back.spaceID, empty.id)
            XCTAssertNil(back.workspaceTitle)
            XCTAssertEqual(back.emptyViewSpaceName, "Empty")

            state.activeProfileID = "deleted since"
            let gone = relaunch(state, in: harness)
            XCTAssertEqual(gone.spaceID, work.id)
            XCTAssertEqual(gone.workspaceTitle, repoWorkspace.title)
            XCTAssertNil(gone.emptyViewSpaceName)
        }
    }

    /// What a new shell restoring `state` shows. It is gone before the
    /// harness puts the environment back: nothing it deferred may reach the
    /// real state.
    private func relaunch(
        _ state: PersistedState, in harness: UIFlowHarness
    ) -> (spaceID: String, workspaceTitle: String?, emptyViewSpaceName: String?) {
        XCTAssertTrue(Persistence.save(state))
        weak var released: NiruxShellView?
        let shown = autoreleasepool { () -> (String, String?, String?) in
            let relaunched = NiruxShellView(frame: harness.shell.frame)
            released = relaunched
            relaunched.stopHeartbeat()
            let window = NSWindow(
                contentRect: harness.shell.frame, styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false
            )
            window.isReleasedWhenClosed = false
            window.contentView = relaunched
            defer {
                window.close()
                window.contentView = nil
            }
            relaunched.restoreState()
            XCTAssertEqual(relaunched.workspaces.map(\.title), harness.shell.workspaces.map(\.title))
            let view = relaunched.emptySpaceView
            return (relaunched.activeProfileID, relaunched.activeWorkspace?.title, view.isHidden ? nil : view.content?.spaceName)
        }
        harness.waitUntil("the relaunched shell to go") { released == nil }
        return shown
    }

    /// Return as AppKit delivers it once the key interceptor let it
    /// through: the test process has no key window, so `NSApp.sendEvent`
    /// would hand it to the menu instead (see UIFlowHarness.press).
    private func pressReturn(in window: NSWindow) {
        guard let event = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            characters: "\r",
            charactersIgnoringModifiers: "\r",
            isARepeat: false,
            keyCode: 0x24
        ) else { return XCTFail("no key event") }
        window.sendEvent(event)
    }
}
