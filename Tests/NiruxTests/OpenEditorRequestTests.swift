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
        XCTAssertNil(parse("nirux://open-editor?file=/tmp/a.swift&line=0")?.line)
        XCTAssertNil(parse("nirux://open-editor?file=/tmp/a.swift&line=-5")?.line)
        XCTAssertNil(parse("nirux://open-editor?file=/tmp/a.swift&line=99999999999")?.line)
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
}
