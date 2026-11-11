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
            let leadIndex = try XCTUnwrap(shell.workspaces.firstIndex { $0 === lead.workspace })
            shell.sidebar.onRuleProposalsClicked?(leadIndex)
            let sheet = try XCTUnwrap(shell.learnedRuleSheet)
            XCTAssertTrue(sheet.isOpen)
            XCTAssertIdentical(harness.window.attachedSheet, sheet.window)
            XCTAssertEqual(sheet.ruleView.string, "Tests wait on state.")
            XCTAssertEqual(sheet.evidenceField.stringValue, "#395, #417")
            XCTAssertTrue(sheet.explanationLabel.stringValue.contains("sessions already running keep the brief they started with"))
            XCTAssertTrue(sheet.sizeLabel.stringValue.hasPrefix("Brief: 0 → "), sheet.sizeLabel.stringValue)
            XCTAssertNotNil(sheet.dismissButton)

            type("Tests wait on state, never on a fixed sleep.", into: sheet)
            try XCTUnwrap(sheet.addButton).performClick(nil)
            XCTAssertFalse(sheet.isOpen)
            XCTAssertNil(harness.window.attachedSheet)

            let day = LearnedRules.dayText(Date())
            let bullet = "- Tests wait on state, never on a fixed sleep. (learned \(day), #395, #417)"
            let brief = try briefText(lead)
            XCTAssertTrue(brief.hasSuffix("## Rules learned\n\n\(bullet)\n"), brief)
            XCTAssertEqual(leadRowCount(shell), 0)
            let injection = try XCTUnwrap(SpaceBrief.prepareInjection(spaceID: lead.space))
            XCTAssertTrue(try String(contentsOfFile: injection.claudePromptFile, encoding: .utf8).contains(bullet))
            let notice = try XCTUnwrap(shell.pendingLeadNotices.last)
            XCTAssertEqual(notice.workspaceID, lead.workspace.id)
            XCTAssertEqual(notice.agentUUID, lead.agentUUID)
            XCTAssertEqual(notice.text, "[Nirux Mission] The user added your rule to the space brief as: “Tests wait on state, never on "
                + "a fixed sleep.”. Only sessions started from now on read it: tell running tasks yourself if they need it.")

            let again = try propose("Tests wait on state, never on a fixed sleep", lead: lead, in: harness)
            XCTAssertTrue(again.isError)
            XCTAssertTrue(again.text.contains("says this already (learned \(day))"), again.text)
        }
    }

    /// Later leaves it waiting; Dismiss takes it out, writes nothing, tells
    /// the Lead, and the same rule can't come back.
    func testTheUserDismissesARuleOrLeavesItForLater() throws {
        try UIFlowHarness.run { harness in
            let shell = harness.shell
            let lead = try makeLead(harness)
            XCTAssertFalse(try propose("Check who owns the screen first.", lead: lead, in: harness).isError)
            let leadIndex = try XCTUnwrap(shell.workspaces.firstIndex { $0 === lead.workspace })

            shell.showRuleProposal(workspaceIndex: leadIndex)
            let later = try XCTUnwrap(shell.learnedRuleSheet)
            XCTAssertEqual(later.closeButton?.title, "Later")
            later.closeButton?.performClick(nil)
            XCTAssertFalse(later.isOpen)
            XCTAssertEqual(leadRowCount(shell), 1)
            XCTAssertEqual(try briefText(lead), "")

            shell.showRuleProposal(workspaceIndex: leadIndex)
            let sheet = try XCTUnwrap(shell.learnedRuleSheet)
            XCTAssertFalse(sheet === later)
            try XCTUnwrap(sheet.dismissButton).performClick(nil)
            XCTAssertFalse(sheet.isOpen)
            XCTAssertEqual(leadRowCount(shell), 0)
            XCTAssertEqual(try briefText(lead), "")
            XCTAssertEqual(shell.pendingLeadNotices.last?.text,
                           "[Nirux Mission] The user dismissed the rule you proposed: “Check who owns the screen first.”. Don't propose it again.")
            let again = try propose("check who owns the screen first", lead: lead, in: harness)
            XCTAssertTrue(again.isError)
            XCTAssertTrue(again.text.contains("dismissed"), again.text)
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
            XCTAssertTrue(sheet.statusLabel.stringValue.hasPrefix("Shorten the brief"), sheet.statusLabel.stringValue)
            XCTAssertEqual(sheet.sizeLabel.textColor, Theme.Color.error)
            sheet.add()
            XCTAssertTrue(sheet.isOpen)
            sheet.closeButton?.performClick(nil)
            XCTAssertEqual(try briefText(lead), long)
            XCTAssertTrue(shell.pendingLeadNotices.isEmpty)
        }
    }
}
