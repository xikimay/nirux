import AppKit
import IOSurface
import XCTest
@testable import Nirux

/// Depth study P4: what a view shows, frozen in a few milliseconds.
@MainActor
final class FrozenViewTests: XCTestCase {
    /// A clone of what shows, each layer sharing its contents; what is
    /// hidden or clipped out of sight stays out. A surface shows a copy,
    /// which what draws into the surface afterwards leaves as it was. It
    /// takes no click.
    func testAFrozenViewClonesWhatShowsAndCopiesSurfaces() throws {
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        view.wantsLayer = true
        let root = try XCTUnwrap(view.layer)
        let image = try XCTUnwrap(Self.image())
        let card = CALayer()
        card.frame = CGRect(x: 10, y: 10, width: 80, height: 80)
        card.backgroundColor = NSColor.red.cgColor
        card.cornerRadius = 6
        card.maskedCorners = [.layerMinXMinYCorner]
        card.masksToBounds = true
        card.contents = image
        let hidden = CALayer()
        hidden.isHidden = true
        let shape = CAShapeLayer()
        shape.path = CGPath(rect: CGRect(x: 0, y: 0, width: 5, height: 5), transform: nil)
        card.sublayers = [hidden, shape]
        let away = CALayer()
        away.frame = CGRect(x: 300, y: 0, width: 50, height: 50)
        away.masksToBounds = true
        let overflow = CALayer()
        overflow.frame = CGRect(x: 300, y: 0, width: 0, height: 0)
        let spill = CALayer()
        spill.frame = CGRect(x: -280, y: 10, width: 10, height: 10)
        overflow.addSublayer(spill)
        let surface = try XCTUnwrap(Self.surface(filledWith: 0x5A))
        let terminal = CALayer()
        terminal.frame = CGRect(x: 100, y: 10, width: 80, height: 80)
        terminal.contents = surface
        root.sublayers = [card, away, overflow, terminal]

        let frozen = try XCTUnwrap(FrozenView.freeze(view))
        XCTAssertEqual(frozen.frame, view.bounds)
        XCTAssertNil(frozen.hitTest(NSPoint(x: 50, y: 50)), "it takes no click")
        let layers = try XCTUnwrap(frozen.layer?.sublayers)
        XCTAssertEqual(layers.count, 3, "what clips out of sight stays out")
        let cardCopy = try XCTUnwrap(layers.first)
        XCTAssertFalse(cardCopy === card)
        XCTAssertEqual(cardCopy.frame, card.frame)
        XCTAssertEqual(cardCopy.backgroundColor, card.backgroundColor)
        XCTAssertEqual(cardCopy.cornerRadius, 6)
        XCTAssertEqual(cardCopy.maskedCorners, card.maskedCorners)
        XCTAssertTrue(cardCopy.masksToBounds)
        XCTAssertTrue((cardCopy.contents as AnyObject) === image, "its contents shared, not drawn again")
        XCTAssertEqual(cardCopy.sublayers?.count, 1, "the hidden layer stays out")
        XCTAssertEqual((cardCopy.sublayers?.first as? CAShapeLayer)?.path, shape.path)
        XCTAssertEqual(layers[1].sublayers?.first?.frame, spill.frame, "a layer that doesn't clip shows what it holds")

        let copy = try XCTUnwrap(FrozenView.surface(of: layers[2]))
        XCTAssertFalse(copy === surface, "a surface shows a copy")
        XCTAssertEqual(Self.bytes(of: copy), Self.bytes(of: surface))
        Self.fill(surface, with: 0x11)
        XCTAssertEqual(Self.bytes(of: copy).first, 0x5A, "what draws into the surface after leaves the copy as it was")
    }

    /// Where the GPU can't copy a surface, the CPU's copy is the same.
    func testACopyOnTheCPUIsTheSame() throws {
        let surface = try XCTUnwrap(Self.surface(filledWith: 0x33))
        let blank = try XCTUnwrap(SurfaceCopies.blank(like: surface))
        let copy = try XCTUnwrap(SurfaceCopies.cpuCopy(surface, into: blank))
        XCTAssertEqual(Self.bytes(of: copy), Self.bytes(of: surface))
    }

    /// A new workspace and ⌥⌘→ lay what the viewport showed, frozen, over
    /// it as it slides away, gone on time; nothing is drawn again.
    func testASlideLeavesAFrozenPictureGoneOnTime() throws {
        try withShell { shell in
            let first = shell.activeProfileID
            shell.workspaceStore.createProfile(named: "Second", select: true)
            shell.addWorkspace(title: "second", cwd: NSTemporaryDirectory())
            XCTAssertEqual(Self.frozenViews(in: shell).count, 1, "a new workspace slides over what showed, frozen")
            waitUntil("gone on time", timeout: 2) { Self.frozenViews(in: shell).isEmpty }

            shell.selectProfile(first)
            XCTAssertTrue(Self.frozenViews(in: shell).isEmpty, "a pick from the menu doesn't slide")
            shell.focusSpace(.next)
            XCTAssertEqual(Self.frozenViews(in: shell).count, 1, "the space left, frozen, over the viewport")
            XCTAssertFalse(shell.viewport.subviews.contains { $0 is NSImageView }, "nothing drawn again")
            waitUntil("gone on time", timeout: 2) { Self.frozenViews(in: shell).isEmpty }
        }
    }

    // MARK: - Helpers

    private static func frozenViews(in shell: NiruxShellView) -> [FrozenView] {
        shell.viewport.subviews.compactMap { $0 as? FrozenView }
    }

    private static func image() -> CGImage? {
        let context = CGContext(
            data: nil, width: 2, height: 2, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
        )
        return context?.makeImage()
    }

    /// 8 by 8, BGRA, every byte `value`.
    private static func surface(filledWith value: UInt8) -> IOSurfaceRef? {
        let properties: [CFString: Any] = [
            kIOSurfaceWidth: 8, kIOSurfaceHeight: 8, kIOSurfaceBytesPerElement: 4, kIOSurfacePixelFormat: 0x4247_5241
        ]
        guard let surface = IOSurfaceCreate(properties as CFDictionary) else { return nil }
        fill(surface, with: value)
        return surface
    }

    private static func fill(_ surface: IOSurfaceRef, with value: UInt8) {
        IOSurfaceLock(surface, [], nil)
        memset(IOSurfaceGetBaseAddress(surface), Int32(value), IOSurfaceGetAllocSize(surface))
        IOSurfaceUnlock(surface, [], nil)
    }

    private static func bytes(of surface: IOSurfaceRef) -> [UInt8] {
        IOSurfaceLock(surface, .readOnly, nil)
        defer { IOSurfaceUnlock(surface, .readOnly, nil) }
        let count = IOSurfaceGetBytesPerRow(surface) * IOSurfaceGetHeight(surface)
        return Array(UnsafeBufferPointer(start: IOSurfaceGetBaseAddress(surface).assumingMemoryBound(to: UInt8.self), count: count))
    }

    private func withShell(_ body: (NiruxShellView) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("nirux-frozen-\(UUID().uuidString)").path
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
            window.orderFront(nil)
            defer { window.close() }
            try body(shell)
        }
    }
}
