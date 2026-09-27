import XCTest
@testable import Nirux

final class SpaceBriefTests: XCTestCase {
    private var stateDirectory: URL!

    override func setUpWithError() throws {
        stateDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: stateDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: stateDirectory)
    }

    func testNewBriefHoldsOnlyACommentAndInjectsNothing() throws {
        let url = try XCTUnwrap(SpaceBrief.ensureBriefFile(
            spaceID: "space-1", spaceName: "Nirux", stateDirectory: stateDirectory
        ))

        XCTAssertEqual(url.path, stateDirectory.appendingPathComponent("projects/space-1/brief.md").path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        XCTAssertNil(SpaceBrief.prepareInjection(spaceID: "space-1", stateDirectory: stateDirectory))
    }

    func testEnsureBriefFileKeepsExistingContent() throws {
        let url = try XCTUnwrap(SpaceBrief.briefURL(spaceID: "space-1", stateDirectory: stateDirectory))
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("Never merge.".utf8).write(to: url)

        _ = try SpaceBrief.ensureBriefFile(spaceID: "space-1", spaceName: "Nirux", stateDirectory: stateDirectory)

        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "Never merge.")
    }

    func testInjectionWritesHeaderedBriefForClaudeAndATomlStringForCodex() throws {
        let url = try XCTUnwrap(SpaceBrief.ensureBriefFile(
            spaceID: "space-1", spaceName: "Nirux", stateDirectory: stateDirectory
        ))
        let existing = try String(contentsOf: url, encoding: .utf8)
        try Data((existing + "- Never merge; the maintainer merges.\n- Say \"done\".\n").utf8).write(to: url)

        let injection = try XCTUnwrap(SpaceBrief.prepareInjection(
            spaceID: "space-1", stateDirectory: stateDirectory
        ))

        let claude = try String(contentsOfFile: injection.claudePromptFile, encoding: .utf8)
        XCTAssertTrue(claude.hasPrefix("# Project brief (from Nirux)\n"))
        XCTAssertTrue(claude.contains("The brief lives at \(url.path)."))
        XCTAssertTrue(claude.contains("Edit it only when the user asks you to in this conversation"))
        XCTAssertTrue(claude.hasSuffix("- Never merge; the maintainer merges.\n- Say \"done\"."))
        XCTAssertFalse(claude.contains("<!--"), "the template comment is not sent")

        let codex = try String(contentsOfFile: injection.codexInstructionsFile, encoding: .utf8)
        XCTAssertEqual(codex, SpaceBrief.tomlBasicString(claude))
        XCTAssertFalse(codex.contains("\n"), "one line, so the shell passes it whole")
    }

    func testEmptyingTheBriefEmptiesFilesFromEarlierLaunches() throws {
        let url = try XCTUnwrap(SpaceBrief.briefURL(spaceID: "space-1", stateDirectory: stateDirectory))
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("Rule.".utf8).write(to: url)
        let injection = try XCTUnwrap(SpaceBrief.prepareInjection(
            spaceID: "space-1", stateDirectory: stateDirectory
        ))

        try Data("<!-- nothing -->".utf8).write(to: url)

        XCTAssertNil(SpaceBrief.prepareInjection(spaceID: "space-1", stateDirectory: stateDirectory))
        // Emptied, not deleted: a restarted column replays a command naming them.
        XCTAssertEqual(try String(contentsOfFile: injection.claudePromptFile, encoding: .utf8), "")
        XCTAssertEqual(try String(contentsOfFile: injection.codexInstructionsFile, encoding: .utf8), "\"\"")
    }

    func testABriefThatIsNotARegularFileIsIgnored() throws {
        let url = try XCTUnwrap(SpaceBrief.briefURL(spaceID: "space-1", stateDirectory: stateDirectory))
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        XCTAssertEqual(mkfifo(url.path, 0o600), 0)

        // Reading a FIFO would block the launch.
        XCTAssertNil(SpaceBrief.prepareInjection(spaceID: "space-1", stateDirectory: stateDirectory))
    }

    func testSpaceNameCannotCloseTheTemplateComment() throws {
        for (index, name) in ["a --> b", "a ----> b", "a ---> b"].enumerated() {
            let id = "space-\(index)"
            _ = try SpaceBrief.ensureBriefFile(spaceID: id, spaceName: name, stateDirectory: stateDirectory)

            XCTAssertNil(SpaceBrief.prepareInjection(spaceID: id, stateDirectory: stateDirectory), name)
        }
    }

    func testBodyDropsHtmlCommentsAndBlankResults() {
        XCTAssertNil(SpaceBrief.body(of: "  <!-- only a note -->\n\n"))
        XCTAssertEqual(SpaceBrief.body(of: "a <!-- x --> b"), "a  b")
        // An unclosed comment is text, not a way to lose the rest.
        XCTAssertEqual(SpaceBrief.body(of: "keep <!-- this"), "keep <!-- this")
        XCTAssertEqual(SpaceBrief.body(of: "\n keep \n"), "keep")
    }

    func testOversizedBriefIsTruncated() {
        let text = SpaceBrief.injectedText(
            body: String(repeating: "x", count: SpaceBrief.maxCharacters + 10),
            briefPath: "/b"
        )

        XCTAssertTrue(text.hasSuffix(String(repeating: "x", count: 10) + "\n[Brief truncated.]"))
        XCTAssertFalse(text.contains(String(repeating: "x", count: SpaceBrief.maxCharacters + 1)))
    }

    func testBriefIsAlsoCappedInBytes() {
        // One visible character, many bytes: the command-line limit is bytes.
        let heavy = "e" + String(repeating: "\u{0301}", count: 100_000)
        let text = SpaceBrief.injectedText(body: heavy, briefPath: "/b")

        XCTAssertLessThan(text.utf8.count, SpaceBrief.maxBytes + 1_000)
        XCTAssertTrue(text.hasSuffix("[Brief truncated.]"))
    }

    func testTomlBasicStringEscapes() {
        XCTAssertEqual(SpaceBrief.tomlBasicString("a\"b\\c\nd\te\u{01}é"), #""a\"b\\c\nd\te\u0001é""#)
    }

    func testSpaceIDsThatCouldEscapeTheFolderAreRefused() {
        XCTAssertNil(SpaceBrief.briefURL(spaceID: "../x", stateDirectory: stateDirectory))
        XCTAssertNil(SpaceBrief.briefURL(spaceID: "a/b", stateDirectory: stateDirectory))
        XCTAssertNil(SpaceBrief.briefURL(spaceID: "", stateDirectory: stateDirectory))
        XCTAssertNotNil(SpaceBrief.briefURL(spaceID: "default", stateDirectory: stateDirectory))
        XCTAssertNotNil(SpaceBrief.briefURL(
            spaceID: "1A534BA5-F0C6-4589-A8DE-B7211A25FF36", stateDirectory: stateDirectory
        ))
    }

    func testCodexConfigDeveloperInstructionsDetection() {
        XCTAssertTrue(SpaceBrief.codexConfigSetsDeveloperInstructions(
            "model = \"x\"\ndeveloper_instructions = \"mine\"\n[features]\n"
        ))
        // In any table: skipping the brief is the safe way to be wrong.
        XCTAssertTrue(SpaceBrief.codexConfigSetsDeveloperInstructions(
            "model = \"x\"\n[profiles.p]\ndeveloper_instructions = \"scoped\"\n"
        ))
        XCTAssertFalse(SpaceBrief.codexConfigSetsDeveloperInstructions("developer_instructions_file = \"x\"\n"))
        XCTAssertTrue(SpaceBrief.codexConfigSetsDeveloperInstructions("\"developer_instructions\" = \"q\"\n"))
        // A line of a multi-line array doesn't end the top level.
        XCTAssertTrue(SpaceBrief.codexConfigSetsDeveloperInstructions(
            "notify = [\n  [\"a\"],\n]\ndeveloper_instructions = \"mine\"\n"
        ))
    }

    // MARK: - Launch commands

    @MainActor
    func testClaudeCommandAppendsTheBriefTextReadByTheShell() {
        let file = "/Users/me/Library/Application Support/nirux/projects/s/brief.injected.md"

        XCTAssertEqual(
            NiruxShellView.claudeCommand(mode: .plan, briefFile: file, shell: "/bin/zsh", handoverPrompt: "Go"),
            "command claude --permission-mode plan --append-system-prompt \"$(command cat '\(file)')\" 'Go'"
        )
        XCTAssertEqual(
            NiruxShellView.claudeCommand(mode: .default, briefFile: file, shell: "/opt/homebrew/bin/fish"),
            "command claude --append-system-prompt \"$(command cat '\(file)')\""
        )
        // tcsh keeps the file flag: no substitution keeps multi-line text whole.
        XCTAssertEqual(
            NiruxShellView.claudeCommand(mode: .default, briefFile: file, shell: "/bin/tcsh"),
            "command claude '--append-system-prompt-file=\(file)'"
        )
        XCTAssertEqual(NiruxShellView.claudeCommand(mode: .default), "command claude")
    }

    func testShellsPassTheClaudeBriefAsOneExactArgument() throws {
        let brief = "# Project brief (from Nirux)\nLine two: \"q\" $HOME `id` \\ 'x' é\n\n- last"
        let file = stateDirectory.appendingPathComponent("brief injected.md")
        try Data(brief.utf8).write(to: file)
        let arguments = NiruxShellView.claudeAppendSystemPromptArguments(briefFile: file.path, shell: "/bin/zsh")

        let shells = [
            ("/bin/zsh", ["-f", "-c", "alias cat='cat -n'; printf '%s' \(arguments[1])"]),
            ("/bin/bash", ["--noprofile", "--norc", "-O", "expand_aliases", "-c",
                           "alias cat='cat -n'\nprintf '%s' \(arguments[1])"])
        ]
        for (shell, shellArguments) in shells {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: shell)
            process.arguments = shellArguments
            process.environment = ["PATH": "/usr/bin:/bin", "HOME": stateDirectory.path]
            let output = Pipe()
            process.standardOutput = output
            try process.run()
            process.waitUntilExit()
            let printed = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)
            XCTAssertEqual(printed, brief, shell)
        }
    }

    func testShellsPassTheCodexBriefAsOneExactArgument() throws {
        let brief = "# Brief\nSay \"hi\" $HOME `id` \\ 'q' é"
        let file = stateDirectory.appendingPathComponent("brief codex.toml")
        let toml = SpaceBrief.tomlBasicString(brief)
        try Data(toml.utf8).write(to: file)
        let override = try XCTUnwrap(
            NiruxShellView.codexDeveloperInstructionsOverride(briefFile: file.path, shell: "/bin/zsh")
        )

        // Isolated from the user's rc files; a `cat` alias must not apply.
        let shells = [
            ("/bin/zsh", ["-f", "-c", "alias cat='cat -n'; printf '%s' \(override)"]),
            ("/bin/bash", ["--noprofile", "--norc", "-O", "expand_aliases", "-c",
                           "alias cat='cat -n'\nprintf '%s' \(override)"])
        ]
        for (shell, arguments) in shells {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: shell)
            process.arguments = arguments
            process.environment = ["PATH": "/usr/bin:/bin", "HOME": stateDirectory.path]
            let output = Pipe()
            process.standardOutput = output
            try process.run()
            process.waitUntilExit()
            let printed = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)
            XCTAssertEqual(printed, "developer_instructions=" + toml, shell)
        }
    }

    @MainActor
    func testCodexCommandReadsTheBriefThroughTheShell() {
        let file = "/Users/me/Library/Application Support/nirux/projects/s/brief.codex.toml"

        XCTAssertEqual(
            NiruxShellView.codexCommand(mode: .default, briefFile: file, shell: "/bin/zsh", handoverPrompt: "Go"),
            "command codex -c \"developer_instructions=$(command cat '\(file)')\" 'Go'"
        )
        // fish: `(…)` works in every version, `$(…)` only from 3.4.
        XCTAssertEqual(
            NiruxShellView.codexCommand(mode: .default, briefFile: file, shell: "/opt/homebrew/bin/fish"),
            "command codex -c \"developer_instructions=\"(command cat '\(file)')"
        )
        // tcsh has no $(…): no brief rather than a broken launch.
        XCTAssertEqual(
            NiruxShellView.codexCommand(mode: .default, briefFile: file, shell: "/bin/tcsh"),
            "command codex"
        )
    }
}
