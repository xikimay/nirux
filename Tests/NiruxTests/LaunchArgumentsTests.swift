import XCTest
@testable import Nirux

/// What `Nirux` does with its arguments: `NiruxApp.main` runs exactly this
/// decision (see LaunchArguments).
final class LaunchArgumentsTests: XCTestCase {
    private let executable = "/Applications/Nirux.app/Contents/MacOS/Nirux"
    private let workspaceID = "2119EDC0-EC10-4717-929F-C7DBBB882717"

    private func decision(_ arguments: String...) -> LaunchArguments.Decision {
        LaunchArguments.decision(for: [executable] + arguments)
    }

    /// Every command line Nirux writes, or the nightly runs, reaches its mode.
    func testTheCommandLineModesComeFirst() {
        XCTAssertEqual(decision("--hook", "claude", "--statusline"), .mode(.statusLine))
        XCTAssertEqual(decision("--hook", "claude", "--mcp"), .mode(.toolsServer))
        XCTAssertEqual(decision("--hook", "codex", SetupFailureSignal.flag, workspaceID), .mode(.setupFailure(workspaceID: workspaceID)))
        XCTAssertEqual(decision("--hook", "claude"), .mode(.hook(.claude, payload: nil)))
        XCTAssertEqual(decision("--hook", "codex", "{}"), .mode(.hook(.codex, payload: "{}")))
        // The payload is the last argument, after any flag a newer build adds.
        XCTAssertEqual(decision("--hook", "codex", "--newer-flag", "{}"), .mode(.hook(.codex, payload: "{}")))
        XCTAssertEqual(decision("--mission", "ask", "--message", "x"), .mode(.mission(["ask", "--message", "x"])))
        XCTAssertEqual(decision("--mission"), .mode(.mission([])))
        XCTAssertEqual(decision("--check-terminal-runtime"), .mode(.checkTerminalRuntime))
        XCTAssertEqual(decision("--check-release-signature", "/tmp/Nirux.app"), .mode(.checkReleaseSignature(["/tmp/Nirux.app"])))
    }

    func testALaunchWithoutArgumentsOpensTheApp() {
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

    /// macOS reads any `-Key value` pair as a user default for the launch,
    /// Nirux's own escape hatch among them; older macOS added a process
    /// serial number.
    func testDefaultsPairsAndTheProcessSerialNumberStillOpenTheApp() {
        XCTAssertEqual(decision("-IgnoreGhosttyConfig", "YES"), .launchApp)
        XCTAssertEqual(decision("-AppleLanguages", "(fr)"), .launchApp)
        XCTAssertEqual(decision("-com.apple.CoreData.SQLDebug", "1", "-psn_0_1"), .launchApp)
        XCTAssertEqual(decision("-psn_0_12345"), .launchApp)
    }

    func testADefaultNeedsOneDashAKeyAndAValue() {
        XCTAssertEqual(decision("-IgnoreGhosttyConfig"), .unknown("-IgnoreGhosttyConfig"))
        XCTAssertEqual(decision("-", "YES"), .unknown("-"))
        XCTAssertEqual(decision("--NSShowAllViews", "YES"), .unknown("--NSShowAllViews"))
        // Its value can't smuggle an argument through: it is skipped, and
        // what follows is judged again.
        XCTAssertEqual(decision("-NSShowAllViews", "YES", "start-task"), .unknown("start-task"))
    }

    /// A hook a newer build installed, run by this build: it exits quietly
    /// instead of opening the app on every event, after reading the payload
    /// Claude Code writes, unless it is a stdio server.
    func testAHookThisBuildDoesntKnowIsIgnored() {
        XCTAssertEqual(decision("--hook"), .ignoredHook(readsInput: true))
        XCTAssertEqual(decision("--hook", "gemini", "{}"), .ignoredHook(readsInput: true))
        XCTAssertEqual(decision("--hook", "gemini", "--mcp"), .ignoredHook(readsInput: false))
    }
}
