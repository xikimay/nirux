import AppKit
import XCTest
@testable import Nirux

/// A workspace switch: the workspace chosen comes on screen as a floor,
/// the one it leaves stays drawn until it has left, and a card names the
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
            shell.sideEffects.afterCommit = clock.schedule
            // Never a real event monitor in a test.
            shell.sideEffects.watchUserInput = { _ in nil }
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800),
                styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false
            )
            window.isReleasedWhenClosed = false
            window.contentView = shell
            defer { window.close() }
            // Three workspaces in the space; the first one on screen.
            for title in ["second", "third"] { shell.addWorkspace(title: title, cwd: folder) }
            shell.switchToWorkspace(0)
            shell.endWorkspaceSwitch()
            shell.workspaceNameCard.hide(animated: false)
            clock.advance(by: 5)
            try body(shell, clock, folder)
        }
    }

    private func floor(of workspace: WorkspaceState) -> CABasicAnimation? {
        workspace.containerView.layer?.animation(forKey: NiruxShellView.floorsKey) as? CABasicAnimation
    }

    private func shade(of workspace: WorkspaceState) -> CALayer? {
        workspace.containerView.layer?.sublayers?.first { $0.name == NiruxShellView.floorsShadeName }
    }

    private func value(_ any: Any?) -> Double {
        (any as? NSNumber)?.doubleValue ?? .nan
    }

    // MARK: - The floors

    /// The list changing around the workspace on screen (a row under it
    /// moved to another space, which moves the strip) moves nothing: the
    /// workspace stays where it is seen. A switch into another space shows
    /// at once too.
    func testNothingMovesWhenTheWorkspaceOnScreenStays() throws {
        try withShell { shell, _, _ in
            let first = try XCTUnwrap(shell.activeWorkspace)
            let elsewhere = shell.workspaceStore.createProfile(named: "elsewhere", select: false)
            let oldY = shell.verticalStrip.frame.origin.y
            shell.moveWorkspaceToSpace(workspaceID: shell.workspaces[2].id, profileID: elsewhere.id)
            XCTAssertTrue(shell.activeWorkspace === first)
            XCTAssertNotEqual(shell.verticalStrip.frame.origin.y, oldY, "the strip did change")
            XCTAssertTrue(shell.workspaces.allSatisfy { self.floor(of: $0) == nil }, "the workspace on screen stays put")

            // Into the other space: at once.
            let away = try XCTUnwrap(shell.workspaces.firstIndex { $0.profileID == elsewhere.id })
            shell.switchToWorkspace(away)
            XCTAssertEqual(shell.activeProfileID, elsewhere.id)
            XCTAssertTrue(shell.workspaces.allSatisfy { self.floor(of: $0) == nil })
            XCTAssertFalse(shell.workspaceSwitch.isSwitching)
        }
    }

    /// ⌘↓: the next workspace rises from below, on a plate, over the one on
    /// screen, which lies under it, steps back and darkens under a shade;
    /// it stays drawn until the end. A press while it plays ends it at
    /// once. Over, everything is back in the strip, and only the workspace
    /// on screen draws.
    func testTheNextWorkspaceComesOverTheOneOnScreen() throws {
        try withShell { shell, clock, _ in
            // What the terminals are told, column by column.
            var drawing: [ObjectIdentifier: Bool] = [:]
            var turnedOff: [ObjectIdentifier] = []
            shell.sideEffects.setSurfaceVisible = { column, visible in
                drawing[ObjectIdentifier(column)] = visible
                if !visible { turnedOff.append(ObjectIdentifier(column)) }
            }
            let draws = { (workspace: WorkspaceState) in
                workspace.columns.allSatisfy { drawing[ObjectIdentifier($0)] == true }
            }
            let height = Double(shell.viewport.bounds.height)
            let first = try XCTUnwrap(shell.activeWorkspace)
            shell.focusWorkspace(.down)
            let second = try XCTUnwrap(shell.activeWorkspace)
            XCTAssertFalse(first === second)

            let rise = try XCTUnwrap(self.floor(of: second))
            XCTAssertEqual(self.value(rise.fromValue), -height, "from below the viewport")
            XCTAssertEqual(self.value(rise.toValue), 0)
            XCTAssertEqual(rise.duration, NiruxShellView.workspaceSwitchDuration)
            XCTAssertEqual(second.containerView.layer?.zPosition, 1, "on top")
            XCTAssertNotNil(second.containerView.layer?.backgroundColor, "on its plate")

            let under = second.containerView.frame.minY - first.containerView.frame.minY
            XCTAssertEqual(first.containerView.layer?.affineTransform().ty, under, "where the second is, under it")
            XCTAssertEqual(self.value(try XCTUnwrap(self.floor(of: first)).toValue), height * Double(NiruxShellView.floorsRecede), accuracy: 0.01)
            let shade = try XCTUnwrap(self.shade(of: first)?.animation(forKey: NiruxShellView.floorsKey) as? CABasicAnimation)
            XCTAssertEqual(self.value(shade.toValue), Double(NiruxShellView.floorsShade), accuracy: 0.001)
            XCTAssertTrue(shell.drawsTerminals(of: first, isActive: false), "the workspace it leaves, while it leaves")
            XCTAssertTrue(draws(first), "its terminals are told to go on drawing")
            XCTAssertTrue(draws(second))

            // Half-way, another press: the first floors end at once, and the
            // second workspace, drawn all along, never goes off between.
            clock.advance(by: NiruxShellView.workspaceSwitchDuration / 2)
            turnedOff = []
            shell.focusWorkspace(.down)
            let third = try XCTUnwrap(shell.activeWorkspace)
            XCTAssertFalse(second.columns.contains { turnedOff.contains(ObjectIdentifier($0)) }, "no surface off and on again")
            XCTAssertNil(self.floor(of: first))
            XCTAssertNil(self.shade(of: first))
            XCTAssertEqual(first.containerView.layer?.affineTransform(), .identity)
            XCTAssertNotNil(self.floor(of: third))
            XCTAssertFalse(shell.drawsTerminals(of: first, isActive: false))
            XCTAssertTrue(shell.drawsTerminals(of: second, isActive: false))

            // The first switch's end doesn't cut the second one short.
            clock.advance(by: NiruxShellView.workspaceSwitchDuration / 2 + 0.01)
            XCTAssertTrue(shell.workspaceSwitch.isSwitching)
            clock.advance(by: NiruxShellView.workspaceSwitchDuration)
            XCTAssertFalse(shell.workspaceSwitch.isSwitching)
            for workspace in [second, third] {
                XCTAssertNil(self.floor(of: workspace))
                XCTAssertEqual(workspace.containerView.layer?.affineTransform(), .identity)
                XCTAssertEqual(workspace.containerView.layer?.zPosition, 0)
                XCTAssertNil(workspace.containerView.layer?.backgroundColor, "off its plate")
            }
            XCTAssertNil(self.shade(of: second))
            XCTAssertFalse(shell.drawsTerminals(of: second, isActive: false), "settled: only the one on screen")
            XCTAssertFalse(draws(first), "and told to rest")
            XCTAssertFalse(draws(second))
            XCTAssertTrue(draws(third))
        }
    }

    /// Floors end at once when the workspace they bring left the list, or
    /// the one beneath was hidden (moved to another space): no floor stays
    /// out of place until their time is up.
    func testFloorsEndWhenAWorkspaceTheyHoldGoes() throws {
        try withShell { shell, _, _ in
            let elsewhere = shell.workspaceStore.createProfile(named: "elsewhere", select: false)
            let all = shell.workspaces
            let atRest = { (workspace: WorkspaceState) -> Bool in
                let layer = workspace.containerView.layer
                return self.floor(of: workspace) == nil && self.shade(of: workspace) == nil && layer?.affineTransform() == .identity
                    && layer?.zPosition == 0 && layer?.backgroundColor == nil
            }
            // The one they bring leaves the list with no switch between, as a
            // close ends (`closeWorkspace`): the first one selected again.
            shell.focusWorkspace(.down)
            XCTAssertNotNil(self.floor(of: all[1]))
            shell.workspaceStore.selectWorkspace(at: 0)
            _ = shell.workspaceStore.removeWorkspace(all[1])
            all[1].containerView.removeFromSuperview()
            shell.relayout(animated: false)
            XCTAssertTrue(shell.activeWorkspace === all[0])
            XCTAssertFalse(shell.workspaceSwitch.isSwitching, "the workspace they bring went")
            XCTAssertTrue(atRest(all[0]))

            shell.focusWorkspace(.down)
            XCTAssertTrue(shell.activeWorkspace === all[2])
            XCTAssertNotNil(self.floor(of: all[2]))
            shell.moveWorkspaceToSpace(workspaceID: all[0].id, profileID: elsewhere.id)
            XCTAssertTrue(shell.activeWorkspace === all[2])
            XCTAssertFalse(shell.workspaceSwitch.isSwitching, "the one beneath was hidden")
            XCTAssertTrue(atRest(all[0]))
            XCTAssertTrue(atRest(all[2]))
        }
    }

    /// ⌘↑: the workspace on screen leaves downwards, on top, and uncovers
    /// the one above, which comes forward out of its shade.
    func testGoingUpTheOneOnScreenLeavesAndUncoversTheOneAbove() throws {
        try withShell { shell, clock, _ in
            let height = Double(shell.viewport.bounds.height)
            shell.switchToWorkspace(1)
            clock.advance(by: 5)
            let second = try XCTUnwrap(shell.activeWorkspace)
            shell.focusWorkspace(.up)
            let first = try XCTUnwrap(shell.activeWorkspace)
            XCTAssertFalse(first === second)

            XCTAssertEqual(second.containerView.layer?.zPosition, 1, "the one leaving, on top")
            XCTAssertEqual(self.value(try XCTUnwrap(self.floor(of: second)).toValue), -height, "down and away")
            let forward = try XCTUnwrap(self.floor(of: first))
            XCTAssertEqual(self.value(forward.fromValue), height * Double(NiruxShellView.floorsRecede), accuracy: 0.01)
            XCTAssertEqual(self.value(forward.toValue), 0)
            let shade = try XCTUnwrap(self.shade(of: first)?.animation(forKey: NiruxShellView.floorsKey) as? CABasicAnimation)
            XCTAssertEqual(self.value(shade.fromValue), Double(NiruxShellView.floorsShade), accuracy: 0.001)
            XCTAssertEqual(self.value(shade.toValue), 0)
        }
    }

    /// A held key passes many workspaces: each press ends the floors before
    /// it, so only the workspace it just left stays drawn.
    func testAHeldKeyKeepsOnlyTheLastWorkspaceLeftDrawn() throws {
        try withShell { shell, clock, folder in
            shell.addWorkspace(title: "fourth", cwd: folder)
            shell.switchToWorkspace(0)
            clock.advance(by: 5)
            let all = shell.workspaces
            for _ in 0..<3 { shell.focusWorkspace(.down) }
            XCTAssertEqual(shell.activeWSIndex, 3)
            XCTAssertEqual(shell.workspaceSwitch.keepsDrawn, [all[2].id])
            XCTAssertEqual(all.filter { self.floor(of: $0) != nil }.map(\.id), [all[2].id, all[3].id])
        }
    }

    /// With Reduce motion (or animations off) the workspace shows at once:
    /// no floors, nothing kept drawn, no card.
    func testNothingMovesWhileTheInterfaceMayNot() throws {
        try withShell(reducesMotion: true) { shell, _, _ in
            let first = try XCTUnwrap(shell.activeWorkspace)
            shell.focusWorkspace(.down)
            XCTAssertFalse(shell.activeWorkspace === first, "it switched")
            XCTAssertTrue(shell.workspaces.allSatisfy { self.floor(of: $0) == nil })
            XCTAssertFalse(shell.drawsTerminals(of: first, isActive: false))
            XCTAssertFalse(shell.workspaceNameCard.isShown)
        }
    }

    /// A relayout for something else (a resize, the status bar) doesn't
    /// cut the floors short.
    func testARelayoutThatMovesNothingLetsTheFloorsPlay() throws {
        try withShell { shell, _, _ in
            shell.focusWorkspace(.down)
            let second = try XCTUnwrap(shell.activeWorkspace)
            let rise = try XCTUnwrap(self.floor(of: second))
            shell.relayout(animated: false)
            XCTAssertTrue(self.floor(of: second) === rise)
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
            let show = try XCTUnwrap(card.layer?.animation(forKey: WorkspaceNameCard.showKey) as? CAAnimationGroup)
            let settle = try XCTUnwrap(show.animations?.compactMap { $0 as? CASpringAnimation }.first)
            let small = try XCTUnwrap((settle.fromValue as? NSValue)?.caTransform3DValue)
            XCTAssertEqual(small.m11, 0.94, accuracy: 0.001)
            XCTAssertEqual(small.m41, card.bounds.midX * 0.06, accuracy: 0.5, "about its centre, not its corner")
            XCTAssertEqual(card.name, "second")
            XCTAssertEqual(card.dotCount, 3)
            XCTAssertEqual(card.litDot, 1)
            XCTAssertEqual(card.frame.midX, shell.viewport.frame.midX, accuracy: 1)
            XCTAssertEqual(card.frame.midY, shell.viewport.frame.midY, accuracy: 1)
            XCTAssertNil(card.hitTest(NSPoint(x: card.frame.midX, y: card.frame.midY)))
            XCTAssertFalse(card.acceptsFirstResponder)

            clock.advance(by: NiruxShellView.workspaceSwitchDuration + NiruxShellView.workspaceCardHold - 0.05)
            XCTAssertTrue(card.isShown, "the slide, then a moment")
            clock.advance(by: 0.1)
            XCTAssertFalse(card.isShown)
            XCTAssertEqual(card.alphaValue, 0, "gone even if its fade never runs")
        }
    }

    /// Once the view has stopped, the user's first key, click or scroll
    /// takes the card away: they read or work there. During the slide
    /// (another ⌘↓) it stays. The watch on input lasts only as long as
    /// the card.
    func testTheCardLeavesAtTheFirstInputOnceTheViewStopped() throws {
        try withShell { shell, clock, _ in
            let card = shell.workspaceNameCard
            var input: (@MainActor () -> Void)?
            var watching = 0
            var installs = 0
            shell.sideEffects.watchUserInput = { seen in
                input = seen
                watching += 1
                installs += 1
                return NSObject()
            }
            shell.sideEffects.stopWatchingUserInput = { _ in watching -= 1 }
            shell.focusWorkspace(.down)
            XCTAssertEqual(watching, 1)
            let seen = try XCTUnwrap(input)
            seen()
            XCTAssertTrue(card.isShown, "the view still moves")
            shell.focusWorkspace(.down)
            XCTAssertEqual(installs, 1, "one card, kept: its words changed, it didn't come in again")
            XCTAssertEqual(watching, 1)
            clock.advance(by: NiruxShellView.workspaceSwitchDuration + 0.01)
            XCTAssertTrue(card.isShown)
            seen()
            XCTAssertFalse(card.isShown, "at the first input once it stopped")
            XCTAssertEqual(watching, 0, "no more watching")
            clock.advance(by: 5)
            XCTAssertEqual(watching, 0)
        }
    }

    /// Keys come through the app's interceptor, before a terminal takes
    /// them: one typed once the view stopped takes the card away, a
    /// workspace step (⌘↓) changes its words instead.
    func testATypedKeyTakesTheCardAwayButAStepDoesnt() throws {
        try withShell { shell, clock, _ in
            let card = shell.workspaceNameCard
            let key = { (code: UInt16, flags: NSEvent.ModifierFlags) in
                try XCTUnwrap(NSEvent.keyEvent(
                    with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0, context: nil,
                    characters: "x", charactersIgnoringModifiers: "x", isARepeat: false, keyCode: code
                ))
            }
            shell.focusWorkspace(.down)
            clock.advance(by: NiruxShellView.workspaceSwitchDuration + 0.01)
            shell.workspaceCardSawKey(try key(125, .command))
            XCTAssertTrue(card.isShown, "⌘↓")
            shell.workspaceCardSawKey(try key(126, .control))
            XCTAssertTrue(card.isShown, "⌃↑")
            shell.workspaceCardSawKey(try key(7, []))
            XCTAssertFalse(card.isShown, "typing")
        }
    }

    /// A relayout that isn't animated (a task started in the background)
    /// doesn't cut the floors short, and the floor beneath stays under the
    /// one chosen when the strip moves meanwhile.
    func testABackgroundTaskDoesntCutTheFloors() throws {
        try withShell { shell, _, folder in
            let first = try XCTUnwrap(shell.activeWorkspace)
            shell.focusWorkspace(.down)
            let second = try XCTUnwrap(shell.activeWorkspace)
            let oldY = shell.verticalStrip.frame.origin.y
            shell.addWorkspace(title: "background", cwd: folder, activate: false)
            XCTAssertNotEqual(shell.verticalStrip.frame.origin.y, oldY, "the strip moved")
            XCTAssertNotNil(self.floor(of: second), "the floors go on")
            XCTAssertTrue(shell.workspaceSwitch.isSwitching)
            XCTAssertEqual(
                first.containerView.layer?.affineTransform().ty,
                second.containerView.frame.minY - first.containerView.frame.minY, "still under the second"
            )
        }
    }

    /// A strip of another space never comes in as a floor over this one.
    func testAnotherSpacesWorkspaceShowsAtOnce() throws {
        try withShell { shell, _, folder in
            let elsewhere = shell.workspaceStore.createProfile(named: "elsewhere", select: false)
            shell.addWorkspace(title: "there", cwd: folder, profileID: elsewhere.id, activate: false)
            let there = try XCTUnwrap(shell.workspaces.firstIndex { $0.title == "there" })
            XCTAssertTrue(shell.workspaceStore.selectWorkspace(at: there))
            shell.relayout(animated: true)
            XCTAssertEqual(shell.activeProfileID, elsewhere.id)
            XCTAssertTrue(shell.workspaces.allSatisfy { self.floor(of: $0) == nil })
        }
    }

    /// A card never stays over a workspace it doesn't name: a click on
    /// another row, a space switch or a close takes it away at once.
    func testTheCardGoesWhenAnotherWorkspaceComesOnScreen() throws {
        try withShell { shell, _, _ in
            let card = shell.workspaceNameCard
            shell.focusWorkspace(.down)
            XCTAssertEqual(card.name, "second")
            shell.sidebar.onWorkspaceClicked?(2)
            XCTAssertEqual(shell.activeWSIndex, 2)
            XCTAssertFalse(card.isShown)
            XCTAssertEqual(card.alphaValue, 0)
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
            clock.advance(by: 0.5)
            XCTAssertTrue(card.isShown, "the first press's end doesn't take it away")
            clock.advance(by: NiruxShellView.workspaceSwitchDuration + NiruxShellView.workspaceCardHold)
            XCTAssertFalse(card.isShown)

            // At the last workspace, ⌘↓ goes nowhere: no card.
            shell.focusWorkspace(.down)
            XCTAssertFalse(card.isShown)
        }
    }

    /// Only ⌘↑ ⌘↓ show the card. A jump to a workspace the user named
    /// (its row, the palette) or that comes to them (a notification, an
    /// agent) comes on screen without it: it lands where they look.
    func testOnlyMovingUpOrDownShowsTheCard() throws {
        try withShell { shell, _, _ in
            let card = shell.workspaceNameCard
            shell.sidebar.onWorkspaceClicked?(1)
            XCTAssertEqual(shell.activeWSIndex, 1)
            XCTAssertNotNil(self.floor(of: shell.workspaces[1]), "it comes on screen as a floor")
            XCTAssertFalse(card.isShown)
            shell.switchToWorkspace(2)
            XCTAssertEqual(shell.activeWSIndex, 2)
            XCTAssertFalse(card.isShown)
            shell.focusWorkspace(id: shell.workspaces[0].id)
            XCTAssertEqual(shell.activeWSIndex, 0)
            XCTAssertFalse(card.isShown)
            shell.focusWorkspace(.down)
            XCTAssertTrue(card.isShown)
        }
    }

    /// More workspaces than dots fit: the card says the place in words.
    func testManyWorkspacesAreCountedInWords() {
        let card = WorkspaceNameCard()
        let area = NSRect(x: 0, y: 0, width: 900, height: 600)
        card.show(
            .init(workspaceID: "a", name: "big", state: StateIcon(.working), position: 3, count: 30), centredIn: area,
            animated: false
        )
        XCTAssertEqual(card.dotCount, 0)
        XCTAssertEqual(card.place, "4 of 30")
        XCTAssertNil(card.layer?.animation(forKey: WorkspaceNameCard.showKey), "not animated when asked not to")
        card.show(
            .init(workspaceID: "b", name: "small", state: StateIcon(.working), position: 0, count: 14), centredIn: area,
            animated: false
        )
        XCTAssertEqual(card.dotCount, 14, "a space of fourteen still shows its dots")
        XCTAssertEqual(card.place, "")
        XCTAssertLessThanOrEqual(card.frame.width, area.width)
        XCTAssertGreaterThanOrEqual(card.frame.width, WorkspaceNameCard.minWidth)

        // As wide as the space's longest name, whichever it names.
        let longest = "feat/a-branch-name-as-long-as-they-come"
        card.show(
            .init(workspaceID: "c", name: longest, state: StateIcon(.idle), position: 1, count: 14, widestName: longest),
            centredIn: area, animated: false
        )
        let width = card.frame.width
        card.show(
            .init(workspaceID: "c", name: "x", state: StateIcon(.idle), position: 1, count: 14, widestName: longest),
            centredIn: area, animated: false
        )
        XCTAssertEqual(card.frame.width, width, "a short name doesn't make it jump")

        // Twenty dots don't fit a narrow viewport: the place in words.
        card.show(
            .init(workspaceID: "e", name: "x", state: StateIcon(.idle), position: 4, count: 20),
            centredIn: NSRect(x: 0, y: 0, width: 200, height: 300), animated: false
        )
        XCTAssertEqual(card.dotCount, 0)
        XCTAssertEqual(card.place, "5 of 20")

        // A very long name stays inside the area.
        let long = String(repeating: "a long workspace name ", count: 20)
        card.show(.init(workspaceID: "d", name: long, state: StateIcon(.idle), position: 0, count: 3), centredIn: area, animated: false)
        XCTAssertLessThanOrEqual(card.frame.width, area.width)
        XCTAssertTrue(area.contains(card.frame))
    }

    private func info(_ statuses: [AgentStatus], reason: AgentAttentionReason? = nil, ci: String? = nil, id: String = "ws") -> WorkspaceInfo {
        let columns = statuses.enumerated().map { index, status in
            ColumnInfo(
                index: index, processName: "claude", abbreviatedCwd: nil, isFocused: false, isWebView: false,
                webTitle: nil, terminalTitle: nil, agentStatus: status, isEditor: false, editorFileName: nil,
                attentionReason: status == .needsAttention ? reason : nil
            )
        }
        return WorkspaceInfo(
            id: id, index: 0, title: "ws", profileID: WorkspaceProfile.defaultID, isInactive: false,
            columnCount: columns.count, focusedColumn: 0, gitBranch: nil, notification: nil, isActive: false,
            columns: columns,
            prInfo: ci.map {
                PRInfo(
                    number: 7, state: .open, isDraft: false, ciStatus: $0, checks: [], reviewDecision: nil, mergeable: nil,
                    url: "https://example.test/pull/7", additions: nil, deletions: nil, changedFiles: nil
                )
            },
            diffStats: nil, purpose: nil, nextStep: nil, blocker: nil, phase: .active, lastSummary: nil, lastActivityAt: nil
        )
    }

    /// A switch shows the row's own icon on the card, whatever the row
    /// says: a failed check, checks passed, a turn over, a permission (its
    /// glyph), its station.
    func testASwitchShowsTheRowsIcon() throws {
        try withShell { shell, _, _ in
            let card = shell.workspaceNameCard
            shell.focusWorkspace(.down)
            let workspace = try XCTUnwrap(shell.activeWorkspace)
            let shown = try XCTUnwrap(shell.sidebar.lastInfos.first { $0.id == workspace.id })
            XCTAssertEqual(card.state, shown.stateIcon, "a real switch")
            var permission = info([.working, .needsAttention], reason: .permission(tool: "Bash", summary: "x"), id: workspace.id)
            permission.boardProgress = SidebarBoardProgress(station: .checks)
            let rows: [(WorkspaceInfo, StateIcon)] = [
                (info([.idle], ci: "FAILURE", id: workspace.id), StateIcon(.error)),
                (info([.idle], ci: "SUCCESS", id: workspace.id), StateIcon(.readyToMerge)),
                (info([.needsAttention], reason: .turnFinished, id: workspace.id), info([.needsAttention], reason: .turnFinished).stateIcon),
                (permission, StateIcon(.needsYou(.command), stage: 3))
            ]
            for (row, icon) in rows {
                shell.sidebar.lastInfos = [row]
                shell.announceWorkspaceSwitch()
                XCTAssertEqual(card.state, icon)
                XCTAssertEqual(card.state, row.stateIcon, "the row's own path")
            }
            XCTAssertNotEqual(rows[2].1.color, Theme.Color.waiting, "a turn over waits on nobody")
            // On whole points: a ring between two pixels blurs.
            let icon = try XCTUnwrap(card.subviews.lazy.compactMap { $0 as? StateIconView }.first).frame
            XCTAssertEqual([icon.minX, icon.minY], [icon.minX.rounded(), icon.minY.rounded()])
        }
    }
}
