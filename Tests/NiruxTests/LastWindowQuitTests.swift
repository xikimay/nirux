import AppKit
import XCTest
@testable import Nirux

/// AppKit asks whether to quit once no window is on screen. A hidden app has
/// none, so any panel closing while it is hidden asks too.
final class LastWindowQuitTests: XCTestCase {
    /// Hidden (⌘H), a panel closing doesn't quit Nirux; shown, closing its
    /// window does.
    @MainActor
    func testOnlyClosingTheShownWindowQuits() {
        let app = NSApplication.shared
        let question = LastWindowQuestion(nirux: NiruxApp())
        let previousDelegate = app.delegate
        app.delegate = question
        defer { app.delegate = previousDelegate }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 200), styleMask: [.titled, .closable], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 100, height: 60), styleMask: [.titled], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        whileTheAppRuns {
            window.orderFront(nil)
            panel.orderFront(nil)
            waitUntil("both windows on screen") { window.isVisible && panel.isVisible }
            app.hide(nil)
            waitUntil("the app hidden") { app.isHidden }
            panel.close()
            waitUntil("AppKit's question after the panel closed") { question.answers.count == 1 }
            app.unhideWithoutActivation()
            waitUntil("the window back on screen") { !app.isHidden && window.isVisible }
            window.close()
            waitUntil("AppKit's question after the window closed") { question.answers.count == 2 }
        }
        XCTAssertEqual(question.answers, [false, true])
    }

    /// AppKit asks only while the app runs, which an xctest process doesn't.
    @MainActor
    private func whileTheAppRuns(_ body: @escaping @MainActor () -> Void) {
        let app = NSApplication.shared
        Timer.scheduledTimer(withTimeInterval: 0, repeats: false) { _ in
            MainActor.assumeIsolated {
                body()
                app.stop(nil)
                // The run ends after its next event.
                let event = NSEvent.otherEvent(
                    with: .applicationDefined, location: .zero, modifierFlags: [], timestamp: 0,
                    windowNumber: 0, context: nil, subtype: 0, data1: 0, data2: 0
                )
                event.map { app.postEvent($0, atStart: false) }
            }
        }
        app.run()
    }
}

/// Hands AppKit's question to Nirux and keeps its answers, answering no
/// itself: a yes would quit the test process.
@MainActor
private final class LastWindowQuestion: NSObject, NSApplicationDelegate {
    let nirux: NiruxApp
    private(set) var answers: [Bool] = []

    init(nirux: NiruxApp) {
        self.nirux = nirux
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        answers.append(nirux.applicationShouldTerminateAfterLastWindowClosed(sender))
        return false
    }
}
