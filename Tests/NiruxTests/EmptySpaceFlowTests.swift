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

            // Return presses New…, which asks for the workspace's name.
            pressReturn(in: harness.window)
            let field = try XCTUnwrap(harness.waitForField(placeholder: "Name this workspace for the task"))
            harness.submit("first", into: field)
            let first = try XCTUnwrap(shell.activeWorkspace)
            XCTAssertEqual(first.title, "first")
            XCTAssertEqual(first.profileID, empty.id)
            XCTAssertTrue(view.isHidden)
        }
    }

    /// Quit on an empty space, Nirux opens on it again.
    func testAnEmptySpaceComesBackAtLaunch() throws {
        try UIFlowHarness.run { harness in
            let shell = harness.shell
            let empty = shell.workspaceStore.createProfile(named: "Empty", select: false)
            shell.selectProfile(empty.id)
            let state = shell.persistedState()
            XCTAssertEqual(state.activeProfileID, empty.id)
            XCTAssertNil(state.activeWorkspaceID)

            XCTAssertTrue(Persistence.save(state))

            // Gone before the harness puts the environment back: nothing it
            // deferred may reach the real state.
            weak var released: NiruxShellView?
            try autoreleasepool {
                let relaunched = NiruxShellView(frame: shell.frame)
                released = relaunched
                relaunched.stopHeartbeat()
                let window = NSWindow(
                    contentRect: shell.frame, styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false
                )
                window.isReleasedWhenClosed = false
                window.contentView = relaunched
                defer {
                    window.close()
                    window.contentView = nil
                }
                relaunched.restoreState()
                XCTAssertEqual(relaunched.activeProfileID, empty.id)
                XCTAssertNil(relaunched.activeWorkspace)
                XCTAssertEqual(relaunched.workspaces.map(\.title), shell.workspaces.map(\.title))
                XCTAssertFalse(relaunched.emptySpaceView.isHidden)
                XCTAssertEqual(try XCTUnwrap(relaunched.emptySpaceView.content).spaceName, "Empty")
            }
            harness.waitUntil("the relaunched shell to go") { released == nil }
        }
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
