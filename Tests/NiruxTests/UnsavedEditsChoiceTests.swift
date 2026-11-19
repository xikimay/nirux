import AppKit
import XCTest
@testable import Nirux

final class UnsavedEditsChoiceTests: XCTestCase {
    /// Files of the same name show as many folders as tell them apart: the
    /// question about them would read alike.
    func testFilesOfTheSameNameShowTheirFolders() {
        XCTAssertEqual(
            UnsavedEditsChoice.labels(for: ["/w/a/Sources/README.md", "/w/b/Sources/README.md", "/w/a/main.swift"]),
            ["a/Sources/README.md", "b/Sources/README.md", "main.swift"]
        )
    }

    /// A file unsaved in several editors is said so: Save writes one only.
    @MainActor
    func testAFileUnsavedInSeveralEditorsIsSaidSo() {
        XCTAssertEqual(
            UnsavedEditsChoice.alert(for: ["/w/a.swift", "/w/b.swift"], shared: ["/w/b.swift"]).informativeText,
            "“a.swift”, “b.swift” have changes that are lost if you don’t save them. "
                + "“b.swift” is unsaved in several editors: Save writes one, and the others show the conflict."
        )
    }
}
