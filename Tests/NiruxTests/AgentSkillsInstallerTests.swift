import XCTest
@testable import Nirux

final class AgentSkillsInstallerTests: XCTestCase {
    private var home: String!
    private let skills = ["alpha": "---\nname: alpha\n---\nAlpha", "beta": "---\nname: beta\n---\nBeta"]

    override func setUp() {
        super.setUp()
        home = FileManager.default.temporaryDirectory
            .appendingPathComponent("nirux-skills-\(UUID().uuidString)").path
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: home)
        super.tearDown()
    }

    func testInstallWritesEverySkillToBothRoots() throws {
        XCTAssertEqual(AgentSkillsInstaller.status(of: skills, home: home), .missing)

        try AgentSkillsInstaller.install(skills, home: home)

        for root in [home + "/.agents/skills", home + "/.claude/skills"] {
            for (name, content) in skills {
                let written = try String(contentsOfFile: "\(root)/\(name)/SKILL.md", encoding: .utf8)
                XCTAssertEqual(written, content + "\n")
            }
        }
        XCTAssertEqual(AgentSkillsInstaller.status(of: skills, home: home), .installed)
    }

    func testChangedCopyIsOutdated() throws {
        try AgentSkillsInstaller.install(skills, home: home)
        try "older wording\n".write(
            toFile: home + "/.claude/skills/beta/SKILL.md", atomically: true, encoding: .utf8)
        XCTAssertEqual(AgentSkillsInstaller.status(of: skills, home: home), .outdated)

        try AgentSkillsInstaller.install(skills, home: home)
        XCTAssertEqual(AgentSkillsInstaller.status(of: skills, home: home), .installed)
    }

    func testPartialInstallIsOutdated() throws {
        // Older builds only wrote some of the skills, or one root.
        try AgentSkillsInstaller.install(["alpha": skills["alpha"]!], home: home)
        XCTAssertEqual(AgentSkillsInstaller.status(of: skills, home: home), .outdated)

        try AgentSkillsInstaller.install(skills, home: home)
        try FileManager.default.removeItem(atPath: home + "/.agents/skills/alpha")
        XCTAssertEqual(AgentSkillsInstaller.status(of: skills, home: home), .outdated)
    }

    @MainActor
    func testShippedSkillsAreTheOnesTheChecklistChecks() {
        XCTAssertEqual(NiruxShellView.agentSkills.keys.sorted(), ["nirux-second-opinion", "nirux-show-code", "nirux-worktree"])
    }

    @MainActor
    func testSecondOpinionRunsCodexReadOnlyWithoutTools() {
        // `-s read-only` only sandboxes shell commands: MCP servers and
        // connectors come from the user config and the apps feature.
        XCTAssertTrue(NiruxShellView.secondOpinionSkillContent.contains(
            "codex exec -s read-only --ignore-user-config --disable apps --ephemeral \\\n"))
    }
}
