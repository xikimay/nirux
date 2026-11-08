import XCTest
@testable import Nirux

/// docs/projects.md, section 5: a repository's setup script, where it
/// lives, what is typed before the agent, and how its failure comes back.
final class SpaceSetupScriptTests: XCTestCase {
    private var stateDirectory: URL!

    override func setUpWithError() throws {
        stateDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("nirux-setup-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: stateDirectory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        if let stateDirectory { try? FileManager.default.removeItem(at: stateDirectory) }
        super.tearDown()
    }

    private let web = SpaceAnchor(kind: .gitRepository(commonDir: "/code/web/.git"), name: "web")
    private let otherWeb = SpaceAnchor(kind: .gitRepository(commonDir: "/elsewhere/web/.git"), name: "web")

    /// One file per repository, in the space's folder: two repositories
    /// with the same name don't share one, and a renamed one keeps its own.
    func testEachRepositoryHasItsOwnScriptInTheSpaceFolder() throws {
        let url = try XCTUnwrap(SpaceSetupScript.url(spaceID: "s", anchor: web, stateDirectory: stateDirectory))
        XCTAssertEqual(url.deletingLastPathComponent().path, stateDirectory.appendingPathComponent("projects/s/setup").path)
        XCTAssertTrue(url.lastPathComponent.hasPrefix("web-"), url.lastPathComponent)
        XCTAssertTrue(url.lastPathComponent.hasSuffix(".sh"))
        let other = try XCTUnwrap(SpaceSetupScript.url(spaceID: "s", anchor: otherWeb, stateDirectory: stateDirectory))
        XCTAssertNotEqual(url, other)

        try SpaceSetupScript.save("npm ci", to: url)
        var renamed = web
        renamed.name = "web-renamed"
        XCTAssertEqual(SpaceSetupScript.url(spaceID: "s", anchor: renamed, stateDirectory: stateDirectory), url)
        XCTAssertEqual(SpaceSetupScript.scriptToRun(spaceID: "s", anchor: renamed, stateDirectory: stateDirectory), url)
        XCTAssertNil(SpaceSetupScript.url(spaceID: "s", anchor: SpaceAnchor(kind: .unknown(.null), name: "x"), stateDirectory: stateDirectory))
        XCTAssertNil(SpaceSetupScript.url(spaceID: "../s", anchor: web, stateDirectory: stateDirectory))
    }

    /// Saved 0600 with a final newline; only comments removes it, and a
    /// script without commands never runs.
    func testOnlyAScriptWithCommandsIsKeptAndRun() throws {
        let url = try XCTUnwrap(SpaceSetupScript.url(spaceID: "s", anchor: web, stateDirectory: stateDirectory))
        XCTAssertNil(SpaceSetupScript.scriptToRun(spaceID: "s", anchor: web, stateDirectory: stateDirectory))
        XCTAssertFalse(SpaceSetupScript.hasCommands(SpaceSetupScript.template(anchorName: "web")))

        try SpaceSetupScript.save(SpaceSetupScript.template(anchorName: "web") + "npm ci", to: url)
        XCTAssertEqual(SpaceSetupScript.read(at: url), SpaceSetupScript.template(anchorName: "web") + "npm ci\n")
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int, 0o600)
        XCTAssertEqual(SpaceSetupScript.scriptToRun(spaceID: "s", anchor: web, stateDirectory: stateDirectory), url)

        try SpaceSetupScript.save("# nothing left\n\n   \n", to: url)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertNil(SpaceSetupScript.scriptToRun(spaceID: "s", anchor: web, stateDirectory: stateDirectory))
    }

    /// `/bin/sh '<script>' || '<Nirux>' --hook codex --setup-failed '<id>';
    /// <agent>`: the agent starts whatever the script did.
    func testTheTypedLineRunsTheScriptThenTheAgent() {
        XCTAssertEqual(
            SpaceSetupScript.command(
                script: "/state/projects/s/setup/it's-1.sh", executable: "/Applications/Nirux.app/Contents/MacOS/Nirux",
                workspaceID: "W-1", then: "command claude --permission-mode plan"
            ),
            "/bin/sh '/state/projects/s/setup/it'\\''s-1.sh' || '/Applications/Nirux.app/Contents/MacOS/Nirux' "
                + "'--hook' 'codex' '--setup-failed' 'W-1'; command claude --permission-mode plan"
        )
        XCTAssertEqual(
            SpaceSetupScript.command(script: "/s.sh", executable: nil, workspaceID: "W-1", then: nil),
            "/bin/sh '/s.sh'"
        )
    }

    /// The typed line runs in the user's shell: the script fails, the
    /// report runs, then the agent command, in that order.
    func testAFailingScriptReportsThenTheAgentStillStarts() throws {
        let script = stateDirectory.appendingPathComponent("fail.sh")
        try "echo setup; exit 3\n".write(to: script, atomically: true, encoding: .utf8)
        let report = stateDirectory.appendingPathComponent("report.sh")
        try "#!/bin/sh\necho \"report $*\"\n".write(to: report, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: report.path)
        let line = SpaceSetupScript.command(script: script.path, executable: report.path, workspaceID: "W-1", then: "echo agent")
        for shell in ["/bin/zsh", "/bin/bash", "/bin/sh"] {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: shell)
            process.arguments = ["-c", line]
            let output = Pipe()
            process.standardOutput = output
            try process.run()
            process.waitUntilExit()
            let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            XCTAssertEqual(text, "setup\nreport --hook codex --setup-failed W-1\nagent\n", shell)
        }
    }

    /// Spelled as a hook for a rollback (an older Nirux reads a Codex
    /// payload and exits); anything else isn't the signal.
    func testOnlyTheExactSignalIsRecognized() {
        let nirux = "/Applications/Nirux.app/Contents/MacOS/Nirux"
        XCTAssertEqual(SetupFailureSignal.workspaceID(in: [nirux] + SetupFailureSignal.arguments(workspaceID: "ABC-123")), "ABC-123")
        XCTAssertEqual(AgentHookEvent.Kind(rawValue: SetupFailureSignal.arguments(workspaceID: "x")[1]), .codex)
        XCTAssertNil(SetupFailureSignal.workspaceID(in: [nirux, "--hook", "codex", "--setup-failed"]))
        XCTAssertNil(SetupFailureSignal.workspaceID(in: [nirux, "--hook", "codex", "--setup-failed", "ABC", "extra"]))
        XCTAssertNil(SetupFailureSignal.workspaceID(in: [nirux, "--hook", "claude", "--setup-failed", "ABC"]))
        XCTAssertNil(SetupFailureSignal.workspaceID(in: [nirux, "--hook", "codex", "--setup-failed", "../../x"]))
        XCTAssertNil(SetupFailureSignal.workspaceID(in: [nirux, "--hook", "codex", "--setup-failed", ""]))
    }
}
