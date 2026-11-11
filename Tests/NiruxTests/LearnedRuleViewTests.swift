import AppKit
import XCTest
@testable import Nirux

/// What the user sees of learned rules outside the sheet: the Lead row's
/// "Rule proposed · Review" and where its click goes, and the brief's size
/// in Space Settings › Brief and in the sheet.
@MainActor
final class LearnedRuleViewTests: XCTestCase {
    private func info(index: Int, isLead: Bool, proposals: Int) -> WorkspaceInfo {
        var info = WorkspaceInfo(
            id: "workspace-\(index)", index: index, title: isLead ? "Lead" : "task \(index)",
            profileID: "space", isInactive: false, columnCount: 0, focusedColumn: 0, gitBranch: nil, notification: nil,
            isActive: false, columns: [], prInfo: nil, diffStats: nil, purpose: nil, nextStep: nil, blocker: nil,
            phase: .active, lastSummary: nil, lastActivityAt: nil
        )
        info.isLead = isLead
        info.ruleProposalCount = proposals
        return info
    }

    /// The Lead's row says how many rules wait, quietly; a click asks for
    /// that row's proposals. A task's row never says it.
    func testTheLeadRowOffersItsProposedRules() throws {
        _ = NSApplication.shared
        let sidebar = SidebarView(frame: NSRect(x: 0, y: 0, width: 260, height: 660))
        let window = NSWindow(contentRect: sidebar.bounds, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = sidebar
        defer { window.close() }
        sidebar.isExpanded = true
        var clicked: [String] = []
        sidebar.onRuleProposalsClicked = { clicked.append($0) }

        XCTAssertEqual(info(index: 0, isLead: true, proposals: 2).cardActions, [.ruleProposals(count: 2)])
        XCTAssertEqual(info(index: 0, isLead: true, proposals: 0).cardActions, [])
        XCTAssertEqual(info(index: 1, isLead: false, proposals: 2).cardActions, [])
        XCTAssertTrue(SidebarCardAction.ruleProposals(count: 1).isQuiet, "nothing waits on it: no separator, no amber")

        sidebar.update(profiles: [], workspaces: [info(index: 0, isLead: true, proposals: 2), info(index: 1, isLead: false, proposals: 0)])
        sidebar.layoutSubtreeIfNeeded()
        let url = SidebarView.ruleProposalsActionURL(spaceID: "space")
        let area = try XCTUnwrap(sidebar.hitAreas.first { area in
            if case .link(let target, _) = area.region { return target == url }
            return false
        })
        guard case .link(_, let label) = area.region else { return XCTFail("not a link") }
        XCTAssertEqual(label.stringValue, "2 rules proposed · Review")
        sidebar.mouseDown(with: try XCTUnwrap(NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: sidebar.contentDocumentView.convert(NSPoint(x: area.frame.midX, y: area.frame.midY), to: nil),
            modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
            context: nil, eventNumber: 0, clickCount: 1, pressure: 0
        )))
        XCTAssertEqual(clicked, ["space"])
        XCTAssertEqual(SidebarWorkspaceCardRenderer.ruleProposalsTitle(count: 1), "Rule proposed")
    }

    /// Space Settings › Brief shows what sessions get of the brief as it
    /// is typed; the other files show no size.
    func testTheBriefEditorShowsItsSize() throws {
        let state = FileManager.default.temporaryDirectory.appendingPathComponent("nirux-brief-size-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: state) }
        let max = SpaceBrief.maxCharacters.formatted()
        let brief = SpaceFileEditorPane(source: try XCTUnwrap(.brief(spaceID: "space", spaceName: "Nirux", stateDirectory: state)))
        XCTAssertEqual(brief.sizeLabel.stringValue, "0 of \(max)", "the template is a comment")
        brief.textView.string += "Ship v2 first.\n"
        brief.textDidChange(Notification(name: NSText.didChangeNotification))
        XCTAssertEqual(brief.sizeLabel.stringValue, "14 of \(max)")
        let templates = SpaceFileEditorPane(source: try XCTUnwrap(.taskTemplates(spaceID: "space", spaceName: "Nirux", stateDirectory: state)))
        XCTAssertEqual(templates.sizeLabel.stringValue, "")
    }

    /// Grey; "long" past half of what sessions get; red past all of it.
    /// Never amber: that means an agent waits for the user.
    func testTheSizeLineWarnsBeforeTheLimit() {
        let max = SpaceBrief.maxCharacters
        let small = LearnedRuleSheet.sizeText(before: 1_240, after: 1_330, max: max)
        XCTAssertEqual(small.text, "Brief: \(1_240.formatted()) → \(1_330.formatted()) of \(max.formatted()) characters")
        XCTAssertEqual(small.color, Theme.Color.textTertiary)
        let long = LearnedRuleSheet.sizeText(before: 8_000, after: 8_100, max: max)
        XCTAssertTrue(long.text.hasSuffix(" · long"), long.text)
        XCTAssertEqual(long.color, Theme.Color.textSecondary)
        XCTAssertEqual(LearnedRuleSheet.sizeText(before: 15_990, after: 16_090, max: max).color, Theme.Color.error)
    }
}
