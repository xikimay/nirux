import AppKit
import XCTest
@testable import Nirux

/// The glass interface's state icons (docs/design/glass-interface.md).
@MainActor
final class StateIconTests: XCTestCase {
    /// Amber is the colour of an agent waiting for the user, and of nothing
    /// else, from a row or from a Board line; the reason it waits picks the
    /// glyph.
    func testAmberMeansOnlyThatAnAgentWaitsForTheUser() {
        for mark in SidebarRowMark.allCases {
            for reason in [StateIcon.Reason.command, .question, nil] {
                let icon = StateIcon(mark: mark, reason: reason, station: .checks)
                XCTAssertEqual(icon.color == Theme.Color.waiting, mark == .needsYou, "\(mark)")
            }
        }
        let states: [BoardStages.State] = [.needsYou, .failed, .working, .blocked, .waiting, .ready, .merged, .idle]
        for state in states {
            XCTAssertEqual(StateIcon(state: state, station: .code).color == Theme.Color.waiting, state == .needsYou, "\(state)")
        }
        XCTAssertEqual(StateIcon.Reason(.permission(tool: "Bash", summary: "npm run migrate")), .command)
        XCTAssertEqual(StateIcon.Reason(.permission(tool: "ExitPlanMode", summary: nil)), .question, "a plan to approve")
        XCTAssertEqual(StateIcon.Reason(.stillWaiting(.permission(tool: nil, summary: nil), waited: 900)), .command)
        XCTAssertEqual(StateIcon.Reason(.question("Which branch?")), .question)
        XCTAssertEqual(StateIcon.Reason(.askedInReply("Shall I merge it?")), .question)
        XCTAssertEqual(StateIcon.Reason(.message("needs you")), .question)
        XCTAssertEqual(StateIcon.Reason(nil), .question, "an agent without hooks falling silent may be asking")
        XCTAssertNil(StateIcon.Reason(.turnFinished))
        XCTAssertNil(StateIcon.Reason(.stillWaiting(.turnFinished, waited: 900)))
        XCTAssertNil(StateIcon.Reason(.apiError(kind: nil, detail: nil)))
        XCTAssertNil(StateIcon.Reason(.exitedMidTurn))
        XCTAssertEqual(StateIcon(mark: .needsYou).kind, .needsYou(.question))
    }

    /// The ring fills a quarter per station, the station a task is at
    /// included; VoiceOver hears it.
    func testTheRingFillsWithTheBoardsStations() {
        XCTAssertEqual(BoardStages.Station.allCases.map { StateIcon.stage(of: $0) }, [1, 2, 3, 4])
        XCTAssertEqual(StateIcon.stage(of: nil), 0)
        XCTAssertEqual(StateIcon(.idle, stage: 7).stage, 4)
        XCTAssertEqual(StateIcon(.idle, stage: -1).stage, 0)
        XCTAssertEqual(StateIcon(.working, stage: 3).accessibilityText, "Working, at Checks")
        XCTAssertEqual(StateIcon(.working).accessibilityText, "Working")
    }

    /// Drawn in a flipped view: the ring of a task at Code fills its top
    /// right quarter only, from 12 o'clock clockwise; a wait is an amber
    /// disc.
    func testTheRingFillsClockwiseFromTwelve() throws {
        func pixels(_ icon: StateIcon) throws -> (NSPoint) -> NSColor {
            let view = StateIconView(icon, size: 32)
            let window = NSWindow(contentRect: view.frame, styleMask: .borderless, backing: .buffered, defer: true)
            window.isReleasedWhenClosed = false
            window.contentView = view
            let rep = try XCTUnwrap(NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: 32, pixelsHigh: 32, bitsPerSample: 8, samplesPerPixel: 4,
                hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
            ))
            rep.size = view.bounds.size
            view.cacheDisplay(in: view.bounds, to: rep)
            // Bitmap rows count from the top, like the flipped view.
            return { point in rep.colorAt(x: Int(point.x), y: Int(point.y)) ?? .clear }
        }
        func isFilled(_ color: NSColor) -> Bool { color.alphaComponent > 0.5 }
        let code = try pixels(StateIcon(.idle, stage: 1))
        XCTAssertTrue(isFilled(code(NSPoint(x: 19, y: 12))), "top right: Code")
        XCTAssertFalse(isFilled(code(NSPoint(x: 12, y: 12))), "top left")
        XCTAssertFalse(isFilled(code(NSPoint(x: 19, y: 19))), "bottom right")
        let wait = try pixels(StateIcon(.needsYou(.command)))
        let rim = try XCTUnwrap(wait(NSPoint(x: 16, y: 4)).usingColorSpace(.sRGB))
        let amber = try XCTUnwrap(Theme.Color.waiting.usingColorSpace(.sRGB))
        XCTAssertEqual(rim.redComponent, amber.redComponent, accuracy: 0.08)
        XCTAssertEqual(rim.greenComponent, amber.greenComponent, accuracy: 0.08)
    }

    /// The view keeps quiet for VoiceOver unless its host makes it speak,
    /// follows the icon it is given, and keeps its size whatever frame a
    /// layout gave it.
    func testTheViewFollowsItsIconAndKeepsItsSize() {
        let view = StateIconView(StateIcon(.working, stage: 3))
        XCTAssertFalse(view.isAccessibilityElement(), "a row says its state in words")
        view.icon = StateIcon(mark: .needsYou, reason: .command)
        XCTAssertEqual(view.accessibilityLabel(), "Needs you: a permission")
        view.frame.size = .zero
        XCTAssertEqual(view.intrinsicContentSize, NSSize(width: 14, height: 14))
    }
}
