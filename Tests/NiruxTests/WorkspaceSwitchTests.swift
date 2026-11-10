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

    /// The strip slides so that the workspace that was on screen starts
    /// where it was seen; a workspace that stays on screen while the list
    /// changes around it doesn't slide.
    func testASlideStartsWhereTheWorkspaceOnScreenWas() {
        // A workspace that left the list: from the strip's old place.
        XCTAssertEqual(
            NiruxShellView.workspaceSlideStart(oldY: -800, targetY: 0, shownOffset: 0, leavingWas: nil, leavingIs: nil), -800
        )
        // The one on screen sat 800 up the strip; it still does, the strip
        // one row lower: it starts a row lower than its new place.
        XCTAssertEqual(
            NiruxShellView.workspaceSlideStart(oldY: -800, targetY: 0, shownOffset: 0, leavingWas: 800, leavingIs: 800), -800
        )
        // It stays on screen, the list shrinking above it: no slide.
        XCTAssertEqual(
            NiruxShellView.workspaceSlideStart(oldY: -800, targetY: 0, shownOffset: 0, leavingWas: 800, leavingIs: 0), 0
        )
    }

    /// The list changing around the workspace on screen (a row under it
    /// moved to another space, which moves the strip) slides nothing: the
    /// workspace stays where it is seen. A switch into another space shows
    /// at once too.
    func testNoSlideWhenTheWorkspaceOnScreenStays() throws {
        try withShell { shell, _, _ in
            let first = try XCTUnwrap(shell.activeWorkspace)
            let elsewhere = shell.workspaceStore.createProfile(named: "elsewhere", select: false)
            let oldY = shell.verticalStrip.frame.origin.y
            shell.moveWorkspaceToSpace(workspaceID: shell.workspaces[2].id, profileID: elsewhere.id)
            XCTAssertTrue(shell.activeWorkspace === first)
            XCTAssertNotEqual(shell.verticalStrip.frame.origin.y, oldY, "the strip did change")
            XCTAssertNil(self.slide(of: shell), "the workspace on screen stays put")

            // Into the other space: at once.
            let away = try XCTUnwrap(shell.workspaces.firstIndex { $0.profileID == elsewhere.id })
            shell.switchToWorkspace(away)
            XCTAssertEqual(shell.activeProfileID, elsewhere.id)
            XCTAssertNil(self.slide(of: shell))
        }
    }

    /// ⌘↓: the strip slides to the next workspace, the one it leaves stays
    /// drawn until the slide ends, then only the workspace on screen draws.
    /// Presses during a slide take it on from where it is, one slide at a
    /// time.
    func testTheStripSlidesAndKeepsTheWorkspaceItLeavesDrawn() throws {
        try withShell { shell, clock, _ in
            // What the terminals are told, column by column.
            var drawing: [ObjectIdentifier: Bool] = [:]
            shell.sideEffects.setSurfaceVisible = { column, visible in drawing[ObjectIdentifier(column)] = visible }
            let draws = { (workspace: WorkspaceState) in
                workspace.columns.allSatisfy { drawing[ObjectIdentifier($0)] == true }
            }
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
            XCTAssertTrue(draws(first), "its terminals are told to go on drawing")
            XCTAssertTrue(draws(second))

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
            XCTAssertFalse(draws(first), "and told to rest")
            XCTAssertFalse(draws(second))
            XCTAssertTrue(draws(third))
        }
    }

    /// A held key passes many workspaces: only those the slide still shows
    /// on its way stay drawn, and each slide taken on mid-way keeps going
    /// instead of starting again from rest.
    func testAHeldKeyKeepsOnlyWhatTheSlideShowsDrawn() throws {
        try withShell { shell, clock, folder in
            shell.addWorkspace(title: "fourth", cwd: folder)
            shell.switchToWorkspace(0)
            clock.advance(by: 5)
            let all = shell.workspaces
            shell.focusWorkspace(.down)
            let first = try XCTUnwrap(self.slide(of: shell)?.timingFunction)
            shell.focusWorkspace(.down)
            // The strip lags a row behind where it was headed when the
            // third press comes: the slide shows two rows on its way.
            shell.workspaceSwitch.shownStripOffset = { _ in -shell.viewport.bounds.height }
            shell.focusWorkspace(.down)
            XCTAssertEqual(shell.activeWSIndex, 3)
            XCTAssertEqual(shell.workspaceSwitch.keepsDrawn, [all[1].id, all[2].id])
            XCTAssertFalse(shell.drawsTerminals(of: all[0], isActive: false), "out of the way")
            var start = [Float](repeating: 0, count: 2)
            first.getControlPoint(at: 1, values: &start)
            XCTAssertGreaterThan(start[0], 0, "from rest the first time")
            try XCTUnwrap(self.slide(of: shell)?.timingFunction).getControlPoint(at: 1, values: &start)
            XCTAssertEqual(start[0], 0, "taken on: at speed")
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

            clock.advance(by: NiruxShellView.workspaceSlideDuration + NiruxShellView.workspaceCardHold - 0.05)
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
            clock.advance(by: NiruxShellView.workspaceSlideDuration + 0.01)
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
            clock.advance(by: NiruxShellView.workspaceSlideDuration + 0.01)
            shell.workspaceCardSawKey(try key(125, .command))
            XCTAssertTrue(card.isShown, "⌘↓")
            shell.workspaceCardSawKey(try key(126, .control))
            XCTAssertTrue(card.isShown, "⌃↑")
            shell.workspaceCardSawKey(try key(7, []))
            XCTAssertFalse(card.isShown, "typing")
        }
    }

    /// A relayout that isn't animated (a task started in the background)
    /// doesn't cut a slide that plays.
    func testABackgroundTaskDoesntCutTheSlide() throws {
        try withShell { shell, _, folder in
            shell.focusWorkspace(.down)
            XCTAssertNotNil(self.slide(of: shell))
            // Mid-way: the strip shows 300 short of its place.
            shell.workspaceSwitch.shownStripOffset = { _ in -300 }
            let oldY = shell.verticalStrip.frame.origin.y
            shell.addWorkspace(title: "background", cwd: folder, activate: false)
            XCTAssertNotEqual(shell.verticalStrip.frame.origin.y, oldY, "the strip moved")
            let slide = try XCTUnwrap(self.slide(of: shell), "the slide goes on")
            XCTAssertEqual((slide.fromValue as? NSNumber)?.doubleValue ?? 0, -300, accuracy: 0.5, "from where it is")
            XCTAssertTrue(shell.workspaceSwitch.isSliding)
        }
    }

    /// A strip of another space never slides in from this one's place.
    func testAnotherSpacesStripDoesntSlideIn() throws {
        try withShell { shell, _, folder in
            let elsewhere = shell.workspaceStore.createProfile(named: "elsewhere", select: false)
            shell.addWorkspace(title: "there", cwd: folder, profileID: elsewhere.id, activate: false)
            let there = try XCTUnwrap(shell.workspaces.firstIndex { $0.title == "there" })
            shell.verticalStrip.layer?.removeAllAnimations()
            XCTAssertTrue(shell.workspaceStore.selectWorkspace(at: there))
            shell.relayout(animated: true)
            XCTAssertEqual(shell.activeProfileID, elsewhere.id)
            XCTAssertNil(self.slide(of: shell))
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
            clock.advance(by: NiruxShellView.workspaceSlideDuration + NiruxShellView.workspaceCardHold)
            XCTAssertFalse(card.isShown)

            // At the last workspace, ⌘↓ goes nowhere: no card.
            shell.focusWorkspace(.down)
            XCTAssertFalse(card.isShown)
        }
    }

    /// Only ⌘↑ ⌘↓ show the card. A jump to a workspace the user named
    /// (its row, the palette) or that comes to them (a notification, an
    /// agent) slides without it: it lands where they look.
    func testOnlyMovingUpOrDownShowsTheCard() throws {
        try withShell { shell, _, _ in
            let card = shell.workspaceNameCard
            shell.sidebar.onWorkspaceClicked?(1)
            XCTAssertEqual(shell.activeWSIndex, 1)
            XCTAssertNotNil(self.slide(of: shell), "it slides")
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
            .init(workspaceID: "a", name: "big", state: Theme.Color.working, position: 3, count: 30), centredIn: area,
            animated: false
        )
        XCTAssertEqual(card.dotCount, 0)
        XCTAssertEqual(card.place, "4 of 30")
        XCTAssertNil(card.layer?.animation(forKey: WorkspaceNameCard.showKey), "not animated when asked not to")
        card.show(
            .init(workspaceID: "b", name: "small", state: Theme.Color.working, position: 0, count: 14), centredIn: area,
            animated: false
        )
        XCTAssertEqual(card.dotCount, 14, "a space of fourteen still shows its dots")
        XCTAssertEqual(card.place, "")
        XCTAssertLessThanOrEqual(card.frame.width, area.width)
        XCTAssertGreaterThanOrEqual(card.frame.width, WorkspaceNameCard.minWidth)

        // As wide as the space's longest name, whichever it names.
        let longest = "feat/a-branch-name-as-long-as-they-come"
        card.show(
            .init(workspaceID: "c", name: longest, state: Theme.Color.idle, position: 1, count: 14, widestName: longest),
            centredIn: area, animated: false
        )
        let width = card.frame.width
        card.show(
            .init(workspaceID: "c", name: "x", state: Theme.Color.idle, position: 1, count: 14, widestName: longest),
            centredIn: area, animated: false
        )
        XCTAssertEqual(card.frame.width, width, "a short name doesn't make it jump")

        // Twenty dots don't fit a narrow viewport: the place in words.
        card.show(
            .init(workspaceID: "e", name: "x", state: Theme.Color.idle, position: 4, count: 20),
            centredIn: NSRect(x: 0, y: 0, width: 200, height: 300), animated: false
        )
        XCTAssertEqual(card.dotCount, 0)
        XCTAssertEqual(card.place, "5 of 20")

        // A very long name stays inside the area.
        let long = String(repeating: "a long workspace name ", count: 20)
        card.show(.init(workspaceID: "d", name: long, state: Theme.Color.idle, position: 0, count: 3), centredIn: area, animated: false)
        XCTAssertLessThanOrEqual(card.frame.width, area.width)
        XCTAssertTrue(area.contains(card.frame))
    }

    private func info(_ statuses: [AgentStatus], reason: AgentAttentionReason? = nil, ci: String? = nil) -> WorkspaceInfo {
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
            columns: columns,
            prInfo: ci.map {
                PRInfo(
                    number: 7, state: "OPEN", isDraft: false, ciStatus: $0, checks: [], reviewDecision: nil, mergeable: nil,
                    url: "https://example.test/pull/7", additions: nil, deletions: nil, changedFiles: nil
                )
            },
            diffStats: nil, purpose: nil, nextStep: nil, blocker: nil, phase: .active, lastSummary: nil, lastActivityAt: nil
        )
    }

    /// The card's dot says what the workspace's row says: amber only for a
    /// wait on the user, red when something broke, green while an agent
    /// works, else grey.
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
        XCTAssertEqual(NiruxShellView.cardStateColor(info([.idle], ci: "FAILURE")), Theme.Color.error, "as its row says")
        XCTAssertEqual(NiruxShellView.cardStateColor(info([.idle], ci: "SUCCESS")), Theme.Color.success, "ready to merge")
    }
}
