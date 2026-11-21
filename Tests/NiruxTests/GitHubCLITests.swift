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
