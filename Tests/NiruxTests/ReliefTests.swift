import AppKit
import XCTest
@testable import Nirux

/// Controls in relief (depth study P9): they rise under the pointer over a
/// short shadow, a rail icon sinks pressed, and nothing moves while the
/// interface may not.
@MainActor
final class ReliefTests: XCTestCase {
    private final class FlippedView: NSView {
        override var isFlipped: Bool { true }
    }

    private static let enter = NSEvent.enterExitEvent(
        with: .mouseEntered, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
        context: nil, eventNumber: 0, trackingNumber: 0, userData: nil
    )!
    private static let exit = NSEvent.enterExitEvent(
        with: .mouseExited, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
        context: nil, eventNumber: 0, trackingNumber: 0, userData: nil
    )!

    private static func click(_ type: NSEvent.EventType, at point: NSPoint) -> NSEvent {
        NSEvent.mouseEvent(
            with: type, location: point, modifierFlags: [], timestamp: 0, windowNumber: 0,
            context: nil, eventNumber: 0, clickCount: 1, pressure: 1
        )!
    }

    /// A window holding `view` in a host, flipped as the rail's list is.
    private func window(holding view: NSView, flipped: Bool) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200), styleMask: [.borderless], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        let host = flipped ? FlippedView(frame: NSRect(x: 0, y: 0, width: 300, height: 200)) : NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
        host.wantsLayer = true
        window.contentView = host
        host.addSubview(view)
        return window
    }

    /// Where `view` shows in its window, y up, its layer's transform
    /// included.
    private func shownMidY(of view: NSView) throws -> CGFloat {
        let layer = try XCTUnwrap(view.layer), root = try XCTUnwrap(view.window?.contentView?.layer)
        let rect = layer.convert(layer.bounds, to: root)
        return root.contentsAreFlipped() ? root.bounds.height - rect.midY : rect.midY
    }

    private func shadowOpacity(of view: NSView) -> Float? {
        view.layer?.sublayers?.first { $0.name == Relief.shadowName }?.opacity
    }

    func testARailIconRisesUnderThePointerAndSinksPressed() throws {
        let icon = RailItemView(frame: NSRect(x: 100, y: 80, width: IconRail.width, height: 36))
        let window = window(holding: icon, flipped: true)
        defer { window.close() }
        icon.layoutSubtreeIfNeeded()
        let rest = try shownMidY(of: icon)

        icon.mouseEntered(with: Self.enter)
        XCTAssertEqual(try shownMidY(of: icon), rest + RailItemView.liftHeight, accuracy: 0.01, "up, on screen")
        XCTAssertEqual(shadowOpacity(of: icon), 1, "over its shadow")
        XCTAssertEqual(icon.layer?.masksToBounds, false, "which nothing cuts")

        icon.mouseDown(with: Self.click(.leftMouseDown, at: NSPoint(x: 119, y: 98)))
        XCTAssertEqual(try XCTUnwrap(icon.layer).transform.m11, Relief.pressedScale, accuracy: 0.001, "pressed, it sinks")
        XCTAssertLessThan(try shownMidY(of: icon), rest, "a little down")
        XCTAssertEqual(shadowOpacity(of: icon), 0)
        icon.mouseUp(with: Self.click(.leftMouseUp, at: NSPoint(x: 119, y: 98)))
        XCTAssertEqual(try shownMidY(of: icon), rest + RailItemView.liftHeight, accuracy: 0.01, "up again, still under the pointer")

        icon.moves = false
        XCTAssertEqual(try shownMidY(of: icon), rest, accuracy: 0.01, "still while nothing may move")
        XCTAssertEqual(shadowOpacity(of: icon), 0)
        icon.moves = true
        icon.mouseExited(with: Self.exit)
        XCTAssertEqual(try shownMidY(of: icon), rest, accuracy: 0.01)
    }

    func testABarSegmentRisesUnderThePointerAndLiesFlatPressed() throws {
        let bar = CommandBarView(level: .opaque)
        let button = bar.searchButton
        button.removeFromSuperview()
        button.frame = NSRect(x: 40, y: 40, width: 120, height: 24)
        let window = window(holding: button, flipped: false)
        defer { window.close() }
        let rest = try shownMidY(of: button)

        button.mouseEntered(with: Self.enter)
        XCTAssertEqual(try shownMidY(of: button), rest, accuracy: 0.01, "flat while the bar doesn't lift")
        bar.lifts = true
        XCTAssertEqual(button.relief, 1)
        XCTAssertEqual(try shownMidY(of: button), rest + 1, accuracy: 0.01, "up, on screen")
        XCTAssertEqual(shadowOpacity(of: button), 1)
        XCTAssertEqual(button.layer?.masksToBounds, false, "its shadow uncut")

        button.cell?.highlight(true, withFrame: button.bounds, in: button)
        XCTAssertEqual(try shownMidY(of: button), rest, accuracy: 0.01, "pressed, flat again")
        button.cell?.highlight(false, withFrame: button.bounds, in: button)
        button.mouseExited(with: Self.exit)
        XCTAssertEqual(try shownMidY(of: button), rest, accuracy: 0.01)
        XCTAssertEqual(shadowOpacity(of: button), 0)
    }

    /// Pressed, a control shrinks about its middle and moves a little down,
    /// whichever way its superlayer counts y.
    func testPressedShrinksAboutTheMiddle() {
        let size = NSSize(width: 40, height: 30)
        for flipped in [false, true] {
            let middle = CGPoint(x: 20, y: 15).applying(Relief.transform(.pressed, size: size, flipped: flipped))
            XCTAssertEqual(middle.x, 20, accuracy: 0.001)
            XCTAssertEqual(middle.y, flipped ? 15.5 : 14.5, accuracy: 0.001)
        }
    }
}
