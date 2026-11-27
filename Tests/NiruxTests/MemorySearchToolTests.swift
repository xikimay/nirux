import XCTest
@testable import Nirux

final class MemorySearchToolTests: XCTestCase {
    private let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    private var repo: URL { root.appendingPathComponent("repo") }
    private var state: URL { root.appendingPathComponent("state") }
    private var config: URL { root.appendingPathComponent("claude") }
    private var memory: URL { config.appendingPathComponent("projects/sample/memory") }
    private var context: NiruxMCPServer.Context {
        .init(
            workingDirectory: repo.path,
            environment: ["NIRUX_PROFILE_ID": "sample", "CLAUDE_CONFIG_DIR": config.path, "CLAUDE_CODE_PROJECT_DIR_NAME": "sample"],
            stateDirectory: state, claudeProjects: config.appendingPathComponent("projects")
        )
    }

    override func setUpWithError() throws {
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: root)
    }

    private func write(_ text: String, to file: URL) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: file)
    }

    private func search(_ args: [String: Any] = [:]) -> String {
        let result = MemorySearchTool.call(args, context: context)
        XCTAssertFalse(result.isError, result.text)
        return result.text
    }

    func testQueryScopesAndSummaryOrder() throws {
        let brief = try XCTUnwrap(SpaceBrief.briefURL(spaceID: "sample", stateDirectory: state))
        try write("# Brief\n- Check the café build.", to: brief)
        try write("- Café menu\n- Build command", to: repo.appendingPathComponent(".claude/CLAUDE.md"))
        try write("- [Indexed](nested/note.md)\n- [Old decision](gone.md) — hold", to: memory.appendingPathComponent("MEMORY.md"))
        try write("Rebuild the CAFÉ.", to: memory.appendingPathComponent("nested/note.md"))
        try write("Other", to: memory.appendingPathComponent("a.md"))

        let summary = search().components(separatedBy: "\n")
        guard summary.count == 6 else { return XCTFail("Expected six items, got \(summary)") }
        XCTAssertEqual(summary[0], "[Always · brief.md:2] Check the café build.")
        XCTAssertEqual(summary[1], "[Team · .claude/CLAUDE.md:1] Café menu")
        XCTAssertTrue(summary[3].contains("[When relevant · nested/note.md] Indexed"))
        XCTAssertTrue(summary[4].contains("a.md"))
        XCTAssertTrue(summary[5].contains("[When relevant · MEMORY.md:2] Old decision"))
        XCTAssertEqual(search(["query": " \t ", "scope": "all"]), summary.joined(separator: "\n"))
        XCTAssertEqual(search(["query": "BuIlD  cafe"]), [summary[0], summary[3]].joined(separator: "\n"))
        XCTAssertEqual(search(["scope": "always"]), summary[0])
        XCTAssertEqual(search(["scope": "team"]), summary[1...2].joined(separator: "\n"))
        XCTAssertEqual(search(["scope": "when_relevant"]), summary[3...5].joined(separator: "\n"))
        XCTAssertTrue(search(["query": "missing term"]).contains("No matching"))
    }

    func testBricksAreFoundOnlyWhileAgentsMayGetThem() throws {
        let store = try XCTUnwrap(SpaceKnowledge.store(spaceID: "sample", stateDirectory: state))
        func brick(_ sentence: String, _ number: Int, validated: Bool = true) -> KnowledgeBrick {
            KnowledgeBrick(
                sentence: sentence, subject: "café build", scope: .init(anchor: "git:/x/.git", name: "x", paths: ["Sources/**"]),
                proofs: [.file(path: "a.swift"), .pullRequest(number)], validatedAt: validated ? 1 : nil
            )
        }
        let open = brick("The café build signs with the team's key on CI.", 1)
        let closed = brick("The café build skipped signing before November.", 2)
        var knowledge = KnowledgeState()
        for brick in [open, closed] { knowledge.bricks[try store.add(brick)] = BrickState() }
        knowledge.bricks[closed.id]?.closedAt = 5
        knowledge.proposals = [BrickProposal(brick: brick("The café build waits for the notary each time.", 3, validated: false), proposedAt: 2)]
        try store.save(knowledge, now: 6)

        let answer = search(["query": "cafe build"])
        XCTAssertEqual(answer, "[When relevant · brick \(open.id), Sources/**] The café build signs with the team's key on CI. (proof: a.swift · PR #1)")
        try write(#"{"schemaVersion": 1, "knowledgeBricks": false}"#, to: state.appendingPathComponent("projects/sample/defaults.json"))
        XCTAssertEqual(search(["query": "cafe build"]), "No matching project memory.", "the space's switch is off")
    }

    func testNoMemoryAndDisabledAutoMemoryAreReadOnly() throws {
        var outside = context
        outside.environment.removeValue(forKey: "NIRUX_PROFILE_ID")
        XCTAssertTrue(MemorySearchTool.call([:], context: outside).text.contains("No project memory"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: state.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: config.path))

        try write("Existing note", to: memory.appendingPathComponent("note.md"))
        outside.environment["CLAUDE_CODE_DISABLE_AUTO_MEMORY"] = "1"
        let answer = MemorySearchTool.call([:], context: outside)
        XCTAssertTrue(answer.text.contains("Auto-memory is off"))
        XCTAssertTrue(answer.text.contains("[When relevant · note.md]"))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: memory.path), ["note.md"])
    }

    func testClampsLimitAndBoundsMultibyteExcerptsAndResponse() throws {
        let team = repo.appendingPathComponent("AGENTS.md")
        try write((1...23).map { "- Rule \($0)" }.joined(separator: "\n"), to: team)
        for (args, expected) in [([:], 8), (["limit": -1], 1), (["limit": 200], 20)] {
            let lines = search(args).components(separatedBy: "\n")
            XCTAssertEqual(lines.filter { $0.hasPrefix("[Team") }.count, expected)
            XCTAssertTrue(lines.last?.contains("truncated") == true)
        }
        let wide = String(repeating: "🎈", count: 1_000)
        try write((1...20).map { "- \($0) \(wide)" }.joined(separator: "\n"), to: team)
        let answer = search(["limit": 20])
        XCTAssertLessThanOrEqual(answer.utf8.count, 16_000)
        let rows = answer.components(separatedBy: "\n").filter { $0.hasPrefix("[Team") }
        XCTAssertGreaterThan(rows.count, 1)
        XCTAssertLessThan(rows.count, 20)
        for row in rows {
            let excerpt = try XCTUnwrap(row.components(separatedBy: "] ").last)
            XCTAssertLessThanOrEqual(excerpt.utf8.count, 1_200)
            XCTAssertTrue(excerpt.hasSuffix("…"))
        }
    }

    func testAutoMemoryReadLimitIsReportedEvenWithoutMatches() throws {
        let note = String(repeating: "a", count: ProjectMemory.maxFileBytes + 1)
        try write(note, to: memory.appendingPathComponent("note.md"))
        XCTAssertTrue(search(["query": "absent"]).contains("auto-memory scan was truncated"))
    }

    func testIndexTruncatedAtSessionStartupStaysSearchable() throws {
        let index = String(repeating: "heading\n", count: ProjectMemory.indexLineLimit) + "- [Late choice](choice.md)"
        try write(index, to: memory.appendingPathComponent("MEMORY.md"))
        try write("Use the library.", to: memory.appendingPathComponent("choice.md"))
        let answer = search(["query": "Late library"])
        XCTAssertTrue(answer.contains("[When relevant · choice.md]"))
        XCTAssertTrue(answer.contains("startup limit"))
    }

    func testInvalidArguments() {
        let invalid: [[String: Any]] = [
            ["query": 2], ["query": NSNull()], ["scope": "other"], ["scope": 1], ["limit": "2"],
            ["limit": false], ["limit": 1.5], ["limit": NSNull()], ["path": repo.path]
        ]
        for args in invalid {
            let answer = MemorySearchTool.call(args, context: context)
            XCTAssertTrue(answer.isError, String(describing: args))
            XCTAssertFalse(answer.text.isEmpty)
        }
    }

    func testSkipsLinksAndNamedPipes() throws {
        let outside = root.appendingPathComponent("outside")
        let file = outside.appendingPathComponent("CLAUDE.md")
        try write("- [External contents](missing.md)", to: file)
        let brief = try XCTUnwrap(SpaceBrief.briefURL(spaceID: "sample", stateDirectory: state))
        for (link, target) in [(repo.appendingPathComponent("AGENTS.md"), file), (repo.appendingPathComponent(".claude"), outside),
                              (brief, file), (memory.appendingPathComponent("MEMORY.md"), file), (memory.appendingPathComponent("sub"), outside)] {
            try FileManager.default.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        }
        XCTAssertEqual(mkfifo(memory.appendingPathComponent("pipe.md").path, 0o600), 0)
        try write("Local contents", to: memory.appendingPathComponent("local.md"))
        let answer = search()
        XCTAssertTrue(answer.contains("Local contents"))
        XCTAssertFalse(answer.contains("External contents"))
        XCTAssertFalse(answer.contains("MEMORY.md"))
        XCTAssertFalse(answer.contains("[Team"))
        XCTAssertFalse(answer.contains("[Always"))
    }
}
