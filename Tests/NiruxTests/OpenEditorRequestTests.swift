import XCTest
@testable import Nirux

final class OpenEditorRequestTests: XCTestCase {

    private func parse(
        _ url: String,
        existing: Set<String> = ["/tmp/a.swift"]
    ) -> OpenEditorRequest? {
        guard let components = URLComponents(string: url) else {
            XCTFail("unparseable URL: \(url)")
            return nil
        }
        return OpenEditorRequest(queryItems: components.queryItems) { existing.contains($0) }
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
        // instead of confirmed via dialog.
        let big = dir + "/big.bin"
        FileManager.default.createFile(
            atPath: big, contents: Data(count: Int(OpenEditorRequest.maxFileBytes) + 1)
        )
        XCTAssertFalse(OpenEditorRequest.fileExistsOnDisk(big), "oversized files must be rejected")
    }
}
