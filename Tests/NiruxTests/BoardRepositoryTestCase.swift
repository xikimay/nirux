import XCTest
@testable import Nirux

class BoardRepositoryTestCase: XCTestCase {
    private static let templatePrefix = "nirux-board-template-\(UUID().uuidString)"
    private class var template: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("\(templatePrefix)-\(self)")
    }

    private(set) var root: String!

    override class func setUp() {
        super.setUp()
        do {
            try BoardConfigSuggestionsTests.makeRepository(at: template.path, remote: "https://github.com/acme/widgets.git")
        } catch {
            XCTFail("Could not build the board repository fixture: \(error)")
        }
    }

    override class func tearDown() {
        try? FileManager.default.removeItem(at: template)
        super.tearDown()
    }

    override func setUpWithError() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("nirux-board-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        root = try XCTUnwrap(base.path.realPath)
    }

    override func tearDown() {
        if let root { try? FileManager.default.removeItem(atPath: root) }
        super.tearDown()
    }

    func makeRepository(at path: String, remote: String?) throws {
        try FileManager.default.copyItem(atPath: Self.template.path, toPath: path)
        if let remote {
            try BoardConfigSuggestionsTests.git(["remote", "set-url", "origin", remote], at: path)
        } else {
            try BoardConfigSuggestionsTests.git(["remote", "remove", "origin"], at: path)
        }
    }
}
