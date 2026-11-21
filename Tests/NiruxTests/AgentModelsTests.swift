import XCTest
@testable import Nirux

final class AgentModelsTests: XCTestCase {
    func testModelChoicesUseTheSelectedAgentsCatalog() throws {
        let installed = AgentCLIAvailability(claudePath: "claude", codexPath: "codex", agyPath: "agy")
        func model(_ agent: CodingAgent, _ name: String) throws -> String? {
            try AgentModels.validate(TaskAgentSelection(agent: agent, model: name), environment: [:], installed: installed) { agent, _, _ in
                switch agent {
                case .agy: return AgentModels.agyChoices("Fetching available models…\nneon-low\tGemini Neon (Low)\n")
                case .codex: return AgentModels.codexChoices(#"{"models":[{"slug":"public","visibility":"list"},{"slug":"hidden","visibility":"hide"}]}"#)
                default: XCTFail("Claude has no listing command"); return []
                }
            }.model
        }
        XCTAssertEqual(try model(.agy, "Neon-Low"), "neon-low")
        XCTAssertEqual(try model(.codex, "hidden"), "hidden")
        XCTAssertThrowsError(try model(.agy, "unknown")) { XCTAssertTrue($0.localizedDescription.contains("neon-low (Gemini Neon (Low))")) }
        XCTAssertThrowsError(try model(.codex, "unknown")) {
            XCTAssertTrue($0.localizedDescription.contains("public"))
            XCTAssertFalse($0.localizedDescription.contains("hidden"))
        }
        XCTAssertEqual(try model(.claude, "OPUS[1m]"), "opus[1m]")
        XCTAssertEqual(try model(.claude, "claude-sonnet-4-6"), "claude-sonnet-4-6")
        XCTAssertThrowsError(try model(.claude, "--dangerously-skip-permissions"))
        XCTAssertThrowsError(try AgentModels.validate(.init(agent: .agy), environment: [:], installed: .init()))
    }

    func testModelFromArgvIsAnOptionBeforeTheEndOfOptions() {
        XCTAssertEqual(AgentModels.launchModel(arguments: ["codex", "resume", "id", "-m", "one"]), "one")
        XCTAssertEqual(AgentModels.launchModel(arguments: ["agy", "--model=two"]), "two")
        XCTAssertEqual(AgentModels.launchModel(arguments: ["claude", "--model", "sonnet"]), "sonnet")
        XCTAssertNil(AgentModels.launchModel(arguments: ["agy", "--", "--model", "two"]))
        XCTAssertNil(AgentModels.launchModel(arguments: ["agy", "--model"]))
        XCTAssertNil(AgentModels.launchModel(arguments: ["agy", "--model="]))
        XCTAssertNil(AgentModels.launchModel(arguments: ["codex", "--model", "--sandbox"]))
    }
}
