import AppKit
import XCTest
@testable import Nirux

@MainActor
final class SidebarPullRequestLinkTests: XCTestCase {
    private func workspace(index: Int, prInfo: PRInfo?) -> WorkspaceInfo {
        WorkspaceInfo(
            id: "workspace-\(index)",
            index: index,
            title: "workspace \(index)",
            profileID: WorkspaceProfile.defaultID,
            isInactive: false,
            columnCount: 0,
            focusedColumn: 0,
            gitBranch: "feat/\(index)",
            hasNotification: false,
            isActive: index == 0,
            columns: [],
            prInfo: prInfo,
            diffStats: nil,
            purpose: nil,
            nextStep: nil,
            blocker: nil,
            phase: .active,
            lastSummary: nil,
            lastActivityAt: nil
        )
    }

    private func pullRequest(ciStatus: String, failedCheckUrl: String? = nil) -> PRInfo {
        PRInfo(
            number: 42,
            state: "OPEN",
            isDraft: false,
            ciStatus: ciStatus,
            failedCheckUrl: failedCheckUrl,
            reviewDecision: "REVIEW_REQUIRED",
            mergeable: nil,
            url: "https://github.com/owner/repo/pull/42",
            additions: nil,
            deletions: nil,
            changedFiles: nil
        )
    }

    /// Clicks every link of the second card, in order, and returns what the
    /// sidebar asked to open, and where.
    private func clickLinks(of prInfo: PRInfo) throws -> [(workspaceIndex: Int, url: String)] {
        _ = NSApplication.shared
        let sidebar = SidebarView(frame: NSRect(x: 0, y: 0, width: 260, height: 660))
        let window = NSWindow(contentRect: sidebar.bounds, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = sidebar
        defer { window.close() }
        sidebar.isExpanded = true
        sidebar.update(profiles: [], workspaces: [workspace(index: 0, prInfo: nil), workspace(index: 1, prInfo: prInfo)])
        sidebar.layoutSubtreeIfNeeded()

        var opened: [(workspaceIndex: Int, url: String)] = []
        sidebar.onWorkspaceURLClicked = { opened.append(($0, $1)) }
        let links = sidebar.hitAreas.filter {
            if case .link = $0.region { return true }
            return false
        }
        for link in links {
            sidebar.mouseDown(with: try XCTUnwrap(NSEvent.mouseEvent(
                with: .leftMouseDown,
                location: sidebar.contentDocumentView.convert(NSPoint(x: link.frame.midX, y: link.frame.midY), to: nil),
                modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber,
                context: nil,
                eventNumber: 0,
                clickCount: 1,
                pressure: 0
            )))
        }
        return opened
    }

    func testPullRequestLinksOpenInTheirCardsWorkspace() throws {
        let opened = try clickLinks(of: pullRequest(ciStatus: "PENDING"))

        XCTAssertEqual(opened.map(\.workspaceIndex), [1, 1, 1])
        XCTAssertEqual(opened.map(\.url), [
            "https://github.com/owner/repo/pull/42",
            "https://github.com/owner/repo/pull/42/checks",
            "https://github.com/owner/repo/pull/42"
        ])
    }

    func testFailedCILinkOpensTheFailedCheck() throws {
        let failed = "https://github.com/owner/repo/actions/runs/7/job/8"
        let opened = try clickLinks(of: pullRequest(ciStatus: "FAILURE", failedCheckUrl: failed))

        XCTAssertEqual(opened.map(\.url)[1], failed)
    }
}
