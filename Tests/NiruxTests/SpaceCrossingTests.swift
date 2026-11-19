import AppKit
import XCTest
@testable import Nirux

/// Depth study P4: ⌥⌘← ⌥⌘→ pass through depth, on frozen pictures.
@MainActor
final class SpaceCrossingTests: XCTestCase {
    /// The space left recedes as it fades; the one chosen comes from the
    /// front and lands over it. Both are frozen, the live views hidden under
    /// them until the crossing ends, on time.
    func testTheSpaceLeftRecedesAndTheOneChosenComesFromTheFront() throws {
        try withSpaces { shell, _, second in
            let steps = TimedSteps(on: shell)
            shell.focusSpace(.next)
            XCTAssertEqual(shell.activeProfileID, second)
            let pictures = Self.frozenViews(in: shell)
            XCTAssertEqual(pictures.count, 2)
            let leaving = try XCTUnwrap(pictures.first?.layer), arriving = try XCTUnwrap(pictures.last?.layer)
            XCTAssertEqual(leaving.opacity, 0, "the space left fades")
            XCTAssertEqual(Self.scale(leaving.transform), NiruxShellView.recedeScale, accuracy: 0.001, "and recedes")
            XCTAssertEqual(arriving.opacity, 1)
            XCTAssertEqual(Self.scale(arriving.transform), 1, accuracy: 0.001, "the one chosen lands")
            let comes = try XCTUnwrap((arriving.animation(forKey: "crossing") as? CAAnimationGroup)?.animations)
            let from = try XCTUnwrap(comes.compactMap { ($0 as? CABasicAnimation)?.fromValue as? NSValue }.first)
            XCTAssertEqual(Self.scale(from.caTransform3DValue), NiruxShellView.arrivalFromScale, accuracy: 0.001, "from the front")
            // Its middle, from its anchor, stays where it lies.
            let middle = CGPoint(
                x: (0.5 - arriving.anchorPoint.x) * arriving.bounds.width, y: (0.5 - arriving.anchorPoint.y) * arriving.bounds.height
            )
            let moved = middle.applying(CATransform3DGetAffineTransform(from.caTransform3DValue))
            XCTAssertEqual(moved.x, middle.x, accuracy: 0.5, "about its middle")
            XCTAssertEqual(moved.y, middle.y, accuracy: 0.5)
            XCTAssertEqual(shell.verticalStrip.alphaValue, 0, "the live views hidden under them")

            XCTAssertEqual(steps.durations, [NiruxShellView.crossingDuration], "it lands on time")
            steps.runNext()
            XCTAssertTrue(Self.frozenViews(in: shell).isEmpty)
            XCTAssertEqual(shell.verticalStrip.alphaValue, 1)
        }
    }

    /// With Reduce motion, or a pick from the menu, the space shows at once.
    func testNothingCrossesWhileNothingMayMove() throws {
        try withSpaces { shell, first, _ in
            shell.sideEffects.reducesMotion = { true }
            shell.focusSpace(.next)
            XCTAssertTrue(Self.frozenViews(in: shell).isEmpty)
            XCTAssertEqual(shell.verticalStrip.alphaValue, 1)

            shell.sideEffects.reducesMotion = { false }
            shell.selectProfile(first)
            XCTAssertTrue(Self.frozenViews(in: shell).isEmpty, "a pick from the menu")
        }
    }

    /// A switch while one plays ends it at once, so a held key shows each
    /// space in turn; a crossing's end acts only on its own.
    func testASwitchEndsTheCrossingOnItsWayAndOnlyItsOwnEndEndsIt() throws {
        try withSpaces { shell, _, _ in
            let steps = TimedSteps(on: shell)
            shell.focusSpace(.next)
            shell.focusSpace(.next)
            XCTAssertEqual(Self.frozenViews(in: shell).count, 2, "the first crossing's pictures gone")
            // A new workspace's picture still sliding away isn't frozen again.
            shell.addWorkspace(title: "third", cwd: NSTemporaryDirectory())
            shell.focusSpace(.next)
            XCTAssertTrue(Self.frozenViews(in: shell).allSatisfy { Self.pictureLayers(in: $0.layer) == 1 }, "no picture holds another")

            waitUntil("the new workspace's slide gone", timeout: 2) { Self.frozenViews(in: shell).allSatisfy { shell.crossingPictures.contains($0) } }
            while steps.runNext() {}
            shell.crossSpaces(leaving: try XCTUnwrap(FrozenView.freeze(shell.viewport)), duration: 0.05)
            shell.crossSpaces(leaving: try XCTUnwrap(FrozenView.freeze(shell.viewport)), duration: 1)
            XCTAssertEqual(steps.durations, [0.05, 1])
            steps.runNext()
            XCTAssertEqual(Self.frozenViews(in: shell).count, 2, "the first's end left the second alone")
            XCTAssertEqual(shell.verticalStrip.alphaValue, 0)
            steps.runNext()
            XCTAssertTrue(Self.frozenViews(in: shell).isEmpty, "its own end ends it")
        }
    }

    // MARK: - Helpers

    private static func frozenViews(in shell: NiruxShellView) -> [FrozenView] {
        shell.viewport.subviews.compactMap { $0 as? FrozenView }
    }

    private static func scale(_ transform: CATransform3D) -> CGFloat { transform.m11 }

    /// Layers named as a picture's own, `layer` included.
    private static func pictureLayers(in layer: CALayer?) -> Int {
        guard let layer else { return 0 }
        return (layer.name == FrozenView.layerName ? 1 : 0) + (layer.sublayers ?? []).reduce(0) { $0 + pictureLayers(in: $1) }
    }

    /// Two spaces of one workspace each, the first on screen, the interface
    /// free to move.
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
            let first = shell.activeProfileID
            let second = shell.workspaceStore.createProfile(named: "Second", select: true).id
            shell.addWorkspace(title: "second", cwd: NSTemporaryDirectory())
            shell.selectProfile(first)
            waitUntil("the new workspace's slide gone", timeout: 2) { Self.frozenViews(in: shell).isEmpty }
            try body(shell, first, second)
        }
    }
}
