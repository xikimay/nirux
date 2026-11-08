import XCTest
@testable import Nirux

final class AgentSkillsInstallerTests: XCTestCase {
    private var home: String!
    private var state: URL!
    private let skills = ["alpha": "---\nname: alpha\n---\nAlpha", "beta": "---\nname: beta\n---\nBeta"]

    override func setUp() {
        super.setUp()
        home = FileManager.default.temporaryDirectory
            .appendingPathComponent("nirux-skills-\(UUID().uuidString)").path
        state = URL(fileURLWithPath: home + "/state")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: home)
        super.tearDown()
    }

    func testInstallWritesEverySkillToBothRoots() throws {
        XCTAssertEqual(AgentSkillsInstaller.status(of: skills, home: home), .missing)

        try AgentSkillsInstaller.install(skills, home: home, stateDirectory: state)

        for root in [home + "/.agents/skills", home + "/.claude/skills"] {
            for (name, content) in skills {
                let written = try String(contentsOfFile: "\(root)/\(name)/SKILL.md", encoding: .utf8)
                XCTAssertEqual(written, content + "\n")
            }
        }
        XCTAssertEqual(AgentSkillsInstaller.status(of: skills, home: home), .installed)
    }

    func testChangedCopyIsOutdated() throws {
        try AgentSkillsInstaller.install(skills, home: home, stateDirectory: state)
        try "older wording\n".write(
            toFile: home + "/.claude/skills/beta/SKILL.md", atomically: true, encoding: .utf8)
        XCTAssertEqual(AgentSkillsInstaller.status(of: skills, home: home), .outdated)

        try AgentSkillsInstaller.install(skills, home: home, stateDirectory: state)
        XCTAssertEqual(AgentSkillsInstaller.status(of: skills, home: home), .installed)
    }

    func testPartialInstallIsOutdated() throws {
        // Older builds only wrote some of the skills, or one root.
        try AgentSkillsInstaller.install(["alpha": skills["alpha"]!], home: home, stateDirectory: state)
        XCTAssertEqual(AgentSkillsInstaller.status(of: skills, home: home), .outdated)

        try AgentSkillsInstaller.install(skills, home: home, stateDirectory: state)
        try FileManager.default.removeItem(atPath: home + "/.agents/skills/alpha")
        XCTAssertEqual(AgentSkillsInstaller.status(of: skills, home: home), .outdated)
    }

    // MARK: - Updates at launch

    /// The next version's wording.
    private var newSkills: [String: String] { skills.mapValues { $0 + ", reworded" } }

    @discardableResult
    private func update(
        _ skills: [String: String], shippedBefore: [String: Set<String>] = [:]
    ) -> AgentSkillsInstaller.UpdateReport {
        AgentSkillsInstaller.updateNiruxCopies(
            of: skills, home: home, stateDirectory: state, shippedBefore: shippedBefore)
    }

    private func write(_ text: String, to path: String) throws {
        try FileManager.default.createDirectory(
            atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try text.write(toFile: path, atomically: true, encoding: .utf8)
    }

    private func read(_ path: String) throws -> String {
        try String(contentsOfFile: path, encoding: .utf8)
    }

    func testUpdateRewritesTheCopiesNiruxWrote() throws {
        try AgentSkillsInstaller.install(skills, home: home, stateDirectory: state)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: state.appendingPathComponent(AgentSkillsInstaller.recordFileName).path))

        XCTAssertEqual(update(newSkills).updated.count, 4)
        XCTAssertEqual(AgentSkillsInstaller.status(of: newSkills, home: home), .installed)
    }

    func testUpdateKeepsACopyTheUserEdited() throws {
        try AgentSkillsInstaller.install(skills, home: home, stateDirectory: state)
        let edited = home + "/.claude/skills/beta/SKILL.md"
        try write("my own wording\n", to: edited)

        XCTAssertEqual(update(newSkills).kept, [edited])
        XCTAssertEqual(try read(edited), "my own wording\n")
        XCTAssertEqual(try read(home + "/.agents/skills/beta/SKILL.md"), newSkills["beta"]! + "\n")
        // Getting Started keeps offering the update.
        XCTAssertEqual(AgentSkillsInstaller.status(of: newSkills, home: home), .outdated)
    }

    func testUpdateKnowsTextsShippedBeforeRecords() throws {
        // Installed by builds that kept no record: only the shipped list
        // tells alpha's text from an edit.
        let shipped = home + "/.claude/skills/alpha/SKILL.md"
        let unknown = home + "/.claude/skills/beta/SKILL.md"
        try write(skills["alpha"]! + "\n", to: shipped)
        try write(skills["beta"]! + "\n", to: unknown)

        let report = update(
            newSkills, shippedBefore: ["alpha": [AgentSkillsInstaller.digest(Data((skills["alpha"]! + "\n").utf8))]])

        XCTAssertEqual(report.updated, [shipped])
        XCTAssertEqual(report.kept, [unknown])
    }

    func testThisVersionsTextIsKnownToTheNextOne() throws {
        // A matching copy nothing recorded (copied by hand, or written by a
        // Nirux on a state of its own).
        let path = home + "/.claude/skills/alpha/SKILL.md"
        try write(skills["alpha"]! + "\n", to: path)
        XCTAssertEqual(update(skills), AgentSkillsInstaller.UpdateReport())

        XCTAssertEqual(update(newSkills).updated, [path])
    }

    func testUpdateNeverInstallsASkill() throws {
        try AgentSkillsInstaller.install(["alpha": skills["alpha"]!], home: home, stateDirectory: state)
        try FileManager.default.removeItem(atPath: home + "/.agents/skills/alpha")

        XCTAssertEqual(update(newSkills).updated, [home + "/.claude/skills/alpha/SKILL.md"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: home + "/.agents/skills/alpha"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: home + "/.agents/skills/beta"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: home + "/.claude/skills/beta"))
    }

    func testUpdateKeepsALinkedCopy() throws {
        try AgentSkillsInstaller.install(skills, home: home, stateDirectory: state)
        let target = home + "/dotfiles/alpha.md"
        try write(skills["alpha"]! + "\n", to: target)
        let link = home + "/.claude/skills/alpha/SKILL.md"
        try FileManager.default.removeItem(atPath: link)
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: target)

        XCTAssertEqual(update(newSkills).kept, [link])
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: link), target)
        XCTAssertEqual(try read(target), skills["alpha"]! + "\n")
    }

    func testOnlyTheInstalledAppOnTheRealStateUpdatesAtLaunch() {
        let app = URL(fileURLWithPath: "/Applications/Nirux.app")
        XCTAssertTrue(AgentSkillsInstaller.updatesOnLaunch(environment: [:], bundleURL: app))
        XCTAssertFalse(AgentSkillsInstaller.updatesOnLaunch(environment: ["NIRUX_STATE_DIR": "/tmp/x"], bundleURL: app))
        XCTAssertFalse(AgentSkillsInstaller.updatesOnLaunch(
            environment: [:], bundleURL: URL(fileURLWithPath: "/tmp/nirux/.build/debug")))
    }

    @MainActor
    func testShippedTextsBelongToSkillsNiruxShips() {
        let names = Set(NiruxShellView.agentSkills.keys)
        for (name, digests) in AgentSkillsInstaller.textsShippedBeforeRecords {
            XCTAssertTrue(names.contains(name), name)
            for digest in digests {
                XCTAssertTrue(digest.count == 64 && digest.allSatisfy { "0123456789abcdef".contains($0) }, digest)
            }
        }
    }

    @MainActor
    func testShippedSkillsAreTheOnesTheChecklistChecks() {
        XCTAssertEqual(NiruxShellView.agentSkills.keys.sorted(), ["nirux-draft", "nirux-second-opinion", "nirux-show-code", "nirux-worktree"])
    }

    @MainActor
    func testSecondOpinionRunsCodexReadOnlyWithoutTools() {
        // `-s read-only` only sandboxes shell commands: MCP servers and
        // connectors come from the user config and the apps feature.
        XCTAssertTrue(NiruxShellView.secondOpinionSkillContent.contains(
            "codex exec -s read-only --ignore-user-config --disable apps --ephemeral \\\n"))
    }
}
