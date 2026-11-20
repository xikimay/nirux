import AppKit
import XCTest
@testable import Nirux

/// Depth study P4: ⌥⌘← ⌥⌘→ pass through depth, on frozen pictures.
@MainActor
final class SpaceCrossingTests: XCTestCase {
    /// The space left recedes as it fades at once; the one chosen, once its
    /// terminals drew, comes from the front and lands over it, frozen as it
    /// is laid out now (not as the screen last showed it). Every live view
    /// hides under them until the crossing ends, on time.
    func testTheSpaceLeftRecedesAndTheOneChosenComesFromTheFront() throws {
        try withSpaces { shell, _, second in
            let steps = TimedSteps(on: shell)
            var drawing: [ObjectIdentifier: Bool] = [:]
            let real = shell.sideEffects.setSurfaceVisible
            shell.sideEffects.setSurfaceVisible = { column, visible in
                drawing[ObjectIdentifier(column)] = visible
                real(column, visible)
            }
            let chosen = try XCTUnwrap(shell.workspaces.first { $0.profileID == second })
            let restingSize = try XCTUnwrap(chosen.columns.first).view.frame.size
            // Narrower while it rests in its space: laid out again as it comes.
            for column in chosen.columns { column.widthFraction = 1.0 / 3 }

            shell.focusSpace(.next)
            XCTAssertEqual(shell.activeProfileID, second)
            XCTAssertEqual(Self.frozenViews(in: shell).count, 1, "the space left, at once")
            XCTAssertEqual(shell.verticalStrip.alphaValue, 0, "the live views hidden")
            XCTAssertEqual(shell.emptySpaceView.alphaValue, 0, "all of them")
            XCTAssertTrue(chosen.columns.allSatisfy { drawing[ObjectIdentifier($0)] == true }, "the space chosen draws before it's frozen")
            XCTAssertEqual(steps.durations, [NiruxShellView.arrivalDelay, NiruxShellView.crossingDuration])
            steps.runNext()

            let pictures = Self.frozenViews(in: shell)
            XCTAssertEqual(pictures.count, 2)
            let leaving = try XCTUnwrap(pictures.first?.content), arriving = try XCTUnwrap(pictures.last?.content)
            XCTAssertEqual(leaving.opacity, 0, "the space left fades")
            XCTAssertEqual(Self.scale(leaving.transform), NiruxShellView.recedeScale, accuracy: 0.001, "and recedes")
            XCTAssertEqual(arriving.opacity, 1)
            XCTAssertEqual(Self.scale(arriving.transform), 1, accuracy: 0.001, "the one chosen lands")
            let comes = try XCTUnwrap((arriving.animation(forKey: "crossing") as? CAAnimationGroup)?.animations)
            let from = try XCTUnwrap(comes.compactMap { ($0 as? CABasicAnimation)?.fromValue as? NSValue }.first)
            XCTAssertEqual(Self.scale(from.caTransform3DValue), NiruxShellView.arrivalFromScale, accuracy: 0.001, "from the front")
            let sizes = Self.sizes(in: arriving)
            XCTAssertTrue(chosen.columns.allSatisfy { sizes.contains($0.view.frame.size) }, "the space chosen, as laid out now")
            XCTAssertFalse(sizes.contains(restingSize), "not as the screen last showed it")

            steps.runNext()
            XCTAssertTrue(Self.frozenViews(in: shell).isEmpty)
            XCTAssertEqual(shell.verticalStrip.alphaValue, 1)
            XCTAssertEqual(shell.emptySpaceView.alphaValue, 1)
        }
    }

    /// A second ⌥⌘→ while one plays, once the screen showed it, freezes the
    /// space it leaves, not an empty viewport.
    func testASecondSwitchFreezesTheSpaceItLeaves() throws {
        try withSpaces { shell, _, second in
            let steps = TimedSteps(on: shell)
            let chosen = try XCTUnwrap(shell.workspaces.first { $0.profileID == second })
            shell.focusSpace(.next)
            steps.runNext()
            CATransaction.flush()
            shell.focusSpace(.next)
            let leaving = try XCTUnwrap(Self.frozenViews(in: shell).first?.content)
            let sizes = Self.sizes(in: leaving)
            XCTAssertTrue(chosen.columns.allSatisfy { sizes.contains($0.view.frame.size) }, "the space it leaves")
        }
    }

    /// With Reduce motion, or a pick from the menu, the space shows at once;
    /// movement turning off lands a crossing on its way at once.
    func testNothingCrossesWhileNothingMayMove() throws {
        try withSpaces { shell, _, second in
            shell.focusSpace(.next)
            XCTAssertEqual(Self.frozenViews(in: shell).count, 1)
            shell.sideEffects.reducesMotion = { true }
            shell.applyAgentLights()
            XCTAssertTrue(Self.frozenViews(in: shell).isEmpty, "landed at once")
            XCTAssertEqual(shell.verticalStrip.alphaValue, 1)

            shell.focusSpace(.next)
            XCTAssertTrue(Self.frozenViews(in: shell).isEmpty)
            XCTAssertEqual(shell.verticalStrip.alphaValue, 1)
            shell.crossSpaces(leaving: try XCTUnwrap(FrozenView.freeze(shell.viewport)))
            XCTAssertTrue(Self.frozenViews(in: shell).isEmpty, "the crossing itself checks")

            shell.sideEffects.reducesMotion = { false }
            XCTAssertNotEqual(shell.activeProfileID, second)
            shell.selectProfile(second)
            XCTAssertEqual(shell.activeProfileID, second)
            XCTAssertTrue(Self.frozenViews(in: shell).isEmpty, "a pick from the menu")
        }
    }

    /// A switch while one plays ends it at once, so a held key shows each
    /// space in turn; a crossing's steps act only on their own.
    func testASwitchEndsTheCrossingOnItsWayAndOnlyItsOwnStepsAct() throws {
        try withSpaces { shell, _, _ in
            let steps = TimedSteps(on: shell)
            shell.focusSpace(.next)
            steps.runNext()
            shell.focusSpace(.next)
            XCTAssertEqual(Self.frozenViews(in: shell).count, 1, "the first crossing's pictures gone")

            while steps.runNext() {}
            shell.crossSpaces(leaving: try XCTUnwrap(FrozenView.freeze(shell.viewport)), duration: 0.05)
            shell.crossSpaces(leaving: try XCTUnwrap(FrozenView.freeze(shell.viewport)), duration: 1)
            XCTAssertEqual(steps.durations, [NiruxShellView.arrivalDelay, 0.05, NiruxShellView.arrivalDelay, 1])
            steps.runNext()
            steps.runNext()
            XCTAssertEqual(Self.frozenViews(in: shell).count, 1, "the first's steps left the second alone")
            XCTAssertEqual(shell.verticalStrip.alphaValue, 0)
            steps.runNext()
            XCTAssertEqual(Self.frozenViews(in: shell).count, 2, "its own arrival")
            steps.runNext()
            XCTAssertTrue(Self.frozenViews(in: shell).isEmpty, "its own end ends it")
        }
    }

    /// Showing another workspace (⌘N, a switch) or a user's move ends a
    /// crossing; a layout that changes nothing leaves it.
    func testAnotherWorkspaceOrAMoveEndsACrossing() throws {
        try withSpaces { shell, _, _ in
            let steps = TimedSteps(on: shell)
            shell.focusSpace(.next)
            shell.relayout(animated: false)
            XCTAssertEqual(Self.frozenViews(in: shell).count, 1, "a layout that changes nothing")
            shell.addWorkspace(title: "new", cwd: NSTemporaryDirectory())
            XCTAssertTrue(shell.crossingPictures.isEmpty, "⌘N")
            XCTAssertEqual(shell.verticalStrip.alphaValue, 1)

            while steps.runNext() {}
            XCTAssertTrue(Self.frozenViews(in: shell).isEmpty, "the new workspace's slide gone")
            shell.focusSpace(.next)
            XCTAssertFalse(shell.crossingPictures.isEmpty)
            shell.focusColumn(.right)
            XCTAssertTrue(shell.crossingPictures.isEmpty, "a move")
            XCTAssertEqual(shell.verticalStrip.alphaValue, 1)
        }
    }

    // MARK: - Helpers

    private static func frozenViews(in shell: NiruxShellView) -> [FrozenView] {
        shell.viewport.subviews.compactMap { $0 as? FrozenView }
    }

    private static func scale(_ transform: CATransform3D) -> CGFloat { transform.m11 }

    /// Every layer's size in a picture: a card shows as its column's.
    private static func sizes(in layer: CALayer) -> [CGSize] {
        [layer.bounds.size] + (layer.sublayers ?? []).flatMap { sizes(in: $0) }
    }

    /// Two spaces, the first on screen with one workspace of a column, the
    /// second with one of two half columns; the interface free to move.
    private func withSpaces(_ body: (NiruxShellView, String, String) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("nirux-crossing-\(UUID().uuidString)").path
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
            try? FileManager.default.removeItem(atPath: root)
        }

        _ = NSApplication.shared
        try autoreleasepool {
            let shell = NiruxShellView(frame: NSRect(x: 0, y: 0, width: 1200, height: 800))
            shell.stopHeartbeat()
            shell.sideEffects.windowShows = { _ in true }
            shell.sideEffects.reducesMotion = { false }
            shell.agentLights.isDisplayAsleep = false
            shell.animatesInterface = true
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800),
                styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false
            )
            window.isReleasedWhenClosed = false
            window.contentView = shell
            window.orderFront(nil)
            defer { window.close() }
            let setup = TimedSteps(on: shell)
            let first = shell.activeProfileID
            let second = shell.workspaceStore.createProfile(named: "Second", select: true).id
            shell.addWorkspace(title: "second", cwd: NSTemporaryDirectory())
            let workspace = try XCTUnwrap(shell.activeWorkspace)
            workspace.addColumn()
            for column in workspace.columns { column.widthFraction = 0.5 }
            shell.relayout(animated: false)
            shell.selectProfile(first)
            while setup.runNext() {}
            XCTAssertTrue(Self.frozenViews(in: shell).isEmpty, "the new workspace's slide gone")
            // AppKit hangs the columns' layers in a later pass; a picture holds
            // only what hangs in its workspace's tree.
            waitUntil("every column's layer in its workspace's tree", timeout: 5) {
                shell.workspaces.allSatisfy { workspace in
                    workspace.columns.allSatisfy { column in
                        sequence(first: column.view.layer, next: { $0?.superlayer }).contains { $0 === workspace.containerView.layer }
                    }
                }
            }
            try body(shell, first, second)
        }
    }
}
