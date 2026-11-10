import Foundation
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
    // Terminals keep vsync, as in the app: with no display active, Ghostty
    // builds their surfaces without the display link all the same.

    // Ghostty keeps the environment as it found it at its first terminal (a
    // slice of libc's `environ`, see `ghostty_init`) and reads it at every
    // later one: an entry removed since leaves a null in it, and a variable
    // added can move the array, either crashing the next terminal
    // (EXC_BAD_ACCESS in ghostty_config_finalize). Tests change the
    // environment all along (NIRUX_STATE_DIR, the flow harness's HOME). So
    // Ghostty takes its copy here, before any test: the variables the flow
    // harness clears go first, and the array gets room for the ones tests
    // add, so it never moves; a test that adds and removes its own variables
    // only touches entries past Ghostty's copy.
    let environment = ProcessInfo.processInfo.environment
    let cleared = ["ZDOTDIR", "XDG_CONFIG_HOME", "RIPGREP_CONFIG_PATH", "CLAUDE_CONFIG_DIR"]
        + environment.keys.filter { $0.hasPrefix("CLAUDE_CODE_") || $0.hasPrefix("GIT_") }
    cleared.forEach { unsetenv($0) }
    let room = (0..<64).map { "NIRUX_TESTS_ENVIRONMENT_ROOM_\($0)" }
    room.forEach { setenv($0, "", 1) }
    room.reversed().forEach { unsetenv($0) }
    MainActor.assumeIsolated { ghosttyRuntime = TerminalAppearance.makeController() }
}

/// Keeps Ghostty's first terminal app, created at load (see above).
@MainActor private var ghosttyRuntime: AnyObject?

@MainActor
final class TestBootstrapTests: XCTestCase {
    /// Without the bootstrap (its constructor left out of the link, say), a
    /// run on a locked Mac hangs again.
    func testTheBootstrapRan() {
        let arguments = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
        XCTAssertEqual(arguments[windowAnimationsKey] as? Bool, false)
        XCTAssertEqual(UserDefaults.standard.object(forKey: windowAnimationsKey) as? Bool, false, "a lookup misses it")
    }
}
