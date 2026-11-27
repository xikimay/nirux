import XCTest
@testable import Nirux

/// A space's bricks against a real repository: the recheck, the proofs a
/// proposal needs, corrections, the switch, Codex's start, the receiver.
final class SpaceKnowledgeTests: XCTestCase {
    private var root: URL!
    private var state: URL { root.appendingPathComponent("state") }
    private var repo: URL { root.appendingPathComponent("repo") }
    private let spaceID = "space-1"

    override func setUpWithError() throws {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("space-knowledge-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        // Anchors keep symlinks resolved, /private included.
        let real = try XCTUnwrap(realpath(temporary.path, nil))
        defer { free(real) }
        root = URL(fileURLWithPath: String(cString: real))
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        try git("init", "-q", "-b", "main")
        try commit("Sources/Views/Glass.swift", "/// AppKit owns a view's backing\n/// layer: it rewrites its transform.\nfunc glass() {}\n",
                   message: "Merge pull request #12 from me/glass")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    @discardableResult
    private func git(_ arguments: String...) throws -> String {
        let result = GitWorktree.gitRunFull(arguments, cwd: repo.path, timeout: 30, environment: [
            "GIT_AUTHOR_NAME": "Test", "GIT_AUTHOR_EMAIL": "test@example.invalid",
            "GIT_COMMITTER_NAME": "Test", "GIT_COMMITTER_EMAIL": "test@example.invalid", "GIT_CONFIG_GLOBAL": "/dev/null"
        ])
        guard result.status == 0 else { throw NSError(domain: "git", code: Int(result.status), userInfo: [NSLocalizedDescriptionKey: result.stderr]) }
        return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func commit(_ path: String, _ text: String, message: String) throws {
        let url = repo.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
        try git("add", "-A")
        try git("commit", "-q", "-m", message)
    }

    private var anchor: SpaceAnchor { .repository(commonDir: repo.appendingPathComponent(".git").path, topLevel: nil) }
    private var store: KnowledgeStore { SpaceKnowledge.store(spaceID: spaceID, stateDirectory: state)! }

    private func brick(proofs: [Proof] = [.text(path: "Sources/Views/Glass.swift", text: "backing layer: it rewrites"), .pullRequest(12)],
                       paths: [String] = ["Sources/Views/**"]) -> KnowledgeBrick {
        KnowledgeBrick(
            sentence: "AppKit rewrites a view's backing layer: its transform, clip and size.", subject: "backing layer",
            scope: .init(anchor: anchor.key!, name: "repo", paths: paths), proofs: proofs, proposedBy: "the Lead", validatedAt: 10
        )
    }

    /// Writes \`brick\` as validated, as the panel does.
    @discardableResult
    private func validated(_ brick: KnowledgeBrick) throws -> String {
        let id = try store.add(brick)
        var loaded = store.load()
        loaded.state.bricks[id] = BrickState()
        try store.save(loaded.state, now: 10)
        return id
    }

    @discardableResult
    private func recheck(serves: Bool = true, at now: TimeInterval) -> SpaceKnowledge.Pass {
        SpaceKnowledge.recheck(spaceID: spaceID, serves: serves, now: now, stateDirectory: state)
    }

    private var served: [String] { ServedKnowledge.read(store.servedURL)?.bricks.map(\.id) ?? [] }

    // MARK: Recheck

    func testAProofThatStopsHoldingOnTheBaseBranchClosesItsBrick() throws {
        let id = try validated(brick())
        XCTAssertEqual(recheck(at: 100), SpaceKnowledge.Pass())
        XCTAssertEqual(served, [id])
        XCTAssertEqual(store.load().state.checkedTips[anchor.key!], try git("rev-parse", "HEAD"))
        try commit("Sources/Views/Glass.swift", "func glass() {}\n", message: "Drop the comment")
        XCTAssertEqual(recheck(at: 200).closed, [], "a first failure may be a blip")
        XCTAssertEqual(served, [], "a failing brick reaches no agent")
        try commit("README.md", "hello\n", message: "Readme")
        XCTAssertEqual(recheck(at: 300).closed, [id])
        guard case .closed(let why)? = store.load().status(of: id, now: 201, macOS: SpaceKnowledge.macOS) else { return XCTFail("still open") }
        XCTAssertTrue(why.contains("no longer says"), why)
        XCTAssertEqual(served, [], "a closed brick reaches no agent")
    }

    func testABrickIsCheckedAgainWhenItsBaseMovesOrOnceADay() throws {
        let id = try validated(brick())
        recheck(at: 100)
        recheck(at: 200)
        XCTAssertEqual(store.load().state(of: id).checkedAt, 100, "same tip, same day: nothing to check")
        try commit("README.md", "hello\n", message: "Readme")
        recheck(at: 300)
        XCTAssertEqual(store.load().state(of: id).checkedAt, 300)
        recheck(at: 300 + SpaceKnowledge.dailyInterval)
        XCTAssertEqual(store.load().state(of: id).checkedAt, 300 + SpaceKnowledge.dailyInterval)
    }

    func testAProposalNeedsProofsThatHoldNow() throws {
        try commit("Sources/Model/Store.swift", "struct Store {}\n", message: "Store a thing (#14)")
        try commit("Sources/Model/Train.swift", "struct Train {}\n", message: "Merge #15 (feat/train) into the train")
        func problem(_ proofs: [Proof]) -> String? { SpaceKnowledge.proofProblem(of: brick(proofs: proofs), anchor: anchor, now: Date().timeIntervalSince1970) }
        XCTAssertNil(problem([.pullRequest(12), .pullRequest(14), .pullRequest(15), .commit(try git("rev-parse", "HEAD~2"))]))
        XCTAssertNil(problem([.test(path: "Sources/Views/Glass.swift", name: "glass"), .file(path: "Sources/Model")]))
        XCTAssertTrue(problem([.pullRequest(13)])?.contains("PR #13") == true)
        XCTAssertTrue(problem([.commit("deadbeefdeadbeef")])?.contains("commit deadbee") == true)
        XCTAssertTrue(problem([.file(path: "Sources/Gone.swift")])?.contains("is gone") == true)
        XCTAssertTrue(problem([.said(quote: "keep it", day: "2999-01-01")])?.contains("past day") == true)
        XCTAssertNil(problem([.said(quote: "keep it", day: "2026-11-01")]))
    }

    func testABareRepositoryIsCheckedThroughItsGitDir() throws {
        let bare = root.appendingPathComponent("bare.git")
        try git("clone", "-q", "--bare", repo.path, bare.path)
        let anchor = SpaceAnchor.repository(commonDir: bare.path, topLevel: nil)
        XCTAssertNil(anchor.folder, "no main checkout to run git in")
        XCTAssertNil(SpaceKnowledge.proofProblem(of: brick(), anchor: anchor, now: Date().timeIntervalSince1970))
        XCTAssertNotNil(SpaceKnowledge.proofProblem(of: brick(proofs: [.pullRequest(13)]), anchor: anchor, now: Date().timeIntervalSince1970))
        // Its HEAD names its default branch, whatever it is called.
        try git("--git-dir=" + bare.path, "branch", "-q", "-m", "main", "trunk")
        XCTAssertNotNil(SpaceKnowledge.baseTip(gitDir: bare.path))
        try git("branch", "-q", "-m", "main", "trunk")
        XCTAssertNil(SpaceKnowledge.baseTip(gitDir: repo.appendingPathComponent(".git").path), "a checkout's HEAD follows its branch")
    }

    func testCorrectionsInTwoTasksMakeItsBrickSuspectUntilTheUserConfirmsIt() throws {
        let id = try validated(brick())
        recheck(at: 100)
        try FileManager.default.createDirectory(at: store.folder, withIntermediateDirectories: true)
        func correct(in task: String, at time: TimeInterval) {
            KnowledgeUse.append([KnowledgeUse(time: time, brick: id, kind: .corrected, task: task, agent: "claude")], in: store)
        }
        correct(in: "w1", at: 150)
        correct(in: "w1", at: 160)
        XCTAssertEqual(recheck(at: 200).suspected, [], "one task's corrections are recorded, not acted on")
        XCTAssertEqual(served, [id])
        correct(in: "w2", at: 210)
        XCTAssertEqual(recheck(at: 220).suspected, [id])
        XCTAssertEqual(served, [])
        var loaded = store.load()
        XCTAssertTrue(loaded.reconfirm(id, now: 300, macOS: SpaceKnowledge.macOS))
        try store.save(loaded.state, now: 300)
        correct(in: "w3", at: 310)
        XCTAssertEqual(recheck(at: 400), SpaceKnowledge.Pass(), "corrections before the confirmation no longer count")
        XCTAssertEqual(served, [id])
    }

    func testAgentsFlaggingABrickWrongCountLikeCorrections() throws {
        let id = try validated(brick())
        recheck(at: 100)
        try KnowledgeFlag.append(KnowledgeFlag(time: 150, kind: .error, brick: id, about: "clip", text: "the code sets bounds", evidence: nil, task: "w1"), in: store)
        try KnowledgeFlag.append(KnowledgeFlag(time: 151, kind: .gap, brick: nil, about: "train", text: "riders are inner merges", evidence: nil, task: "w2"), in: store)
        XCTAssertEqual(recheck(at: 200).suspected, [], "one task's flag is shown, not acted on; a gap names no brick")
        KnowledgeUse.append([KnowledgeUse(time: 210, brick: id, kind: .corrected, task: "w2", agent: "claude")], in: store)
        XCTAssertEqual(recheck(at: 220).suspected, [id])
        guard case .suspect(let why)? = store.load().status(of: id, now: 221, macOS: SpaceKnowledge.macOS) else { return XCTFail("not suspect") }
        XCTAssertTrue(why.hasPrefix("You and agents"), why)
    }

    func testAnUnansweredCheckIsTriedAgainAtTheNextPass() throws {
        // Nothing listens on port 9: the page can't be read.
        let id = try validated(brick(proofs: [.file(path: "Sources/Views/Glass.swift"), .page(url: "https://127.0.0.1:9/glass", quote: "a quote of the page")]))
        recheck(at: SpaceKnowledge.dailyInterval + 100)
        let state = store.load().state
        XCTAssertNil(state.checkedTips[anchor.key!], "the base isn't recorded as checked")
        XCTAssertNil(state.dailyChecks?[anchor.key!], "nor the daily check")
        XCTAssertEqual(store.load().status(of: id, now: SpaceKnowledge.dailyInterval + 101, macOS: SpaceKnowledge.macOS), .open)
    }

    func testOnlyAMissingCommitIsOffTheBranchAndProposalsKeepFullSHAs() throws {
        let head = try git("rev-parse", "HEAD")
        let resolved = SpaceKnowledge.resolvingCommits(of: brick(proofs: [.commit(String(head.prefix(8)))]), anchor: anchor)
        XCTAssertEqual(resolved.proofs, [.commit(head)])
        let gitDir = repo.appendingPathComponent(".git").path
        XCTAssertEqual(SpaceKnowledge.repositorySource(gitDir: gitDir, tip: head, readsPages: false).hasCommit(String(repeating: "ab", count: 20)), false)
        let notARepository = root.appendingPathComponent("empty")
        try FileManager.default.createDirectory(at: notARepository, withIntermediateDirectories: true)
        XCTAssertNil(SpaceKnowledge.repositorySource(gitDir: notARepository.path, tip: head, readsPages: false).hasCommit(head), "a git error says nothing")
    }

    func testTurningTheSwitchOffTakesBackWhatAgentsGet() throws {
        let id = try validated(brick())
        recheck(at: 100)
        XCTAssertEqual(served, [id])
        let before = store.load().state
        recheck(serves: false, at: 200)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.servedURL.path))
        XCTAssertEqual(store.load().state, before)
    }

    // MARK: Codex

    func testCodexGetsAtItsStartTheBricksOfFilesItsBranchChanges() throws {
        try validated(brick())
        recheck(at: Date().timeIntervalSince1970)
        try git("checkout", "-q", "-b", "task")
        try Data("notes\n".utf8).write(to: repo.appendingPathComponent("NOTES.md"))
        // Its own bound, far past any runner's git: the test reads the result, not the machine's speed.
        let gitTimeout: TimeInterval = 120
        XCTAssertEqual(SpaceKnowledge.writeCodexInstructions(
            spaceID: spaceID, task: "w1", launchDirectory: repo.path, withBrief: false, gitTimeout: gitTimeout, stateDirectory: state
        ), [])
        try Data("func glass() { }\n".utf8).write(to: repo.appendingPathComponent("Sources/Views/Glass.swift"))
        let brief = try XCTUnwrap(SpaceBrief.briefURL(spaceID: spaceID, stateDirectory: state))
        try Data("- Keep it short.".utf8).write(to: brief)
        XCTAssertEqual(SpaceKnowledge.writeCodexInstructions(
            spaceID: spaceID, task: "w1", launchDirectory: repo.path, withBrief: true, gitTimeout: gitTimeout, stateDirectory: state
        ).count, 1)
        let file = SpaceKnowledge.codexFile(in: store, task: "w1").path
        let text = try String(contentsOfFile: file, encoding: .utf8)
        XCTAssertTrue(text.hasPrefix("\"# Space brief"), "one TOML string, the brief first")
        XCTAssertTrue(text.contains("Keep it short."))
        XCTAssertTrue(text.contains("about the files this branch changes"))
        XCTAssertTrue(text.contains("AppKit rewrites a view's backing layer"))
        XCTAssertEqual(KnowledgeUse.load(in: store).map(\.agent), ["codex"])

        // Closed since: a restarted column replays the launch naming this file.
        try git("checkout", "-q", "main")
        try git("stash", "push", "-q", "-u", "-m", "space-knowledge-test")
        try commit("Sources/Views/Glass.swift", "func glass() {}\n", message: "Drop the comment")
        recheck(at: Date().timeIntervalSince1970 + 1)
        let replayed = try String(contentsOfFile: file, encoding: .utf8)
        XCTAssertTrue(replayed.contains("Keep it short."))
        XCTAssertFalse(replayed.contains("backing layer"), replayed)
    }

    // MARK: The receiver

    func testTheReceiverHandsClaudeTheBrickAboutTheFileItRead() throws {
        try validated(brick())
        recheck(at: Date().timeIntervalSince1970)
        let payload: [String: Any] = [
            "hook_event_name": "PostToolUse", "session_id": "s1", "tool_name": "Read", "cwd": repo.path,
            "tool_input": ["file_path": "Sources/Views/Glass.swift"], "tool_use_id": "t1"
        ]
        func receive() throws -> Data {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: try niruxExecutable())
            process.arguments = ["--hook", "claude"]
            process.environment = [
                "NIRUX_STATE_DIR": state.path, "NIRUX_AGENT_UUID": "uuid-1", "NIRUX_PROFILE_ID": spaceID, "NIRUX_WORKSPACE_ID": "w1",
                "HOME": root.path, "PATH": "/usr/bin:/bin"
            ]
            let stdin = Pipe()
            let stdout = Pipe()
            process.standardInput = stdin
            process.standardOutput = stdout
            try process.run()
            stdin.fileHandleForWriting.write(try JSONSerialization.data(withJSONObject: payload))
            try stdin.fileHandleForWriting.close()
            let output = stdout.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return output
        }
        let output = try receive()
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: output) as? [String: Any])
        let specific = try XCTUnwrap(json["hookSpecificOutput"] as? [String: Any])
        XCTAssertEqual(specific["hookEventName"] as? String, "PostToolUse")
        XCTAssertTrue((specific["additionalContext"] as? String)?.contains("AppKit rewrites a view's backing layer") == true)
        XCTAssertEqual(KnowledgeUse.load(in: store).map(\.task), ["w1"])
        XCTAssertTrue(try receive().isEmpty, "once per session")
    }
}

/// propose_brick's arguments, as the Lead sends them.
final class ProposeBrickArgumentsTests: XCTestCase {
    private let valid: [String: Any] = [
        "sentence": "GitHub counts a cancelled check as failed on a pull request.", "subject": "cancelled check",
        "paths": ["Sources/Nirux/Model/MergeQueue+Checks.swift"],
        "proofs": [
            ["kind": "pull_request", "number": 512], ["kind": "commit", "sha": "ABC1234"], ["kind": "file", "path": "a.swift"],
            ["kind": "text", "path": "a.swift", "text": "case cancelled"], ["kind": "test", "path": "T.swift", "name": "testCancelled"],
            ["kind": "page", "url": "https://docs.github.com/x", "quote": "a cancelled check fails"],
            ["kind": "said", "quote": "treat it as red", "day": "2026-11-20"]
        ]
    ]

    func testEachProofKindTakesWhatItNames() throws {
        var arguments = valid
        arguments["proofs"] = Array((valid["proofs"] as! [[String: Any]]).prefix(6))
        guard case .success(let parsed) = LeadTools.brickProposal(arguments) else { return XCTFail("refused") }
        XCTAssertEqual(parsed.proofs, [
            .pullRequest(512), .commit("abc1234"), .file(path: "a.swift"), .text(path: "a.swift", text: "case cancelled"),
            .test(path: "T.swift", name: "testCancelled"), .page(url: "https://docs.github.com/x", quote: "a cancelled check fails")
        ])
        XCTAssertNil(LeadTools.problem(tool: LeadTools.proposeBrick, arguments: arguments))
        XCTAssertNotNil(LeadTools.problem(tool: LeadTools.proposeBrick, arguments: valid), "at most six proofs")
    }

    func testWhatIsWrongIsSaid() {
        for (key, value, words) in [
            ("proofs", [["kind": "guess"]] as Any, "kind is one of"), ("proofs", [["kind": "text", "path": "a.swift"]] as Any, "misses"),
            ("paths", "a.swift" as Any, "array of strings"), ("replaces", "old" as Any, "b-"), ("macos", "yes" as Any, "true or false"),
            ("sentence", "One fact. And another one here." as Any, "one sentence")
        ] {
            var arguments = valid
            arguments["proofs"] = [["kind": "pull_request", "number": 1]]
            arguments[key] = value
            let problem = LeadTools.problem(tool: LeadTools.proposeBrick, arguments: arguments) ?? ""
            XCTAssertTrue(problem.contains(words), "\(key): \(problem)")
        }
    }
}

/// flag_knowledge, as an agent calls it through the MCP server.
final class FlagKnowledgeToolTests: XCTestCase {
    private let root = FileManager.default.temporaryDirectory.appendingPathComponent("flag-tool-\(UUID().uuidString)")
    private var state: URL { root.appendingPathComponent("state") }
    private func context(workspace: String? = "w1") -> NiruxMCPServer.Context {
        var environment = ["NIRUX_PROFILE_ID": "space-1"]
        if let workspace {
            environment["NIRUX_WORKSPACE_ID"] = workspace
            environment["NIRUX_AGENT_UUID"] = "agent-1"
            environment[NiruxLaunchAuthorization.environmentKey] = "launch-1"
        }
        return .init(workingDirectory: root.path, environment: environment, stateDirectory: state, claudeProjects: root.appendingPathComponent("claude"))
    }
    private var store: KnowledgeStore { SpaceKnowledge.store(spaceID: "space-1", stateDirectory: state)! }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testAnAgentFlagsOnceAndChangesNoBrick() throws {
        let gap: [String: Any] = ["kind": "gap", "about": "merge train", "text": "a rider shows as Merge #N into the train", "evidence": "#801"]
        let result = FlagKnowledgeTool.call(gap, context: context(), now: 100)
        XCTAssertFalse(result.isError, result.text)
        XCTAssertEqual(KnowledgeFlag.load(in: store).map(\.about), ["merge train"])
        XCTAssertEqual(KnowledgeFlag.load(in: store).first?.task, "w1")
        XCTAssertTrue(FlagKnowledgeTool.call(gap, context: context(), now: 200).isError, "the same flag from the same task, the same day")
        XCTAssertFalse(FlagKnowledgeTool.call(gap, context: context(workspace: "w2"), now: 200).isError, "another task may")
        XCTAssertTrue(store.load().bricks.isEmpty)
    }

    func testWhatAFlagCantHold() {
        let calls: [[String: Any]] = [
            ["kind": "guess", "about": "a", "text": "b"],
            ["kind": "gap", "about": "a", "text": "reach me at jane.doe@example.com"],
            ["kind": "error", "about": "a", "text": "wrong", "brick": "b-0123456789ab"],
            ["kind": "gap", "about": "a", "text": "b", "extra": 1]
        ]
        for call in calls {
            XCTAssertTrue(FlagKnowledgeTool.call(call, context: context(), now: 1).isError, "\(call)")
        }
        XCTAssertTrue(FlagKnowledgeTool.call(["kind": "gap", "about": "a", "text": "b"], context: context(workspace: nil), now: 1).isError,
                      "only an agent Nirux started")
        XCTAssertTrue(KnowledgeFlag.load(in: store).isEmpty)
    }
}
