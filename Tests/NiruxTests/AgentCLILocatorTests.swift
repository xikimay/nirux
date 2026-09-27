import XCTest
@testable import Nirux

final class AgentCLILocatorTests: XCTestCase {
    private var root: URL!

    override func setUp() {
        super.setUp()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("nirux-cli-locator-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
        super.tearDown()
    }

    @discardableResult
    private func file(_ relative: String, executable: Bool = true) throws -> String {
        let url = root.appendingPathComponent(relative)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("#!/bin/sh\n".utf8).write(to: url)
        try FileManager.default.setAttributes(
            [.posixPermissions: executable ? 0o755 : 0o644], ofItemAtPath: url.path)
        return url.path
    }

    private func path(_ relative: String) -> String {
        root.appendingPathComponent(relative).path
    }

    func testFindsFirstExecutableOnPath() throws {
        try file("first/claude", executable: false)
        let expected = try file("second/claude")
        try file("third/claude")
        let directories = [path("missing"), path("first"), path("second"), path("third")]

        XCTAssertEqual(AgentCLILocator.executable(named: "claude", in: directories), expected)
        XCTAssertNil(AgentCLILocator.executable(named: "codex", in: directories))
    }

    func testIgnoresDirectoriesNamedLikeTheBinary() throws {
        try FileManager.default.createDirectory(
            atPath: path("bin/codex"), withIntermediateDirectories: true)
        XCTAssertNil(AgentCLILocator.executable(named: "codex", in: [path("bin")]))
    }

    func testFollowsSymlinksToExecutables() throws {
        let target = try file("lib/node_modules/@openai/codex/bin/codex.js")
        try FileManager.default.createDirectory(atPath: path("bin"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: path("bin/codex"), withDestinationPath: target)
        XCTAssertEqual(AgentCLILocator.executable(named: "codex", in: [path("bin")]), path("bin/codex"))

        try FileManager.default.createSymbolicLink(atPath: path("bin/claude"), withDestinationPath: path("nowhere"))
        XCTAssertNil(AgentCLILocator.executable(named: "claude", in: [path("bin")]))
    }

    func testSearchesPathBeforeUserInstallLocationsWithoutDuplicates() {
        let home = path("home")
        let directories = AgentCLILocator.searchDirectories(
            path: "/usr/bin::\(home)/.local/bin:/opt/homebrew/bin", home: home
        )
        XCTAssertEqual(Array(directories.prefix(3)), ["/usr/bin", "\(home)/.local/bin", "/opt/homebrew/bin"])
        XCTAssertEqual(directories.filter { $0 == "\(home)/.local/bin" }.count, 1)
        XCTAssertFalse(directories.contains(""))
        XCTAssertTrue(directories.contains("\(home)/.claude/local"))
        XCTAssertTrue(directories.contains("\(home)/.volta/bin"))
        XCTAssertEqual(
            AgentCLILocator.searchDirectories(path: "", home: home, systemDirectories: ["/nix/bin"]).last,
            "/nix/bin", "system-wide profiles come last"
        )
    }

    func testListsNodeVersionManagerBinsNewestFirst() throws {
        try file("home/.nvm/versions/node/v9.11.2/bin/node")
        try file("home/.nvm/versions/node/v22.3.0/bin/node")
        try file("home/.nvm/versions/node/v18.20.1/bin/node")
        try file("home/Library/Application Support/fnm/node-versions/v20.1.0/installation/bin/node")

        let directories = AgentCLILocator.userInstallDirectories(home: path("home"))
        let nvm = directories.filter { $0.contains("/.nvm/") }
        XCTAssertEqual(nvm, [
            path("home/.nvm/versions/node/v22.3.0/bin"),
            path("home/.nvm/versions/node/v18.20.1/bin"),
            path("home/.nvm/versions/node/v9.11.2/bin")
        ])
        XCTAssertTrue(directories.contains(
            path("home/Library/Application Support/fnm/node-versions/v20.1.0/installation/bin")
        ))
    }

    func testReadsTheNpmPrefixFromNpmrc() throws {
        let home = path("home")
        try FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: true)
        XCTAssertNil(AgentCLILocator.npmPrefix(home: home))

        for (line, expected) in [
            ("prefix=/opt/npm", "/opt/npm"),
            ("prefix = ~/.npm-packages", "\(home)/.npm-packages"),
            ("prefix=\"${HOME}/.npm\"", "\(home)/.npm"),
            ("prefix=relative/dir", nil),
            ("prefix=$HOMEBREW_PREFIX/npm", nil),
            ("prefix=/first\nprefix=/second", "/second")
        ] as [(String, String?)] {
            try "registry=https://registry.npmjs.org/\n\(line)\n".write(
                toFile: home + "/.npmrc", atomically: true, encoding: .utf8)
            XCTAssertEqual(AgentCLILocator.npmPrefix(home: home), expected, line)
        }

        let codex = try file("home/.npm-packages/bin/codex")
        try "prefix=~/.npm-packages\n".write(toFile: home + "/.npmrc", atomically: true, encoding: .utf8)
        XCTAssertEqual(AgentCLILocator.locate(path: "/usr/bin", home: home, systemDirectories: []).codexPath, codex)
    }

    func testLocatesMiseNodeInstalls() throws {
        let claude = try file("home/.local/share/mise/installs/node/22.3.0/bin/claude")
        XCTAssertEqual(AgentCLILocator.locate(path: "", home: path("home"), systemDirectories: []).claudePath, claude)
    }

    func testLocatesAgentsInstalledOutsideTheAppPath() throws {
        let claude = try file("home/.local/bin/claude")
        let codex = try file("home/.nvm/versions/node/v22.3.0/bin/codex")

        let found = AgentCLILocator.locate(path: "/usr/bin:/bin", home: path("home"), systemDirectories: [])
        XCTAssertEqual(found, AgentCLIAvailability(claudePath: claude, codexPath: codex))
        XCTAssertTrue(found.anyFound)
    }

    func testReportsNothingWhenNeitherIsInstalled() {
        let found = AgentCLILocator.locate(path: path("empty"), home: path("home"), systemDirectories: [])
        XCTAssertEqual(found, AgentCLIAvailability(claudePath: nil, codexPath: nil))
        XCTAssertFalse(found.anyFound)
    }
}
