import AppKit
import GhosttyTerminal
import XCTest
@testable import Nirux

/// Search Everywhere reads Ghostty's text by reflection on the pinned
/// libghostty-spm (TerminalScreenText): a version that moves what it
/// reaches fails here, where the app would quietly search the visible
/// rows only.
@MainActor
final class TerminalScreenTextTests: XCTestCase {
    func testReadsTheWholeScrollbackOffTheMainThread() async throws {
        _ = NSApplication.shared
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let session = InMemoryTerminalSession(write: { _ in }, resize: { _ in })
        let terminal = TerminalView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        terminal.controller = TerminalAppearance.makeController()
        terminal.configuration = TerminalSurfaceOptions(backend: .inMemory(session), workingDirectory: "/tmp")
        window.contentView?.addSubview(terminal)
        window.orderFront(nil)
        waitUntil { session.readViewportText() != nil }

        // Wider than the terminal: each line wraps.
        let lines = (1...300).map { "row \($0) " + String(repeating: "x", count: 120) }
        session.receive(lines.joined(separator: "\r\n"))
        waitUntil { session.readViewportText()?.contains("row 300 ") == true }
        XCTAssertFalse(session.readViewportText()?.contains("row 1 ") ?? true)

        let read = await Self.readOffMain(session)
        let text = try XCTUnwrap(read)
        XCTAssertEqual(text.split(separator: "\n").map(String.init), lines)
    }

    private nonisolated static func readOffMain(_ session: InMemoryTerminalSession) async -> String? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                continuation.resume(returning: TerminalScreenText.wholeScreen(session))
            }
        }
    }

    private func waitUntil(timeout: TimeInterval = 10, _ condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        XCTAssertTrue(condition(), "timed out")
    }
}
