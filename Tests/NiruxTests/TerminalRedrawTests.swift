import XCTest
@testable import Nirux

/// The heavy redraw's Ctrl+L, which repaints a TUI in front.
@MainActor
final class TerminalRedrawTests: XCTestCase {
    func testCtrlLGoesToTUIsOnly() {
        for name in ["vim", "htop"] {
            XCTAssertTrue(NiruxShellView.repaintsWithCtrlL(name), name)
        }
        // A shell, a login one's or one Nirux doesn't start too, needs none.
        for shell in ["zsh", "dash", "ksh", "nu", "csh", "-fish"] {
            XCTAssertFalse(NiruxShellView.repaintsWithCtrlL(shell), shell)
        }
        // Ctrl+L would clear an agent's session.
        for agent in CodingAgent.allCases {
            XCTAssertFalse(NiruxShellView.repaintsWithCtrlL(agent.rawValue), agent.rawValue)
        }
    }

    /// A program in line mode never reads the key: it would wait for the
    /// agent a launch step runs before, and be typed there.
    func testCtrlLGoesOnlyToAProgramReadingKeysAsTyped() throws {
        try UIFlowHarness.run { harness in
            let task = try XCTUnwrap(harness.shell.activeWorkspace)
            let vim = AgentStandIn(), codex = AgentStandIn()
            defer { vim.remove(); codex.remove() }
            let stepEnds = FileManager.default.temporaryDirectory.appendingPathComponent("nirux-launch-step-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: stepEnds) }
            task.addColumn(command: vim.command(named: "vim"), cwd: harness.repo)
            let tui = try XCTUnwrap(task.columns.last?.pty)
            let step = "/usr/bin/perl -e 'select(undef, undef, undef, 0.02) until -e $ARGV[0]' '\(stepEnds.path)'; "
            task.addColumn(command: step + codex.command(named: "codex"), cwd: harness.repo)
            let agent = try XCTUnwrap(task.columns.last?.pty)
            harness.waitUntil("vim, and the launch step before the codex") {
                let snapshot = ProcessSnapshot()
                return tui.foregroundProcessName(snapshot: snapshot) == "vim" && agent.foregroundProcessName(snapshot: snapshot) == "perl"
            }
            harness.shell.redrawAllTerminals()
            harness.waitUntil("vim repainted") { vim.input.contains("\u{0C}") }
            FileManager.default.createFile(atPath: stepEnds.path, contents: nil)
            harness.waitUntil("its codex") { agent.foregroundProcessName(snapshot: ProcessSnapshot()) == "codex" }
            agent.sendRaw("x")
            harness.waitUntil("a key typed since") { codex.input.hasSuffix("x") }
            XCTAssertEqual(codex.input, "x", "the redraw typed nothing into the codex")
        }
    }
}
