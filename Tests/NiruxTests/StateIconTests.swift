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
        // Working with no station known: its ring alone, drawn full, no quarter claimed.
        let working = try pixels(StateIcon(.working))
        XCTAssertFalse(isFilled(working(NSPoint(x: 19, y: 12))), "no station, no fill")
        XCTAssertGreaterThan(working(NSPoint(x: 16, y: 4)).alphaComponent, 0.9, "the ring is the whole mark: full")
        XCTAssertLessThan(try pixels(StateIcon(.working, stage: 1))(NSPoint(x: 16, y: 4)).alphaComponent, 0.6, "dimmed beside a station")
        XCTAssertTrue(isFilled(try pixels(StateIcon(.working, stage: 1))(NSPoint(x: 19, y: 12))), "Code fills its quarter")
        let wait = try pixels(StateIcon(.needsYou(.command)))
        let rim = try XCTUnwrap(wait(NSPoint(x: 16, y: 4)).usingColorSpace(.sRGB))
        let amber = try XCTUnwrap(Theme.Color.waiting.usingColorSpace(.sRGB))
        XCTAssertEqual(rim.redComponent, amber.redComponent, accuracy: 0.08)
        XCTAssertEqual(rim.greenComponent, amber.greenComponent, accuracy: 0.08)
    }

    /// An icon draws its own paths only: a path its caller left open stays
    /// unstroked.
    func testAnIconLeavesItsCallersPathAlone() throws {
        let context = try XCTUnwrap(CGContext(
            data: nil, width: 32, height: 32, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        let kinds: [StateIcon.Kind] = [
            .working, .needsYou(.command), .needsYou(.question), .asking, .error, .waiting, .readyToMerge, .merged, .blocked, .finished, .idle,
        ]
        for kind in kinds {
            for labelled in [false, true] {
                context.move(to: CGPoint(x: 0, y: 30))
                context.addLine(to: CGPoint(x: 32, y: 30))
                StateIcon(kind, stage: 2).draw(in: context, rect: CGRect(x: 0, y: 0, width: 16, height: 16), labelled: labelled)
                let rep = NSBitmapImageRep(cgImage: try XCTUnwrap(context.makeImage()))
                // y counts from the top in the bitmap: the open line was 2 px from it.
                XCTAssertEqual(rep.colorAt(x: 28, y: 1)?.alphaComponent ?? 0, 0, "\(kind), labelled \(labelled): the caller's line, never stroked")
            }
        }
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

    /// A label (the rail's initials) takes the centre of every icon but the
    /// amber and red ones, whose glyph says why; there the glyph stays. With
    /// a label, the glyph and the inner fill go: the station runs along the
    /// ring instead.
    func testALabelTakesTheCentreWhenNoGlyphSaysWhy() throws {
        for kind: StateIcon.Kind in [.needsYou(.command), .needsYou(.question), .error] {
            XCTAssertFalse(StateIcon(kind).admitsLabel, "\(kind)")
        }
        for kind: StateIcon.Kind in [.working, .idle, .waiting, .asking, .readyToMerge, .merged, .blocked, .finished] {
            XCTAssertTrue(StateIcon(kind).admitsLabel, "\(kind)")
        }
        XCTAssertEqual(StateIcon(.merged).labelColor, Theme.Color.canvas, "ink on the disc")
        XCTAssertEqual(StateIcon(.working).labelColor, Theme.Color.working)

        let view = StateIconView(StateIcon(.finished), size: 32)
        view.label = "FC"
        XCTAssertEqual(view.shownLabel, "FC")
        view.icon = StateIcon(.needsYou(.question))
        XCTAssertNil(view.shownLabel, "the glyph shows instead")

        func pixels(_ icon: StateIcon, labelled: Bool) throws -> Data {
            let rep = try XCTUnwrap(NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: 32, pixelsHigh: 32, bitsPerSample: 8, samplesPerPixel: 4,
                hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
            ))
            let context = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: rep)?.cgContext)
            // Flipped, as the view is.
            context.translateBy(x: 0, y: 32)
            context.scaleBy(x: 1, y: -1)
            icon.draw(in: context, rect: CGRect(x: 0, y: 0, width: 32, height: 32), labelled: labelled)
            return try XCTUnwrap(rep.bitmapData.map { Data(bytes: $0, count: rep.bytesPerRow * 32) })
        }
        XCTAssertNotEqual(try pixels(StateIcon(.finished), labelled: true), try pixels(StateIcon(.finished), labelled: false), "the check goes")
        XCTAssertNotEqual(try pixels(StateIcon(.working, stage: 2), labelled: true), try pixels(StateIcon(.working, stage: 2), labelled: false), "the fill moves to the ring")
        XCTAssertEqual(try pixels(StateIcon(.error), labelled: true), try pixels(StateIcon(.error), labelled: false), "the red glyph stays")
    }
}
