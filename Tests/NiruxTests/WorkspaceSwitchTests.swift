import AppKit
import XCTest
@testable import Nirux

/// A workspace switch: the strip slides from where it is on screen, the
/// workspace it leaves stays drawn until it has left, and a card names the
/// workspace it lands on, with its place in the list.
@MainActor
final class WorkspaceSwitchTests: XCTestCase {
    private func withShell(
        reducesMotion: Bool = false, _ body: (NiruxShellView, ManualSchedule, String) throws -> Void
    ) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("nirux-switch-\(UUID().uuidString)").path
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
        try autoreleasepool {
            let shell = NiruxShellView(frame: NSRect(x: 0, y: 0, width: 1200, height: 800))
            shell.stopHeartbeat()
            // Whatever the machine: a window in view, a display awake.
            shell.sideEffects.windowShows = { _ in true }
            shell.sideEffects.reducesMotion = { reducesMotion }
            shell.agentLights.isDisplayAsleep = false
            let clock = ManualSchedule()
            shell.workspaceSwitch.schedule = clock.schedule
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800),
                styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false
            )
            window.isReleasedWhenClosed = false
            window.contentView = shell
            defer { window.close() }
            // Three workspaces in the space; the first one on screen.
            for title in ["second", "third"] { shell.addWorkspace(title: title, cwd: folder) }
            shell.switchToWorkspace(0, announces: false)
            shell.verticalStrip.layer?.removeAllAnimations()
            shell.workspaceNameCard.hide(animated: false)
            clock.advance(by: 5)
            try body(shell, clock, folder)
        }
    }

    private func slide(of shell: NiruxShellView) -> CABasicAnimation? {
        shell.verticalStrip.layer?.animation(forKey: NiruxShellView.workspaceSlideKey) as? CABasicAnimation
    }

    // MARK: - The slide

    /// A new switch while one plays starts from where the strip is on
    /// screen, not from where the last one was headed.
    func testASlideStartsFromWhereTheStripIsOnScreen() {
        XCTAssertEqual(NiruxShellView.workspaceSlideStart(oldY: -800, targetY: 0, shownOffset: 0), -800)
        // Half-way down from -1600 to -800, the strip shows at -1200: the
        // next slide, back up to 0, starts there.
        XCTAssertEqual(NiruxShellView.workspaceSlideStart(oldY: -800, targetY: 0, shownOffset: -400), -1200)
    }

    /// ⌘↓: the strip slides to the next workspace, the one it leaves stays
    /// drawn until the slide ends, then only the workspace on screen draws.
    /// Presses during a slide take it on from where it is, one slide at a
    /// time.
    func testTheStripSlidesAndKeepsTheWorkspaceItLeavesDrawn() throws {
        try withShell { shell, clock, _ in
            let first = try XCTUnwrap(shell.activeWorkspace)
            shell.focusWorkspace(.down)
            let second = try XCTUnwrap(shell.activeWorkspace)
            XCTAssertFalse(first === second)
            let slide = try XCTUnwrap(self.slide(of: shell))
            XCTAssertEqual(slide.duration, NiruxShellView.workspaceSlideDuration)
            XCTAssertEqual((slide.toValue as? NSNumber)?.doubleValue, 0)
            XCTAssertNotEqual((slide.fromValue as? NSNumber)?.doubleValue ?? 0, 0)
            XCTAssertTrue(shell.drawsTerminals(of: first, isActive: false), "the workspace it leaves, while it leaves")
            XCTAssertTrue(shell.drawsTerminals(of: second, isActive: true))

            // Half-way, another press: the strip is shown half-way between
            // its two places.
            shell.workspaceSwitch.shownStripOffset = { _ in -200 }
            clock.advance(by: NiruxShellView.workspaceSlideDuration / 2)
            let oldY = shell.verticalStrip.frame.origin.y
            shell.focusWorkspace(.down)
            let third = try XCTUnwrap(shell.activeWorkspace)
            let retarget = try XCTUnwrap(self.slide(of: shell))
            XCTAssertEqual(
                (retarget.fromValue as? NSNumber)?.doubleValue, Double(oldY - 200 - shell.verticalStrip.frame.origin.y),
                "from where it is on screen"
            )
            XCTAssertEqual(shell.verticalStrip.layer?.animationKeys(), [NiruxShellView.workspaceSlideKey], "one slide, not two")
            XCTAssertTrue(shell.drawsTerminals(of: first, isActive: false))
            XCTAssertTrue(shell.drawsTerminals(of: second, isActive: false))

            // The first slide's end doesn't cut the second one short.
            clock.advance(by: NiruxShellView.workspaceSlideDuration / 2 + 0.01)
            XCTAssertTrue(shell.drawsTerminals(of: second, isActive: false))
            clock.advance(by: NiruxShellView.workspaceSlideDuration)
            XCTAssertFalse(shell.drawsTerminals(of: first, isActive: false), "settled: only the one on screen")
            XCTAssertFalse(shell.drawsTerminals(of: second, isActive: false))
            XCTAssertTrue(shell.drawsTerminals(of: third, isActive: true))
        }
    }

    /// With Reduce motion (or animations off) the workspace shows at once:
    /// no slide, nothing kept drawn, no card.
    func testNothingMovesWhileTheInterfaceMayNot() throws {
        try withShell(reducesMotion: true) { shell, _, _ in
            let first = try XCTUnwrap(shell.activeWorkspace)
            shell.focusWorkspace(.down)
            XCTAssertFalse(shell.activeWorkspace === first, "it switched")
            XCTAssertNil(self.slide(of: shell))
            XCTAssertFalse(shell.drawsTerminals(of: first, isActive: false))
            XCTAssertFalse(shell.workspaceNameCard.isShown)
        }
    }

    /// A relayout for something else (a resize, the status bar) doesn't
    /// cut a slide short.
    func testARelayoutThatMovesNothingLetsTheSlidePlay() throws {
        try withShell { shell, _, _ in
            shell.focusWorkspace(.down)
            let from = try XCTUnwrap(self.slide(of: shell)?.fromValue as? NSNumber)
            shell.relayout(animated: false)
            XCTAssertEqual(self.slide(of: shell)?.fromValue as? NSNumber, from)
        }
    }

    // MARK: - The card

    /// The card names the workspace the switch lands on, with its state's
    /// dot and one dot per workspace, its own lit; centred in the
    /// viewport; for a moment after the slide, then it leaves. It takes no
    /// click and no keyboard.
    func testTheCardNamesTheWorkspaceAndItsPlace() throws {
        try withShell { shell, clock, _ in
            let card = shell.workspaceNameCard
            XCTAssertFalse(card.isShown)
            shell.focusWorkspace(.down)
            XCTAssertTrue(card.isShown)
            XCTAssertEqual(card.alphaValue, 1)
            XCTAssertNotNil(card.layer?.animation(forKey: WorkspaceNameCard.showKey))
            XCTAssertEqual(card.name, "second")
            XCTAssertEqual(card.dotCount, 3)
            XCTAssertEqual(card.litDot, 1)
            XCTAssertEqual(card.stateColor, Theme.Color.idle.cgColor, "nothing works there")
            XCTAssertEqual(card.frame.midX, shell.viewport.frame.midX, accuracy: 1)
            XCTAssertEqual(card.frame.midY, shell.viewport.frame.midY, accuracy: 1)
            XCTAssertNil(card.hitTest(NSPoint(x: card.frame.midX, y: card.frame.midY)))
            XCTAssertFalse(card.acceptsFirstResponder)
            XCTAssertFalse(card.isAccessibilityElement())

            clock.advance(by: NiruxShellView.workspaceSlideDuration + NiruxShellView.workspaceCardHold - 0.05)
            XCTAssertTrue(card.isShown, "the slide, then a moment")
            clock.advance(by: 0.1)
            XCTAssertFalse(card.isShown)
            XCTAssertEqual(card.alphaValue, 0, "gone even if its fade never runs")
        }
    }

    /// Presses in a row change the card's words and start its moment
    /// again: one card, nothing queued.
    func testPressesInARowUpdateOneCard() throws {
        try withShell { shell, clock, _ in
            let card = shell.workspaceNameCard
            shell.focusWorkspace(.down)
            clock.advance(by: 0.5)
            shell.focusWorkspace(.down)
            XCTAssertEqual(card.name, "third")
            XCTAssertEqual(card.litDot, 2)
            XCTAssertEqual(shell.subviews.filter { $0 is WorkspaceNameCard }.count, 1)
            clock.advance(by: 0.5)
            XCTAssertTrue(card.isShown, "the first press's end doesn't take it away")
            clock.advance(by: NiruxShellView.workspaceSlideDuration + NiruxShellView.workspaceCardHold)
            XCTAssertFalse(card.isShown)

            // At the last workspace, ⌘↓ goes nowhere: no card.
            shell.focusWorkspace(.down)
            XCTAssertFalse(card.isShown)
        }
    }

    /// A click on a workspace's own row: the user knows where they go, no
    /// card. A switch from elsewhere (the palette, a notification) shows
    /// it.
    func testNoCardForAClickOnTheWorkspacesOwnRow() throws {
        try withShell { shell, _, _ in
            let card = shell.workspaceNameCard
            shell.sidebar.onWorkspaceClicked?(1)
            XCTAssertEqual(shell.activeWSIndex, 1)
            XCTAssertFalse(card.isShown)
            shell.switchToWorkspace(2)
            XCTAssertTrue(card.isShown)
            XCTAssertEqual(card.name, "third")
        }
    }

    /// More workspaces than dots fit: the card says the place in words.
    func testManyWorkspacesAreCountedInWords() {
        let card = WorkspaceNameCard()
        let area = NSRect(x: 0, y: 0, width: 900, height: 600)
        card.show(.init(name: "big", state: Theme.Color.working, position: 3, count: 20), centredIn: area, animated: false)
        XCTAssertEqual(card.dotCount, 0)
        XCTAssertEqual(card.place, "4 of 20")
        XCTAssertNil(card.layer?.animation(forKey: WorkspaceNameCard.showKey), "not animated when asked not to")
        card.show(.init(name: "small", state: Theme.Color.working, position: 0, count: 3), centredIn: area, animated: false)
        XCTAssertEqual(card.dotCount, 3)
        XCTAssertEqual(card.place, "")
        XCTAssertLessThanOrEqual(card.frame.width, area.width)

        // A very long name stays inside the area.
        let long = String(repeating: "a long workspace name ", count: 20)
        card.show(.init(name: long, state: Theme.Color.idle, position: 0, count: 3), centredIn: area, animated: false)
        XCTAssertLessThanOrEqual(card.frame.width, area.width)
        XCTAssertTrue(area.contains(card.frame))
    }

    private func info(_ statuses: [AgentStatus], reason: AgentAttentionReason? = nil) -> WorkspaceInfo {
        let columns = statuses.enumerated().map { index, status in
            ColumnInfo(
                index: index, processName: "claude", abbreviatedCwd: nil, isFocused: false, isWebView: false,
                webTitle: nil, terminalTitle: nil, agentStatus: status, isEditor: false, editorFileName: nil,
                attentionReason: status == .needsAttention ? reason : nil
            )
        }
        return WorkspaceInfo(
            id: "ws", index: 0, title: "ws", profileID: WorkspaceProfile.defaultID, isInactive: false,
            columnCount: columns.count, focusedColumn: 0, gitBranch: nil, notification: nil, isActive: false,
            columns: columns, prInfo: nil, diffStats: nil, purpose: nil, nextStep: nil, blocker: nil, phase: .active,
            lastSummary: nil, lastActivityAt: nil
        )
    }

    /// The card's dot: amber only for a wait on the user, red when
    /// something broke, green while an agent works, else grey.
    func testTheCardsDotSaysTheWorkspacesState() {
        XCTAssertEqual(NiruxShellView.cardStateColor(info([.idle])), Theme.Color.idle)
        XCTAssertEqual(NiruxShellView.cardStateColor(info([.idle, .working])), Theme.Color.working)
        XCTAssertEqual(
            NiruxShellView.cardStateColor(info([.working, .needsAttention], reason: .permission(tool: "Bash", summary: "x"))),
            Theme.Color.waiting
        )
        XCTAssertEqual(
            NiruxShellView.cardStateColor(info([.needsAttention], reason: .apiError(kind: nil, detail: "overloaded"))),
            Theme.Color.error
        )
        XCTAssertEqual(NiruxShellView.cardStateColor(info([.needsAttention], reason: .turnFinished)), Theme.Color.idle)
    }
}
