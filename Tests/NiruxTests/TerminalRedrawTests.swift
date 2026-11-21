import XCTest
@testable import Nirux

/// The heavy redraw's Ctrl+L, which repaints a TUI in front.
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
}
