import AppKit
import XCTest
@testable import Nirux

/// Learned rules end to end (NiruxShellView+LearnedRules), in a real window
/// on throwaway state (see UIFlowHarness): the Lead proposes a rule, its
/// row offers it, and the sheet adds it to the brief, or dismisses it, or
/// leaves it for later; the Lead hears what the user decided.
@MainActor
final class LearnedRulesFlowTests: XCTestCase {
    private struct Lead {
        let space: String
        let workspace: WorkspaceState
        let agentUUID: String
    }

    private func makeLead(_ harness: UIFlowHarness) throws -> Lead {
        let shell = harness.shell
        shell.projectBoardClient = ProjectBoardFlowTests.FakeGitHub(openPullRequests: "[]", runs: "[]")
        let repository = SpaceAnchor(kind: .gitRepository(commonDir: harness.repo + "/.git"), name: "repo", isDefault: true)
        let space = shell.workspaceStore.createProfile(named: "Rules", anchors: [repository], select: true).id
        shell.startLead(spaceID: space)
        let workspace = try XCTUnwrap(shell.leadWorkspace(inSpace: space))
        return Lead(space: space, workspace: workspace, agentUUID: try XCTUnwrap(workspace.columns.first?.agentUUID))
    }

    private func propose(
        _ rule: String, evidence: String = "#395, #417", lead: Lead, in harness: UIFlowHarness,
        file: StaticString = #filePath, line: UInt = #line
    ) throws -> (text: String, isError: Bool) {
        let arguments = ["rule": rule, "evidence": evidence]
        let json = try XCTUnwrap(String(data: JSONSerialization.data(withJSONObject: arguments), encoding: .utf8))
        let request = LeadChannel.Request(
            id: UUID().uuidString, tool: LeadTools.proposeRule, arguments: json,
            workspaceID: lead.workspace.id, agentUUID: lead.agentUUID, createdAt: Date().timeIntervalSince1970
        )
        var answer: (text: String, isError: Bool)?
        harness.shell.handleLeadRequest(request) { text, isError in answer = (text, isError) }
        harness.waitUntil("the answer to propose_rule", file: file, line: line) { answer != nil }
        return try XCTUnwrap(answer, file: file, line: line)
    }

    private func briefText(_ lead: Lead) throws -> String {
        LearnedRules.briefText(at: try XCTUnwrap(SpaceBrief.briefURL(spaceID: lead.space)))
    }

    private func leadRowCount(_ shell: NiruxShellView) -> Int? {
        shell.updateSidebar()
        return shell.sidebar.lastInfos.first(where: \.isLead)?.ruleProposalCount
    }

    /// The sheet gone from the window: the next one can open.
    private func waitForNoSheet(_ harness: UIFlowHarness, file: StaticString = #filePath, line: UInt = #line) {
        harness.waitUntil("the sheet to close", file: file, line: line) { harness.window.attachedSheet == nil }
    }

    /// The lines its Lead hasn't heard yet, as the file keeps them.
    private func untold(_ shell: NiruxShellView, _ lead: Lead) -> [String] {
        (RuleProposalStore(spaceID: lead.space)?.load().toTell ?? []).map(NiruxShellView.ruleDecisionText)
    }

    /// Types into the rule's field as a user does (its delegate hears it).
    private func type(_ text: String, into sheet: LearnedRuleSheet) {
        let all = NSRange(location: 0, length: (sheet.ruleView.string as NSString).length)
        sheet.ruleView.insertText(text, replacementRange: all)
    }

    /// Proposed, offered on the Lead's row, edited and added: the brief
    /// gets it under "Rules learned" and launches carry it; the Lead hears
    /// it, told running tasks don't have it. Proposed again, it is refused.
    func testTheLeadProposesARuleAndTheUserAddsIt() throws {
        try UIFlowHarness.run { harness in
            let shell = harness.shell
            let lead = try makeLead(harness)
            let proposed = try propose("Tests wait on state.", lead: lead, in: harness)
            XCTAssertFalse(proposed.isError, proposed.text)
            XCTAssertEqual(leadRowCount(shell), 1)
            XCTAssertTrue(try propose("tests wait on STATE", lead: lead, in: harness).isError, "it waits already")

            // The row's click, as the sidebar sends it.
            shell.sidebar.onRuleProposalsClicked?(lead.space)
            let sheet = try XCTUnwrap(shell.learnedRuleSheet)
            XCTAssertTrue(sheet.isOpen)
            XCTAssertIdentical(harness.window.attachedSheet, sheet.window)
            XCTAssertEqual(sheet.ruleView.string, "Tests wait on state.")
            XCTAssertEqual(sheet.evidenceField.stringValue, "#395, #417")
            XCTAssertTrue(sheet.explanationLabel.stringValue.contains("sessions already running keep the brief they started with"))
            XCTAssertTrue(sheet.sizeLabel.stringValue.hasPrefix("Brief: 0 → "), sheet.sizeLabel.stringValue)
            XCTAssertNotNil(sheet.dismissButton)

            type("Tests wait on state, never on a fixed sleep.", into: sheet)
            // Either day, should it be midnight.
            let days = [LearnedRules.dayText(Date())]
            try XCTUnwrap(sheet.addButton).performClick(nil)
            XCTAssertFalse(sheet.isOpen, sheet.statusLabel.stringValue)
            waitForNoSheet(harness)

            let brief = try briefText(lead)
            let day = try XCTUnwrap((days + [LearnedRules.dayText(Date())]).first { day in
                brief.hasSuffix("## Rules learned\n\n- Tests wait on state, never on a fixed sleep. (learned \(day), #395, #417)\n")
            }, brief)
            let bullet = "- Tests wait on state, never on a fixed sleep. (learned \(day), #395, #417)"
            XCTAssertEqual(leadRowCount(shell), 0)
            let injection = try XCTUnwrap(SpaceBrief.prepareInjection(spaceID: lead.space))
            XCTAssertTrue(try String(contentsOfFile: injection.claudePromptFile, encoding: .utf8).contains(bullet))
            // The Lead hears it at its next free prompt, even after a
            // relaunch (the decision waits in the file), and only once.
            let line = "[Nirux Mission] The user added your rule to the space brief as: “Tests wait on state, never on "
                + "a fixed sleep.”. Only sessions started from now on read it: tell running tasks yourself if they need it."
            XCTAssertEqual(untold(shell, lead), [line])
            shell.ruleProposals = [:]
            shell.typeRuleDecisions(isFree: { _ in false }, send: { _, text in XCTFail("typed into a busy prompt: \(text)") })
            XCTAssertEqual(untold(shell, lead), [line], "a busy prompt keeps it")
            var typed: [(agent: String?, text: String)] = []
            shell.typeRuleDecisions(isFree: { _ in true }, send: { column, text in typed.append((column.agentUUID, text)) })
            XCTAssertEqual(typed.map(\.agent), [lead.agentUUID])
            XCTAssertEqual(typed.map(\.text), [line])
            XCTAssertEqual(untold(shell, lead), [])
            shell.typeRuleDecisions(isFree: { _ in true }, send: { _, text in XCTFail("told twice: \(text)") })

            let again = try propose("Tests wait on state, never on a fixed sleep", lead: lead, in: harness)
            XCTAssertTrue(again.isError)
            XCTAssertTrue(again.text.contains("says this already (learned \(day))"), again.text)
            // Its own first words, which the brief doesn't hold.
            let original = try propose("Tests wait on state.", lead: lead, in: harness)
            XCTAssertTrue(original.isError)
            XCTAssertTrue(original.text.contains("added this rule"), original.text)
        }
    }

    /// Later leaves it waiting; Dismiss takes it out, writes nothing, tells
    /// the Lead, and the same rule can't come back.
    func testTheUserDismissesARuleOrLeavesItForLater() throws {
        try UIFlowHarness.run { harness in
            let shell = harness.shell
            let lead = try makeLead(harness)
            XCTAssertFalse(try propose("Check who owns the screen first.", lead: lead, in: harness).isError)

            shell.showRuleProposal(spaceID: lead.space)
            let later = try XCTUnwrap(shell.learnedRuleSheet)
            XCTAssertEqual(later.closeButton?.title, "Later")
            later.closeButton?.performClick(nil)
            XCTAssertFalse(later.isOpen)
            waitForNoSheet(harness)
            XCTAssertEqual(leadRowCount(shell), 1)
            XCTAssertEqual(try briefText(lead), "")

            shell.showRuleProposal(spaceID: lead.space)
            let sheet = try XCTUnwrap(shell.learnedRuleSheet)
            XCTAssertFalse(sheet === later)
            try XCTUnwrap(sheet.dismissButton).performClick(nil)
            XCTAssertFalse(sheet.isOpen)
            waitForNoSheet(harness)
            XCTAssertEqual(leadRowCount(shell), 0)
            XCTAssertEqual(try briefText(lead), "")
            XCTAssertEqual(untold(shell, lead),
                           ["[Nirux Mission] The user dismissed the rule you proposed: “Check who owns the screen first.”. Don't propose it again."])
            let again = try propose("check who owns the screen first", lead: lead, in: harness)
            XCTAssertTrue(again.isError)
            XCTAssertTrue(again.text.contains("dismissed"), again.text)

            // Written by hand while it waited: Add takes it out, not twice.
            XCTAssertFalse(try propose("Draft PRs only.", lead: lead, in: harness).isError)
            let url = try XCTUnwrap(SpaceBrief.briefURL(spaceID: lead.space))
            try Data("## Rules learned\n- Draft PRs only\n".utf8).write(to: url)
            shell.showRuleProposal(spaceID: lead.space)
            let byHand = try XCTUnwrap(shell.learnedRuleSheet)
            try XCTUnwrap(byHand.addButton).performClick(nil)
            XCTAssertFalse(byHand.isOpen, byHand.statusLabel.stringValue)
            XCTAssertEqual(try briefText(lead), "## Rules learned\n- Draft PRs only\n")
            XCTAssertEqual(leadRowCount(shell), 0)
            XCTAssertEqual(untold(shell, lead).last, "[Nirux Mission] The user looked at the rule you proposed, “Draft PRs only.”: "
                + "the space brief says it already, as “Draft PRs only”. Nothing was added.")

            // A decision Nirux couldn't record would leave the rule waiting,
            // to be added again: Add says why before writing anything.
            waitForNoSheet(harness)
            XCTAssertFalse(try propose("Name the repository.", lead: lead, in: harness).isError)
            let store = try XCTUnwrap(RuleProposalStore(spaceID: lead.space))
            var file = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: store.fileURL)) as? [String: Any])
            file["schemaVersion"] = RuleProposalStore.schemaVersion + 1
            try JSONSerialization.data(withJSONObject: file).write(to: store.fileURL)
            shell.showRuleProposal(spaceID: lead.space)
            let locked = try XCTUnwrap(shell.learnedRuleSheet)
            XCTAssertEqual(locked.ruleView.string, "Name the repository.")
            locked.add()
            XCTAssertTrue(locked.isOpen)
            XCTAssertEqual(locked.statusLabel.stringValue, "A newer Nirux keeps this space’s proposed rules.")
            XCTAssertEqual(try briefText(lead), "## Rules learned\n- Draft PRs only\n")
            // Its decisions can't be recorded as told either: none is typed,
            // or it would come back at every turn end.
            XCTAssertFalse(untold(shell, lead).isEmpty)
            shell.typeRuleDecisions(isFree: { _ in true }, send: { _, text in XCTFail("typed though not recorded: \(text)") })
        }
    }

    /// From a task's row: where it was learned is the task's branch, and a
    /// rule that would take the brief past what sessions get can't be
    /// added; the brief stays as it was.
    func testARuleThatWouldPassTheBriefsLimitCantBeAdded() throws {
        try UIFlowHarness.run { harness in
            let shell = harness.shell
            let lead = try makeLead(harness)
            let url = try XCTUnwrap(SpaceBrief.briefURL(spaceID: lead.space))
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let long = String(repeating: "x", count: SpaceBrief.maxCharacters - 20) + "\n"
            try Data(long.utf8).write(to: url)
            shell.addWorkspace(title: "task", cwd: harness.worktree, profileID: lead.space)
            let task = try XCTUnwrap(shell.workspaces.first { $0.title == "task" })
            shell.refreshGitContextNow(for: task)
            harness.waitUntil("the task's branch") { task.gitBranch != nil }

            shell.showAddRuleSheet(for: task)
            let sheet = try XCTUnwrap(shell.learnedRuleSheet)
            XCTAssertEqual(sheet.evidenceField.stringValue, task.gitBranch)
            XCTAssertNil(sheet.dismissButton)
            XCTAssertEqual(sheet.closeButton?.title, "Cancel")
            XCTAssertEqual(sheet.addButton?.isEnabled, false, "no rule yet")
            type("Short.", into: sheet)
            XCTAssertEqual(sheet.addButton?.isEnabled, false)
            XCTAssertTrue(sheet.statusLabel.stringValue.hasPrefix("The brief would be too long for sessions"), sheet.statusLabel.stringValue)
            XCTAssertEqual(sheet.sizeLabel.textColor, Theme.Color.error)
            sheet.add()
            XCTAssertTrue(sheet.isOpen)
            sheet.closeButton?.performClick(nil)
            XCTAssertEqual(try briefText(lead), long)
            waitForNoSheet(harness)

            // A brief file sessions don't read (past 1 MB): no rule goes in.
            let huge = "<!--\n" + String(repeating: "x", count: SpaceBrief.maxFileBytes) + "\n-->\n"
            try Data(huge.utf8).write(to: url)
            shell.showAddRuleSheet(for: task)
            let unread = try XCTUnwrap(shell.learnedRuleSheet)
            type("Short.", into: unread)
            XCTAssertEqual(unread.addButton?.isEnabled, false)
            XCTAssertTrue(unread.statusLabel.stringValue.hasPrefix("The brief’s file is over 1 MB"), unread.statusLabel.stringValue)
            unread.closeButton?.performClick(nil)
            XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), huge)
            waitForNoSheet(harness)

            // Edits not saved in Space Settings › Brief: its Save would drop
            // the rule, so Add waits for them.
            try Data("Goals.\n".utf8).write(to: url)
            shell.showSpaceSettings(profileID: lead.space, tab: .brief)
            let editor = try XCTUnwrap(shell.spaceSettings?.brief)
            editor.checkDisk()
            editor.textView.string += "Draft.\n"
            editor.textDidChange(Notification(name: NSText.didChangeNotification))
            XCTAssertTrue(editor.isDirty)
            shell.showAddRuleSheet(for: task)
            let waiting = try XCTUnwrap(shell.learnedRuleSheet)
            type("Short.", into: waiting)
            waiting.add()
            XCTAssertTrue(waiting.isOpen)
            XCTAssertEqual(waiting.statusLabel.stringValue, "Save or revert your edits in Space Settings › Brief first.")
            XCTAssertEqual(try briefText(lead), "Goals.\n")
            editor.revert()
            waiting.add()
            XCTAssertFalse(waiting.isOpen, waiting.statusLabel.stringValue)
            XCTAssertTrue(try briefText(lead).hasPrefix("Goals.\n\n## Rules learned\n\n- Short. (learned "))
        }
    }
}
