import Foundation
import NiruxCore
import Testing

struct KnowledgeDeliveryTests {
    typealias Served = ServedKnowledge.Brick
    static let anchor = KnowledgeBrickTests.anchor

    static func served(_ id: String, paths: [String] = ["Sources/Nirux/Views/**"], sentence: String? = nil, subject: String = "backing layer",
                       anchor: String = anchor, until: TimeInterval? = nil, macOS: Int? = nil) -> Served {
        Served(id: id, sentence: sentence ?? "Fact \(id) about the views, as one sentence.", subject: subject, anchor: anchor, name: "nirux",
               paths: paths, proof: "PR #582", servedUntil: until, macOS: macOS)
    }

    // MARK: Paths

    @Test func pathsNameAFileAFolderOrAPattern() {
        #expect(KnowledgePath.matches("Sources/Nirux/Views/Glass.swift", "Sources/Nirux/Views/Glass.swift"))
        #expect(!KnowledgePath.matches("Sources/Nirux/Views/Glass.swift", "Sources/Nirux/Views/Glass.swift.orig"))
        #expect(KnowledgePath.matches("Sources/Nirux/Views", "Sources/Nirux/Views/Deep/Glass.swift"))
        #expect(KnowledgePath.matches("Sources/Nirux/Views/", "Sources/Nirux/Views/Glass.swift"))
        #expect(!KnowledgePath.matches("Sources/Nirux/Views", "Sources/Nirux/ViewsOld/Glass.swift"))
        #expect(KnowledgePath.matches("Sources/**/Glass*.swift", "Sources/Nirux/Views/GlassView.swift"))
        #expect(KnowledgePath.matches("Sources/**/Glass*.swift", "Sources/GlassView.swift"))
        #expect(!KnowledgePath.matches("Sources/*.swift", "Sources/Nirux/A.swift"))
        #expect(KnowledgePath.matches("Tests/*Tests.swift", "Tests/AppTests.swift"))
        #expect(KnowledgePath.matches("a?.swift", "ab.swift") && !KnowledgePath.matches("a?.swift", "a/.swift"))
        #expect(KnowledgePath.matches("docs/**", "docs/design/a.md"))
        #expect(!KnowledgePath.matches("docs/(x)+", "docs/xx"))
    }

    // MARK: Picking

    @Test func aFileTouchBringsEachOfItsBricksOncePerSession() {
        let knowledge = ServedKnowledge(bricks: [
            Self.served("b-1"), Self.served("b-2", paths: ["Sources/Nirux/Model/**"]), Self.served("b-3", anchor: "git:/other/.git")
        ])
        var session = KnowledgeSession()
        let picked = KnowledgeDelivery.pick(knowledge, anchor: Self.anchor, path: "Sources/Nirux/Views/A.swift", session: session, now: 0, macOS: 27)
        #expect(picked.map(\.id) == ["b-1"])
        session.delivered["b-1"] = 0
        #expect(KnowledgeDelivery.pick(knowledge, anchor: Self.anchor, path: "Sources/Nirux/Views/A.swift", session: session, now: 0, macOS: 27).isEmpty)
        session.pending = ["b-2"]
        #expect(KnowledgeDelivery.pick(knowledge, anchor: Self.anchor, path: "Sources/Nirux/Model/B.swift", session: session, now: 0, macOS: 27).isEmpty)
    }

    @Test func aSessionNeverGetsMoreThanItsBudget() {
        let long = String(repeating: "word ", count: 55) + "end."
        let knowledge = ServedKnowledge(bricks: (1...20).map { Self.served("b-\($0)", sentence: long) })
        var session = KnowledgeSession()
        var total = 0
        for index in 0..<10 {
            let picked = KnowledgeDelivery.pick(knowledge, anchor: Self.anchor, path: "Sources/Nirux/Views/F\(index).swift", session: session, now: 0, macOS: 27)
            guard !picked.isEmpty else { break }
            let text = KnowledgeDelivery.text(picked, about: KnowledgeDelivery.about("nirux", path: "Sources/Nirux/Views/F\(index).swift"))
            total += KnowledgeDelivery.cost(text)
            session.bytes += KnowledgeDelivery.cost(text)
            for brick in picked { session.delivered[brick.id] = 0 }
        }
        #expect(total <= KnowledgeDelivery.budget)
        #expect(session.delivered.count >= 5)
    }

    @Test func anExpiredOrOtherMacOSBrickIsNotServedEvenFromAStaleFile() {
        let knowledge = ServedKnowledge(bricks: [Self.served("b-1", until: 100), Self.served("b-2", macOS: 27)])
        let path = "Sources/Nirux/Views/A.swift"
        #expect(KnowledgeDelivery.pick(knowledge, anchor: Self.anchor, path: path, session: .init(), now: 99, macOS: 27).map(\.id) == ["b-1", "b-2"])
        #expect(KnowledgeDelivery.pick(knowledge, anchor: Self.anchor, path: path, session: .init(), now: 100, macOS: 28).isEmpty)
    }

    @Test func compilingServesOnlyOpenValidatedBricks() {
        var loaded = KnowledgeStore.Loaded()
        let open = KnowledgeBrickTests.brick(proofs: [.file(path: "a.swift")])
        let suspect = KnowledgeBrickTests.brick(proofs: [.file(path: "b.swift")])
        let expiring = KnowledgeBrickTests.brick(proofs: [.pullRequest(9)], validatedAt: 0)
        for brick in [open, suspect, expiring] { loaded.bricks[brick.id] = brick }
        _ = loaded.suspect(suspect.id, because: "why", now: 1)
        loaded.state.proposals = [BrickProposal(brick: KnowledgeBrickTests.brick(proofs: [.pullRequest(10)], validatedAt: nil), proposedAt: 0)]
        let served = ServedKnowledge.compile(loaded, now: 10, macOS: 27)
        #expect(Set(served.bricks.map(\.id)) == [open.id, expiring.id])
        #expect(served.bricks.first { $0.id == expiring.id }?.servedUntil == KnowledgeBrick.lifetime)
        #expect(served.bricks.first { $0.id == open.id }?.proof == "a.swift")
    }

    // MARK: Where a file is

    @Test func aFileIsFoundInItsRepositoryFromAnyWorktree() throws {
        let root = KnowledgeLocationTestsSupport.resolved(FileManager.default.temporaryDirectory.appendingPathComponent("kl-\(UUID().uuidString)"))
        let main = root.appendingPathComponent("main")
        let gitDir = main.appendingPathComponent(".git")
        let worktreeGitDir = gitDir.appendingPathComponent("worktrees/wt")
        try FileManager.default.createDirectory(at: worktreeGitDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: main.appendingPathComponent("Sources/A"), withIntermediateDirectories: true)
        let worktree = root.appendingPathComponent("wt")
        try FileManager.default.createDirectory(at: worktree.appendingPathComponent("Sources/A"), withIntermediateDirectories: true)
        try Data("gitdir: \(worktreeGitDir.path)\n".utf8).write(to: worktree.appendingPathComponent(".git"))
        try Data("../..\n".utf8).write(to: worktreeGitDir.appendingPathComponent("commondir"))
        let fromMain = KnowledgeLocation.repository(of: main.appendingPathComponent("Sources/A/x.swift").path)
        let fromWorktree = KnowledgeLocation.repository(of: worktree.appendingPathComponent("Sources/A/x.swift").path)
        #expect(fromMain?.anchor == "git:" + gitDir.path)
        #expect(fromMain?.path == "Sources/A/x.swift")
        #expect(fromWorktree?.anchor == fromMain?.anchor)
        #expect(fromWorktree?.path == "Sources/A/x.swift")
        #expect(KnowledgeLocation.repository(of: root.appendingPathComponent("loose.txt").path) == nil)
        #expect(KnowledgeLocation.folder(of: root.appendingPathComponent("wt/notes.md").path, among: ["folder:" + worktree.path])?.path == "notes.md")
    }

    // MARK: Sessions

    @Test func aSessionKeepsWhatItGotAcrossUpdates() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ks-\(UUID().uuidString)")
        let url = KnowledgeSession.url(in: folder, agent: "claude", session: "s1", subagent: nil)
        #expect(url != KnowledgeSession.url(in: folder, agent: "claude", session: "s1", subagent: "a1"))
        let wrote: Void? = KnowledgeSession.update(url) { session in
            session.delivered["b-1"] = 5
            session.bytes = 120
        }
        #expect(wrote != nil)
        let read = KnowledgeSession.update(url) { $0 }
        #expect(read?.delivered == ["b-1": 5])
        #expect(read?.bytes == 120)
        let rewrote: Void? = KnowledgeSession.update(url) { $0.bytes = 1 }
        #expect(rewrote != nil)
        let bytes = KnowledgeSession.update(url) { $0.bytes }
        #expect(bytes == 1)
    }

    // MARK: Corrections

    @Test func aPromptSayingTheSubjectIsWrongInAnyCaseOrAccentIsACorrection() {
        let bricks = [Self.served("b-1", subject: "backing layer"), Self.served("b-2", subject: "keyDown"), Self.served("b-3", subject: "élan")]
        #expect(KnowledgeCorrection.named(in: "Non, le Backing  Layer n'est pas comme ça", among: bricks) == ["b-1"])
        #expect(KnowledgeCorrection.named(in: "keydown isn't handled there", among: bricks) == ["b-2"])
        #expect(KnowledgeCorrection.named(in: "the layering is wrong; keydowns too", among: bricks).isEmpty)
        #expect(KnowledgeCorrection.named(in: "ELAN : faux !", among: bricks) == ["b-3"])
        #expect(KnowledgeCorrection.named(in: "Now add a drop shadow to the backing layer", among: bricks).isEmpty, "naming it isn't correcting it")
    }
}

enum KnowledgeLocationTestsSupport {
    static func resolved(_ url: URL) -> URL {
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        // Foundation's own resolving drops /private, as anchors don't.
        guard let real = realpath(url.path, nil) else { return url }
        defer { free(real) }
        return URL(fileURLWithPath: String(cString: real))
    }
}

struct KnowledgeCheckTests {
    static func source(files: [String: String], prs: Set<Int> = [], commits: Set<String> = [], pages: [String: String]? = nil) -> KnowledgeSource {
        @Sendable func read(_ text: String?) -> KnowledgeSource.Read { text.map { .data(Data($0.utf8)) } ?? .missing }
        var page: (@Sendable (String) -> KnowledgeSource.Read)?
        if let pages { page = { url in read(pages[url]) } }
        return KnowledgeSource(
            tip: "0123456789abcdef", file: { path in read(files[path]) },
            hasPullRequest: { prs.contains($0) }, hasCommit: { commits.contains($0) }, page: page
        )
    }

    @Test func wordsHoldAcrossReflowedCommentLines() {
        let file = """
            /// AppKit owns a view's backing
            ///   layer: don't write its “transform”
            func glass() {}
            """
        let source = Self.source(files: ["Glass.swift": file])
        #expect(Proof.text(path: "Glass.swift", text: "backing layer: don't write its \"transform\"").check(in: source) == .holds)
        #expect(Proof.text(path: "Glass.swift", text: "func glass()").check(in: source) == .holds)
        guard case .fails = Proof.text(path: "Glass.swift", text: "sublayerTransform").check(in: source) else { Issue.record("held"); return }
        guard case .fails = Proof.file(path: "Gone.swift").check(in: source) else { Issue.record("held"); return }
    }

    @Test func aTestHoldsWhileItsFunctionIsThere() {
        let source = Self.source(files: ["T.swift": "final class T: XCTestCase {\n    func testKeyDownIsHandled() throws {}\n}"])
        #expect(Proof.test(path: "T.swift", name: "testKeyDownIsHandled").check(in: source) == .holds)
        guard case .fails = Proof.test(path: "T.swift", name: "testKeyDown").check(in: source) else { Issue.record("held"); return }
    }

    @Test func historyAndPagesAnswerOnlyWhenRead() {
        let source = Self.source(files: [:], prs: [582], commits: ["abc1234"])
        #expect(Proof.pullRequest(582).check(in: source) == .holds)
        guard case .fails = Proof.pullRequest(583).check(in: source) else { Issue.record("held"); return }
        #expect(Proof.commit("abc1234").check(in: source) == .holds)
        #expect(Proof.page(url: "https://a.example/x", quote: "the quote of the page").check(in: source) == .skipped)
        let daily = Self.source(files: [:], pages: ["https://a.example/x": "<p>The <b>quote</b> of the&nbsp;page</p><script>x()</script>"])
        #expect(Proof.page(url: "https://a.example/x", quote: "The quote of the page").check(in: daily) == .holds)
        #expect(KnowledgeText.pageText("a &amp;lt;T&amp;gt; b") == "a &lt;T&gt; b", "an escaped entity stays text")
        guard case .fails = Proof.page(url: "https://a.example/y", quote: "The quote of the page").check(in: daily) else { Issue.record("held"); return }
        #expect(Proof.said(quote: "keep it", day: "2026-11-27").check(in: daily) == .holds)
    }

    @Test func aProofFailingTwiceClosesItsBrickOnceFailsAndAnUnknownLeavesIt() {
        var loaded = KnowledgeStore.Loaded()
        let first = KnowledgeBrickTests.brick(proofs: [.file(path: "a.swift")])
        let second = KnowledgeBrickTests.brick(proofs: [.file(path: "b.swift")])
        let third = KnowledgeBrickTests.brick(proofs: [.file(path: "c.swift")])
        for brick in [first, second, third] { loaded.bricks[brick.id] = brick }
        let once = loaded.record([
            first.id: [.fails("a.swift is gone.")], second.id: [.holds, .fails("b.swift is gone.")], third.id: [.unknown("git failed")]
        ], tip: "tip1", now: 70)
        #expect(once.isEmpty)
        guard case .failing = loaded.status(of: second.id, now: 71, macOS: 27) else { Issue.record("not failing"); return }
        #expect(ServedKnowledge.compile(loaded, now: 71, macOS: 27).bricks.map(\.id) == [third.id], "a failing brick isn't served")
        #expect(loaded.state(of: third.id) == BrickState())
        let twice = loaded.record([first.id: [.holds], second.id: [.fails("b.swift is gone.")]], tip: "tip2", now: 80)
        #expect(twice == [second.id])
        #expect(loaded.status(of: second.id, now: 81, macOS: 27) == .closed("b.swift is gone."))
        #expect(loaded.status(of: first.id, now: 81, macOS: 27) == .open, "a check that holds clears the failure")
        #expect(loaded.state(of: first.id).checkedTip == "tip2")
    }
}
