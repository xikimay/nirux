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
}
