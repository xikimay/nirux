import XCTest
@testable import Nirux

final class GhosttyConfigFileTests: XCTestCase {

    // MARK: - Parsing

    func testParseSkipsBlankLinesAndComments() {
        let entries = GhosttyConfigFile.parse("# comment\n\n   \n  # indented comment\nfont-size = 13\n", source: "c")
        XCTAssertEqual(entries.map(\.key), ["font-size"])
        XCTAssertEqual(entries.first?.lineNumber, 5)
    }

    func testParseTrimsAndKeepsTheLineVerbatim() {
        let entry = GhosttyConfigFile.parse("\t font-family =   JetBrains Mono  \r", source: "c").first
        XCTAssertEqual(entry?.key, "font-family")
        XCTAssertEqual(entry?.value, "JetBrains Mono")
        XCTAssertEqual(entry?.line, "font-family =   JetBrains Mono")
    }

    func testParseStripsOnePairOfQuotes() {
        let entries = GhosttyConfigFile.parse("font-family = \"Fira Code\"\nfont-family = \"\"\n", source: "c")
        XCTAssertEqual(entries.map(\.value), ["Fira Code", ""])
    }

    func testParseSplitsOnTheFirstEquals() {
        let entry = GhosttyConfigFile.parse("keybind = cmd+t=new_tab", source: "c").first
        XCTAssertEqual(entry?.key, "keybind")
        XCTAssertEqual(entry?.value, "cmd+t=new_tab")
    }

    func testParseBareKey() {
        let entry = GhosttyConfigFile.parse("font-thicken", source: "c").first
        XCTAssertEqual(entry?.key, "font-thicken")
        XCTAssertEqual(entry?.value, "")
        XCTAssertEqual(entry?.line, "font-thicken")
    }

    func testLineOverGhosttysBufferEndsTheFile() {
        let limit = GhosttyConfigFile.maxLineBytes
        let long = Data(("font-size = 12\r\n" + String(repeating: "x", count: limit + 1) + "\nfont-size = 20\n").utf8)
        XCTAssertEqual(GhosttyConfigFile.truncatedAtOverlongLine(long), Data("font-size = 12\r\n".utf8))

        let fits = Data((String(repeating: "x", count: limit) + "\nfont-size = 20").utf8)
        XCTAssertEqual(GhosttyConfigFile.truncatedAtOverlongLine(fits), fits)
        let lastLine = Data(("font-size = 20\n" + String(repeating: "x", count: limit + 1)).utf8)
        XCTAssertEqual(GhosttyConfigFile.truncatedAtOverlongLine(lastLine), Data("font-size = 20\n".utf8))
    }

    func testParseHandlesCRLF() {
        let entries = GhosttyConfigFile.parse("font-size = 13\r\nbackground = #000000\r\n", source: "c")
        XCTAssertEqual(entries.map(\.line), ["font-size = 13", "background = #000000"])
        XCTAssertEqual(entries.map(\.lineNumber), [1, 2])
    }

    // MARK: - Default paths

    func testDefaultPathsFollowGhosttyLoadOrder() {
        XCTAssertEqual(GhosttyConfigFile.defaultPaths(environment: [:], home: "/Users/me"), [
            "/Users/me/.config/ghostty/config",
            "/Users/me/.config/ghostty/config.ghostty",
            "/Users/me/Library/Application Support/com.mitchellh.ghostty/config",
            "/Users/me/Library/Application Support/com.mitchellh.ghostty/config.ghostty"
        ])
    }

    func testDefaultPathsHonorAbsoluteXDGConfigHome() {
        let paths = GhosttyConfigFile.defaultPaths(environment: ["XDG_CONFIG_HOME": "/xdg"], home: "/Users/me")
        XCTAssertEqual(paths.first, "/xdg/ghostty/config")
        let relative = GhosttyConfigFile.defaultPaths(environment: ["XDG_CONFIG_HOME": "xdg"], home: "/Users/me")
        XCTAssertEqual(relative.first, "/Users/me/.config/ghostty/config")
    }

    // MARK: - Loading

    private func load(_ files: [String: String], paths: [String]) -> [String] {
        GhosttyConfigFile.load(paths: paths, home: "/home") { files[$0] }.map(\.line)
    }

    func testLoadReadsExistingFilesInOrder() {
        let lines = load(
            ["/a/config": "font-size = 12", "/b/config.ghostty": "font-size = 13"],
            paths: ["/a/config", "/a/config.ghostty", "/b/config", "/b/config.ghostty"]
        )
        XCTAssertEqual(lines, ["font-size = 12", "font-size = 13"])
    }

    func testIncludesLoadAfterEveryDefaultFile() {
        let lines = load([
            "/a/config": "config-file = theme.conf\nfont-size = 12",
            "/a/theme.conf": "background = #000000",
            "/b/config": "font-size = 13"
        ], paths: ["/a/config", "/b/config"])
        XCTAssertEqual(lines, ["font-size = 12", "font-size = 13", "background = #000000"])
    }

    func testIncludePathsResolveRelativeToTheIncludingFile() {
        let lines = load([
            "/a/config": "config-file = sub/one.conf",
            "/a/sub/one.conf": "config-file = two.conf\nfont-size = 1",
            "/a/sub/two.conf": "font-size = 2"
        ], paths: ["/a/config"])
        XCTAssertEqual(lines, ["font-size = 1", "font-size = 2"])
    }

    func testIncludeSupportsOptionalMarkerQuotesAndHome() {
        let lines = load([
            "/a/config": "config-file = ?\"missing.conf\"\nconfig-file = \"~/extra.conf\"",
            "/home/extra.conf": "font-size = 3"
        ], paths: ["/a/config"])
        XCTAssertEqual(lines, ["font-size = 3"])
    }

    func testIncludeCyclesAreReadOnce() {
        let lines = load([
            "/a/config": "config-file = one.conf",
            "/a/one.conf": "config-file = two.conf\nfont-size = 1",
            "/a/two.conf": "config-file = one.conf\nfont-size = 2"
        ], paths: ["/a/config"])
        XCTAssertEqual(lines, ["font-size = 1", "font-size = 2"])
    }

    func testIncludeCanReReadADefaultFile() {
        // Ghostty's cycle check only tracks includes.
        let lines = load([
            "/a/config": "config-file = other.conf\nfont-size = 1",
            "/a/other.conf": "config-file = config\nfont-size = 2"
        ], paths: ["/a/config"])
        XCTAssertEqual(lines, ["font-size = 1", "font-size = 2", "font-size = 1"])
    }

    func testBareConfigFileKeyKeepsQueuedIncludes() {
        let lines = load([
            "/a/config": "config-file = one.conf\nconfig-file",
            "/a/one.conf": "font-size = 1"
        ], paths: ["/a/config"])
        XCTAssertEqual(lines, ["font-size = 1"])
    }

    func testIncludePathStripsQuotesAfterOptionalMarker() {
        XCTAssertEqual(
            GhosttyConfigFile.includePath("?\"extra config\"", relativeTo: "/a", home: "/home"),
            "/a/extra config"
        )
        XCTAssertNil(GhosttyConfigFile.includePath("?", relativeTo: "/a", home: "/home"))
    }

    func testEmptyConfigFileClearsQueuedIncludes() {
        let lines = load([
            "/a/config": "config-file = one.conf\nconfig-file =\nconfig-file = two.conf",
            "/a/one.conf": "font-size = 1",
            "/a/two.conf": "font-size = 2"
        ], paths: ["/a/config"])
        XCTAssertEqual(lines, ["font-size = 2"])
    }

    func testIncludeChainIsBounded() {
        var files: [String: String] = [:]
        for index in 0..<100 {
            files["/a/\(index)"] = "config-file = \(index + 1)\nfont-size = \(index)"
        }
        let lines = load(files, paths: ["/a/0"])
        XCTAssertEqual(lines.count, GhosttyConfigFile.maxFiles)
    }

    func testReadRegularFile() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("nirux-ghostty-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let file = dir.appendingPathComponent("config")
        // BOM, then a Latin-1 "é" in a comment: invalid UTF-8.
        try Data([0xEF, 0xBB, 0xBF] + Array("# caf".utf8) + [0xE9] + Array("\nfont-size = 20\n".utf8)).write(to: file)
        let entries = GhosttyConfigFile.parse(GhosttyConfigFile.readRegularFile(file.path) ?? "", source: "c")
        XCTAssertEqual(entries.map(\.line), ["font-size = 20"])

        // The limit counts raw bytes: invalid bytes that widen once
        // decoded don't end the file.
        let widening = dir.appendingPathComponent("widening")
        let invalid = [UInt8](repeating: 0xFF, count: GhosttyConfigFile.maxLineBytes - 2)
        try Data(Array("# ".utf8) + invalid + Array("\nfont-size = 21\n".utf8)).write(to: widening)
        let wide = GhosttyConfigFile.parse(GhosttyConfigFile.readRegularFile(widening.path) ?? "", source: "c")
        XCTAssertEqual(wide.map(\.line), ["font-size = 21"])

        let link = dir.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
        XCTAssertTrue(GhosttyConfigFile.isRegularFile(link.path))

        let fifo = dir.appendingPathComponent("fifo")
        XCTAssertEqual(mkfifo(fifo.path, 0o600), 0)
        XCTAssertFalse(GhosttyConfigFile.isRegularFile(fifo.path))
        XCTAssertNil(GhosttyConfigFile.readRegularFile(fifo.path))
        XCTAssertNil(GhosttyConfigFile.readRegularFile(dir.path))
        XCTAssertNil(GhosttyConfigFile.readRegularFile(dir.appendingPathComponent("missing").path))
    }
}
