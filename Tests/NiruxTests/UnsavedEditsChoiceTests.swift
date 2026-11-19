import AppKit
import XCTest
@testable import Nirux

final class UnsavedEditsChoiceTests: XCTestCase {
    /// Files of the same name show their folders: the question about them
    /// would read alike.
    @MainActor
    func testFilesOfTheSameNameShowTheirFolders() {
        let lost = "have changes that are lost if you don’t save them."
        XCTAssertEqual(
            UnsavedEditsChoice.alert(for: ["/w/repo.feat-a/README.md", "/w/repo.feat-b/README.md"]).informativeText,
            "“repo.feat-a/README.md”, “repo.feat-b/README.md” \(lost)"
        )
        XCTAssertEqual(UnsavedEditsChoice.alert(for: ["/w/a/x.swift", "/w/b/y.swift"]).informativeText, "“x.swift”, “y.swift” \(lost)")
    }
}
