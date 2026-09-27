import XCTest
@testable import Nirux

/// The installer adds StopFailure only for a claude known to have it, so
/// the version must come from the install itself, never a guess.
final class ClaudeCodeVersionTests: XCTestCase {
    private var root: URL!

    override func setUp() {
        super.setUp()
        root = FileManager.default.temporaryDirectory.appendingPathComponent("nirux-claude-version-\(UUID().uuidString)")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
        super.tearDown()
    }

    @discardableResult
    private func file(_ relative: String, _ contents: String = "#!/bin/sh\n") throws -> String {
        let url = root.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url.path
    }

    private func link(_ relative: String, to destination: String) throws -> String {
        let url = root.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: url.path, withDestinationPath: destination)
        return url.path
    }

    private func manifest(name: String = "@anthropic-ai/claude-code", version: String) -> String {
        #"{"name": "\#(name)", "version": "\#(version)"}"#
    }

    func testParsingAndOrder() {
        XCTAssertEqual(ClaudeCodeVersion("2.1.283")?.description, "2.1.283")
        XCTAssertEqual(ClaudeCodeVersion("2.1.90-beta.1"), ClaudeCodeVersion("2.1.90"))
        for invalid in ["", "2.1", "2.1.x", "2.1.3.4", "v2.1.3", "2..3", "２.1.3"] {
            XCTAssertNil(ClaudeCodeVersion(invalid), invalid)
        }
        let minimum = ClaudeCodeVersion(major: 2, minor: 1, patch: 78)
        XCTAssertLessThan(ClaudeCodeVersion("2.1.77")!, minimum)
        XCTAssertLessThan(ClaudeCodeVersion("2.0.999")!, minimum)
        XCTAssertGreaterThanOrEqual(ClaudeCodeVersion("2.1.78")!, minimum)
        XCTAssertGreaterThan(ClaudeCodeVersion("2.1.101")!, minimum, "numeric, not lexical")
        XCTAssertGreaterThan(ClaudeCodeVersion("3.0.0")!, minimum)
    }

    func testNativeInstallerLink() throws {
        let binary = try file(".local/share/claude/versions/2.1.283")
        let claude = try link(".local/bin/claude", to: binary)
        XCTAssertEqual(ClaudeCodeVersion.installed(at: claude), ClaudeCodeVersion("2.1.283"))
    }

    func testHomebrewCask() throws {
        let claude = try file("opt/homebrew/Caskroom/claude-code/2.1.120/claude")
        XCTAssertEqual(ClaudeCodeVersion.installed(at: claude), ClaudeCodeVersion("2.1.120"))
    }

    func testNpmPackageLink() throws {
        try file("lib/node_modules/@anthropic-ai/claude-code/package.json", manifest(version: "2.1.79"))
        let cli = try file("lib/node_modules/@anthropic-ai/claude-code/cli.js")
        let claude = try link("bin/claude", to: cli)
        XCTAssertEqual(ClaudeCodeVersion.installed(at: claude), ClaudeCodeVersion("2.1.79"))
    }

    func testOlderLocalInstallScript() throws {
        try file(".claude/local/node_modules/@anthropic-ai/claude-code/package.json", manifest(version: "1.0.51"))
        let claude = try file(".claude/local/claude", "#!/bin/bash\nexec node_modules/.bin/claude \"$@\"\n")
        XCTAssertEqual(ClaudeCodeVersion.installed(at: claude), ClaudeCodeVersion("1.0.51"))
    }

    func testUnknownLayoutsReadAsUnknown() throws {
        XCTAssertNil(ClaudeCodeVersion.installed(at: try file("shims/claude")), "a shim says nothing")
        // Someone else's package.json next to a wrapper is not Claude's.
        try file("tools/package.json", manifest(name: "my-wrapper", version: "9.9.9"))
        XCTAssertNil(ClaudeCodeVersion.installed(at: try file("tools/claude")))
        // A folder named like a version, but not the native installer's.
        XCTAssertNil(ClaudeCodeVersion.installed(at: try file("stuff/versions/2.1.283")))
        XCTAssertNil(ClaudeCodeVersion.installed(at: root.appendingPathComponent("missing/claude").path))
    }
}
