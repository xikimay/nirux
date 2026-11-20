import AppKit
import XCTest
@testable import Nirux

/// Depth study P6, its second part: the command bar is an island of glass
/// over the work. While floors play the work passes under it, the rest of
/// the title band under a frost like the window's; at rest nothing lies
/// under it.
@MainActor
final class UnderBarTests: XCTestCase {
    /// ⌘↓ in glass: the viewport reaches up under the title band, what it
    /// holds where it lay; the band covered but for the bar; every row but
    /// the floors' clear; what centres on the viewport stays put. The
    /// floors' end brings it all back.
    func testTheWorkPassesUnderTheBarWhileFloorsPlay() throws {
        try withShell { shell, clock in
            let rest = shell.viewport.frame
            let place = try XCTUnwrap(shell.titleBand)
            let first = try XCTUnwrap(shell.activeWorkspace)
            shell.focusWorkspace(.down)
            let second = try XCTUnwrap(shell.activeWorkspace)
            XCTAssertFalse(first === second)
            XCTAssertEqual(shell.viewport.frame.maxY, place.band.maxY, accuracy: 0.5, "up to the band's top")
            XCTAssertEqual(shell.viewport.frame.minY, rest.minY)
            XCTAssertEqual(second.containerView.convert(second.containerView.bounds, to: shell), rest, "what it holds where it lay")
            let cover = try XCTUnwrap(shell.titleBandCover)
            XCTAssertEqual(cover.frame, place.band)
            XCTAssertEqual(cover.convert(cover.opening, to: shell), place.bar, "open where the bar lies")
            XCTAssertIdentical(shell.subviews.last, cover, "over the work")
            XCTAssertEqual([first, second].map(\.containerView.alphaValue), [1, 1])
            XCTAssertTrue(shell.workspaces.filter { $0 !== first && $0 !== second }.allSatisfy { $0.containerView.alphaValue == 0 }, "every other row clear")
            XCTAssertEqual(shell.viewportRestFrame, rest, "what centres on it stays put")

            clock.advance(by: NiruxShellView.workspaceSwitchDuration)
            XCTAssertNil(shell.titleBandCover)
            XCTAssertNil(cover.superview)
            XCTAssertEqual(shell.viewport.frame, rest)
            XCTAssertTrue(shell.workspaces.allSatisfy { $0.containerView.alphaValue == 1 })
        }
    }

    /// At Opaque, or without macOS's glass, floors play with nothing under
    /// the bar.
    func testNothingPassesUnderABarThatDoesNotFloat() throws {
        try withShell { shell, clock in
            let rest = shell.viewport.frame
            let cases: [(name: String, change: () -> Void)] = [
                ("at Opaque", { shell.interfaceTransparency = .opaque }),
                ("without macOS's glass", { shell.sideEffects.drawsGlass = { false } })
            ]
            for test in cases {
                shell.interfaceTransparency = .tinted
                shell.sideEffects.drawsGlass = { true }
                test.change()
                shell.focusWorkspace(.down)
                XCTAssertTrue(shell.workspaceSwitch.isSwitching, "\(test.name): floors play")
                XCTAssertNil(shell.titleBandCover, test.name)
                XCTAssertEqual(shell.viewport.frame, rest, test.name)
                clock.advance(by: 1)
                shell.focusWorkspace(.up)
                clock.advance(by: 1)
            }
        }
    }

    /// A pass goes on through a layout, going up as down; it ends at once
    /// where the bar stops floating or movement turns off.
    func testAPassGoesOnThroughALayoutAndEndsWhereNothingMayPass() throws {
        try withShell { shell, clock in
            let rest = shell.viewport.frame
            shell.focusWorkspace(.down)
            shell.relayout(animated: false)
            XCTAssertNotNil(shell.titleBandCover, "a layout keeps it")
            XCTAssertGreaterThan(shell.viewport.frame.maxY, rest.maxY)
            shell.interfaceTransparency = .opaque
            shell.relayout(animated: false)
            XCTAssertNil(shell.titleBandCover, "at Opaque it ends")
            XCTAssertEqual(shell.viewport.frame, rest)
            clock.advance(by: 1)

            shell.interfaceTransparency = .tinted
            shell.focusWorkspace(.up)
            XCTAssertNotNil(shell.titleBandCover, "going up too")
            shell.sideEffects.reducesMotion = { true }
            shell.applyAgentLights()
            XCTAssertNil(shell.titleBandCover, "movement turning off ends it at once")
            XCTAssertEqual(shell.viewport.frame, rest)
            XCTAssertTrue(shell.workspaces.allSatisfy { $0.containerView.alphaValue == 1 })
        }
    }

    /// A picture of the work taken during a pass (a new workspace's slide,
    /// a crossing to another space, the plan) is of the viewport at rest.
    func testAPictureDuringAPassIsOfTheWorkAtRest() throws {
        try withShell { shell, clock in
            let rest = shell.viewport.frame
            shell.focusWorkspace(.down)
            XCTAssertNotNil(shell.titleBandCover)
            shell.addWorkspace(title: "new", cwd: NSTemporaryDirectory())
            let slide = shell.viewport.subviews.compactMap { $0 as? FrozenView }
            XCTAssertEqual(slide.count, 1, "the slide")
            XCTAssertEqual(slide.first?.frame.height, rest.height, "a new workspace's slide")
            XCTAssertEqual(slide.first?.content.bounds.height, rest.height)
            clock.advance(by: 1)

            shell.focusWorkspace(.up)
            XCTAssertNotNil(shell.titleBandCover)
            shell.toggleSpacePlan()
            waitUntil("the plan", timeout: 5) { shell.spacePlan != nil }
            XCTAssertEqual(shell.spacePlan?.frame.size, rest.size, "the plan")
            shell.toggleSpacePlan()
            waitUntil("the plan gone", timeout: 5) { shell.spacePlan == nil }
            clock.advance(by: 1)

            let first = shell.activeProfileID
            shell.workspaceStore.createProfile(named: "Second", select: true)
            shell.addWorkspace(title: "second space", cwd: NSTemporaryDirectory())
            shell.selectProfile(first)
            clock.advance(by: 1)
            shell.focusWorkspace(.down)
            XCTAssertNotNil(shell.titleBandCover)
            shell.focusSpace(.next)
            let leaving = try XCTUnwrap(shell.crossingPictures.first)
            XCTAssertEqual(leaving.frame.size, rest.size, "a crossing's")
        }
    }

    // MARK: - Helpers

    /// The main window as Nirux builds it, its toolbar's bar over the title
    /// band, in glass at Tinted, the interface free to move; three
    /// workspaces, the first on screen.
    private func withShell(_ body: (NiruxShellView, ManualSchedule) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("nirux-bar-\(UUID().uuidString)").path
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
            let window = NiruxApp.makeMainWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800))
            window.isReleasedWhenClosed = false
            let shell = NiruxShellView(frame: NSRect(x: 0, y: 0, width: 1200, height: 800))
            shell.stopHeartbeat()
            shell.sideEffects.windowShows = { _ in true }
            shell.sideEffects.reducesMotion = { false }
            shell.sideEffects.drawsGlass = { true }
            shell.sideEffects.drawnTransparency = { $0 }
            shell.sideEffects.watchUserInput = { _ in nil }
            shell.agentLights.isDisplayAsleep = false
            shell.animatesInterface = true
            let clock = ManualSchedule()
            shell.workspaceSwitch.schedule = clock.schedule
            window.contentView = MainWindowContent(shell: shell)
            shell.installCommandBar(in: window)
            shell.interfaceTransparency = .tinted
            window.orderFront(nil)
            defer { window.close() }
            for title in ["second", "third"] { shell.addWorkspace(title: title, cwd: folder) }
            shell.switchToWorkspace(0)
            shell.endWorkspaceSwitch()
            shell.workspaceNameCard.hide(animated: false)
            clock.advance(by: 5)
            waitUntil("the bar over the title band", timeout: 5) {
                window.contentView?.superview?.layoutSubtreeIfNeeded()
                shell.relayout(animated: false)
                return shell.titleBand != nil
            }
            try body(shell, clock)
        }
    }
}
