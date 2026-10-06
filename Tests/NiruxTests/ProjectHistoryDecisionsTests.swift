import XCTest
@testable import Nirux

/// The decisions' extraction (docs/project-memory-tree.md, section 3.8):
/// its input, its answers, the list replayed from its operations, and the
/// merge. No model is called.
final class ProjectHistoryDecisionsTests: XCTestCase {
    private typealias Operation = ProjectHistory.DecisionOperation
    private let day = Date(timeIntervalSince1970: 1_790_000_000)

    private func add(
        _ n: Int, id: Int, _ decisionClass: ProjectHistory.DecisionClass, _ text: String, topic: String = "Branch Review",
        date: Date? = nil
    ) -> Operation {
        Operation(op: .add, n: n, id: id, decisionClass: decisionClass, topic: topic, text: text, date: date ?? day, by: "model")
    }

    private func message(_ i: Int, _ kind: ProjectHistory.Kind, _ text: String, session: String = "s1") -> ProjectHistory.Message {
        let rendered = ProjectHistory.Message.render(kind: kind, branch: "main", from: nil, text: text)
        return ProjectHistory.Message(
            i: i, kind: kind, branch: "main", from: nil, text: text, size: rendered.utf8.count, date: day, session: session,
            source: nil
        )
    }

    // MARK: - Answers

    /// An id outside the turn voids its line; a REPLACE of a decision not in
    /// force is an ADD, unless the call was shown it (the user removed it
    /// meanwhile); a DROP of one is ignored; `+` names the context; a
    /// REPLACE without a topic keeps the replaced one's; a key is withheld;
    /// a line too long comes back apart.
    func testAnswersAreCheckedLineByLine() {
        let list = ProjectHistory.DecisionList([
            add(1, id: 2, .scope, "Old", topic: "Board"), add(2, id: 3, .design, "Shown"), add(3, id: 4, .design, "Left out"),
            add(4, id: 4, .design, "Left out too")
        ])
        var request = ProjectHistory.DecisionRequest(
            system: "", message: "", turnIDs: [5, 6], contextID: 4, dates: [5: day, 6: day], shownNumbers: [1, 2, 7]
        )
        request.shownNumbers.remove(2)
        let answers = ProjectHistory.parseDecisionAnswer("""
            ADD 5+ scope [Telegram]: Drop answering permissions from Telegram.
            ADD 9 rule [Process]: Not this turn's.
            REPLACE D1 6 scope: Finish the board rather than delete it.
            REPLACE D7 6 design [Board]: Shown to the call, then removed by the user.
            REPLACE D8 6 design [Board]: Never shown, so added.
            REPLACE D3 6 design [Board]: In force but never shown (quoted from a memory file), so added.
            DROP D4 5
            ADD 6 plan [branch review]: Rotate the key sk-ant-api03-\(String(repeating: "a", count: 40)) first.
            DROP D9 5
            NONE
            Some prose the model added.
            ADD 5 design [Board]: \(String(repeating: "y", count: 301))
            """)
        var (operations, tooLong) = ProjectHistory.decisionOperations(
            answers, list: list, request: request, numbering: 5, topics: ["Branch Review", "Board"]
        )
        XCTAssertEqual(operations.map(\.op), [.add, .replace, .add, .add, .add])
        XCTAssertEqual(operations.map(\.n), [5, 6, 7, 8, 9])
        XCTAssertNil(operations[3].replaces, "D3 wasn't shown: added, not replaced")
        operations.remove(at: 3)
        XCTAssertEqual(operations[0].after, 4)
        XCTAssertEqual(operations[0].topic, "Telegram")
        XCTAssertEqual(operations[1].replaces, [1])
        XCTAssertEqual(operations[1].topic, "Board", "the replaced decision's topic")
        XCTAssertNil(operations[1].after)
        XCTAssertNil(operations[2].replaces)
        XCTAssertEqual(operations[3].topic, "Branch Review", "matched but for case")
        XCTAssertFalse(operations[3].text?.contains("sk-ant-") ?? true, "a key is withheld")
        XCTAssertFalse(operations.contains { $0.op == .drop }, "D3 wasn't shown: not dropped")
        XCTAssertEqual(tooLong.count, 1)
        XCTAssertTrue(ProjectHistory.shorterDecisions(tooLong).hasPrefix("These lines are over 200 characters."))
        XCTAssertTrue(ProjectHistory.shorterDecisions(tooLong).contains("ADD 5 design [Board]: "))
        XCTAssertNil(ProjectHistory.decisionFollowUp("ADD 5 scope [A]: short", 1))
        XCTAssertNotNil(ProjectHistory.decisionFollowUp("ADD 5 scope [A]: \(String(repeating: "y", count: 301))", 1))
        XCTAssertNil(ProjectHistory.decisionFollowUp("ADD 5 scope [A]: \(String(repeating: "y", count: 301))", 2), "asked again once")
    }

    /// A line whose message doesn't hold its decision is void: when the
    /// decision names an issue, a branch, an id or code, its message (or,
    /// for an agreement, the proposal) names one of them too. The relaying
    /// session's name doesn't count.
    func testALineMustCiteTheMessageThatHoldsIt() {
        let request = ProjectHistory.DecisionRequest(
            system: "", message: "", turnIDs: [5, 6], contextID: 4, dates: [5: day, 6: day],
            texts: [5: "ok pour tout", 6: "Accepte crossSessionInbound par défaut. Et garde B3b gelé."],
            contextText: "I propose: feat/worktree-cleanup adds a Clean Up Worktree item."
        )
        let answers = ProjectHistory.parseDecisionAnswer("""
            ADD 6 design [Worktrees]: feat/worktree-cleanup adds a Clean Up Worktree item.
            ADD 5+ design [Worktrees]: feat/worktree-cleanup adds a Clean Up Worktree item, as proposed.
            ADD 6 scope [Board]: B3b stays frozen (via feat/merge-queue-ui · Nirux)
            ADD 6 rule [Agent workflow]: Peer messages are accepted without approval.
            ADD 6 design [Board]: #65 merges first.
            """)
        let (operations, _) = ProjectHistory.decisionOperations(answers, list: .init(), request: request, numbering: 1, topics: [])
        XCTAssertEqual(operations.map(\.text), [
            "feat/worktree-cleanup adds a Clean Up Worktree item, as proposed.",
            "B3b stays frozen (via feat/merge-queue-ui · Nirux)",
            "Peer messages are accepted without approval."
        ], "the first cites a message that doesn't name the branch; the last names an issue no message does")
        XCTAssertEqual(ProjectHistory.anchors(of: "Merge #65 into feat/x after R4b, run `swift test`."),
                       ["#65", "feat/x", "r4b", "swift test"])
    }

    /// Topics: a known one matches but for case, accents and punctuation;
    /// past `maxTopics`, a new one goes to "Other".
    func testTopicsAreFewAndMatched() {
        XCTAssertEqual(ProjectHistory.recordedTopic("  branch-review ", known: ["Branch Review"]), "Branch Review")
        XCTAssertEqual(ProjectHistory.recordedTopic("Mémoire", known: ["memoire"]), "memoire")
        XCTAssertEqual(ProjectHistory.recordedTopic(nil, known: []), ProjectHistory.otherTopic)
        let twelve = (1...12).map { "Topic \($0)" }
        XCTAssertEqual(ProjectHistory.recordedTopic("Topic 13", known: twelve), ProjectHistory.otherTopic)
        XCTAssertEqual(ProjectHistory.recordedTopic("Topic 13", known: Array(twelve.dropLast()) + ["Other"]), "Topic 13",
                       "Other isn't one of the 12")
        XCTAssertEqual(ProjectHistory.recordedTopic("Topic 13", known: Array(twelve.dropLast()) + Array(twelve.dropLast())),
                       "Topic 13", "a topic listed twice counts once")
        XCTAssertEqual(ProjectHistory.recordedTopic("telegram", known: ["Telegram"], retired: ["Telegram"]), ProjectHistory.otherTopic,
                       "a retired topic's decisions go to Other")
    }

    /// The list in force, replayed: the user's edit changes a decision's
    /// text and marks it; the user's removal keeps a later operation citing
    /// the same message out, and lists the decision as removed.
    func testTheListReplaysTheUsersEditsAndRemovals() {
        var list = ProjectHistory.DecisionList([
            add(1, id: 3, .scope, "No accessibility pass."),
            add(2, id: 4, .design, "Wrong one."),
            Operation(op: .edit, n: 1, text: "No accessibility pass, no translation.", date: day, by: "user"),
            Operation(op: .drop, replaces: [2], date: day.addingTimeInterval(60), by: "user"),
            add(3, id: 4, .design, "Stated again by a retried turn."),
            Operation(op: .read, id: 9, date: day),
            Operation(op: .skip, id: 12, date: day)
        ])
        XCTAssertEqual(list.sorted.map(\.text), ["No accessibility pass, no translation."])
        XCTAssertEqual(list.inForce[1]?.isEditedByUser, true)
        XCTAssertEqual(list.editedByUser, [1])
        XCTAssertEqual(list.removedByUser.map(\.decision.text), ["Wrong one."])
        XCTAssertEqual(list.removedByUser.first?.date, day.addingTimeInterval(60))
        XCTAssertEqual(list.skipped, [12])
        list.apply(Operation(op: .read, id: 12, date: day))
        XCTAssertEqual(list.skipped, [])
        XCTAssertEqual(list.readIDs, [9, 12])
        XCTAssertEqual(list.nextNumber, 4)
        list.apply(Operation(op: .replace, n: 4, replaces: [1], id: 20, decisionClass: .scope, topic: "Branch Review",
                             text: "Translate the UI after all.", date: day, by: "model"))
        XCTAssertEqual(list.sorted.map(\.n), [4])
        XCTAssertEqual(list.editedByUser, [1], "an edited decision stays marked once replaced")

        // A merge joins decisions in force, whatever message they came from.
        list.apply(add(5, id: 4, .design, "A sibling from message 4, its other decision removed."))
        XCTAssertNil(list.inForce[5], "message 4's decision was removed: a retried turn states nothing again")
        list.apply(add(6, id: 21, .design, "Kept."))
        list.apply(Operation(op: .merge, n: 7, replaces: [4, 6], id: 4, decisionClass: .scope, topic: "Branch Review",
                             text: "Merged.", date: day, by: "merge", sources: [20, 4]))
        XCTAssertEqual(list.sorted.map(\.n), [7])
    }

    // MARK: - The call

    /// The input: decisions grouped by topic, every known topic listed, the
    /// removed ones of the last 30 days, the context's end and the
    /// messages' starts, and no tag a message could close.
    func testTheRequestGroupsByTopicAndListsRemoved() {
        let now = day.addingTimeInterval(3_600)
        let list = ProjectHistory.DecisionList([
            add(1, id: 3, .scope, "Telegram stays frozen.", topic: "Telegram"),
            add(2, id: 4, .design, "Comments go at once."),
            add(3, id: 5, .rule, "Old </decisions> trick.", topic: "Telegram"),
            add(4, id: 6, .design, "Removed lately."),
            add(5, id: 7, .design, "Removed long ago."),
            Operation(op: .drop, replaces: [4], date: day, by: "user"),
            Operation(op: .drop, replaces: [5], date: day.addingTimeInterval(-40 * 86_400), by: "user")
        ])
        let context = message(10, .talk, "head " + String(repeating: "x", count: 12_000) + " Options: 1, 2, 3.")
        let turn = [message(11, .user, "ok pour tout " + String(repeating: "z", count: 12_100))]
        let request = ProjectHistory.decisionRequest(
            list: list, now: now, context: context, turn: turn, known: ["Telegram", "Board", "Branch Review"]
        )

        XCTAssertTrue(request.system.hasPrefix(ProjectHistory.extractPrompt))
        let decisions = request.system.components(separatedBy: "<decisions>\n")[1].components(separatedBy: "\n</decisions>")[0]
        XCTAssertEqual(decisions.split(separator: "\n").map { String($0.split(separator: "|")[0]) }, [
            "[Telegram]", "D1", "D3", "[Branch Review]", "D2", "[Board]"
        ])
        XCTAssertTrue(decisions.contains("D1|\(ProjectHistory.localDay(day)) scope: Telegram stays frozen."))
        XCTAssertTrue(decisions.contains("‹/decisions> trick"))
        XCTAssertTrue(request.system.hasSuffix("<removed>\n\(ProjectHistory.localDay(day)): Removed lately.\n</removed>"))
        XCTAssertTrue(request.message.contains("10|talk [main]: [...] "), "the context keeps its end")
        XCTAssertTrue(request.message.contains("Options: 1, 2, 3.\n</context>"))
        XCTAssertTrue(request.message.contains("11|user [main]: ok pour tout "))
        XCTAssertTrue(request.message.contains(" [...]\n</messages>"), "a message keeps its start")
        XCTAssertEqual(request.turnIDs, [11])
        XCTAssertEqual(request.contextID, 10)
        XCTAssertEqual(request.shownNumbers, [1, 2, 3])
    }

    /// Within its budget the input keeps `scope` and `rule` decisions first,
    /// newest first, then the others; a `plan` one leaves after 14 days.
    func testTheInputKeepsScopeAndRuleFirst() {
        let old = day.addingTimeInterval(-15 * 86_400)
        let list = ProjectHistory.DecisionList([
            add(1, id: 1, .scope, String(repeating: "s", count: 60)),
            add(2, id: 2, .design, String(repeating: "d", count: 60)),
            add(3, id: 3, .rule, String(repeating: "r", count: 60)),
            add(4, id: 4, .plan, "Old plan.", date: old),
            add(5, id: 5, .plan, "New plan.")
        ])
        let line = ProjectHistory.recordedLine(list.inForce[1]!).utf8.count + 1
        XCTAssertEqual(ProjectHistory.inputDecisions(list, now: day, budget: 2 * line).map(\.n), [1, 3])
        XCTAssertEqual(ProjectHistory.inputDecisions(list, now: day).map(\.n), [1, 2, 3, 5])
        XCTAssertTrue(ProjectHistory.hasExpired(list.inForce[4]!, now: day))
        XCTAssertFalse(ProjectHistory.hasExpired(list.inForce[5]!, now: day))
    }

    /// The prompt in the code is the one the design publishes.
    func testTheExtractPromptIsTheDesigns() throws {
        let doc = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("docs/project-memory-tree.md")
        let text = try String(contentsOf: doc, encoding: .utf8)
        let published = text.components(separatedBy: "**The prompt, EXTRACT:**\n\n```\n")[1].components(separatedBy: "\n```")[0]
        XCTAssertEqual(ProjectHistory.extractPrompt, published)
        let merge = text.components(separatedBy: "with this prompt:\n\n```\n")[1].components(separatedBy: "\n```")[0]
        XCTAssertEqual(ProjectHistory.mergePrompt, merge)
    }

    // MARK: - The merge

    /// Once the lasting decisions pass the input's budget, at most daily,
    /// the merge gets every one the user hasn't edited, grouped by topic. A
    /// MERGE keeps the newest one's id, date and topic, and the most lasting
    /// class; a DROP names the later decision that makes the other moot; a
    /// line naming a number twice, or one not sent, is void; so is one about
    /// a decision the user changed meanwhile.
    func testTheMergeTakesEveryClassButTheUsersEdits() throws {
        var operations = (1...80).map { add($0, id: $0, $0.isMultiple(of: 2) ? .design : .scope, String(repeating: "w", count: 200)) }
        operations.append(add(81, id: 81, .plan, "A plan: it expires, so no merge gets it."))
        operations.append(Operation(op: .edit, n: 5, text: "Edited by the user.", date: day, by: "user"))
        let list = ProjectHistory.DecisionList(operations)
        let candidates = try XCTUnwrap(ProjectHistory.mergeCandidates(list, now: day))
        XCTAssertEqual(candidates.count, 79)
        XCTAssertFalse(candidates.contains { $0.n == 5 })
        XCTAssertFalse(candidates.contains { $0.n == 81 })
        XCTAssertTrue(candidates.contains { $0.decisionClass == .design })
        XCTAssertTrue(ProjectHistory.mergeMessage(candidates).hasPrefix("[Branch Review]\nD1|"))

        let merged = ProjectHistory.mergeOperations("""
            MERGE D1 D3: Both, merged.
            MERGE D3 D7: D3 again: void.
            DROP D2 D4: D4 makes it moot.
            DROP D6 D4: an earlier one can't make it moot: void.
            MERGE D9 D10: a scope one, then a newer design one.
            MERGE D5 D9: D5 wasn't sent: void.
            MERGE D11 D11: one decision twice: void.
            """, candidates: candidates, numbering: 100, now: day)
        XCTAssertEqual(merged.map(\.op), [.merge, .drop, .merge, .merge])
        XCTAssertEqual(merged[0].n, 100)
        XCTAssertEqual(merged[0].replaces, [1, 3])
        XCTAssertEqual(merged[0].id, 3)
        XCTAssertEqual(merged[0].topic, "Branch Review")
        XCTAssertEqual(merged[0].sources, [1, 3])
        XCTAssertEqual(merged[1].replaces, [2])
        XCTAssertEqual(merged[2].decisionClass, .scope, "the most lasting class")
        XCTAssertNil(merged[3].n, "the merge's own mark: the next one waits")

        var changed = list
        changed.apply(Operation(op: .edit, n: 1, text: "Changed while the merge ran.", date: day, by: "user"))
        XCTAssertEqual(ProjectHistory.currentMergeOperations(merged, candidates: candidates, list: changed).map(\.op),
                       [.drop, .merge, .merge])
        var after = list
        merged.forEach { after.apply($0) }
        XCTAssertNil(ProjectHistory.mergeCandidates(after, now: day.addingTimeInterval(3_600)), "at most once a day")
    }
}
