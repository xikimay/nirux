import XCTest
@testable import Nirux

final class OpenEditorRequestTests: XCTestCase {

    /// Hermetic parse: identity canonicalization (no real-FS symlink
    /// resolution) and an injected existence set.
    private func parse(
        _ url: String,
        existing: Set<String> = ["/tmp/a.swift"]
    ) -> OpenEditorRequest? {
        guard let components = URLComponents(string: url) else {
            XCTFail("unparseable URL: \(url)")
            return nil
        }
        return OpenEditorRequest(
            queryItems: components.queryItems,
            canonicalize: { $0 },
            isOpenableFile: { existing.contains($0) }
        )
    }

    // MARK: - File validation

    func testValidAbsolutePath() {
        let request = parse("nirux://open-editor?file=/tmp/a.swift")
        XCTAssertEqual(request?.file, "/tmp/a.swift")
        XCTAssertNil(request?.line)
        XCTAssertNil(request?.endLine)
        XCTAssertNil(request?.workspaceID)
    }

    func testMissingFileReturnsNil() {
        XCTAssertNil(parse("nirux://open-editor?line=3"))
        XCTAssertNil(parse("nirux://open-editor"))
    }

    func testRelativePathReturnsNil() {
        XCTAssertNil(parse("nirux://open-editor?file=a.swift"))
        XCTAssertNil(parse("nirux://open-editor?file=tmp/a.swift"))
    }

    func testNonexistentFileReturnsNil() {
        XCTAssertNil(parse("nirux://open-editor?file=/tmp/missing.swift"))
    }

    func testDotSegmentsAreStandardized() {
        let request = parse("nirux://open-editor?file=/tmp/sub/../a.swift")
        XCTAssertEqual(request?.file, "/tmp/a.swift")
        XCTAssertEqual(parse("nirux://open-editor?file=/tmp//./a.swift")?.file, "/tmp/a.swift")
        XCTAssertEqual(parse("nirux://open-editor?file=/tmp/a.swift/")?.file, "/tmp/a.swift")
    }

    func testPrivatePrefixIsPreserved() {
        // standardizingPath would strip "/private" and manufacture a second
        // tab spelling for files already open as /private/tmp/... — the
        // normalization must not do that.
        let request = parse(
            "nirux://open-editor?file=/private/tmp/a.swift",
            existing: ["/private/tmp/a.swift"]
        )
        XCTAssertEqual(request?.file, "/private/tmp/a.swift")
    }

    func testURLEncodedPathDecodes() {
        let request = parse(
            "nirux://open-editor?file=/tmp/with%20space.swift",
            existing: ["/tmp/with space.swift"]
        )
        XCTAssertEqual(request?.file, "/tmp/with space.swift")
    }

    // MARK: - Line parsing

    func testLineAndEndLine() {
        let request = parse("nirux://open-editor?file=/tmp/a.swift&line=42&endLine=57")
        XCTAssertEqual(request?.line, 42)
        XCTAssertEqual(request?.endLine, 57)
    }

    func testInvertedRangeIsReversed() {
        let request = parse("nirux://open-editor?file=/tmp/a.swift&line=57&endLine=42")
        XCTAssertEqual(request?.line, 42)
        XCTAssertEqual(request?.endLine, 57)
    }

    func testEndLineWithoutLineIsDropped() {
        let request = parse("nirux://open-editor?file=/tmp/a.swift&endLine=57")
        XCTAssertNil(request?.line)
        XCTAssertNil(request?.endLine)
    }

    func testNonNumericLineIsDropped() {
        let request = parse("nirux://open-editor?file=/tmp/a.swift&line=abc")
        XCTAssertNotNil(request)
        XCTAssertNil(request?.line)
    }

    func testOutOfRangeLinesAreDropped() {
        for bad in ["0", "-5", "99999999999"] {
            let request = parse("nirux://open-editor?file=/tmp/a.swift&line=\(bad)")
            XCTAssertNotNil(request, "request must survive with line=\(bad) dropped")
            XCTAssertNil(request?.line)
        }
    }

    func testCapDroppedEndLineKeepsLine() {
        let request = parse("nirux://open-editor?file=/tmp/a.swift&line=10&endLine=99999999999")
        XCTAssertEqual(request?.line, 10)
        XCTAssertNil(request?.endLine)
    }

    // MARK: - Workspace

    func testWorkspaceID() {
        let request = parse("nirux://open-editor?file=/tmp/a.swift&workspace=ws-123")
        XCTAssertEqual(request?.workspaceID, "ws-123")
    }

    func testEmptyWorkspaceIsNil() {
        let request = parse("nirux://open-editor?file=/tmp/a.swift&workspace=")
        XCTAssertNil(request?.workspaceID)
    }

    // MARK: - Real filesystem check

    func testFileExistsOnDiskAcceptsRegularFilesOnly() throws {
        let dir = NSTemporaryDirectory() + "open-editor-tests-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }

        let regular = dir + "/regular.txt"
        FileManager.default.createFile(atPath: regular, contents: Data("hi".utf8))
        XCTAssertTrue(OpenEditorRequest.fileExistsOnDisk(regular))

        XCTAssertFalse(OpenEditorRequest.fileExistsOnDisk(dir), "directories must be rejected")
        XCTAssertFalse(OpenEditorRequest.fileExistsOnDisk(dir + "/missing.txt"))

        // A FIFO would hang EditorColumn's synchronous main-thread read.
        let fifo = dir + "/fifo"
        guard mkfifo(fifo, 0o644) == 0 else { return XCTFail("mkfifo failed") }
        XCTAssertFalse(OpenEditorRequest.fileExistsOnDisk(fifo))

        let linkToFifo = dir + "/link-to-fifo"
        try FileManager.default.createSymbolicLink(atPath: linkToFifo, withDestinationPath: fifo)
        XCTAssertFalse(OpenEditorRequest.fileExistsOnDisk(linkToFifo), "symlinked FIFO must be rejected")

        let linkToRegular = dir + "/link-to-regular"
        try FileManager.default.createSymbolicLink(atPath: linkToRegular, withDestinationPath: regular)
        XCTAssertTrue(OpenEditorRequest.fileExistsOnDisk(linkToRegular))

        XCTAssertFalse(OpenEditorRequest.fileExistsOnDisk("/dev/zero"), "device nodes must be rejected")

        // URL opens are non-interactive, so oversized files are refused
        // instead of confirmed via dialog. Non-NUL content so this stays a
        // pure size test (NUL bytes would trip the binary sniff too).
        let big = dir + "/big.txt"
        FileManager.default.createFile(
            atPath: big, contents: Data(repeating: 0x61, count: Int(OpenEditorRequest.maxFileBytes) + 1)
        )
        XCTAssertFalse(OpenEditorRequest.fileExistsOnDisk(big), "oversized files must be rejected")
    }

    func testFileExistsOnDiskRejectsBinaries() throws {
        let dir = NSTemporaryDirectory() + "open-editor-tests-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }

        // A binary would fail EditorColumn's decode and leave a silently
        // empty editor column behind on a non-interactive open.
        let binary = dir + "/image.png"
        FileManager.default.createFile(atPath: binary, contents: Data([0x89, 0x50, 0x4E, 0x47, 0x00, 0x01]))
        XCTAssertFalse(OpenEditorRequest.fileExistsOnDisk(binary), "NUL-bearing files must be rejected")

        // UTF-16 text is full of NULs but decodable — the BOM exempts it.
        let utf16 = dir + "/utf16.txt"
        try "hello".data(using: .utf16)!.write(to: URL(fileURLWithPath: utf16))
        XCTAssertTrue(OpenEditorRequest.fileExistsOnDisk(utf16), "BOM'd UTF-16 must be accepted")
    }

    func testDefaultCanonicalizationResolvesSymlinkSpellings() throws {
        let dir = NSTemporaryDirectory() + "open-editor-tests-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: dir + "/real", withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }

        let real = dir + "/real/a.swift"
        FileManager.default.createFile(atPath: real, contents: Data("x".utf8))
        try FileManager.default.createSymbolicLink(atPath: dir + "/link", withDestinationPath: dir + "/real")

        // Default canonicalize + default FS check: a symlinked spelling
        // must land on the resolved path, so tab identity can't fork into
        // two divergent buffers for one inode.
        guard let components = URLComponents(string: "nirux://open-editor")
        else { return XCTFail("components") }
        var items = components.queryItems ?? []
        items.append(URLQueryItem(name: "file", value: dir + "/link/a.swift"))
        let request = OpenEditorRequest(queryItems: items)
        XCTAssertEqual(request?.file, (real as NSString).resolvingSymlinksInPath)
    }
}
