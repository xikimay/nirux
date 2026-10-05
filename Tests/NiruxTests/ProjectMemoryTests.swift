import AppKit
import XCTest
@testable import Nirux

/// Reading what agents know (see ProjectMemory): Claude Code's memory
/// folder and its index, the rules of the brief and of the repository's
/// files, and the one list the panel shows.
final class ProjectMemoryTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("project-memory-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func write(_ path: String, _ text: String) throws {
        let url = directory.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    private static func memoryFile(_ name: String, type: String, description: String = "summary", body: String = "Fact.") -> String {
        "---\nname: \(name)\ndescription: \(description)\nmetadata:\n  type: \(type)\n---\n\n\(body)\n"
    }

    // MARK: - Memory files

    /// As Claude Code stamps them: nested metadata with its own keys, a
    /// quoted description; older ones put `type` at the top; Windows line
    /// endings too.
    func testFrontmatterAsClaudeCodeWritesIt() throws {
        let stamped = """
        ---
        name: review-workflow
        description: "Cycle before a PR: review, \\"premortem\\", fix"
        metadata:
          node_type: memory
          type: feedback
          originSessionId: 7d1c2a3e-0d4b-4e5f-8a9b-1c2d3e4f5a60
          modified: 2026-10-03T15:57:12.123Z
        ---

        The fact.
        **Why:** stated.
        """
        let memory = ProjectMemory.memory(fileName: "review-workflow.md", text: stamped, indexLine: nil, fileDate: nil)
        XCTAssertEqual(memory.name, "review-workflow")
        XCTAssertEqual(memory.description, "Cycle before a PR: review, \"premortem\", fix")
        XCTAssertEqual(memory.kind, .feedback)
        XCTAssertEqual(memory.body, "The fact.\n**Why:** stated.")
        let modified = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-10-03T15:57:12Z")).timeIntervalSince1970 + 0.123
        XCTAssertEqual(try XCTUnwrap(memory.modified).timeIntervalSince1970, modified, accuracy: 0.0005)

        let legacy = "---\nname: 'it''s old'\ntype: Project\ndescription: >\n  folded over\n  two lines\n---\nBody"
        let old = ProjectMemory.memory(fileName: "old.md", text: legacy, indexLine: nil, fileDate: nil)
        XCTAssertEqual(old.name, "it's old")
        XCTAssertEqual(old.kind, .project)
        XCTAssertEqual(old.description, "folded over two lines")

        let windows = ProjectMemory.memory(
            fileName: "crlf.md", text: Self.memoryFile("crlf", type: "user").replacingOccurrences(of: "\n", with: "\r\n"),
            indexLine: nil, fileDate: nil
        )
        XCTAssertEqual(windows.name, "crlf")
        XCTAssertEqual(windows.kind, .user)
        XCTAssertEqual(windows.body, "Fact.")

        // No frontmatter: the file's name, its whole text, no type.
        let bare = ProjectMemory.memory(fileName: "notes.md", text: "Just text", indexLine: nil, fileDate: nil)
        XCTAssertEqual(bare.name, "notes")
        XCTAssertEqual(bare.body, "Just text")
        XCTAssertNil(bare.type)
    }

    /// The index's order first, then the files it doesn't list; its lines
    /// without a file apart. Subfolders are read; the folders Claude Code
    /// skips, hidden and linked files aren't, but aren't missing either.
    /// Links match files in any case, with an anchor or a pair of
    /// parentheses.
    func testReadListsTheFolderAsClaudeCodeFindsIt() throws {
        try write("MEMORY.md", """
        # Memory index

        - [Second](B.md#why) — listed first
        * [Nested](topics/c.md): in a subfolder
        - [Gone](deleted.md) — no file
        - [Site](https://example.com) — not a memory
        - [Shared](team/shared.md) — skipped, there all the same
        - [First](notes%20(v2).md) — listed last
        """)
        try write("notes (v2).md", Self.memoryFile("a", type: "user"))
        try write("b.md", Self.memoryFile("b", type: "feedback"))
        try write("topics/c.md", Self.memoryFile("c", type: "project"))
        try write("z-unlisted.md", Self.memoryFile("z-unlisted", type: "reference"))
        try write("m-unlisted.md", Self.memoryFile("m-unlisted", type: "reference"))
        try write("team/shared.md", Self.memoryFile("shared", type: "project"))
        try write("Logs./old.md", Self.memoryFile("old", type: "project"))
        try write("topics/MEMORY.md", "- [b](b.md) — another index")
        try write(".hidden.md", Self.memoryFile("hidden", type: "user"))
        try write("notes.txt", "not markdown")
        try FileManager.default.createSymbolicLink(
            at: directory.appendingPathComponent("linked.md"), withDestinationURL: directory.appendingPathComponent("b.md")
        )

        // Read through a linked parent folder, as a linked ~/.claude.
        let link = directory.deletingLastPathComponent().appendingPathComponent("link-\(UUID().uuidString)")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: directory)
        defer { try? FileManager.default.removeItem(at: link) }
        let contents = try XCTUnwrap(ProjectMemory.read(directory: link))
        XCTAssertEqual(contents.memories.map(\.fileName), ["b.md", "topics/c.md", "notes (v2).md", "m-unlisted.md", "z-unlisted.md"])
        XCTAssertEqual(contents.memories.map(\.title), ["Second", "Nested", "First", "m-unlisted", "z-unlisted"])
        XCTAssertEqual(contents.memories.first?.indexLine?.hook, "listed first")
        XCTAssertEqual(contents.memories[1].indexLine?.hook, "in a subfolder")
        XCTAssertEqual(contents.unindexed.map(\.name), ["m-unlisted", "z-unlisted"])
        XCTAssertEqual(contents.missingFiles.map(\.number), [5])
        XCTAssertEqual(contents.missingFiles.map(\.fileName), ["deleted.md"])
        XCTAssertEqual(contents.linesRead, [1, 3, 4, 5, 6, 7, 8])

        XCTAssertNil(ProjectMemory.read(directory: directory.appendingPathComponent("missing")))
    }

    /// Claude Code drops comments, trims, then reads MEMORY.md up to line
    /// 200 and up to 25,000 characters, cut at a line break.
    func testIndexPastWhatClaudeCodeReads() throws {
        let long = (1...205).map { "- [Memory \($0)](m\($0).md) — hook" }.joined(separator: "\n")
        XCTAssertEqual(ProjectMemory.linesRead(of: long), Set(1...200))
        // Blank lines and a comment before the entries don't count.
        XCTAssertEqual(ProjectMemory.linesRead(of: "\n\n<!-- a\nb -->\n" + long), Set(5...204))
        let wide = String(repeating: "x", count: 9_999)
        XCTAssertEqual(ProjectMemory.linesRead(of: [wide, wide, wide, "last"].joined(separator: "\n")), [1, 2])
        // A line ending right at 25,000 stays; without a line break before
        // it, the text is cut there.
        XCTAssertEqual(ProjectMemory.linesRead(of: String(repeating: "x", count: 25_000) + "\ny"), [1])
        XCTAssertEqual(ProjectMemory.linesRead(of: String(repeating: "x", count: 30_000) + "\n- [X](x.md)"), [1])
        // A commented index line is no line of the index.
        XCTAssertEqual(ProjectMemory.indexLines(in: "\u{FEFF}- [A](a.md) — x\n<!--\n- [B](b.md) — y\n-->").map(\.target), ["a.md"])

        try write("MEMORY.md", long)
        for number in [200, 201] { try write("m\(number).md", Self.memoryFile("m\(number)", type: "user")) }
        let contents = try XCTUnwrap(ProjectMemory.read(directory: directory))
        XCTAssertEqual(contents.memories.compactMap(\.indexLine).map(contents.isRead), [true, false])
    }

    // MARK: - Rules

    /// One rule per top-level bullet, its indented lines with it, or per
    /// paragraph; no heading, comment or frontmatter; a code block whole.
    func testRules() {
        let text = """
        ---
        title: x
        ---
        <!-- Not sent:
        - a commented bullet -->
        # Workflow
        - **Never merge.** The user merges.
        - CI is stricter:
          - mark tests `@MainActor`;
          - no closures off main.
        1. Numbered, and
        lazily continued.

        A paragraph
        on two lines.

        ```
        code block

        still code
        ```
        ---
        """
        let rules = ProjectMemory.rules(in: text)
        XCTAssertEqual(rules.map(\.text), [
            "**Never merge.** The user merges.",
            "CI is stricter:\n- mark tests `@MainActor`;\n- no closures off main.",
            "Numbered, and\nlazily continued.",
            "A paragraph\non two lines.",
            "```\ncode block\n\nstill code\n```"
        ])
        XCTAssertEqual(rules.map(\.lines), [7...7, 8...10, 11...12, 14...15, 17...21])

        // Laid out otherwise: an indented list, tabs, a `#` that isn't a
        // heading, a code block on its own, an empty bullet, a comment in a
        // line for the team's files (Claude Code keeps it).
        let other = ProjectMemory.rules(in: """
          - Never merge
          - Run swift test
        - Top
        \t- sub, tabbed
        - Fix the bug
          #123 tracks it
        ```bash
        swift build
        ```
        Then run tests.
        -
        - Use pnpm <!-- not npm -->
        <!-- a comment on its own line -->
        """, blockCommentsOnly: true)
        XCTAssertEqual(other.map(\.text), [
            "Never merge", "Run swift test", "Top\n  - sub, tabbed", "Fix the bug\n#123 tracks it",
            "```bash\nswift build\n```", "Then run tests.", "Use pnpm <!-- not npm -->"
        ])
        XCTAssertEqual(other.map(\.lines), [1...1, 2...2, 3...4, 5...6, 7...9, 10...10, 12...12])
        XCTAssertEqual(ProjectMemory.headline(of: other[4].text).title, "swift build")

        XCTAssertEqual(ProjectMemory.headline(of: rules[0].text).title, "Never merge")
        XCTAssertEqual(ProjectMemory.headline(of: rules[0].text).detail, "The user merges.")
        XCTAssertEqual(ProjectMemory.headline(of: rules[1].text).title, "CI is stricter")
        XCTAssertEqual(ProjectMemory.headline(of: rules[1].text).detail, "mark tests @MainActor; · no closures off main.")
        // A version number isn't a sentence's end; a bold lead loses the
        // punctuation after it, never its own words.
        XCTAssertEqual(ProjectMemory.headline(of: "CI (Swift 6.1) is stricter. Mark tests.").title, "CI (Swift 6.1) is stricter")
        XCTAssertEqual(ProjectMemory.headline(of: "**Never stash**: it pops").detail, "it pops")
        XCTAssertEqual(ProjectMemory.headline(of: "**1. Setup**: run make first").title, "1. Setup")
        XCTAssertEqual(ProjectMemory.headline(of: "**1. Setup**: run make first").detail, "run make first")
        XCTAssertEqual(ProjectMemory.headline(of: "**Two\nlines** after").title, "Two lines")
    }

    // MARK: - The list

    /// Always first (the brief), then the team's, then the memory, then the
    /// index's lines without a file; filtered by every word, in any case and
    /// accent, and by scope: the team's rules apply always.
    func testKnowledgeListsEveryScope() throws {
        try write("MEMORY.md", "- [Café rules](cafe.md) — x\n- [Gone](gone.md) — y\n")
        try write("cafe.md", Self.memoryFile("cafe", type: "feedback", body: "Order an espresso."))
        try write("loose.md", Self.memoryFile("loose", type: "project", body: "Unlisted espresso."))
        let brief = ProjectMemory.RuleFile(
            url: directory.appendingPathComponent("brief.md"), label: "Project brief",
            rules: ProjectMemory.rules(in: "- Chat in French.\n- One PR per change.")
        )
        let team = ProjectMemory.RuleFile(
            url: directory.appendingPathComponent("CLAUDE.md"), label: "CLAUDE.md",
            rules: ProjectMemory.rules(in: "# Repo\nBuild with swift build. Espresso optional.")
        )
        let knowledge = ProjectMemory.Knowledge(brief: brief, teamFiles: [team], memory: ProjectMemory.read(directory: directory))
        XCTAssertEqual(knowledge.entries.map(\.scope), [.always, .always, .team, .whenRelevant, .whenRelevant, .whenRelevant])
        XCTAssertEqual(knowledge.entries.map(\.title), ["Chat in French", "One PR per change", "Build with swift build", "Café rules", "loose", "Gone"])
        XCTAssertEqual(ProjectMemory.summary(of: knowledge), "2 always · 1 team · 3 when relevant")

        XCTAssertEqual(ProjectMemory.entries(in: knowledge, text: "CAFE  espresso", scope: nil), [3])
        XCTAssertEqual(ProjectMemory.entries(in: knowledge, text: "espresso", scope: nil), [2, 3, 4])
        XCTAssertEqual(ProjectMemory.entries(in: knowledge, text: "", scope: .always), [0, 1, 2])
        XCTAssertEqual(ProjectMemory.entries(in: knowledge, text: "espresso", scope: .whenRelevant), [3, 4])
        XCTAssertEqual(ProjectMemory.summary(of: knowledge, shown: 2), "2 of 6")

        // Each opens where it is written.
        XCTAssertEqual(knowledge.location(of: knowledge.entries[1])?.line, 2)
        XCTAssertEqual(knowledge.location(of: knowledge.entries[2])?.line, 2)
        XCTAssertEqual(knowledge.location(of: knowledge.entries[3])?.url.lastPathComponent, "cafe.md")
        XCTAssertNil(knowledge.location(of: knowledge.entries[3])?.line)
        XCTAssertEqual(knowledge.location(of: knowledge.entries[5])?.url.lastPathComponent, "MEMORY.md")
        XCTAssertEqual(knowledge.location(of: knowledge.entries[5])?.line, 2)

        XCTAssertEqual(ProjectMemory.summary(of: ProjectMemory.Knowledge(brief: nil, teamFiles: [], memory: nil)), "Nothing yet")
    }

    // MARK: - Links

    func testLinks() throws {
        let text = "See [[alpha]], [[ beta ]] and [[]], [[[gamma]]], [[not\nclosed]] [[alpha]]."
        let links = ProjectMemory.links(in: text)
        XCTAssertEqual(links.map(\.name), ["alpha", "beta", "gamma", "alpha"])
        XCTAssertEqual((text as NSString).substring(with: links[2].range), "[[gamma]]")

        try write("alpha.md", Self.memoryFile("alpha", type: "user"))
        try write("beta-file.md", Self.memoryFile("beta", type: "user"))
        let contents = try XCTUnwrap(ProjectMemory.read(directory: directory))
        @Sendable func file(_ name: String) -> String? { contents.index(ofMemoryNamed: name).map { contents.memories[$0].fileName } }
        // By name first, else by file, in any case.
        XCTAssertEqual(file("alpha"), "alpha.md")
        XCTAssertEqual(file("beta"), "beta-file.md")
        XCTAssertEqual(file("Beta-File"), "beta-file.md")
        XCTAssertNil(file("gamma"))
    }

    /// The preview shows Markdown read: marks gone, code in mono, a link to
    /// a memory linked by its file (in bold too), a link to none plain.
    func testPreviewText() throws {
        try write("a file.md", Self.memoryFile("a", type: "user"))
        let contents = try XCTUnwrap(ProjectMemory.read(directory: directory))
        let text = ProjectMemoryPreview.text(of: "**Why: see [[a]]**, not [[b]] nor `[[a]] **x**`.", in: contents)
        XCTAssertEqual(text.string, "Why: see a, not b nor [[a]] **x**.")
        let string = text.string as NSString
        let why = string.range(of: "Why:")
        XCTAssertEqual(text.attribute(.font, at: why.location, effectiveRange: nil) as? NSFont, Theme.Font.bodyEmphasized)
        let link = try XCTUnwrap(text.attribute(.link, at: string.range(of: "a,").location, effectiveRange: nil) as? URL)
        XCTAssertEqual(URLComponents(url: link, resolvingAgainstBaseURL: false)?.path, "a file.md")
        XCTAssertNil(text.attribute(.link, at: string.range(of: "b nor").location, effectiveRange: nil))
        let code = string.range(of: "[[a]]")
        XCTAssertNil(text.attribute(.link, at: code.location, effectiveRange: nil))
        XCTAssertEqual((text.attribute(.font, at: code.location, effectiveRange: nil) as? NSFont)?.isFixedPitch, true)
    }
}

/// Where Claude Code keeps a repository's memory, and whether it uses it
/// (see ProjectMemory+Location), on throwaway folders: never ~/.claude.
@MainActor
final class ProjectMemoryLocationTests: XCTestCase {
    /// Resolved (`/private/var/…`), as Claude Code resolves the launch
    /// folder.
    private nonisolated let root = (FileManager.default.temporaryDirectory.path.realPath ?? NSTemporaryDirectory())
        + "/project-memory-location-\(UUID().uuidString)"
    private nonisolated var home: String { root + "/home" }
    private nonisolated var managed: ProjectMemory.ManagedFolders {
        ProjectMemory.ManagedFolders(
            preferences: URL(fileURLWithPath: root + "/managed-preferences"),
            settings: URL(fileURLWithPath: root + "/managed")
        )
    }

    override func setUpWithError() throws {
        try FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(atPath: root)
    }

    private func write(_ path: String, _ text: String) throws {
        try FileManager.default.createDirectory(
            atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true
        )
        try text.write(toFile: path, atomically: true, encoding: .utf8)
    }

    private func locate(_ folder: String, _ environment: [String: String] = [:]) -> ProjectMemory.Location {
        ProjectMemory.locate(folder: folder, home: home, environment: environment, managed: managed)
    }

    /// Values from Claude Code's own function run in Node: only ASCII
    /// letters and digits stay, one `-` per UTF-16 unit; past 200, a hash.
    func testEncodedProjectName() {
        XCTAssertEqual(ProjectMemory.encodedProjectName("/Users/x/é😀 repo.v2"), "-Users-x-----repo-v2")
        let long = "/Users/x/" + String(repeating: "a", count: 230) + "/é😀 repo.v2"
        XCTAssertEqual(
            ProjectMemory.encodedProjectName(long),
            "-Users-x-" + String(repeating: "a", count: 191) + "-18y8v6"
        )
    }

    /// Every worktree of a repository, and every subfolder, shares the main
    /// checkout's memory; outside a repository, the folder's own.
    func testFolderIsTheMainCheckouts() throws {
        let repo = root + "/my repo"
        let worktree = root + "/my repo.feat"
        try FileManager.default.createDirectory(atPath: repo + "/Sources/App", withIntermediateDirectories: true)
        try "x\n".write(toFile: repo + "/README.md", atomically: true, encoding: .utf8)
        try UIFlowHarness.git(["init", "-q", "-b", "main"], at: repo)
        try UIFlowHarness.git(["add", "README.md"], at: repo)
        try UIFlowHarness.git(["-c", "user.name=T", "-c", "user.email=t@example.com", "commit", "-q", "-m", "init"], at: repo)
        try UIFlowHarness.git(["worktree", "add", "-q", "-b", "feat", worktree], at: repo)

        let expected = home + "/.claude/projects/" + ProjectMemory.encodedProjectName(repo) + "/memory"
        for folder in [repo, repo + "/Sources/App", worktree] {
            let location = locate(folder)
            XCTAssertEqual(location.projectRoot, repo, folder)
            XCTAssertEqual(location.directory.path, expected, folder)
            XCTAssertNil(location.notice, folder)
        }

        // A worktree whose git folder doesn't point back is its own root,
        // as Claude Code decides.
        let gitFile = try String(contentsOfFile: worktree + "/.git", encoding: .utf8)
        let gitDirectory = gitFile.replacingOccurrences(of: "gitdir:", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
        try "/elsewhere/.git\n".write(toFile: gitDirectory + "/gitdir", atomically: true, encoding: .utf8)
        XCTAssertEqual(locate(worktree).projectRoot, worktree)

        let plain = root + "/plain"
        try FileManager.default.createDirectory(atPath: plain, withIntermediateDirectories: true)
        XCTAssertEqual(locate(plain).projectRoot, plain)

        // A main checkout named in decomposed Unicode, as git writes it: the
        // folder is named after its composed form, as Claude Code does.
        let decomposed = root + "/Cafe\u{0301}"
        try FileManager.default.createDirectory(atPath: decomposed, withIntermediateDirectories: true)
        try "x\n".write(toFile: decomposed + "/README.md", atomically: true, encoding: .utf8)
        try UIFlowHarness.git(["init", "-q", "-b", "main"], at: decomposed)
        try UIFlowHarness.git(["add", "README.md"], at: decomposed)
        try UIFlowHarness.git(["-c", "user.name=T", "-c", "user.email=t@example.com", "commit", "-q", "-m", "init"], at: decomposed)
        try UIFlowHarness.git(["worktree", "add", "-q", "-b", "nfd", decomposed + ".nfd"], at: decomposed)
        XCTAssertEqual(
            locate(decomposed + ".nfd").directory.lastPathComponent == "memory"
                ? locate(decomposed + ".nfd").directory.deletingLastPathComponent().lastPathComponent : nil,
            ProjectMemory.encodedProjectName((root + "/Caf\u{00E9}").precomposedStringWithCanonicalMapping)
        )

        // Created through a path typed in another case, which git keeps:
        // on a volume that ignores case, still the same main checkout.
        let typed = (root as NSString).deletingLastPathComponent + "/" + (root as NSString).lastPathComponent.uppercased()
        if FileManager.default.fileExists(atPath: typed) {
            try UIFlowHarness.git(["worktree", "add", "-q", "-b", "cased", typed + "/cased"], at: repo)
            XCTAssertEqual(locate(root + "/cased").projectRoot, repo)
        }
    }

    func testConfigDirectoryAndItsProjectName() throws {
        let folder = root + "/plain"
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        let encoded = ProjectMemory.encodedProjectName(folder)
        XCTAssertEqual(locate(folder, ["CLAUDE_CONFIG_DIR": root + "/config"]).directory.path, root + "/config/projects/\(encoded)/memory")
        // Its own project name only with its own config folder, and a
        // valid one.
        XCTAssertEqual(locate(folder, ["CLAUDE_CODE_PROJECT_DIR_NAME": "shared"]).directory.path, home + "/.claude/projects/\(encoded)/memory")
        XCTAssertEqual(
            locate(folder, ["CLAUDE_CONFIG_DIR": root + "/config", "CLAUDE_CODE_PROJECT_DIR_NAME": "shared"]).directory.path,
            root + "/config/projects/shared/memory"
        )
        for refused in ["no/slash", "com0"] {
            XCTAssertEqual(
                locate(folder, ["CLAUDE_CONFIG_DIR": root + "/config", "CLAUDE_CODE_PROJECT_DIR_NAME": refused]).directory.path,
                root + "/config/projects/\(encoded)/memory", refused
            )
        }
    }

    /// The first scope that sets `autoMemoryDirectory` decides: a folder it
    /// refuses doesn't fall through to the next scope.
    func testAutoMemoryDirectorySetting() throws {
        let folder = root + "/plain"
        let user = home + "/.claude/settings.json"
        try write(user, #"{"autoMemoryDirectory": "~/notes/memory/"}"#)
        var location = locate(folder)
        XCTAssertEqual(location.directory.path, home + "/notes/memory")
        XCTAssertEqual(location.movedBy, "autoMemoryDirectory in ~/.claude/settings.json")
        XCTAssertEqual(location.notice, "autoMemoryDirectory in ~/.claude/settings.json puts every repository’s Claude Code memory in one folder.")

        try write(folder + "/.claude/settings.json", #"{"autoMemoryDirectory": "/project/memory"}"#)
        XCTAssertEqual(locate(folder).directory.path, "/project/memory")
        try write(folder + "/.claude/settings.local.json", #"{"autoMemoryDirectory": null}"#)
        XCTAssertEqual(locate(folder).directory.path, "/project/memory")
        try write(managed.settings.path + "/managed-settings.json", #"{"autoMemoryDirectory": "/policy/one"}"#)
        try write(managed.settings.path + "/managed-settings.d/20-team.json", #"{"autoMemoryDirectory": "/policy/two"}"#)
        location = locate(folder)
        XCTAssertEqual(location.directory.path, "/policy/two")
        XCTAssertEqual(location.movedBy, "autoMemoryDirectory in managed settings")
        try write(managed.settings.path + "/managed-settings.d/20-team.json", #"{"autoMemoryDirectory": "//srv/memory/"}"#)
        XCTAssertEqual(locate(folder).directory.path, "/srv/memory")

        // Refused: the default, not the next scope's folder.
        for refused in ["relative/memory", "~/../escape", "~", "~/", "~/.", "~/a/..", "~/a/../../b", "/", "/Volumes/../net/host/x"] {
            try write(managed.settings.path + "/managed-settings.d/20-team.json", "{\"autoMemoryDirectory\": \"\(refused)\"}")
            location = locate(folder)
            XCTAssertEqual(location.directory.path, home + "/.claude/projects/\(ProjectMemory.encodedProjectName(folder))/memory", refused)
            XCTAssertNil(location.movedBy, refused)
        }
    }

    func testDisabled() throws {
        let folder = root + "/plain"
        XCTAssertNil(locate(folder).disabledBy)
        XCTAssertEqual(locate(folder, ["CLAUDE_CODE_DISABLE_AUTO_MEMORY": " TRUE "]).disabledBy, "CLAUDE_CODE_DISABLE_AUTO_MEMORY is set")
        XCTAssertEqual(locate(folder, ["CLAUDE_CODE_SIMPLE": "1"]).disabledBy, "CLAUDE_CODE_SIMPLE is set")
        XCTAssertNil(locate(folder, ["CLAUDE_CODE_SIMPLE": "maybe"]).disabledBy)

        try write(folder + "/.claude/settings.json", #"{"autoMemoryEnabled": false}"#)
        XCTAssertEqual(locate(folder).disabledBy, "autoMemoryEnabled is false in .claude/settings.json")
        XCTAssertEqual(
            locate(folder).notice,
            "Auto-memory is off (autoMemoryEnabled is false in .claude/settings.json): Claude Code neither reads nor notes what is “When relevant”."
        )
        // The local settings win over the project's; a false variable turns
        // it on whatever the settings say.
        try write(folder + "/.claude/settings.local.json", #"{"autoMemoryEnabled": true}"#)
        XCTAssertNil(locate(folder).disabledBy)
        try write(folder + "/.claude/settings.local.json", "{}")
        XCTAssertNil(locate(folder, ["CLAUDE_CODE_DISABLE_AUTO_MEMORY": "0"]).disabledBy)
        XCTAssertEqual(locate(folder, ["CLAUDE_CODE_SAFE_MODE": "yes", "CLAUDE_CODE_DISABLE_AUTO_MEMORY": "0"]).disabledBy, "CLAUDE_CODE_SAFE_MODE is set")
    }
}
