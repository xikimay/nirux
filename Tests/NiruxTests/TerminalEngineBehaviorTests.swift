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

        // Several lines with bracketed paste off: Ghostty asks first. Not
        // through the system pasteboard, which other test classes running
        // alongside write.
        XCTAssertTrue(terminal.pasteWithProtection(text: "first pasted line\nsecond pasted line"))
        UIFlowHarness.waitUntil("the paste in the PTY") { writes.text.contains("second pasted line") }

        // A program asking for the clipboard gets an empty answer, whatever
        // the clipboard holds. Anything there will do, whoever wrote it.
        let pasteboard = NSPasteboard.general
        let wasEmpty = pasteboard.types?.isEmpty ?? true
        if wasEmpty {
            pasteboard.clearContents()
            pasteboard.setString("clipboard text", forType: .string)
        }
        defer { if wasEmpty { pasteboard.clearContents() } }
        session.receive("\u{1b}]52;c;?\u{07}")
        UIFlowHarness.waitUntil("the clipboard answer") { writes.text.contains("\u{1b}]52;c;") }
        let answer = writes.text.components(separatedBy: "\u{1b}]52;c;").last ?? ""
        XCTAssertTrue(answer.hasPrefix("\u{1b}\\") || answer.hasPrefix("\u{07}"), writes.text.debugDescription)
    }

    /// libghostty-spm sets GHOSTTY_RESOURCES_DIR in Nirux's own process.
    func testShellsDontInheritGhosttysResourcesFolder() throws {
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("nirux-ghostty-env-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        // A real shell runs on scratch state, like in every test that starts one.
        var previous: [String: String?] = [:]
        for (name, value) in ["GHOSTTY_RESOURCES_DIR": "/nowhere/Ghostty", "NIRUX_STATE_DIR": scratch.path] {
            previous[name] = ProcessInfo.processInfo.environment[name]
            setenv(name, value, 1)
        }
        defer {
            for (name, value) in previous {
                if let value { setenv(name, value, 1) } else { unsetenv(name) }
            }
        }
        let out = scratch.appendingPathComponent("env").path
        let shell = PtySession()
        shell.start(shell: "/bin/sh", args: ["-c", "printf '%s' \"${GHOSTTY_RESOURCES_DIR-unset}\" > '\(out)'"], cwd: scratch.path)
        UIFlowHarness.waitUntil("the shell's answer") { FileManager.default.fileExists(atPath: out) }
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        XCTAssertEqual(try String(contentsOfFile: out, encoding: .utf8), "unset")
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
