import AppKit
import XCTest
@testable import Nirux

/// Two fingers sideways over the columns (`StripSwipe`): the content under
/// them keeps what it can scroll; otherwise the strip follows them, past its
/// ends with a rubber band, and settles where their speed carries it.
final class StripSwipeTests: XCTestCase {
    /// Five cards, the first two sharing the strip's start; the third focused.
    private let stops: [CGFloat] = [0, 0, 400, 800, 1000]

    private func swipe(
        _ reach: (toStart: StripSwipe.Reach, toEnd: StripSwipe.Reach) = (.cannot, .cannot), camera: CGFloat = 400, focus: Int = 2
    ) -> StripSwipe {
        StripSwipe(began: 10, reach: reach, camera: camera, stops: stops, focus: focus, viewport: 1000)
    }

    /// The fingers' steps, `dx` each, one every `every` seconds from 10 s,
    /// the first one beginning the gesture.
    private func move(
        _ swipe: inout StripSwipe, _ dx: [CGFloat], dy: CGFloat = 0, every: TimeInterval = 0.01, from start: TimeInterval = 10
    ) -> [StripSwipe.Step] {
        dx.enumerated().map { index, dx in
            let time = start + TimeInterval(index) * every
            return swipe.scrolled(.init(dx: dx, dy: dy, phase: index == 0 && start == 10 ? .began : .changed, time: time))
        }
    }

    func testFingersSidewaysOverWhatCantScrollMoveTheStrip() {
        var swipe = swipe()
        // Under 6 points, nothing knows yet which way they mean.
        XCTAssertEqual(move(&swipe, [-4, -4, -10]), [.pass, .follow(camera: 408), .follow(camera: 418)])
        XCTAssertTrue(swipe.holdsCamera)
    }

    func testAScrollUpOrDownStaysWithTheContent() {
        var swipe = swipe()
        XCTAssertEqual(move(&swipe, [2, -30], dy: 8), [.pass, .pass])
        // Sideways needs twice as much as up or down.
        var diagonal = self.swipe()
        XCTAssertEqual(move(&diagonal, [-8], dy: 5), [.pass])
        XCTAssertFalse(diagonal.holdsCamera)
    }

    func testContentThatCanScrollThatWayKeepsTheSwipe() {
        var towardEnd = swipe((toStart: .cannot, toEnd: .can))
        XCTAssertEqual(move(&towardEnd, [-10, -10]), [.pass, .pass])
        var towardStart = swipe((toStart: .cannot, toEnd: .can))
        XCTAssertEqual(move(&towardStart, [10, 10]), [.follow(camera: 390), .follow(camera: 380)])
    }

    /// A web page says itself what it can't scroll: WebKit leaves the
    /// event, and the strip takes the swipe then, caught up with the fingers.
    func testAPageKeepsTheSwipeUntilItLeavesIt() {
        var swipe = swipe((toStart: .asks, toEnd: .asks))
        XCTAssertEqual(move(&swipe, [-10, -10]), [.pass, .pass])
        XCTAssertEqual(swipe.declined(at: 9.5), .pass, "a decline from an earlier gesture")
        XCTAssertEqual(swipe.declined(at: 10), .follow(camera: 420))
        XCTAssertEqual(move(&swipe, [-10], from: 10.02), [.follow(camera: 430)])
    }

    func testADeclineBeforeTheFingersShowTheirWayWaitsForThem() {
        var swipe = swipe((toStart: .asks, toEnd: .asks))
        XCTAssertEqual(move(&swipe, [-2]), [.pass])
        XCTAssertEqual(swipe.declined(at: 10), .pass)
        XCTAssertEqual(move(&swipe, [-10], from: 10.01), [.follow(camera: 412)])
        var upward = self.swipe((toStart: .asks, toEnd: .asks))
        _ = upward.declined(at: 10)
        XCTAssertEqual(move(&upward, [0, 0], dy: 10), [.pass, .pass], "a page leaving a scroll up or down")
        var lifted = self.swipe((toStart: .asks, toEnd: .asks))
        _ = move(&lifted, [-20])
        _ = lifted.scrolled(.init(dx: 0, phase: .ended, time: 10.01))
        XCTAssertEqual(lifted.declined(at: 10), .pass, "the fingers gone before the page answered")
    }

    func testPastItsEndsTheStripFollowsLessAndLess() throws {
        var swipe = swipe(camera: 1000, focus: 4)
        let shown = move(&swipe, [-100, -100, -100]).map { step -> CGFloat in
            guard case .follow(let camera) = step else { return .nan }
            return camera
        }
        XCTAssertGreaterThan(shown[0], 1000)
        XCTAssertLessThan(shown[0], 1100)
        XCTAssertLessThan(shown[2] - shown[1], shown[1] - shown[0])
        XCTAssertLessThan(StripSwipe.band(-1_000_000, viewport: 1000), 0)
        XCTAssertGreaterThan(StripSwipe.band(-1_000_000, viewport: 1000), -1000)
    }

    /// Caught on its way back from past an end, the strip goes on from
    /// where it shows.
    func testAStripCaughtPastItsEndGoesOnFromWhereItShows() throws {
        var swipe = swipe(camera: 1028, focus: 4)
        guard case .follow(let camera) = move(&swipe, [-8]).first else { return XCTFail("follows") }
        XCTAssertGreaterThan(camera, 1028)
        XCTAssertLessThan(camera, 1036)
        XCTAssertEqual(StripSwipe.band(StripSwipe.unband(-300, viewport: 1000), viewport: 1000), -300, accuracy: 0.001)
    }

    func testLetGoSettlesOnTheCardTheFingersSpeedCarriesTo() {
        // Slowly, a quarter of the way, and still before lifting: back.
        var short = swipe()
        _ = move(&short, Array(repeating: -10, count: 10), every: 0.1)
        XCTAssertEqual(short.scrolled(.init(dx: 0, phase: .ended, time: 11.1)), .settle(index: 2, camera: 500, velocity: 0))
        // Slowly, past half way: the next card.
        var far = swipe()
        _ = move(&far, Array(repeating: -25, count: 10), every: 0.1)
        XCTAssertEqual(far.scrolled(.init(dx: 0, phase: .ended, time: 11.1)), .settle(index: 3, camera: 650, velocity: 0))
        // A flick, a quarter of the way at 1,000 points a second, read over
        // its last 0.08 s, the lift's own still moment included: carried on.
        var flick = swipe()
        _ = move(&flick, Array(repeating: -10, count: 10))
        guard case .settle(let index, let camera, let velocity) = flick.scrolled(.init(dx: 0, phase: .ended, time: 10.1)) else {
            return XCTFail("settles")
        }
        XCTAssertEqual(index, 3)
        XCTAssertEqual(camera, 500)
        XCTAssertEqual(velocity, 880, accuracy: 15)
    }

    func testACancelledSwipeGoesBackToItsCard() {
        var swipe = swipe()
        _ = move(&swipe, Array(repeating: -30, count: 10))
        XCTAssertEqual(swipe.scrolled(.init(dx: 0, phase: .cancelled, time: 10.1)), .settle(index: 2, camera: 700, velocity: 0))
    }

    func testCardsSharingTheStartSettleOnTheOneNearestTheFocus() {
        XCTAssertEqual(StripSwipe.stop(nearest: -50, in: stops, focus: 3), 1)
        XCTAssertEqual(StripSwipe.stop(nearest: 30, in: stops, focus: 0), 0)
        XCTAssertEqual(StripSwipe.stop(nearest: 950, in: stops, focus: 0), 4)
    }

    func testTheStripsMomentumIsSwallowedTheContentsPasses() {
        var strip = swipe()
        _ = move(&strip, [-20, -20])
        _ = strip.scrolled(.init(dx: 0, phase: .ended, time: 10.02))
        XCTAssertFalse(strip.holdsCamera)
        XCTAssertEqual(strip.scrolled(.init(dx: -30, phase: [], momentum: .began, time: 10.03)), .swallow)
        XCTAssertEqual(strip.scrolled(.init(dx: -20, phase: [], momentum: .changed, time: 10.04)), .swallow)
        XCTAssertEqual(strip.scrolled(.init(dx: -20, phase: [], time: 10.05)), .pass, "a mouse's wheel")
        var content = swipe((toStart: .can, toEnd: .can))
        _ = move(&content, [-20, -20])
        _ = content.scrolled(.init(dx: 0, phase: .ended, time: 10.02))
        XCTAssertEqual(content.scrolled(.init(dx: -30, phase: [], momentum: .began, time: 10.03)), .pass)
        // Let go before its end (the cards changed): the rest stays the strip's.
        var gone = swipe()
        _ = move(&gone, [-20])
        gone.letGo()
        XCTAssertFalse(gone.holdsCamera)
        XCTAssertEqual(gone.scrolled(.init(dx: -20, phase: .changed, time: 10.01)), .swallow)
        // Lifted before showing a way: the content's.
        var tap = swipe()
        _ = move(&tap, [-2])
        XCTAssertEqual(tap.scrolled(.init(dx: 0, phase: .ended, time: 10.01)), .pass)
        XCTAssertEqual(tap.scrolled(.init(dx: -30, phase: [], momentum: .began, time: 10.02)), .pass)
    }

    func testAFitFillsTheWindowAndComesBack() {
        let fitted = ColumnWidth.fitToggled(0.4, unfit: nil)
        XCTAssertEqual(fitted.fraction, 1)
        XCTAssertEqual(fitted.unfit, 0.4)
        let back = ColumnWidth.fitToggled(fitted.fraction, unfit: fitted.unfit)
        XCTAssertEqual(back.fraction, 0.4)
        XCTAssertNil(back.unfit)
        XCTAssertEqual(ColumnWidth.fitToggled(1, unfit: nil).fraction, 0.5, "filling the window from the start")
        XCTAssertEqual(ColumnWidth.fitToggled(0.9999, unfit: 0.3).fraction, 0.3)
    }
}
