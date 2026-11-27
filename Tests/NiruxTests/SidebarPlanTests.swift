import AppKit
import XCTest
@testable import Nirux

/// The day plan in the sidebar (SidebarView+Plan): a feature lists its tasks and lines, folds, and leaves the rest
/// of the list as it was.
@MainActor
final class SidebarPlanTests: XCTestCase {
    private func row(_ id: String, index: Int, lead: Bool = false, asks: Bool = false, parent: String? = nil, next: String? = nil, pr: PRInfo? = nil) -> WorkspaceInfo {
        let column = ColumnInfo(
            index: 0, processName: "claude", abbreviatedCwd: "~/app", isFocused: false, isWebView: false, webTitle: nil,
            terminalTitle: nil, agentStatus: asks ? .needsAttention : .idle, isEditor: false, editorFileName: nil,
            attentionReason: asks ? .question("Which date?") : nil
        )
        var info = WorkspaceInfo(
            id: id, index: index, title: id.capitalized, profileID: WorkspaceProfile.defaultID, isInactive: false,
            columnCount: 1, focusedColumn: 0, gitBranch: "feat/\(id)", notification: nil, isActive: false, columns: [column],
            prInfo: pr, diffStats: nil, purpose: nil, nextStep: next, blocker: nil, phase: .active, lastSummary: nil, lastActivityAt: nil
        )
        info.isLead = lead
        info.parentTitle = parent
        return info
    }

    private var rows: [WorkspaceInfo] {
        [
            row("lead", index: 0, lead: true), row("checkout", index: 1), row("export", index: 2, asks: true),
            row("fonts", index: 3, parent: "Export"), row("last", index: 4)
        ]
    }

    private func plan() throws -> Plan {
        var plan = Plan()
        try plan.add(Plan.Line(id: "f1", kind: .feature, title: "Export PDF", by: .user, at: 1), to: .top)
        try plan.add(Plan.Line(id: "s1", kind: .session, title: "Export", by: .lead, at: 1, workspaceID: "export"), to: .under("f1"))
        try plan.add(Plan.Line(id: "l1", kind: .lead, title: "Check the renders", by: .lead, at: 1), to: .under("f1"))
        try plan.add(Plan.Line(id: "t1", kind: .todo, title: "Reply to the printer", by: .user, at: 1), to: .top)
        try plan.add(Plan.Line(id: "l2", kind: .lead, title: "Run the noon train", by: .lead, at: 1), to: .top)
        return plan
    }

    /// The labels from the top down, and where each starts.
    private func labels(_ sidebar: SidebarView) -> [(text: String, x: CGFloat)] {
        sidebar.contentDocumentView.subviews.compactMap { $0 as? NSTextField }
            .filter { !$0.isHidden && !$0.stringValue.isEmpty }
            .sorted { $0.frame.maxY > $1.frame.maxY }
            .map { ($0.stringValue, $0.frame.minX) }
    }

    /// A folded feature counts what waits for the user at any depth: a sub-task asking, an agent stopped at the
    /// user's step in a session under a to-do. Without a Lead row, the Lead's lines end Tasks.
    func testAFoldedFeatureCountsWhatWaitsAtAnyDepthAndLeadLinesStayWithoutALead() throws {
        var plan = try plan()
        try plan.add(Plan.Line(id: "t2", kind: .todo, title: "Pick the paper", by: .user, at: 1), to: .under("f1"))
        try plan.add(Plan.Line(id: "s2", kind: .session, title: "Last", by: .lead, at: 1, workspaceID: "last"), to: .under("t2"))
        try plan.add(Plan.Line(id: "u", kind: .step, title: "Check the proof", by: .lead, at: 1, isForUser: true), to: .under("s2"))
        var waiting = rows.filter { !$0.isLead }
        waiting[2] = row("fonts", index: 3, asks: true, parent: "Export")
        let sidebar = SidebarView(frame: NSRect(x: 0, y: 0, width: 300, height: 700))
        sidebar.isExpanded = true
        sidebar.plan = plan
        sidebar.update(profiles: [], workspaces: waiting)
        let open = labels(sidebar)
        XCTAssertTrue(open.contains { $0.text == "Run the noon train" }, "the Lead's line, with no Lead row")
        let x = { (text: String) in open.first { $0.text == text }?.x ?? 0 }
        XCTAssertEqual(x("Last") - x("Checkout"), SidebarExpandedMetrics.nestIndent, "the session under the to-do lists in its feature")
        sidebar.toggleFeature("f1")
        // Export and its sub-task asking, Last's agent at the user's step, the to-do.
        XCTAssertTrue(labels(sidebar).map(\.text).contains("4 for you"))
    }

    /// Any count of steps fits the bar: the gap narrows, then goes.
    func testTheBarFitsAnyCountOfSteps() throws {
        let three = SidebarSegmentBar.spans(count: 3, width: 30)
        XCTAssertEqual(three[1].x - (three[0].x + three[0].width), SidebarSegmentBar.gap, accuracy: 0.001)
        let many = SidebarSegmentBar.spans(count: 40, width: SidebarSegmentBar.maxWidth)
        XCTAssertTrue(many.allSatisfy { $0.width > 0 })
        let last = try XCTUnwrap(many.last)
        XCTAssertLessThanOrEqual(last.x + last.width, SidebarSegmentBar.maxWidth + 0.001)
    }

    /// A planned session's row says what it waits for while that line is unchecked, then Start, which hands the
    /// shell its id.
    func testAPlannedSessionSaysWhatItWaitsForThenStarts() throws {
        var plan = Plan()
        try plan.add(Plan.Line(id: "t1", kind: .todo, title: "Choose the offers", by: .user, at: 1), to: .top)
        try plan.add(Plan.Line(id: "p1", kind: .session, title: "Pricing page", by: .lead, at: 1, after: "t1"), to: .top)
        let sidebar = SidebarView(frame: NSRect(x: 0, y: 0, width: 300, height: 700))
        sidebar.isExpanded = true
        var started: [String] = []
        sidebar.onStartPlanned = { started.append($0) }
        sidebar.plan = plan
        sidebar.update(profiles: [], workspaces: rows)
        XCTAssertTrue(labels(sidebar).map(\.text).contains("After “Choose the offers” · "))
        try plan.check("t1", by: .user, at: 2)
        sidebar.plan = plan
        sidebar.update(profiles: [], workspaces: rows)
        let texts = labels(sidebar).map(\.text)
        XCTAssertTrue(texts.contains("Planned · ") && texts.contains("Start"), "\(texts)")
        let start = try XCTUnwrap(sidebar.contentDocumentView.subviews.first { $0.accessibilityLabel() == "Start “Pricing page”" })
        XCTAssertTrue(start.accessibilityPerformPress())
        XCTAssertEqual(started, ["p1"])
    }

    func testAFeatureListsItsTasksAndLinesAndFolds() throws {
        let sidebar = SidebarView(frame: NSRect(x: 0, y: 0, width: 300, height: 700))
        sidebar.isExpanded = true
        sidebar.update(profiles: [], workspaces: rows)
        let before = labels(sidebar).map(\.text)
        XCTAssertLessThan(try XCTUnwrap(before.firstIndex(of: "Checkout")), try XCTUnwrap(before.firstIndex(of: "Export")))

        sidebar.plan = try plan()
        sidebar.update(profiles: [], workspaces: rows)
        let shown = labels(sidebar)
        let order = ["Lead", "Run the noon train", "Tasks", "Export PDF", "Export", "Check the renders", "Checkout", "Reply to the printer"]
        XCTAssertEqual(shown.map(\.text).filter(order.contains), order)
        let x = { (text: String) in shown.first { $0.text == text }?.x ?? 0 }
        XCTAssertEqual(x("Export") - x("Checkout"), SidebarExpandedMetrics.nestIndent, "the feature's task sits under it")
        XCTAssertEqual(x("Fonts") - x("Checkout"), SidebarExpandedMetrics.nestIndent * 2, "and its sub-task under that")
        XCTAssertTrue(sidebar.inFeatureIDs == ["export"], "it doesn't drag")
        // Checkout dropped below Last, the last of the tasks that drag, lands below it in the store too: past Export.
        XCTAssertEqual(sidebar.storePosition(1, draggedID: "checkout"), 2)

        sidebar.toggleFeature("f1")
        let folded = labels(sidebar).map(\.text)
        XCTAssertFalse(folded.contains("Check the renders"))
        XCTAssertTrue(folded.contains("Export") && folded.contains("Fonts"), "a task asking the user stays, with its sub-task")
        XCTAssertTrue(folded.contains("1 for you"), "its task waits for the user")
        XCTAssertTrue(folded.contains("Checkout"))

        sidebar.plan = nil
        sidebar.update(profiles: [], workspaces: rows)
        XCTAssertEqual(labels(sidebar).map(\.text), before)
    }

    /// A task's steps: an unselected row says its current step, a step for the user turns it amber, and the selected
    /// row lists them.
    func testARowSaysItsCurrentStepAndTheSelectedOneListsThem() throws {
        let steps = [
            SidebarPlanStep(title: "Reproduce", isDone: true, isForUser: false),
            SidebarPlanStep(title: "Fix the height", isDone: false, isForUser: false),
            SidebarPlanStep(title: "Check the render", isDone: false, isForUser: true)
        ]
        var idle = row("checkout", index: 1)
        idle.planSteps = steps
        XCTAssertEqual(idle.rowSummary.status.text, "Next · Fix the height")
        XCTAssertTrue(idle.rowSummary.isPlanStep)
        idle.planSteps = [steps[0], steps[2]]
        XCTAssertEqual(idle.rowSummary.status, SidebarStatusLine(text: "Needs you · Check the render", tone: .needsYou))
        XCTAssertEqual(idle.rowSummary.mark, .needsYou)
        XCTAssertTrue(idle.rowSummary(includesNextStep: false).isPlanStep, "a full row says its step too")
        XCTAssertTrue(idle.asksUser, "the fold, the rail and the archived list keep it")
        var merged = row("checkout", index: 1, pr: PRInfo(number: 7, state: .merged, isDraft: false, ciStatus: nil, checks: [], reviewDecision: nil,
                                                          mergeable: nil, url: "u", additions: nil, deletions: nil, changedFiles: nil))
        merged.planSteps = idle.planSteps
        XCTAssertNotEqual(merged.rowSummary.mark, .needsYou, "merged, the step left unticked no longer stops it")
        XCTAssertFalse(merged.asksUser)
        var withNext = row("checkout", index: 1, next: "Ship it")
        withNext.planSteps = [steps[0], steps[1]]
        XCTAssertTrue(TaskPreviewCard.statusAndNext(withNext) == ("Next · Fix the height", ""), "the preview says Next once")
        var working = row("export", index: 2)
        working = WorkspaceInfo(
            id: "export", index: 2, title: "Export", profileID: WorkspaceProfile.defaultID, isInactive: false, columnCount: 1,
            focusedColumn: 0, gitBranch: "feat/export", notification: nil, isActive: false,
            columns: [ColumnInfo(index: 0, processName: "claude", abbreviatedCwd: "~/app", isFocused: false, isWebView: false, webTitle: nil,
                                 terminalTitle: nil, agentStatus: .working, isEditor: false, editorFileName: nil)],
            prInfo: nil, diffStats: nil, purpose: nil, nextStep: nil, blocker: nil, phase: .active, lastSummary: nil, lastActivityAt: nil
        )
        working.planSteps = [steps[2]]
        XCTAssertEqual(working.rowSummary.status.text, "Working", "the user's step isn't the agent's")
        XCTAssertGreaterThan(SidebarCardLayout(workspace: working, sidebarWidth: 300).segmentsWidth, 0, "the bar stays while it works")
        working.planSteps = [steps[1]]
        XCTAssertEqual(working.rowSummary.status.text, "Fix the height")
        XCTAssertEqual(working.rowSummary.statusAlone, "Working · Fix the height", "where no bar shows")
        working.planSteps = [SidebarPlanStep(title: "Cut the images at the bottom of each page so none spills over", isDone: false, isForUser: false)]
        let long = SidebarCardLayout(workspace: working, sidebarWidth: 244)
        XCTAssertGreaterThan(long.segmentsWidth, 0)
        XCTAssertFalse(long.statusBelowStep, "a long step keeps the bar beside the badge, as on its neighbours")

        var plan = Plan()
        try plan.add(Plan.Line(id: "s1", kind: .session, title: "Checkout", by: .lead, at: 1, workspaceID: "checkout"), to: .top)
        try plan.add(Plan.Line(id: "a", kind: .step, title: "Reproduce", by: .agent, at: 1), to: .under("s1"))
        try plan.add(Plan.Line(id: "b", kind: .step, title: "Fix the height", by: .agent, at: 1), to: .under("s1"))
        try plan.check("a", by: .agent, at: 2)
        let sidebar = SidebarView(frame: NSRect(x: 0, y: 0, width: 300, height: 700))
        sidebar.isExpanded = true
        sidebar.plan = plan
        // As the shell fills them.
        let withSteps = { (infos: [WorkspaceInfo]) in
            infos.map { info in
                var info = info
                info.planSteps = SidebarView.steps(in: plan)[info.id] ?? []
                return info
            }
        }
        sidebar.update(profiles: [], workspaces: withSteps(rows))
        XCTAssertTrue(labels(sidebar).map(\.text).contains("Next · Fix the height"))
        XCTAssertFalse(labels(sidebar).map(\.text).contains("✓ 1 done"), "only the selected row lists its steps")
        var selected = rows
        selected[1] = WorkspaceInfo(
            id: "checkout", index: 1, title: "Checkout", profileID: WorkspaceProfile.defaultID, isInactive: false, columnCount: 1,
            focusedColumn: 0, gitBranch: "feat/checkout", notification: nil, isActive: true, columns: rows[1].columns, prInfo: nil,
            diffStats: nil, purpose: nil, nextStep: nil, blocker: nil, phase: .active, lastSummary: nil, lastActivityAt: nil
        )
        sidebar.update(profiles: [], workspaces: withSteps(selected))
        let texts = labels(sidebar).map(\.text)
        XCTAssertLessThan(try XCTUnwrap(texts.firstIndex(of: "✓ 1 done")), try XCTUnwrap(texts.lastIndex(of: "Fix the height")))
    }
}
