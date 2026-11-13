import XCTest
@testable import Nirux

/// Which arguments still open the app once every command-line mode passed
/// on them (see LaunchArguments).
final class LaunchArgumentsTests: XCTestCase {
    private let executable = "/Applications/Nirux.app/Contents/MacOS/Nirux"

    private func decision(_ arguments: String...) -> LaunchArguments.Decision {
        LaunchArguments.decision(for: [executable] + arguments)
    }

    func testOnlyALaunchWithoutArgumentsOpensTheApp() {
        XCTAssertEqual(decision(), .launchApp)
    }

    func testAHelpArgumentPrintsTheUsage() {
        for argument in ["--help", "-help", "-h", "help"] {
            XCTAssertEqual(decision(argument), .help, argument)
        }
    }

    /// What agents tried, or could: none opens a second Nirux.
    func testAnyOtherArgumentIsRefused() {
        XCTAssertEqual(decision("start-task", "--description", "x"), .unknown("start-task"))
        XCTAssertEqual(decision("--task", "new"), .unknown("--task"))
        XCTAssertEqual(decision("--mision", "ask"), .unknown("--mision"))
        XCTAssertEqual(decision("--version"), .unknown("--version"))
        // A mode with an argument it doesn't take.
        XCTAssertEqual(decision("--check-terminal-runtime", "now"), .unknown("--check-terminal-runtime"))
        // Help only as the first argument: anything after a real one is no help.
        XCTAssertEqual(decision("open", "--help"), .unknown("open"))
    }

    /// The process serial number older macOS passed, and Cocoa's
    /// argument-domain defaults, still open the app.
    func testArgumentsMacOSAndCocoaAddStillOpenTheApp() {
        XCTAssertEqual(decision("-psn_0_12345"), .launchApp)
        XCTAssertEqual(decision("-AppleLanguages", "(fr)"), .launchApp)
        XCTAssertEqual(decision("-NSShowAllViews", "YES", "-psn_0_1"), .launchApp)
    }

    func testACocoaDefaultNeedsItsValueAndAKnownPrefix() {
        XCTAssertEqual(decision("-ApplePersistenceIgnoreState"), .unknown("-ApplePersistenceIgnoreState"))
        XCTAssertEqual(decision("-task", "x"), .unknown("-task"))
        XCTAssertEqual(decision("--NSShowAllViews", "YES"), .unknown("--NSShowAllViews"))
        // Its value can't smuggle an argument through: it is skipped, and
        // what follows is judged again.
        XCTAssertEqual(decision("-NSShowAllViews", "YES", "start-task"), .unknown("start-task"))
    }

    /// A hook a newer build installed, run by this build: it exits quietly
    /// instead of opening the app on every event.
    func testAHookThisBuildDoesntKnowIsIgnored() {
        XCTAssertEqual(decision("--hook"), .ignoredHook)
        XCTAssertEqual(decision("--hook", "gemini", "{}"), .ignoredHook)
    }
}
