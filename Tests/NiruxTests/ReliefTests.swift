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

    /// A window on screen holding `view` in a host, flipped as the rail's
    /// list is: AppKit assembles the layer tree of a window that shows.
    private func window(holding view: NSView, flipped: Bool) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 200), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = flipped ? FlippedView(frame: NSRect(x: 0, y: 0, width: 640, height: 200)) : NSView(frame: NSRect(x: 0, y: 0, width: 640, height: 200))
        host.wantsLayer = true
        window.contentView = host
        host.addSubview(view)
        window.orderFront(nil)
        host.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        return window
    }

    /// Where `view` shows in its window, y up, its layer's transform
    /// included.
    private func shownMidY(of view: NSView) throws -> CGFloat {
        let layer = try XCTUnwrap(view.layer), root = try XCTUnwrap(view.window?.contentView?.layer)
        let rect = layer.convert(layer.bounds, to: root)
        return root.contentsAreFlipped() ? root.bounds.height - rect.midY : rect.midY
    }

    private func shadowOpacity(of view: NSView?) -> Float? {
        view?.layer?.sublayers?.first { $0.name == Relief.shadowName }?.opacity
    }

    private func shadow(of view: NSView?) -> CALayer? {
        view?.layer?.sublayers?.first { $0.name == Relief.shadowName }
    }

    func testARailIconRisesUnderThePointerAndSinksPressed() throws {
        let icon = RailItemView(frame: NSRect(x: 100, y: 80, width: IconRail.width, height: 36))
        let window = window(holding: icon, flipped: true)
        defer { window.close() }
        icon.layoutSubtreeIfNeeded()
        let rest = try shownMidY(of: icon.iconView)
        let inside = NSPoint(x: 119, y: 98), outside = NSPoint(x: 10, y: 10)

        icon.mouseEntered(with: Self.enter)
        XCTAssertEqual(try shownMidY(of: icon.iconView), rest + RailItemView.liftHeight, accuracy: 0.01, "up, on screen")
        XCTAssertEqual(shadowOpacity(of: icon), 1, "over its shadow")
        XCTAssertEqual(shadow(of: icon)?.animationKeys(), [Relief.key], "one fade, not CA's own beside it")
        XCTAssertEqual(icon.layer?.masksToBounds, false, "which nothing cuts")
        icon.frame.origin.x += 3
        icon.frame.size.width += 2
        XCTAssertEqual(try shownMidY(of: icon.iconView), rest + RailItemView.liftHeight, accuracy: 0.01, "a new frame keeps it up")

        icon.mouseDown(with: Self.click(.leftMouseDown, at: inside))
        XCTAssertLessThan(try shownMidY(of: icon.iconView), rest, "pressed, it sinks")
        XCTAssertEqual(shadowOpacity(of: icon), 0)
        icon.mouseDragged(with: Self.click(.leftMouseDragged, at: outside))
        XCTAssertEqual(try shownMidY(of: icon.iconView), rest, accuracy: 0.01, "dragged off: neither pressed nor up")
        icon.mouseDragged(with: Self.click(.leftMouseDragged, at: inside))
        XCTAssertLessThan(try shownMidY(of: icon.iconView), rest, "back on: pressed")
        icon.mouseUp(with: Self.click(.leftMouseUp, at: inside))
        XCTAssertEqual(try shownMidY(of: icon.iconView), rest + RailItemView.liftHeight, accuracy: 0.01, "up again, still under the pointer")

        icon.moves = false
        XCTAssertEqual(try shownMidY(of: icon.iconView), rest, accuracy: 0.01, "still while nothing may move")
        XCTAssertNil(icon.layer?.animation(forKey: Relief.key), "at once")
        icon.moves = true

        // Pressed when it leaves its window: neither pressed nor up after.
        icon.mouseDown(with: Self.click(.leftMouseDown, at: inside))
        let host = try XCTUnwrap(icon.superview)
        icon.removeFromSuperview()
        host.addSubview(icon)
        XCTAssertEqual(try shownMidY(of: icon.iconView), rest, accuracy: 0.01, "nothing pressed is left behind")
    }

    func testABarSegmentRisesWhole() throws {
        let bar = CommandBarView(level: .opaque)
        bar.frame = NSRect(x: 0, y: 40, width: 600, height: CommandBarView.height)
        bar.show(CommandBarView.Content(
            spaceName: "Demo", spaceColor: .systemBlue, taskTitle: "Fix the login", taskIcon: nil, taskDetail: nil, waitingCount: 0
        ))
        let window = window(holding: bar, flipped: false)
        defer { window.close() }
        bar.layoutSubtreeIfNeeded()
        let restIcon = try shownMidY(of: bar.searchIcon), restKey = try shownMidY(of: bar.searchKey)
        let restTask = try shownMidY(of: bar.taskLabel)

        bar.searchButton.mouseEntered(with: Self.enter)
        XCTAssertEqual(try shownMidY(of: bar.searchIcon), restIcon, accuracy: 0.01, "flat while the bar doesn't lift")
        bar.lifts = true
        XCTAssertEqual(try shownMidY(of: bar.searchIcon), restIcon + 1, accuracy: 0.01, "its icon up, on screen")
        XCTAssertEqual(try shownMidY(of: bar.searchKey), restKey + 1, accuracy: 0.01, "its key with it")
        XCTAssertEqual(try shownMidY(of: bar.taskLabel), restTask, accuracy: 0.01, "another segment stays")
        XCTAssertEqual(shadowOpacity(of: bar.searchIcon.superview), 1)

        bar.searchButton.cell?.highlight(true, withFrame: bar.searchButton.bounds, in: bar.searchButton)
        XCTAssertEqual(try shownMidY(of: bar.searchIcon), restIcon, accuracy: 0.01, "pressed, flat again")
        bar.searchButton.cell?.highlight(false, withFrame: bar.searchButton.bounds, in: bar.searchButton)
        XCTAssertEqual(try shownMidY(of: bar.searchIcon), restIcon + 1, accuracy: 0.01)

        bar.lifts = false
        XCTAssertEqual(try shownMidY(of: bar.searchIcon), restIcon, accuracy: 0.01, "flat at once when nothing may move")
        XCTAssertNil(bar.searchIcon.superview?.layer?.animation(forKey: Relief.key))
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
