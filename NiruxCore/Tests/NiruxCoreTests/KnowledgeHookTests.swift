import Foundation
import NiruxCore
import Testing

struct KnowledgeHookTests {
    /// A repository with a brick about its views served, and a worktree.
    struct Space {
        let store: KnowledgeStore
        let checkout: URL
        let anchor: String

        init() throws {
            let root = KnowledgeLocationTestsSupport.resolved(FileManager.default.temporaryDirectory.appendingPathComponent("kh-\(UUID().uuidString)"))
            checkout = root.appendingPathComponent("repo")
            try FileManager.default.createDirectory(at: checkout.appendingPathComponent(".git"), withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: checkout.appendingPathComponent("Sources/Views"), withIntermediateDirectories: true)
            anchor = "git:" + checkout.appendingPathComponent(".git").path
            store = KnowledgeStore(spaceFolder: root.appendingPathComponent("space"))
            try store.writeServed(ServedKnowledge(bricks: [
                .init(id: "b-views", sentence: "AppKit rewrites a view's backing layer at each layout.", subject: "backing layer",
                      anchor: anchor, name: "repo", paths: ["Sources/Views/**"], proof: "PR #582"),
                .init(id: "b-model", sentence: "The model never imports AppKit, the core check refuses it.", subject: "core boundary",
                      anchor: anchor, name: "repo", paths: ["Sources/Model/"], proof: "scripts/check-core-boundary.sh")
            ]))
        }

        func path(_ relative: String) -> String { checkout.appendingPathComponent(relative).path }
    }

    static func claudeRead(_ path: String, session: String = "s1", tool: String = "Read", event: String = "PostToolUse") -> [String: Any] {
        ["hook_event_name": event, "session_id": session, "tool_name": tool, "tool_input": ["file_path": path], "cwd": "/"]
    }

    func context(_ answer: KnowledgeHook.Answer) -> String? {
        guard let output = answer.output, let json = try? JSONSerialization.jsonObject(with: output) as? [String: Any],
              let specific = json["hookSpecificOutput"] as? [String: Any], specific["hookEventName"] as? String == "PostToolUse"
        else { return nil }
        return specific["additionalContext"] as? String
    }

    @Test func claudeGetsABrickAfterReadingAFileItConcernsOncePerSession() throws {
        let space = try Space()
        let first = KnowledgeHook.answer(agent: .claude, payload: Self.claudeRead(space.path("Sources/Views/Glass.swift")),
                                         store: space.store, task: "w1", now: 10, macOS: 27)
        let text = try #require(context(first))
        #expect(text.contains("AppKit rewrites a view's backing layer at each layout. (proof: PR #582)"))
        #expect(text.contains("repo/Sources/Views/Glass.swift"))
        #expect(!text.contains("core check"))
        #expect(first.uses == [KnowledgeUse(time: 10, brick: "b-views", kind: .got, task: "w1", agent: "claude")])
        let again = KnowledgeHook.answer(agent: .claude, payload: Self.claudeRead(space.path("Sources/Views/Other.swift"), tool: "Edit"),
                                         store: space.store, task: "w1", now: 11, macOS: 27)
        #expect(again == KnowledgeHook.Answer())
        let otherSession = KnowledgeHook.answer(agent: .claude, payload: Self.claudeRead(space.path("Sources/Views/Glass.swift"), session: "s2"),
                                                store: space.store, task: "w1", now: 12, macOS: 27)
        #expect(context(otherSession) != nil)
    }

    @Test func otherToolsFailedCallsAndOtherFilesBringNothing() throws {
        let space = try Space()
        for payload in [
            Self.claudeRead(space.path("Sources/Views/Glass.swift"), tool: "Grep"),
            Self.claudeRead(space.path("Sources/Views/Glass.swift"), event: "PostToolUseFailure"),
            Self.claudeRead(space.path("README.md")),
            Self.claudeRead("/elsewhere/Sources/Views/Glass.swift")
        ] {
            #expect(KnowledgeHook.answer(agent: .claude, payload: payload, store: space.store, task: nil, now: 0, macOS: 27) == KnowledgeHook.Answer())
        }
        try space.store.writeServed(nil)
        #expect(KnowledgeHook.answer(agent: .claude, payload: Self.claudeRead(space.path("Sources/Views/Glass.swift")),
                                     store: space.store, task: nil, now: 0, macOS: 27) == KnowledgeHook.Answer())
    }

    @Test func aPromptTheUserTypesOnABricksSubjectAfterItArrivedIsACorrection() throws {
        let space = try Space()
        func prompt(_ text: String, source: String? = nil) -> KnowledgeHook.Answer {
            var payload: [String: Any] = ["hook_event_name": "UserPromptSubmit", "session_id": "s1", "prompt": text]
            payload["source"] = source
            return KnowledgeHook.answer(agent: .claude, payload: payload, store: space.store, task: "w1", now: 20, macOS: 27)
        }
        #expect(prompt("the backing layer is wrong").uses.isEmpty)
        _ = KnowledgeHook.answer(agent: .claude, payload: Self.claudeRead(space.path("Sources/Views/Glass.swift")),
                                 store: space.store, task: "w1", now: 10, macOS: 27)
        #expect(prompt("[Nirux Mission] the backing layer answer").uses.isEmpty)
        #expect(prompt("the backing layer is wrong", source: "poll_event").uses.isEmpty)
        #expect(prompt("Non, le backing layer ne marche pas comme ça").uses
            == [KnowledgeUse(time: 20, brick: "b-views", kind: .corrected, task: "w1", agent: "claude")])
        #expect(prompt("backing layer again").uses.isEmpty)
    }

    @Test func aCompactedConversationMayGetItsBricksAgain() throws {
        let space = try Space()
        let read = Self.claudeRead(space.path("Sources/Views/Glass.swift"))
        #expect(context(KnowledgeHook.answer(agent: .claude, payload: read, store: space.store, task: nil, now: 1, macOS: 27)) != nil)
        #expect(KnowledgeHook.answer(agent: .claude, payload: read, store: space.store, task: nil, now: 2, macOS: 27) == KnowledgeHook.Answer())
        let resumed: [String: Any] = ["hook_event_name": "SessionStart", "session_id": "s1", "source": "resume"]
        _ = KnowledgeHook.answer(agent: .claude, payload: resumed, store: space.store, task: nil, now: 3, macOS: 27)
        #expect(KnowledgeHook.answer(agent: .claude, payload: read, store: space.store, task: nil, now: 4, macOS: 27) == KnowledgeHook.Answer())
        let compacted: [String: Any] = ["hook_event_name": "SessionStart", "session_id": "s1", "source": "compact"]
        #expect(KnowledgeHook.answer(agent: .claude, payload: compacted, store: space.store, task: nil, now: 5, macOS: 27) == KnowledgeHook.Answer())
        #expect(context(KnowledgeHook.answer(agent: .claude, payload: read, store: space.store, task: nil, now: 6, macOS: 27)) != nil)
    }

    @Test func agyGetsTheBricksOfTheFilesItOpenedAtItsNextModelCall() throws {
        let space = try Space()
        let read: [String: Any] = [
            "hookEventName": "PostToolUse", "conversationId": "c1", "error": "",
            "toolCall": ["name": "read_file", "args": ["Path": space.path("Sources/Views/Glass.swift")]]
        ]
        #expect(KnowledgeHook.answer(agent: .agy, payload: read, store: space.store, task: "w2", now: 1, macOS: 27) == KnowledgeHook.Answer())
        let call: [String: Any] = ["hookEventName": "PreInvocation", "conversationId": "c1", "invocationNum": 1]
        let injected = KnowledgeHook.answer(agent: .agy, payload: call, store: space.store, task: "w2", now: 2, macOS: 27)
        let json = try #require(injected.output.flatMap { try JSONSerialization.jsonObject(with: $0) as? [String: Any] })
        let step = try #require((json["injectSteps"] as? [[String: Any]])?.first?["systemMessage"] as? [String: Any])
        #expect((step["systemMessage"] as? String)?.contains("backing layer at each layout") == true)
        #expect(injected.uses.map(\.brick) == ["b-views"])
        #expect(KnowledgeHook.answer(agent: .agy, payload: call, store: space.store, task: "w2", now: 3, macOS: 27) == KnowledgeHook.Answer())
        #expect(KnowledgeHook.answer(agent: .agy, payload: read, store: space.store, task: "w2", now: 4, macOS: 27) == KnowledgeHook.Answer())
        #expect(KnowledgeHook.answer(agent: .agy, payload: call, store: space.store, task: "w2", now: 5, macOS: 27) == KnowledgeHook.Answer())
        let turn: [String: Any] = ["hookEventName": "PreInvocation", "conversationId": "c1", "invocationNum": 0,
                                   "lastUserInput": "no, the BACKING layer is fine"]
        #expect(KnowledgeHook.answer(agent: .agy, payload: turn, store: space.store, task: "w2", now: 6, macOS: 27).uses.map(\.kind) == [.corrected])
    }

    @Test func usesCountTasksNotDeliveries() throws {
        let space = try Space()
        try FileManager.default.createDirectory(at: space.store.folder, withIntermediateDirectories: true)
        KnowledgeUse.append([
            .init(time: 1, brick: "b-1", kind: .got, task: "w1", agent: "claude"),
            .init(time: 2, brick: "b-1", kind: .got, task: "w1", agent: "claude"),
            .init(time: 3, brick: "b-1", kind: .got, task: "w2", agent: "agy"),
            .init(time: 4, brick: "b-1", kind: .corrected, task: "w2", agent: "agy")
        ], in: space.store)
        let reach = KnowledgeUse.reach(KnowledgeUse.load(in: space.store))
        #expect(reach["b-1"]?.tasks == 2)
        #expect(reach["b-1"]?.corrections == 1)
        KnowledgeUse.trim(in: space.store, now: 2.5 + Double(KnowledgeUse.keptDays) * 86_400)
        #expect(KnowledgeUse.load(in: space.store).map(\.time) == [3, 4])
    }
}
