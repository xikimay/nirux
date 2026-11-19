import AppKit
import XCTest
@testable import Nirux

/// Depth study P6: folded, the rail is an island of glass over the work.
/// While the columns travel they pass under it; at rest nothing does.
@MainActor
final class UnderGlassTests: XCTestCase {
    /// A slide to a card passes the cards under the rail: the viewport's
    /// layer reaches the sidebar's edge, what it holds where it lay, its
    /// view and its frame unmoved, and the workspace leaves its cards
    /// unclipped. Then the work's edge sweeps back, and the cards are
    /// clipped again.
    func testTheColumnsPassUnderTheRailWhileTheyTravel() throws {
        try withShell { shell in
            let workspace = try floatingRail(in: shell)
            let viewport = try XCTUnwrap(shell.viewport.layer)
            let container = try XCTUnwrap(workspace.containerView.layer)
            let sidebarAbove = try XCTUnwrap(shell.subviews.firstIndex(of: shell.sidebar))
            XCTAssertGreaterThan(sidebarAbove, try XCTUnwrap(shell.subviews.firstIndex(of: shell.viewport)), "the rail lies over the work")
            XCTAssertTrue(shell.divider.isHidden, "no line marks a floating rail's edge")
            let viewFrame = shell.viewport.frame

            shell.focusColumn(.right)
            XCTAssertEqual(viewport.bounds.minX, 0, "no travel, nothing under the rail")
            shell.focusColumn(.right)
            XCTAssertNotNil(try strip(of: workspace).layer?.animation(forKey: "colSlide"), "it travels")
            let reached = try onScreen(viewport, in: shell)
            XCTAssertEqual(reached.minX, shell.sidebar.frame.minX, accuracy: 0.5, "under the sidebar")
            XCTAssertEqual(reached.maxX, viewFrame.maxX, accuracy: 0.5)
            XCTAssertEqual(shell.viewport.frame, viewFrame, "the view stays put")
            XCTAssertFalse(container.masksToBounds, "the cards unclipped")
            for column in workspace.columns {
                let layer = try XCTUnwrap(column.view.layer)
                XCTAssertEqual(try onScreen(layer, in: shell).minX, column.view.convert(column.view.bounds, to: shell).minX, accuracy: 0.5, "where it lies")
            }

            var swept = false
            waitUntil("back at the rail's edge", timeout: 2) {
                if viewport.bounds.minX == 0, !container.masksToBounds {
                    swept = swept || viewport.animation(forKey: "underGlass.bounds") != nil
                }
                return viewport.bounds.minX == 0 && container.masksToBounds
            }
            XCTAssertTrue(swept, "the edge sweeps back while the cards are still unclipped")
            XCTAssertEqual(try onScreen(viewport, in: shell).minX, viewFrame.minX, accuracy: 0.5)
        }
    }

    /// At Opaque, without macOS's glass, unfolded, or while nothing may
    /// move, a travel leaves the work where it was.
    func testNothingPassesUnderARailThatDoesNotFloat() throws {
        try withShell { shell in
            let workspace = try floatingRail(in: shell)
            let viewport = try XCTUnwrap(shell.viewport.layer)
            let container = try XCTUnwrap(workspace.containerView.layer)
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
                XCTAssertEqual(shell.divider.isHidden, test.floats, "\(test.name): the line")
                shell.focusColumn(.right)
                shell.focusColumn(.right)
                XCTAssertNotNil(try strip(of: workspace).layer?.animation(forKey: "colSlide"), "\(test.name): it travels")
                XCTAssertEqual(viewport.bounds.minX, 0, "\(test.name): nothing under the rail")
                XCTAssertTrue(container.masksToBounds, test.name)
            }
        }
    }

    /// A pass goes on through a layout while the rail floats, and ends at
    /// once when it no longer does; a pass's end acts only on its own: one
    /// that took its place stays until its own end.
    func testAPassGoesOnThroughALayoutAndOnlyItsOwnEndClosesIt() throws {
        try withShell { shell in
            let workspace = try floatingRail(in: shell)
            let viewport = try XCTUnwrap(shell.viewport.layer)
            let container = try XCTUnwrap(workspace.containerView.layer)

            shell.passUnderRail(workspace, for: 1)
            let reached = try onScreen(viewport, in: shell)
            XCTAssertEqual(reached.minX, shell.sidebar.frame.minX, accuracy: 0.5)
            shell.relayout(animated: false)
            XCTAssertEqual(try onScreen(viewport, in: shell), reached, "a layout keeps it")
            XCTAssertEqual(viewport.bounds.minX, shell.sidebar.frame.minX - shell.viewport.frame.minX, accuracy: 0.5, "what it holds where it lay")
            XCTAssertFalse(container.masksToBounds)

            shell.isSidebarExpanded = true
            shell.sidebar.isExpanded = true
            shell.relayout(animated: false)
            XCTAssertEqual(viewport.bounds.minX, 0, "unfolded, it ends at once")
            XCTAssertEqual(try onScreen(viewport, in: shell).minX, shell.viewport.frame.minX, accuracy: 0.5)
            XCTAssertTrue(container.masksToBounds)

            _ = try floatingRail(in: shell)
            shell.passUnderRail(workspace, for: 0.05)
            shell.passUnderRail(workspace, for: 1)
            let due = Date().addingTimeInterval(0.4)
            waitUntil("past the first pass's end", timeout: 2) { Date() >= due }
            XCTAssertLessThan(viewport.bounds.minX, 0, "the first's end left the second alone")
            XCTAssertFalse(container.masksToBounds)
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

    /// Where a layer shows in the shell, from the layers' own geometry.
    private func onScreen(_ layer: CALayer, in shell: NiruxShellView) throws -> CGRect {
        layer.convert(layer.bounds, to: try XCTUnwrap(shell.layer))
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
