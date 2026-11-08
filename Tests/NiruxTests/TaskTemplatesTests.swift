import XCTest
@testable import Nirux

final class TaskTemplatesTests: XCTestCase {
    private var stateDirectory: URL!

    override func setUpWithError() throws {
        stateDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: stateDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: stateDirectory)
    }

    private func writeFile(_ text: String, spaceID: String = "space-1") throws -> URL {
        let url = try XCTUnwrap(TaskTemplates.fileURL(spaceID: spaceID, stateDirectory: stateDirectory))
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
        return url
    }

    func testDefaultsUntilTheFileExistsThenTheTemplateWritesThemOut() throws {
        XCTAssertEqual(TaskTemplates.load(spaceID: "space-1", stateDirectory: stateDirectory), TaskTemplates.defaults)
        XCTAssertEqual(TaskTemplates.defaults.map(\.name), ["Bugfix", "Feature (full review cycle)", "Investigation (no code)"])

        let url = try writeFile(TaskTemplates.template(spaceName: "Nirux"))
        XCTAssertEqual(url.path, stateDirectory.appendingPathComponent("projects/space-1/task-templates.md").path)
        // The comment explaining the file isn't a template.
        XCTAssertEqual(TaskTemplates.load(spaceID: "space-1", stateDirectory: stateDirectory), TaskTemplates.defaults)
    }

    func testAnEmptiedFileOffersNoTemplate() throws {
        _ = try writeFile("<!-- all gone -->\n")
        XCTAssertEqual(TaskTemplates.load(spaceID: "space-1", stateDirectory: stateDirectory), [])
    }

    func testAFileThatIsNotARegularFileOffersNoTemplate() throws {
        let url = try XCTUnwrap(TaskTemplates.fileURL(spaceID: "space-1", stateDirectory: stateDirectory))
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        XCTAssertEqual(TaskTemplates.load(spaceID: "space-1", stateDirectory: stateDirectory), [])
    }

    func testParseSplitsOnSecondLevelHeadingsOnly() {
        let text = """
        Text before the first section is ignored.

        # A title isn't a template
        ## Bugfix
        1. Reproduce.
        ### A sub-heading stays in the body

        ##Not a heading
        ##   Spaced name  \r
        Body.
        """
        XCTAssertEqual(TaskTemplates.parse(text), [
            TaskTemplates.Template(name: "Bugfix", body: "1. Reproduce.\n### A sub-heading stays in the body\n\n##Not a heading"),
            TaskTemplates.Template(name: "Spaced name", body: "Body.")
        ])
        // A section without a name is dropped.
        XCTAssertEqual(
            TaskTemplates.parse("## A\none\n## \t\ntwo"),
            [TaskTemplates.Template(name: "A", body: "one")]
        )
    }

    func testParseDropsCommentsAndKeepsHeadingsInsideCodeBlocks() {
        let text = """
        <!-- ## Commented out
        not a template -->
        ## Steps
        ```sh
        ## a shell comment, not a heading
        ```
        ~~~
        ## nor this
        ~~~
        Unclosed <!-- comment stays text
        ## Second
        Two.
        ## Steps
        A second "Steps" is ignored.
        """
        XCTAssertEqual(TaskTemplates.parse(text), [
            TaskTemplates.Template(
                name: "Steps",
                body: "```sh\n## a shell comment, not a heading\n```\n~~~\n## nor this\n~~~\nUnclosed <!-- comment stays text"
            ),
            TaskTemplates.Template(name: "Second", body: "Two.")
        ])
    }

    func testProjectNameCannotCloseTheTemplateComment() throws {
        let template = TaskTemplates.template(spaceName: "evil -->\n## Injected")
        XCTAssertTrue(template.contains("\n## Injected"))
        _ = try writeFile(template)
        XCTAssertEqual(TaskTemplates.load(spaceID: "space-1", stateDirectory: stateDirectory), TaskTemplates.defaults)
    }

    func testRefusesAnIdThatCouldLeaveTheProjectsFolder() {
        XCTAssertNil(TaskTemplates.fileURL(spaceID: "../outside", stateDirectory: stateDirectory))
        XCTAssertEqual(TaskTemplates.load(spaceID: "../outside", stateDirectory: stateDirectory), TaskTemplates.defaults)
    }
}
