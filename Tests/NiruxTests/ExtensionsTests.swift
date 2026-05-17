import XCTest
@testable import Nirux

final class ExtensionsTests: XCTestCase {

    // MARK: - String.abbreviatedPath

    func testShortPathPassesThroughUnchanged() {
        XCTAssertEqual("/usr/bin".abbreviatedPath(), "/usr/bin")
    }

    func testExactlyMaxComponentsPassesThrough() {
        XCTAssertEqual("/a/b/c".abbreviatedPath(maxComponents: 3), "/a/b/c")
    }

    func testMoreThanMaxComponentsUsesEllipsis() {
        XCTAssertEqual(
            "/a/b/c/d/e".abbreviatedPath(maxComponents: 3),
            "/.../c/d/e"
        )
    }

    func testHomeDirectoryPrefixReplacedWithTilde() {
        let home = NSHomeDirectory()
        XCTAssertEqual("\(home)/docs".abbreviatedPath(), "~/docs")
    }

    func testHomeRelativePathKeepsTildeBase() {
        let home = NSHomeDirectory()
        XCTAssertEqual(
            "\(home)/a/b/c/d/e".abbreviatedPath(maxComponents: 3),
            "~/.../c/d/e"
        )
    }

    func testCustomMaxComponents() {
        XCTAssertEqual(
            "/a/b/c/d/e".abbreviatedPath(maxComponents: 2),
            "/.../d/e"
        )
    }

    func testRootPath() {
        XCTAssertEqual("/".abbreviatedPath(), "/")
    }

    // MARK: - Collection[safe:]

    func testSafeSubscriptReturnsElementForValidIndex() {
        let xs = [10, 20, 30]
        XCTAssertEqual(xs[safe: 0], 10)
        XCTAssertEqual(xs[safe: 2], 30)
    }

    func testSafeSubscriptReturnsNilForOutOfBounds() {
        let xs = [10, 20, 30]
        XCTAssertNil(xs[safe: 3])
        XCTAssertNil(xs[safe: -1])
    }

    func testSafeSubscriptOnEmptyCollection() {
        let xs: [Int] = []
        XCTAssertNil(xs[safe: 0])
    }
}
