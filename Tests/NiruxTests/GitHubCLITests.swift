import XCTest
@testable import Nirux

/// `GitHub.CLI.run`, the one way every feature runs gh.
final class GitHubCLITests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("nirux-gh-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDown() {
        if let folder { try? FileManager.default.removeItem(at: folder) }
    }

    private func script(_ name: String, _ body: String, executable: Bool = true) throws -> String {
        let path = folder.appendingPathComponent(name).path
        try "#!/bin/sh\n\(body)\n".write(toFile: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: executable ? 0o755 : 0o644], ofItemAtPath: path)
        return path
    }

    func testGhIsFoundOnlyWhereItCanRun() throws {
        let plain = try script("plain", "exit 0", executable: false)
        let gh = try script("gh", "exit 0")
        XCTAssertEqual(GitHub.CLI.installedPath(among: [plain, gh]), gh)
        XCTAssertNil(GitHub.CLI.installedPath(among: [plain]))
    }

    /// A canary run's copy runs its run's own fake gh, never the user's; a
    /// normal launch, Homebrew's.
    func testACanaryRunUsesOnlyItsOwnFakeGh() {
        let state = folder.appendingPathComponent("state")
        let canary = ["NIRUX_STATE_DIR": state.path, CanaryChannel.tokenKey: String(repeating: "0123456789abcdef", count: 4)]
        XCTAssertEqual(GitHub.CLI.candidates(environment: [:], stateDirectory: state), ["/opt/homebrew/bin/gh", "/usr/local/bin/gh"])
        XCTAssertEqual(GitHub.CLI.candidates(environment: canary, stateDirectory: state), [folder.appendingPathComponent("agents/gh").path])
        XCTAssertEqual(GitHub.CLI.candidates(environment: ["NIRUX_STATE_DIR": state.path], stateDirectory: state),
                       ["/opt/homebrew/bin/gh", "/usr/local/bin/gh"], "a state folder without the token is a normal launch")
    }

    /// installedPath()'s default follows the launch: in a canary run, the
    /// run's fake gh.
    func testTheDefaultLookupFollowsTheLaunch() throws {
        let state = folder.appendingPathComponent("state", isDirectory: true)
        try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("agents"), withIntermediateDirectories: true)
        let fake = folder.appendingPathComponent("agents/gh").path
        try "#!/bin/sh\nexit 0\n".write(toFile: fake, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake)
        let saved = [CanaryChannel.tokenKey, "NIRUX_STATE_DIR"].map { ($0, ProcessInfo.processInfo.environment[$0]) }
        setenv("NIRUX_STATE_DIR", state.path, 1)
        setenv(CanaryChannel.tokenKey, String(repeating: "0123456789abcdef", count: 4), 1)
        defer {
            for (key, value) in saved {
                if let value { setenv(key, value, 1) } else { unsetenv(key) }
            }
        }
        XCTAssertEqual(GitHub.CLI.installedPath(), fake)
    }

    /// No colour or TTY forced, whatever the caller adds, from the call's
    /// folder: what Branch Review's runner, `GitHub.CLI.installed`, runs.
    func testGhRunsWithTheNeutralEnvironmentFromTheCallsFolder() throws {
        let gh = try script("gh", #"printf '%s %s %s %s\n' "NO_COLOR=$NO_COLOR" "CLICOLOR_FORCE=$CLICOLOR_FORCE" "EXTRA=$EXTRA" "$(pwd -P)""#)
        let checkout = try XCTUnwrap(folder.path.realPath)
        let output = try GitHub.CLI.run(
            .init(["pr", "list"], in: URL(fileURLWithPath: checkout)), gh: gh, environment: ["NO_COLOR": "0", "EXTRA": "kept"]
        ).get()
        XCTAssertEqual(String(decoding: output.standardOutput, as: UTF8.self), "NO_COLOR=1 CLICOLOR_FORCE=0 EXTRA=kept \(checkout)\n")
    }
}
