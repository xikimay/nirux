import AppKit
import XCTest
@testable import Nirux

/// The window's one toast: over the column dots, centered on the viewport,
/// replaced by the next one, gone after its time.
@MainActor
final class ToastTests: XCTestCase {
    func testToastShowsOverTheColumnDotsIsReplacedAndGoesAway() throws {
        try UIFlowHarness.run { harness in
            let shell = harness.shell
            shell.addColumn()
            shell.showToast("First")
            let toast = try XCTUnwrap(shell.toast)
            XCTAssertEqual(toast.message, "First")
            XCTAssertTrue(shell.subviews.last === toast, "above the columns")
            XCTAssertEqual(toast.frame.minY, shell.columnIndicator.frame.maxY + ToastView.bottomGap)
            XCTAssertEqual(toast.frame.midX, shell.viewport.frame.midX, accuracy: 1)
            XCTAssertNil(toast.hitTest(NSPoint(x: toast.frame.midX, y: toast.frame.midY)), "clicks go through")

            shell.presentToast("Second", tone: .error, duration: 0.1)
            XCTAssertTrue(shell.toast === toast, "one toast at a time")
            XCTAssertEqual(toast.message, "Second")
            XCTAssertEqual(toast.tone, .error)
            harness.waitUntil("the toast to go away", timeout: 5) { shell.toast == nil }
            XCTAssertNil(toast.superview)
        }
    }

    /// A key or click puts it away, not in its first half second (it may
    /// have come unasked under a key on its way), and keys typed while it
    /// fades don't hold it on screen.
    func testInputPutsTheToastAwayAfterItsGraceAndKeysDontHoldIt() throws {
        try UIFlowHarness.run { harness in
            let shell = harness.shell
            shell.showToast("Unasked")
            let toast = try XCTUnwrap(shell.toast)
            shell.dismissToastOnInput()
            XCTAssertEqual(toast.alphaValue, 1, "still in its grace")

            shell.toastShownAt -= NiruxShellView.toastInputGrace + 0.01
            shell.dismissToastOnInput()
            XCTAssertEqual(toast.alphaValue, 0)
            // Typing on, faster than the fade; ends as soon as it's gone.
            let typingEnds = Date().addingTimeInterval(2)
            while Date() < typingEnds, shell.toast != nil {
                shell.dismissToastOnInput()
                RunLoop.main.run(until: Date().addingTimeInterval(0.03))
            }
            XCTAssertNil(shell.toast, "gone while the keys kept coming")
        }
    }

    /// Shown while the last one fades out: that one comes back, and stays.
    func testToastShownDuringTheFadeOutStays() throws {
        try UIFlowHarness.run { harness in
            let shell = harness.shell
            shell.showToast("First")
            let toast = try XCTUnwrap(shell.toast)
            shell.dismissToast()
            XCTAssertEqual(toast.alphaValue, 0)
            shell.showToast("Second")
            XCTAssertTrue(shell.toast === toast)
            XCTAssertEqual(toast.alphaValue, 1)
            RunLoop.main.run(until: Date().addingTimeInterval(ToastView.fadeDuration * 3))
            XCTAssertTrue(shell.toast === toast && toast.superview === shell, "the fade-out's removal no longer applies")
            XCTAssertEqual(toast.alphaValue, 1)
        }
    }
}
