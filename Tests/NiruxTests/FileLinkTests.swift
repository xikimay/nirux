import XCTest
@testable import Nirux

final class FileLinkTests: XCTestCase {

    private func parse(_ url: String, existing: Set<String> = []) -> FileLink.Target? {
        guard let parsed = URL(string: url) else {
            XCTFail("unparseable URL: \(url)")
            return nil
        }
        return FileLink.parse(parsed) { existing.contains($0) }
    }

    // MARK: - Scheme gating

    func testNonFileSchemeReturnsNil() {
        XCTAssertNil(parse("https://example.com/a.swift"))
        XCTAssertNil(parse("mailto:a@b.c"))
    }

    func testPlainFileURL() {
        XCTAssertEqual(
            parse("file:///Users/me/a.swift"),
            FileLink.Target(path: "/Users/me/a.swift", line: nil)
        )
    }

    func testHostnameIsIgnored() {
        // Claude Code's OSC 8 links carry the local hostname.
        XCTAssertEqual(
            parse("file://mymac.local/Users/me/a.swift"),
            FileLink.Target(path: "/Users/me/a.swift", line: nil)
        )
    }

    func testPercentEncodedPathIsDecoded() {
        XCTAssertEqual(
            parse("file:///Users/me/some%20dir/a.swift"),
            FileLink.Target(path: "/Users/me/some dir/a.swift", line: nil)
        )
    }

    // MARK: - #L12 fragment

    func testFragmentLine() {
        XCTAssertEqual(
            parse("file:///Users/me/a.swift#L12"),
            FileLink.Target(path: "/Users/me/a.swift", line: 12)
        )
    }

    func testNonLineFragmentIsIgnored() {
        XCTAssertEqual(
            parse("file:///Users/me/a.swift#section"),
            FileLink.Target(path: "/Users/me/a.swift", line: nil)
        )
        XCTAssertEqual(
            parse("file:///Users/me/a.swift#12"),
            FileLink.Target(path: "/Users/me/a.swift", line: nil)
        )
    }

    func testZeroLineFragmentIsIgnored() {
        XCTAssertEqual(
            parse("file:///Users/me/a.swift#L0"),
            FileLink.Target(path: "/Users/me/a.swift", line: nil)
        )
    }

    // MARK: - :12 suffix

    func testColonSuffixWhenStrippedFileExists() {
        XCTAssertEqual(
            parse("file:///Users/me/a.swift:12", existing: ["/Users/me/a.swift"]),
            FileLink.Target(path: "/Users/me/a.swift", line: 12)
        )
    }

    func testColonSuffixKeptWhenFullPathExists() {
        // A real file whose name contains a colon wins over the line reading.
        XCTAssertEqual(
            parse(
                "file:///Users/me/a.swift:12",
                existing: ["/Users/me/a.swift:12", "/Users/me/a.swift"]
            ),
            FileLink.Target(path: "/Users/me/a.swift:12", line: nil)
        )
    }

    func testColonSuffixKeptWhenNeitherExists() {
        XCTAssertEqual(
            parse("file:///Users/me/a.swift:12"),
            FileLink.Target(path: "/Users/me/a.swift:12", line: nil)
        )
    }

    // MARK: - opensInEditor

    func testOpensInEditorDispositions() throws {
        let dir = NSTemporaryDirectory() + "filelink-tests-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }

        let text = dir + "/a.txt"
        try Data("hello\n".utf8).write(to: URL(fileURLWithPath: text))
        let binary = dir + "/a.bin"
        try Data([0x41, 0x00, 0x42]).write(to: URL(fileURLWithPath: binary))
        let utf16 = dir + "/a.utf16"
        try "héllo".data(using: .utf16)!.write(to: URL(fileURLWithPath: utf16))

        XCTAssertTrue(FileLink.opensInEditor(path: text))
        XCTAssertTrue(FileLink.opensInEditor(path: utf16), "UTF-16 BOM files are text")
        XCTAssertTrue(FileLink.opensInEditor(path: dir + "/missing.txt"), "editor surfaces the alert")
        XCTAssertFalse(FileLink.opensInEditor(path: binary))
        XCTAssertFalse(FileLink.opensInEditor(path: dir), "directories go to Finder")
    }

    func testNonNumericColonSuffixIsNotALine() {
        XCTAssertEqual(
            parse("file:///Users/me/a:b.swift", existing: ["/Users/me/a"]),
            FileLink.Target(path: "/Users/me/a:b.swift", line: nil)
        )
    }

    func testLineColumnSuffix() {
        // Compiler-style path:line:col — line wins, column is dropped.
        XCTAssertEqual(
            parse("file:///Users/me/a.swift:12:5", existing: ["/Users/me/a.swift"]),
            FileLink.Target(path: "/Users/me/a.swift", line: 12)
        )
    }

    func testRangeFragmentUsesFirstLine() {
        XCTAssertEqual(
            parse("file:///Users/me/a.swift#L12-L20"),
            FileLink.Target(path: "/Users/me/a.swift", line: 12)
        )
    }

    func testFragmentWinsOverColonSuffix() {
        XCTAssertEqual(
            parse("file:///Users/me/a.swift#L3", existing: ["/Users/me/a.swift"]),
            FileLink.Target(path: "/Users/me/a.swift", line: 3)
        )
    }
}
