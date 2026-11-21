import Foundation
import NiruxCore
import Testing

struct PathAndCollectionTests {
    @Test func abbreviatedPathsKeepShortPathsAndTheRequestedSuffix() {
        #expect("/usr/bin".abbreviatedPath() == "/usr/bin")
        #expect("/a/b/c".abbreviatedPath(maxComponents: 3) == "/a/b/c")
        #expect("/a/b/c/d/e".abbreviatedPath(maxComponents: 3) == "/.../c/d/e")
        #expect("/a/b/c/d/e".abbreviatedPath(maxComponents: 2) == "/.../d/e")
        #expect("/".abbreviatedPath() == "/")
    }

    @Test func homePathsKeepTheirTildeWhenShortened() {
        let home = NSHomeDirectory()
        #expect("\(home)/docs".abbreviatedPath() == "~/docs")
        #expect("\(home)/a/b/c/d/e".abbreviatedPath(maxComponents: 3) == "~/.../c/d/e")
    }

    @Test func safeSubscriptRequiresAnExistingIndex() {
        let values = [10, 20, 30]
        #expect(values[safe: 0] == 10)
        #expect(values[safe: 2] == 30)
        #expect(values[safe: 3] == nil)
        #expect(values[safe: -1] == nil)
        let empty: [Int] = []
        #expect(empty[safe: 0] == nil)
    }
}
