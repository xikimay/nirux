import AppKit
import XCTest
@testable import Nirux

/// The day plan in the sidebar (SidebarView+Plan): a feature lists its tasks and lines, folds, and leaves the rest
/// of the list as it was.
@MainActor
final class SidebarPlanTests: XCTestCase {
    private func row(_ id: String, index: Int, lead: Bool = false, asks: Bool = false) -> WorkspaceInfo {
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
        return info
    }

    private var rows: [WorkspaceInfo] {
        [row("lead", index: 0, lead: true), row("checkout", index: 1), row("export", index: 2, asks: true)]
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
        XCTAssertTrue(sidebar.inFeatureIDs == ["export"], "it doesn't drag")

        sidebar.toggleFeature("f1")
        let folded = labels(sidebar).map(\.text)
        XCTAssertFalse(folded.contains("Export") || folded.contains("Check the renders"))
        XCTAssertTrue(folded.contains("1 for you"), "its task waits for the user")
        XCTAssertTrue(folded.contains("Checkout"))

        sidebar.plan = nil
        sidebar.update(profiles: [], workspaces: rows)
        XCTAssertEqual(labels(sidebar).map(\.text), before)
    }
}
