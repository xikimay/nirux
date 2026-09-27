import XCTest
@testable import Nirux

/// The board config's values and their JSON (see BoardConfig).
final class BoardConfigTests: XCTestCase {
    private func decode(_ json: String) throws -> BoardConfig {
        try JSONDecoder().decode(BoardConfig.self, from: Data(json.utf8))
    }

    private var complete: BoardConfig {
        BoardConfig(
            repository: "xikimay/nirux",
            baseBranch: "main",
            requiredChecks: ["test", "CodeQL / Analyze (swift)"],
            postMergeWorkflow: .workflow("nightly.yml"),
            mergeMethod: .squash,
            checksTimeoutMinutes: 45,
            postMergeTimeoutMinutes: 20
        )
    }

    func testAnEmptyObjectGetsTheDefaults() throws {
        let config = try decode("{}")
        XCTAssertNil(config.repository)
        XCTAssertNil(config.baseBranch)
        XCTAssertEqual(config.requiredChecks, ["test"])
        XCTAssertEqual(config.postMergeWorkflow, .unset)
        XCTAssertEqual(config.mergeMethod, .merge)
        XCTAssertEqual(config.checksTimeoutMinutes, 30)
        XCTAssertEqual(config.postMergeTimeoutMinutes, 30)
        XCTAssertEqual(config, BoardConfig())
    }

    func testNullsAndEmptyStringsReadAsNotSet() throws {
        let config = try decode("""
        {"repository": "", "baseBranch": null, "requiredChecks": null, "postMergeWorkflow": "",
         "mergeMethod": null, "checksTimeoutMinutes": null}
        """)
        XCTAssertEqual(config, BoardConfig())
    }

    func testAConfigRoundTripsThroughJSON() throws {
        let data = try JSONEncoder().encode(complete)
        XCTAssertEqual(try JSONDecoder().decode(BoardConfig.self, from: data), complete)

        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["schemaVersion"] as? Int, 1)
        XCTAssertEqual(object["postMergeWorkflow"] as? String, "nightly.yml")
        XCTAssertEqual(object["mergeMethod"] as? String, "squash")
    }

    func testUnsetValuesAreLeftOutOfTheFile() throws {
        let data = try JSONEncoder().encode(BoardConfig())
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(Set(object.keys), [
            "schemaVersion", "requiredChecks", "mergeMethod", "checksTimeoutMinutes", "postMergeTimeoutMinutes"
        ])
    }

    func testThePostMergeWorkflowHasThreeStates() throws {
        XCTAssertEqual(try decode("{}").postMergeWorkflow, .unset)
        XCTAssertEqual(try decode(#"{"postMergeWorkflow": "none"}"#).postMergeWorkflow, .noWorkflow)
        XCTAssertEqual(try decode(#"{"postMergeWorkflow": "nightly.yml"}"#).postMergeWorkflow, .workflow("nightly.yml"))

        for state in [BoardConfig.PostMergeWorkflow.unset, .noWorkflow, .workflow("release.yaml")] {
            var config = complete
            config.postMergeWorkflow = state
            let decoded = try JSONDecoder().decode(BoardConfig.self, from: JSONEncoder().encode(config))
            XCTAssertEqual(decoded.postMergeWorkflow, state)
        }
    }

    /// Read as `merge` here; the store keeps such a file read-only (see
    /// BoardConfigStoreTests), so the queue never merges with a method the
    /// user didn't pick.
    func testAnUnknownMergeMethodOrRebaseReadsAsMerge() throws {
        XCTAssertEqual(try decode(#"{"mergeMethod": "rebase"}"#).mergeMethod, .merge)
        XCTAssertEqual(try decode(#"{"mergeMethod": "fast-forward"}"#).mergeMethod, .merge)
        XCTAssertEqual(try decode(#"{"mergeMethod": "squash"}"#).mergeMethod, .squash)
        XCTAssertFalse(BoardConfig.MergeMethod.allCases.map(\.rawValue).contains("rebase"))
    }

    func testInvalidValuesAreKeptAsRead() throws {
        let config = try decode("""
        {"requiredChecks": [], "checksTimeoutMinutes": 0, "postMergeWorkflow": "Nightly"}
        """)
        XCTAssertEqual(config.requiredChecks, [])
        XCTAssertEqual(config.checksTimeoutMinutes, 0)
        XCTAssertEqual(config.postMergeWorkflow, .workflow("Nightly"))
    }

    func testAValueOfTheWrongTypeFailsTheDecoding() {
        XCTAssertThrowsError(try decode(#"{"checksTimeoutMinutes": "30"}"#))
        XCTAssertThrowsError(try decode(#"{"requiredChecks": "test"}"#))
    }

    // MARK: - Validation

    private func queueProblems(_ config: BoardConfig) -> [String] {
        BoardConfigStore.Loaded(config: config, status: .loaded).queueStartProblems
    }

    func testACompleteConfigHasNoProblemAndCanStartTheQueue() {
        XCTAssertEqual(complete.problems, [])
        XCTAssertEqual(queueProblems(complete), [])
        var none = complete
        none.postMergeWorkflow = .noWorkflow
        XCTAssertEqual(queueProblems(none), [])
    }

    func testTheQueueNeedsARepositoryAndAChosenPostMergeWorkflow() {
        var unset = complete
        unset.postMergeWorkflow = .unset
        XCTAssertEqual(unset.problems, [], "Save accepts an unset workflow")
        XCTAssertEqual(queueProblems(unset), ["Choose the post-merge workflow in Board Settings…, or None."])

        var noRepository = complete
        noRepository.repository = nil
        XCTAssertEqual(noRepository.problems, ["Set the repository (owner/name)."])
        XCTAssertEqual(queueProblems(noRepository), ["Set the repository (owner/name)."])
    }

    func testTheRepositoryComparesWithoutCase() {
        var config = complete
        config.repository = "Acme/Widgets"
        XCTAssertEqual(config.gitHubRepository, GitHubRepository(owner: "acme", name: "widgets"))
        config.repository = "not valid"
        XCTAssertNil(config.gitHubRepository)
    }

    func testEveryProblemIsReported() {
        let config = BoardConfig(
            repository: "not a repository",
            baseBranch: nil,
            requiredChecks: ["test", " "],
            postMergeWorkflow: .workflow("nightly"),
            checksTimeoutMinutes: 0,
            postMergeTimeoutMinutes: 241
        )
        XCTAssertEqual(config.problems.count, 5)
        var noChecks = complete
        noChecks.requiredChecks = []
        XCTAssertEqual(noChecks.problems, ["Add at least one required check."])
    }

    func testRepositoriesUseGitHubsCharacters() {
        for valid in ["xikimay/nirux", "Lakr233/libghostty-spm", "a/b", "my-org/repo.name_2", "o/.github", "user_emu/r"] {
            XCTAssertTrue(BoardConfig.isValidRepository(valid), valid)
        }
        for invalid in [
            "", "nirux", "a/b/c", "/nirux", "xikimay/", "-org/repo", "org/.", "org/..", "o r/g", "org/rép",
            "https://github.com/a/b", String(repeating: "a", count: 40) + "/b", "a/" + String(repeating: "b", count: 101),
            "acme/widgets.git", "acme/widgets.GIT"
        ] {
            XCTAssertFalse(BoardConfig.isValidRepository(invalid), invalid)
        }
    }

    func testBranchNamesFollowGit() {
        for valid in ["main", "release/1.2", "feat/board-config", "v2.x"] {
            XCTAssertTrue(BoardConfig.isValidBranchName(valid), valid)
        }
        for invalid in [
            "", "-main", "a b", "a..b", "a//b", "/main", "main/", "main.", "main.lock", "a@{1}", "@", "a:b",
            "a~1", "a^", "a?", "a*", "a[b", "a\\b", ".hidden", "a/.b", "tab\there", "HEAD", "refs/heads/main", "+main"
        ] {
            XCTAssertFalse(BoardConfig.isValidBranchName(invalid), invalid)
        }
    }

    func testCheckNamesHoldOneLine() {
        for valid in ["test", "CodeQL / Analyze (swift)", "build (macos-15, debug)"] {
            XCTAssertTrue(BoardConfig.isValidCheckName(valid), valid)
        }
        for invalid in ["", "  ", "a\nb", "a\u{2028}b", "a\u{85}b", "a\tb"] {
            XCTAssertFalse(BoardConfig.isValidCheckName(invalid), invalid)
        }
    }

    func testWorkflowFilesAreYAMLFileNames() {
        for valid in ["nightly.yml", "tests.yaml", "Release.YML"] {
            XCTAssertTrue(BoardConfig.isValidWorkflowFile(valid), valid)
        }
        for invalid in ["", ".yml", "nightly", "Nightly", "workflows/nightly.yml", "-x.yml", "a\nb.yml"] {
            XCTAssertFalse(BoardConfig.isValidWorkflowFile(invalid), invalid)
        }
    }
}
