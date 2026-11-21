import AppKit
import XCTest
@testable import Nirux

@MainActor
final class TaskThreadContentTests: XCTestCase {
    private func labels(_ view: TaskThreadContentView) -> [String] {
        (0..<view.outline.numberOfRows).compactMap { row in
            guard let item = view.outline.item(atRow: row) else { return nil }
            return view.outlineView(view.outline, viewFor: nil, item: item)?.accessibilityLabel()
        }
    }

    func testRefreshKeepsDisclosuresAndLateReadsCannotReplaceAnotherTask() throws {
        let body = TaskThreadContentView(frame: NSRect(x: 0, y: 0, width: 372, height: 500))
        let timeline = TaskThread.Timeline(events: [
            .init(time: 1, kind: .request, text: "First request"),
            .init(time: 2, kind: .review, detail: "Adversarial"),
            .init(time: 3, kind: .findings, text: "One finding")
        ], context: .init(status: "Reviewing"))
        body.show(workspaceID: "one", spaceID: "here") { id, space, done in
            XCTAssertEqual([id, space], ["one", "here"])
            done(timeline)
        }
        XCTAssertEqual(body.outline.numberOfRows, 3)
        body.outline.expandItem(try XCTUnwrap(body.outline.item(atRow: 2)))
        XCTAssertEqual(body.outline.numberOfRows, 5)
        XCTAssertTrue(labels(body).contains { $0.contains("Adversarial") })
        body.show(workspaceID: "one", spaceID: "here") { _, _, done in done(timeline) }
        XCTAssertEqual(body.outline.numberOfRows, 5)
        var finish: (@MainActor (TaskThread.Timeline?) -> Void)?
        body.show(workspaceID: "one", spaceID: "here") { _, _, done in finish = done }
        body.show(workspaceID: "two", spaceID: "here") { _, _, done in done(.init(events: [], context: .init())) }
        finish?(timeline)
        XCTAssertEqual(labels(body), ["No recorded events."])
        body.show(workspaceID: "one", spaceID: "elsewhere") { _, _, done in done(nil) }
        XCTAssertEqual(labels(body), ["Thread unavailable"])
    }

    func testOpeningASectionShowsTheWholeRequestAtCardWidth() throws {
        let body = TaskThreadContentView(frame: NSRect(x: 0, y: 0, width: 372, height: 500))
        let window = NSWindow(contentRect: body.frame, styleMask: [.borderless], backing: .buffered, defer: true)
        window.contentView = body
        let request = Array(repeating: "A request long enough to wrap across the card.", count: 12).joined(separator: " ")
        body.show(workspaceID: "one", spaceID: "here") { _, _, done in
            done(.init(events: [.init(time: 1, kind: .request, text: request)], context: .init()))
        }
        body.outline.expandItem(try XCTUnwrap(body.outline.item(atRow: 0)))
        window.contentView?.layoutSubtreeIfNeeded()
        let child = try XCTUnwrap(body.outline.view(atColumn: 0, row: 1, makeIfNecessary: true))
        XCTAssertTrue(try XCTUnwrap(child.accessibilityLabel()).contains(request))
        XCTAssertGreaterThan(body.outline.rect(ofRow: 1).height, body.outline.rect(ofRow: 0).height * 2)
    }

    func testPendingOwnershipAndAccessRedactionApplyToFoldedAndExpandedContent() throws {
        let timeline = TaskThread.Timeline(events: [
            .init(time: 1, kind: .question, text: "Which credential?", detail: "access", ref: "access"),
            .init(time: 2, kind: .answer, by: .user, text: "private value", ref: "access"),
            .init(time: 3, kind: .commit, text: "Ship reader"),
            .init(time: 4, kind: .question, text: "Which release?", note: "Pick the stable one", ref: "release", recipient: .lead),
            .init(time: 5, kind: .handedToUser, ref: "release"),
            .init(time: 6, kind: .question, text: "Which branch?", ref: "branch", recipient: .lead)
        ], context: .init())
        XCTAssertEqual(timeline.sections.map(\.stage), [.plan, .code])
        XCTAssertEqual(timeline.current.map(\.needsUser), [true, false])
        XCTAssertEqual(timeline.current.map(\.label), ["Needs you", "Waiting on lead"])
        XCTAssertTrue(timeline.current[0].text.contains("Pick the stable one"))
        let body = TaskThreadContentView()
        body.show(workspaceID: "one", spaceID: "here") { _, _, done in done(timeline) }
        for expanded in [false, true] {
            if expanded { body.outline.expandItem(nil, expandChildren: true) }
            let text = labels(body).joined(separator: "\n")
            XCTAssertTrue(text.contains("Answer withheld"))
            XCTAssertFalse(text.contains("private value"))
            XCTAssertTrue(text.contains("Which release?"))
        }
    }

    func testRowAndRailPinTheirOwnThreadThroughRefreshUntilEscape() throws {
        try UIFlowHarness.run { harness in
            let shell = harness.shell
            let sidebar = shell.sidebar
            let space = shell.activeProfileID
            let tasks = [UUID().uuidString, UUID().uuidString]
            for (index, id) in tasks.enumerated() {
                shell.addWorkspace(title: "Thread task", cwd: harness.worktree, workspaceID: id, activate: false)
                TaskThread.Store.append([.init(time: 1, kind: .request, text: "Request for task \(index)")],
                                        workspaceID: id, spaceID: space, stateDirectory: URL(fileURLWithPath: harness.stateDirectory))
            }
            shell.updateSidebar()
            for (index, id) in tasks.enumerated() {
                let expanded = index == 0
                if shell.isSidebarExpanded != expanded { shell.toggleSidebar() }
                harness.waitUntil("the requested sidebar layout") { sidebar.isExpanded == expanded }
                harness.window.contentView?.layoutSubtreeIfNeeded()
                if expanded {
                    let frame = try XCTUnwrap(sidebar.rowFrame(workspaceID: id))
                    let point = sidebar.convert(NSPoint(x: frame.midX, y: frame.midY), to: nil)
                    let event = try XCTUnwrap(NSEvent.mouseEvent(with: .mouseMoved, location: point, modifierFlags: [],
                        timestamp: 0, windowNumber: harness.window.windowNumber, context: nil, eventNumber: 0, clickCount: 0, pressure: 0))
                    sidebar.mouseMoved(with: event)
                } else {
                    try XCTUnwrap(sidebar.iconRail.itemViews[id]).mouseEntered(with: NSEvent())
                }
                harness.waitUntil("the preview for the hovered task") { sidebar.taskPreview.workspaceID == id && sidebar.taskPreview.card != nil }
                let preview = try XCTUnwrap(sidebar.taskPreview.card)
                let open = try XCTUnwrap(preview.subviews.compactMap { $0 as? NSButton }.first { $0.title == "Open task thread" })
                preview.mouseExited(with: NSEvent())
                XCTAssertNotNil(sidebar.taskPreview.pending)
                open.performClick(nil)
                XCTAssertNil(sidebar.taskPreview.pending)
                let body = try XCTUnwrap(preview.subviews.compactMap { $0 as? TaskThreadContentView }.first)
                harness.waitUntil("the pinned workspace's recorded request") {
                    self.labels(body).contains { $0.contains("Request for task \(index)") }
                }
                preview.mouseExited(with: NSEvent())
                sidebar.taskPreview.enter(tasks[1 - index])
                XCTAssertNil(sidebar.taskPreview.pending)
                TaskThread.Store.append([.init(time: 2, kind: .status, text: "Updated task \(index)")], workspaceID: id,
                                        spaceID: space, stateDirectory: URL(fileURLWithPath: harness.stateDirectory))
                sidebar.rebuildContent()
                shell.updateSidebar()
                harness.waitUntil("the same card shows the new entry") {
                    self.labels(body).contains { $0.contains("Updated task \(index)") }
                }
                XCTAssertTrue(sidebar.taskPreview.card === preview)
                XCTAssertEqual(sidebar.taskPreview.workspaceID, id)
                XCTAssertTrue(preview.window === harness.window)
                XCTAssertTrue(body.isDescendant(of: preview))
                XCTAssertTrue(self.labels(body).contains { $0.contains("Request for task \(index)") })
                harness.press(.escape, in: harness.window)
                harness.waitUntil("Escape closes the pinned card") { preview.superview == nil }
                XCTAssertNil(sidebar.taskPreview.pinnedBody)
            }
        }
    }

    func testContentReadsOnlyTheSelectedSpacesFrozenThread() throws {
        try UIFlowHarness.run { harness in
            let space = harness.shell.activeProfileID
            let id = UUID().uuidString
            let directory = URL(fileURLWithPath: harness.stateDirectory)
            TaskThread.Store.append([
                .init(time: 1, kind: .request, text: "Frozen request"),
                .init(time: 2, kind: .closed, detail: "local")
            ], workspaceID: id, spaceID: space, stateDirectory: directory)
            let body = TaskThreadContentView()
            body.show(workspaceID: id, spaceID: space, read: harness.shell.readThreadTimeline)
            harness.waitUntil("the frozen request") { self.labels(body).contains { $0.contains("Frozen request") } }
            body.show(workspaceID: id, spaceID: "other", read: harness.shell.readThreadTimeline)
            harness.waitUntil("the other space has no thread") { self.labels(body) == ["Thread unavailable"] }
        }
    }
}
