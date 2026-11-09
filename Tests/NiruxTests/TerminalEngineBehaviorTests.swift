import AppKit
import GhosttyTerminal
import XCTest
@testable import Nirux

/// What libghostty-spm 2.2 changed and Nirux keeps as it was with 1.3.1:
/// unsafe pastes go through, programs don't read the clipboard (OSC 52),
/// drops on a terminal reach Nirux's drop view. (Copy on select is in
/// Nirux's config, see TerminalConfigBuilderTests.)
@MainActor
final class TerminalEngineBehaviorTests: XCTestCase {
    private final class Writes: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()
        func append(_ chunk: Data) { lock.lock(); data.append(chunk); lock.unlock() }
        var text: String { lock.lock(); defer { lock.unlock() }; return String(decoding: data, as: UTF8.self) }
    }

    func testAnUnsafePasteGoesThroughAndProgramsDontReadTheClipboard() throws {
        _ = NSApplication.shared
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let writes = Writes()
        let session = InMemoryTerminalSession(write: { writes.append($0) }, resize: { _ in })
        // The column answers the terminal's confirmations; no shell runs in it.
        let column = ColumnState(
            cwd: "/tmp",
            deferredAgent: DeferredAgentLaunch(agent: .claude(resume: .session("s1"), mode: .default), title: nil, lastStatus: nil)
        )
        let terminal = TerminalView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        terminal.controller = TerminalAppearance.makeController()
        terminal.configuration = TerminalSurfaceOptions(backend: .inMemory(session), workingDirectory: "/tmp")
        terminal.delegate = column
        window.contentView?.addSubview(terminal)
        window.orderFront(nil)
        UIFlowHarness.waitUntil("the surface") { session.readViewportText() != nil }

        let pasteboard = NSPasteboard.general
        let saved = pasteboard.string(forType: .string)
        defer {
            pasteboard.clearContents()
            if let saved { pasteboard.setString(saved, forType: .string) }
        }
        pasteboard.clearContents()
        pasteboard.setString("first pasted line\nsecond pasted line", forType: .string)

        // Several lines with bracketed paste off: Ghostty asks first.
        XCTAssertTrue(terminal.performBindingAction("paste_from_clipboard"))
        UIFlowHarness.waitUntil("the paste in the PTY") { writes.text.contains("second pasted line") }

        // A program asking for the clipboard gets no answer.
        session.receive("\u{1b}]52;c;?\u{07}")
        RunLoop.main.run(until: Date().addingTimeInterval(1))
        XCTAssertFalse(writes.text.contains("\u{1b}]52;"), writes.text)
    }

    func testDropsOnATerminalReachNiruxsDropView() throws {
        let column = ColumnState(
            cwd: "/tmp",
            deferredAgent: DeferredAgentLaunch(agent: .claude(resume: .session("s1"), mode: .default), title: nil, lastStatus: nil)
        )
        let terminal = try XCTUnwrap(column.terminalView)
        XCTAssertEqual(terminal.registeredDraggedTypes, [])
        XCTAssertTrue(column.view.registeredDraggedTypes.contains(.fileURL))
    }
}
