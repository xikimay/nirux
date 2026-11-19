import AppKit
import XCTest
@testable import Nirux

/// Depth study P6: folded, the rail is an island of glass over the work.
/// While the columns travel they pass under it; at rest nothing does.
@MainActor
final class UnderGlassTests: XCTestCase {
    /// A slide to a card passes the cards under the rail: the viewport
    /// reaches the sidebar's edge, what it holds where it lay, and the
    /// workspace leaves its cards unclipped. Then the work's edge sweeps back, and the cards are
    /// clipped again.
    func testTheColumnsPassUnderTheRailWhileTheyTravel() throws {
        try withShell { shell in
            let workspace = try floatingRail(in: shell)
            let steps = TimedSteps(on: shell)
            let viewport = shell.viewport
            let sidebarAbove = try XCTUnwrap(shell.subviews.firstIndex(of: shell.sidebar))
            XCTAssertGreaterThan(sidebarAbove, try XCTUnwrap(shell.subviews.firstIndex(of: shell.viewport)), "the rail lies over the work")
            XCTAssertEqual(shell.divider.alphaValue, 0, "no line marks a floating rail's edge")
            let viewFrame = shell.viewport.frame
            let stripOrigin = shell.verticalStrip.convert(NSPoint.zero, to: shell)

            shell.focusColumn(.right)
            XCTAssertEqual(viewport.frame, viewFrame, "no travel, nothing under the rail")
            shell.focusColumn(.right)
            XCTAssertNotNil(try strip(of: workspace).layer?.animation(forKey: "colSlide"), "it travels")
            XCTAssertEqual(viewport.frame.minX, shell.sidebar.frame.minX, accuracy: 0.5, "under the sidebar")
            XCTAssertEqual(viewport.frame.maxX, viewFrame.maxX, accuracy: 0.5)
            XCTAssertEqual(shell.verticalStrip.convert(NSPoint.zero, to: shell).x, stripOrigin.x, accuracy: 0.5, "what it holds where it lay")
            XCTAssertFalse(workspace.containerView.clipsToBounds, "the cards unclipped")

            XCTAssertEqual(steps.durations, [WorkspaceState.slideDuration], "it ends with the slide")
            steps.runNext()
            XCTAssertEqual(viewport.bounds.minX, 0, "the edge back at the rail's")
            XCTAssertEqual(viewport.frame, viewFrame)
            XCTAssertNotNil(viewport.layer?.animation(forKey: "underGlass.bounds"), "it sweeps back")
            XCTAssertFalse(workspace.containerView.clipsToBounds, "the cards unclipped while it sweeps")
            XCTAssertEqual(steps.durations, [NiruxShellView.underGlassClose])
            steps.runNext()
            XCTAssertTrue(workspace.containerView.clipsToBounds, "then clipped again")
        }
    }

    /// At Opaque, without macOS's glass, unfolded, or while nothing may
    /// move, a travel leaves the work where it was.
    func testNothingPassesUnderARailThatDoesNotFloat() throws {
        try withShell { shell in
            let workspace = try floatingRail(in: shell)
            let viewport = shell.viewport
            let cases: [(name: String, floats: Bool, change: () -> Void)] = [
                ("at Opaque", false, { shell.interfaceTransparency = .opaque }),
                ("without macOS's glass", false, { shell.sideEffects.drawsGlass = { false } }),
                ("unfolded", false, {
                    shell.isSidebarExpanded = true
                    shell.sidebar.isExpanded = true
                }),
                ("with Reduce motion", true, { shell.sideEffects.reducesMotion = { true } })
            ]
            for test in cases {
                _ = try floatingRail(in: shell)
                test.change()
                shell.relayout(animated: false)
                XCTAssertEqual(shell.railFloats, test.floats, test.name)
                XCTAssertEqual(shell.divider.alphaValue, test.floats ? 0 : 1, "\(test.name): the line")
                shell.focusColumn(.right)
                shell.focusColumn(.right)
                XCTAssertNotNil(try strip(of: workspace).layer?.animation(forKey: "colSlide"), "\(test.name): it travels")
                XCTAssertEqual(viewport.bounds.minX, 0, "\(test.name): nothing under the rail")
                XCTAssertTrue(workspace.containerView.clipsToBounds, test.name)
            }
        }
    }

    /// A pass goes on through a layout while the rail floats, and ends at
    /// once when it no longer does; a pass's end acts only on its own: one
    /// that took its place stays until its own end.
    func testAPassGoesOnThroughALayoutAndOnlyItsOwnEndClosesIt() throws {
        try withShell { shell in
            let workspace = try floatingRail(in: shell)
            let viewport = shell.viewport

            let rest = viewport.frame
            shell.passUnderRail(workspace, for: 1)
            let reached = viewport.frame
            XCTAssertEqual(reached.minX, shell.sidebar.frame.minX, accuracy: 0.5)
            shell.relayout(animated: false)
            XCTAssertEqual(viewport.frame, reached, "a layout keeps it")
            XCTAssertEqual(viewport.bounds.minX, shell.sidebar.frame.minX - rest.minX, accuracy: 0.5, "what it holds where it lay")
            XCTAssertFalse(workspace.containerView.clipsToBounds)

            shell.isSidebarExpanded = true
            shell.sidebar.isExpanded = true
            shell.relayout(animated: false)
            XCTAssertEqual(viewport.bounds.minX, 0, "unfolded, it ends at once")
            XCTAssertGreaterThan(viewport.frame.minX, shell.sidebar.frame.minX)
            XCTAssertTrue(workspace.containerView.clipsToBounds)

            _ = try floatingRail(in: shell)
            let steps = TimedSteps(on: shell)
            shell.passUnderRail(workspace, for: 0.05)
            shell.passUnderRail(workspace, for: 1)
            XCTAssertEqual(steps.durations, [0.05, 1])
            steps.runNext()
            XCTAssertLessThan(viewport.bounds.minX, 0, "the first's end left the second alone")
            XCTAssertFalse(workspace.containerView.clipsToBounds)
            steps.runNext()
            XCTAssertEqual(viewport.bounds.minX, 0, "its own end closes it")
        }
    }

    /// A switch to another workspace's far column, or a fold, moves the
    /// camera too: neither is a travel of the cards on screen, so nothing
    /// passes under the rail (P3's floors play; the sidebar shrinks).
    func testNeitherAWorkspaceSwitchNorAFoldPasses() throws {
        try withShell { shell in
            let first = try floatingRail(in: shell)
            let viewport = shell.viewport
            @MainActor func atRest(_ name: String) {
                XCTAssertEqual(viewport.bounds.minX, 0, "\(name): nothing under the rail")
                XCTAssertTrue(shell.workspaces.allSatisfy { $0.containerView.clipsToBounds }, name)
            }

            shell.addWorkspace(title: "other", cwd: NSTemporaryDirectory())
            let other = try XCTUnwrap(shell.activeWorkspace)
            while other.columns.count < 3 { other.addColumn() }
            for column in other.columns { column.widthFraction = 0.5 }
            other.focusedIndex = 0
            let firstIndex = try XCTUnwrap(shell.workspaces.firstIndex { $0 === first })
            let otherIndex = try XCTUnwrap(shell.workspaces.firstIndex { $0 === other })
            shell.switchToWorkspace(firstIndex)
            let camera = other.lastCameraX
            shell.switchToWorkspace(otherIndex, column: 2)
            XCTAssertNotEqual(other.lastCameraX, camera, "its camera moved")
            atRest("a switch")

            shell.isSidebarExpanded = true
            shell.sidebar.isExpanded = true
            other.focusedIndex = 2
            shell.relayout(animated: false)
            let unfolded = other.lastCameraX
            shell.toggleSidebar()
            XCTAssertFalse(shell.isSidebarExpanded)
            XCTAssertNotEqual(other.lastCameraX, unfolded, "the fold moved the camera")
            atRest("a fold")
        }
    }

    /// A pass ends at once where the rail stops floating (Opaque, an
    /// unfold's fade) or the viewport has no size; the divider follows the
    /// rail, also when the sidebar unfolds after its layout.
    func testAPassEndsWhereTheRailStopsFloatingAndTheDividerFollows() throws {
        try withShell { shell in
            var workspace = try floatingRail(in: shell)
            let viewport = shell.viewport
            @MainActor func ended(_ name: String) {
                XCTAssertEqual(viewport.bounds.minX, 0, "\(name): ended at once")
                XCTAssertTrue(workspace.containerView.clipsToBounds, name)
                XCTAssertNil(shell.passingUnderRail, name)
            }

            shell.passUnderRail(workspace, for: 1)
            shell.interfaceTransparency = .opaque
            ended("at Opaque")
            XCTAssertEqual(shell.divider.alphaValue, 1)

            workspace = try floatingRail(in: shell)
            shell.passUnderRail(workspace, for: 1)
            shell.sidebar.isRailHidden = true
            ended("an unfold's fade")
            XCTAssertEqual(shell.divider.alphaValue, 1, "the line back")

            workspace = try floatingRail(in: shell)
            XCTAssertEqual(shell.divider.alphaValue, 0)
            shell.isSidebarExpanded = true
            shell.sidebar.isExpanded = true
            XCTAssertEqual(shell.divider.alphaValue, 1, "unfolded after its layout, the line is there")

            workspace = try floatingRail(in: shell)
            shell.passUnderRail(workspace, for: 1)
            let size = shell.frame.size
            shell.setFrameSize(NSSize(width: size.width, height: 0))
            shell.relayout(animated: false)
            ended("no viewport")
            shell.setFrameSize(size)
        }
    }

    /// Movement turning off (Reduce motion, the setting) ends a pass at once,
    /// and its sweep too.
    func testMovementTurningOffEndsAPassAtOnce() throws {
        try withShell { shell in
            let workspace = try floatingRail(in: shell)
            let steps = TimedSteps(on: shell)
            shell.passUnderRail(workspace, for: 1)
            shell.sideEffects.reducesMotion = { true }
            shell.applyAgentLights()
            XCTAssertEqual(shell.viewport.bounds.minX, 0, "ended at once")
            XCTAssertTrue(workspace.containerView.clipsToBounds)
            XCTAssertNil(shell.passingUnderRail)

            shell.sideEffects.reducesMotion = { false }
            shell.passUnderRail(workspace, for: 1)
            while steps.durations.first != NiruxShellView.underGlassClose, steps.runNext() {}
            XCTAssertFalse(workspace.containerView.clipsToBounds, "it sweeps")
            shell.animatesInterface = false
            XCTAssertTrue(workspace.containerView.clipsToBounds, "the sweep ends at once")
            XCTAssertNil(shell.viewport.layer?.animation(forKey: "underGlass.bounds"))
        }
    }

    // MARK: - Helpers

    /// Folded, at Tinted, in macOS's glass, the interface free to move; three
    /// half columns, the first focused, so that the third is a travel away.
    private func floatingRail(in shell: NiruxShellView) throws -> WorkspaceState {
        shell.sideEffects.drawsGlass = { true }
        shell.sideEffects.drawnTransparency = { $0 }
        shell.sideEffects.reducesMotion = { false }
        shell.agentLights.isDisplayAsleep = false
        shell.animatesInterface = true
        shell.interfaceTransparency = .tinted
        shell.isSidebarExpanded = false
        shell.sidebar.isExpanded = false
        let workspace = try XCTUnwrap(shell.activeWorkspace)
        while workspace.columns.count < 3 { workspace.addColumn() }
        for column in workspace.columns { column.widthFraction = 0.5 }
        workspace.focusedIndex = 0
        shell.relayout(animated: false)
        let root = try XCTUnwrap(shell.layer)
        waitUntil("the columns' layers in the shell's tree", timeout: 5) {
            workspace.columns.allSatisfy { column in
                sequence(first: column.view.layer, next: { $0?.superlayer }).contains { $0 === root }
            }
        }
        return workspace
    }

    private func strip(of workspace: WorkspaceState) throws -> NSView {
        try XCTUnwrap(workspace.columns.first?.view.superview)
    }

    private func withShell(_ body: (NiruxShellView) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("nirux-glass-\(UUID().uuidString)").path
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
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800),
                styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false
            )
            window.isReleasedWhenClosed = false
            window.contentView = shell
            // Ordered in: AppKit assembles the layer tree.
            window.orderFront(nil)
            defer { window.close() }
            try body(shell)
        }
    }
}
