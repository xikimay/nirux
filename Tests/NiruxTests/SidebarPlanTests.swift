import AppKit
import XCTest
@testable import Nirux

/// The day plan in the sidebar (SidebarView+Plan): a feature lists its tasks and lines, folds, and leaves the rest
/// of the list as it was.
@MainActor
final class SidebarPlanTests: XCTestCase {
    private func row(_ id: String, index: Int, lead: Bool = false, asks: Bool = false, parent: String? = nil) -> WorkspaceInfo {
        let column = ColumnInfo(
            index: 0, processName: "claude", abbreviatedCwd: "~/app", isFocused: false, isWebView: false, webTitle: nil,
            terminalTitle: nil, agentStatus: asks ? .needsAttention : .idle, isEditor: false, editorFileName: nil,
            attentionReason: asks ? .question("Which date?") : nil
        )
        var info = WorkspaceInfo(
            id: id, index: index, title: id.capitalized, profileID: WorkspaceProfile.defaultID, isInactive: false,
            columnCount: 1, focusedColumn: 0, gitBranch: "feat/\(id)", notification: nil, isActive: false, columns: [column],
            prInfo: nil, diffStats: nil, purpose: nil, nextStep: nil, blocker: nil, phase: .active, lastSummary: nil, lastActivityAt: nil
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
}
