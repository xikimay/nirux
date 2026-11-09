import AppKit
import GhosttyTerminal
import XCTest
@testable import Nirux

/// A terminal whose surface was built while no display was active gets its
/// display link only once Ghostty is told its display (`TerminalDisplayID`).
/// CI always has a display: these check that the call reaches a live
/// surface, and that waking displays makes it for every terminal.
@MainActor
final class TerminalDisplayIDTests: XCTestCase {
    /// By reflection on the pinned libghostty-spm, as `TerminalScreenText`.
    func testTheDisplayReachesALiveSurfaceOnly() {
        _ = NSApplication.shared
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let session = InMemoryTerminalSession(write: { _ in }, resize: { _ in })
        XCTAssertFalse(TerminalDisplayID.send(CGMainDisplayID(), to: session))

        let terminal = TerminalView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        terminal.controller = TerminalAppearance.makeController()
        terminal.configuration = TerminalSurfaceOptions(backend: .inMemory(session), workingDirectory: "/tmp")
        window.contentView?.addSubview(terminal)
        window.orderFront(nil)
        UIFlowHarness.waitUntil("the surface") { session.readViewportText() != nil }

        XCTAssertTrue(TerminalDisplayID.send(TerminalDisplayID.display(of: terminal), to: session))
        session.receive("still drawing\r\n")
        UIFlowHarness.waitUntil("the text after the display") { session.readViewportText()?.contains("still drawing") == true }
    }

    func testWakingDisplaysTellsEveryTerminalItsDisplay() throws {
        try UIFlowHarness.run { harness in
            let shell = harness.shell
            let side = shell.workspaceStore.createProfile(named: "side", select: false)
            shell.addWorkspace(title: "task", cwd: harness.repo, profileID: side.id, activate: false)
            // The task's terminal, in a space not on screen, included.
            let all = Set(shell.workspaces.flatMap(\.columns).compactMap { $0.pty?.terminalSession }.map(ObjectIdentifier.init))
            let task = try XCTUnwrap(shell.workspaces.first { $0.title == "task" }?.columns.first?.pty?.terminalSession)
            XCTAssertTrue(all.contains(ObjectIdentifier(task)))
            var told: Set<ObjectIdentifier> = []
            shell.sideEffects.sendTerminalDisplay = { session, _ in told.insert(ObjectIdentifier(session)) }

            NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.screensDidWakeNotification, object: nil)
            harness.waitUntil("every terminal told on wake") { told == all }

            told = []
            NotificationCenter.default.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)
            harness.waitUntil("every terminal told on a display change") { told == all }
        }
    }
}
