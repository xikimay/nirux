import AppKit
import XCTest
@testable import Nirux

/// AppKit reports a plain NSView disabled to assistive apps: VoiceOver read
/// Nirux's drawn buttons "dimmed" and the canary's press skipped them. Each
/// is read here as an assistive app reads it (`NiruxApp.accessibilitySnapshot`):
/// enabled, unless a press would do nothing.
@MainActor
final class AccessibilityEnabledTests: XCTestCase {
    /// Never shown; kept for as long as the test runs.
    private var windows: [NSWindow] = []

    private func hosted(_ view: NSView) -> NSWindow {
        let window = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.contentView = view
        windows.append(window)
        return window
    }

    /// The window's controls in reading order: (label, enabled).
    private func controls(in window: NSWindow) -> [(label: String, enabled: Bool)] {
        let roles = Set([NSAccessibility.Role.button, .radioButton, .radioGroup, .menuButton].map(\.rawValue))
        let elements = NiruxApp.accessibilitySnapshot(of: window)["elements"] as? [[String: Any]] ?? []
        return elements.filter { roles.contains($0["role"] as? String ?? "") }
            .map { ($0["label"] as? String ?? "", $0["enabled"] as? Bool ?? false) }
    }

    private func assertAllEnabled(
        _ controls: [(label: String, enabled: Bool)], showing labels: [String], file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertEqual(controls.filter { !$0.enabled }.map(\.label), [], "none reads dimmed", file: file, line: line)
        for label in labels {
            XCTAssertTrue(controls.contains { $0.label.hasPrefix(label) }, "\(label) in \(controls.map(\.label))", file: file, line: line)
        }
    }

    private let space = ProfileInfo(
        id: WorkspaceProfile.defaultID, name: "Acme", colorHex: "#9ECE6A", isActive: true, workspaceCount: 1, taskCount: 1, attention: nil
    )

    /// Unfolded: the space picker, "+", a row's "⋯", Board, History, the
    /// catch-up card's and the checklist's buttons. Board without a task to
    /// show its space's Board has nothing to press.
    func testTheSidebarsControlsReadEnabled() {
        let sidebar = SidebarView(frame: NSRect(x: 0, y: 0, width: 260, height: 900))
        let window = hosted(sidebar)
        sidebar.isExpanded = true
        sidebar.update(profiles: [space], workspaces: [SidebarTestData.workspace()])
        sidebar.catchUp = SidebarCatchUp(
            since: "since 12:40", rows: [SidebarCatchUp.Row(workspaceID: "ws-1", title: "ws 1", kind: .done, text: "Done")], otherSpaces: []
        )
        sidebar.refreshCatchUpCard()
        sidebar.onboardingChecklist = OnboardingChecklist(
            agents: AgentCLIAvailability(claudePath: nil, codexPath: nil), skills: .missing,
            hooks: AgentHooksStatus(claude: true, codex: true, installsHooks: true)
        )
        assertAllEnabled(controls(in: window), showing: [
            "Space", SidebarView.newTaskTitle, "Workspace actions", SidebarView.boardTitle, SidebarView.historyTitle,
            "Dismiss what happened while you were away", "ws 1: Done", "Install"
        ])

        sidebar.navigation = SidebarNavigation(boardShown: false, boardAvailable: false)
        sidebar.update(profiles: [space], workspaces: [SidebarTestData.workspace()])
        XCTAssertEqual(controls(in: window).filter { !$0.enabled }.map(\.label), [SidebarView.boardTitle], "nothing to press: dimmed")
    }

    /// Folded: the rail's places.
    func testTheRailsPlacesReadEnabled() {
        let sidebar = SidebarView(frame: NSRect(x: 0, y: 0, width: SidebarView.foldedWidth, height: 600))
        let window = hosted(sidebar)
        sidebar.update(profiles: [space], workspaces: [SidebarTestData.workspace()])
        assertAllEnabled(controls(in: window), showing: ["ws 1, "])
    }

    /// A task's line, a merged pull request of a task open here.
    func testTheBoardsLinesReadEnabled() {
        let line = BoardStages.Line(
            id: "task", title: "Task", station: .checks, state: .waiting, rail: BoardStages.Rail(marks: [.done, .current, .ahead, .ahead]),
            phrase: BoardStages.Phrase(text: "Checks running", detail: nil), pullRequest: "#52", since: nil
        )
        let merged = BoardStages.Merged(lineID: "task", title: "Shipped", number: 7, mergedAt: 1_794_405_600)
        let board = BoardStagesView(frame: NSRect(x: 0, y: 0, width: 940, height: 600))
        let window = hosted(board)
        board.clock = { 0 }
        board.after = { _, _ in }
        board.show(BoardStagesView.Content(
            header: BoardStagesView.Header(
                name: "nirux", color: Theme.Color.accent, summary: "1 task", lead: BoardStagesView.Lead(state: .working, text: "Lead")
            ),
            order: .sidebar,
            sections: [BoardStagesView.Section(
                id: "nirux", title: "nirux", detail: "acme/nirux", status: nil,
                lines: BoardStages.Section(id: "nirux", units: [.task(line, subtasks: [])], withoutTask: [], merged: [merged])
            )],
            now: 1_794_405_600
        ))
        board.layoutSubtreeIfNeeded()
        assertAllEnabled(controls(in: window), showing: ["Task, ", "Shipped, "])
    }

    /// Settings › Appearance's tiles, and their group.
    func testTheAppearancePickerReadsEnabled() {
        let picker = TransparencyPicker(selection: .opaque)
        picker.frame = NSRect(x: 0, y: 0, width: 480, height: 120)
        assertAllEnabled(controls(in: hosted(picker)), showing: ["Interface"] + InterfaceTransparency.allCases.map(\.title))
    }
}
