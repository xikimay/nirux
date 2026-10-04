import Foundation
import GhosttyTerminal
import XCTest
@testable import Nirux

private let windowAnimationsKey = "NSAutomaticWindowAnimationsEnabled"

/// Settings the whole test process needs whatever the screen's state, made
/// as the bundle loads, before its first test (Tests/NiruxTestBootstrap).
@_cdecl("NiruxTestBootstrapDidLoad")
func testBundleDidLoad() {
    // With the display asleep (a locked Mac overnight), AppKit's window open
    // and close animations can stay stuck, each holding a GCD worker thread.
    // After about 70 of them GCD had no worker left: background work in the
    // tests timed out, then the first test awaiting a global queue or a
    // Swift task hung the run forever. The argument domain outranks every
    // saved preference and stays in memory.
    let defaults = UserDefaults.standard
    var arguments = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
    arguments[windowAnimationsKey] = false
    defaults.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)
    MainActor.assumeIsolated {
        // With no display active, Ghostty can't create the display link
        // vsync needs, so it creates no surface and terminal tests time out.
        // Off in every run, so a locked Mac runs what CI runs. The app keeps
        // vsync.
        TerminalAppearance.appendedLines = ["window-vsync = false"]
    }
}

@MainActor
final class TestBootstrapTests: XCTestCase {
    /// Without the bootstrap (its constructor left out of the link, say), a
    /// run on a locked Mac hangs again.
    func testTheBootstrapRan() {
        let arguments = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
        XCTAssertEqual(arguments[windowAnimationsKey] as? Bool, false)
        XCTAssertEqual(UserDefaults.standard.object(forKey: windowAnimationsKey) as? Bool, false, "a lookup misses it")
    }

    /// One line libghostty rejects and it drops the whole config, vsync
    /// setting included: a libghostty without this key would bring the
    /// locked-Mac timeouts back.
    func testTerminalsGetVsyncOff() {
        let controller = TerminalAppearance.makeController()
        XCTAssertNil(controller.lastConfigurationIssue)
        XCTAssertTrue(controller.renderedConfig.hasSuffix("window-vsync = false\n"), controller.renderedConfig)
    }
}
