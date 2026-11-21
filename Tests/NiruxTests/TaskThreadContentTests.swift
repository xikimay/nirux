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
            // Synthetic hover events share no pointer with the other CI windows.
            harness.window.orderOut(nil)
            let space = shell.activeProfileID
            let tasks = [UUID().uuidString, UUID().uuidString]
            let reader = shell.pinnedThreadReader
            var reads: [String: Int] = [:]
            shell.pinnedThreadReader = { id, space, done in
                reads[id, default: 0] += 1
                reader(id, space, done)
            }
            for (index, id) in tasks.enumerated() {
                shell.addWorkspace(title: "Thread task", cwd: harness.worktree, workspaceID: id, activate: false)
                TaskThread.Store.append([.init(time: 1, kind: .request, text: "Request for task \(index)")],
                                        workspaceID: id, spaceID: space, stateDirectory: URL(fileURLWithPath: harness.stateDirectory))
            }
            shell.updateSidebar()
            for (index, id) in tasks.enumerated() {
                let expanded = index == 0
                shell.isSidebarExpanded = expanded
                sidebar.isExpanded = expanded
                shell.relayout(animated: false)
                harness.window.contentView?.layoutSubtreeIfNeeded()
                if expanded {
                    let document = sidebar.contentDocumentView
                    let row = try XCTUnwrap(sidebar.rowFrame(workspaceID: id))
                    document.scrollToVisible(document.convert(row, from: sidebar))
                    let frame = try XCTUnwrap(sidebar.rowFrame(workspaceID: id)).intersection(sidebar.visibleRect)
                    XCTAssertFalse(frame.isEmpty)
                    let point = sidebar.convert(NSPoint(x: frame.midX, y: frame.midY), to: nil)
                    let event = try XCTUnwrap(NSEvent.mouseEvent(with: .mouseMoved, location: point, modifierFlags: [],
                        timestamp: 0, windowNumber: harness.window.windowNumber, context: nil, eventNumber: 0, clickCount: 0, pressure: 0))
                    sidebar.mouseMoved(with: event)
                } else {
                    try XCTUnwrap(sidebar.iconRail.itemViews[id]).mouseEntered(with: NSEvent())
                }
                XCTAssertEqual(sidebar.taskPreview.workspaceID, id)
                waitUntil("the preview for \(expanded ? "row" : "rail") \(id), tracking \(sidebar.taskPreview.workspaceID ?? "none")") {
                    sidebar.taskPreview.workspaceID == id && sidebar.taskPreview.card != nil
                }
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
                XCTAssertEqual(reads[id], 1)
                let other = try XCTUnwrap(shell.workspaces.first { $0.id == tasks[1 - index] })
                for change in 1...3 {
                    other.lastSummary = "Unrelated metadata \(change)"
                    shell.updateSidebar()
                    XCTAssertFalse(body.isReading, "sidebar updates do not start a thread check")
                    shell.refreshPinnedTaskThread()
                    harness.waitUntil("the pinned input check completes") { !body.isReading }
                    XCTAssertEqual(reads[id], 1)
                }
                preview.mouseExited(with: NSEvent())
                sidebar.taskPreview.enter(tasks[1 - index])
                XCTAssertNil(sidebar.taskPreview.pending)
                TaskThread.Store.append([.init(time: 2, kind: .status, text: "Updated task \(index)")], workspaceID: id,
                                        spaceID: space, stateDirectory: URL(fileURLWithPath: harness.stateDirectory))
                sidebar.rebuildContent()
                shell.updateSidebar()
                shell.refreshPinnedTaskThread()
                harness.waitUntil("the same card shows the new entry") {
                    self.labels(body).contains { $0.contains("Updated task \(index)") }
                }
                XCTAssertEqual(reads[id], 2)
                let task = try XCTUnwrap(shell.workspaces.first { $0.id == id })
                task.reviewRuns[.adversarial] = ReviewRun(head: "abc1234", at: 3, branch: "thread")
                shell.refreshPinnedTaskThread()
                harness.waitUntil("the in-memory review appears without a thread file write") {
                    self.labels(body).contains { $0.contains("abc1234") }
                }
                XCTAssertEqual(reads[id], 3)
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

    func testRefreshPreservesTheDraftAndDisablesSendWhenItsQuestionCloses() throws {
        let body = TaskThreadContentView(frame: NSRect(x: 0, y: 0, width: 372, height: 500))
        let window = NSWindow(contentRect: body.frame, styleMask: [.borderless], backing: .buffered, defer: true)
        window.contentView = body
        body.onReply = { _, _ in XCTFail("a closed question cannot send"); return .retry }
        let ask = TaskThread.Event(time: 1, kind: .question, text: "Ship?", ref: "q1", recipient: .user)
        let other = TaskThread.Event(time: 2, kind: .question, text: "Ship?", ref: "q2", recipient: .user)
        @MainActor func show(_ events: [TaskThread.Event]) {
            body.show(workspaceID: "task", spaceID: "space") { _, _, done in done(.init(events: events, context: .init())) }
        }
        show([ask])
        let cell = try XCTUnwrap(body.outline.view(atColumn: 0, row: 0, makeIfNecessary: true))
        try XCTUnwrap(UIFlowHarness.button(titled: "Reply…", in: cell)).performClick(nil)
        let editor = try XCTUnwrap(UIFlowHarness.descendant(of: body, as: TaskThreadReplyView.self))
        editor.field.string = "Only after review"
        show([ask, other])
        XCTAssertTrue(window.firstResponder === editor.field)
        let send = try XCTUnwrap(UIFlowHarness.button(titled: "Send ⌘↩", in: editor))
        XCTAssertTrue(send.isEnabled)
        show([ask, other, .init(time: 3, kind: .questionRetired, ref: "q1")])
        XCTAssertFalse(send.isEnabled)
        XCTAssertEqual(editor.field.string, "Only after review")
        editor.field.onCommandReturn?()
        XCTAssertEqual(labels(body).filter { $0.hasPrefix("Needs you") }.count, 1)
    }

    func testPinnedReplyKeepsItsQuestionAcrossAnswersRetirementAndReplacement() throws {
        try UIFlowHarness.run { harness in
            let shell = harness.shell
            let store = MissionStore.shared
            let lead = try harness.makeLead()
            let id = UUID().uuidString
            let mission = try XCTUnwrap(store.create(MissionCreationRequest(
                id: UUID().uuidString, parentWorkspaceID: lead.workspace.id, parentAgentUUID: lead.agentUUID,
                childWorkspaceID: id, childAgentUUID: UUID().uuidString, childAgentKind: "claude",
                branch: "feat/reply", reportsToLead: true
            ), enabled: true))
            shell.addWorkspace(title: "Reply task", cwd: harness.worktree, profileID: lead.space, workspaceID: id,
                               initialAgentUUID: mission.childAgentUUID, missionID: mission.id,
                               reportsToLead: true, activate: false)
            let activeID = shell.activeWorkspace?.id
            XCTAssertNotEqual(activeID, id)

            @MainActor func ask(_ text: String) throws -> MissionEvent {
                let question = MissionEvent(id: UUID().uuidString, missionID: mission.id, childWorkspaceID: id,
                    childAgentUUID: mission.childAgentUUID, kind: .question, message: text, timestamp: Date().timeIntervalSince1970)
                guard case .accepted = store.process(question, enabled: false) else {
                    XCTFail("the child asks its Lead")
                    return question
                }
                _ = try XCTUnwrap(store.handToUser(questionID: question.id, because: "User decision"))
                return question
            }

            let first = try ask("Which format?")
            let second = try ask("Which timezone?")
            shell.isSidebarExpanded = false
            shell.sidebar.isExpanded = false
            shell.updateSidebar()
            shell.relayout(animated: false)
            harness.window.contentView?.layoutSubtreeIfNeeded()
            let rail = try XCTUnwrap(shell.sidebar.iconRail.itemViews[id])
            harness.window.orderOut(nil)
            rail.mouseEntered(with: NSEvent())
            harness.waitUntil("the task preview") { shell.sidebar.taskPreview.card != nil }
            let card = try XCTUnwrap(shell.sidebar.taskPreview.card)
            try XCTUnwrap(UIFlowHarness.button(titled: "Open task thread", in: card)).performClick(nil)
            let body = try XCTUnwrap(shell.sidebar.taskPreview.pinnedBody)

            @MainActor func openReply(_ question: MissionEvent) throws -> TaskThreadReplyView {
                harness.waitUntil("the open question") {
                    self.labels(body).contains { $0.hasPrefix("Needs you") && $0.contains(question.message) }
                }
                let row = try XCTUnwrap(self.labels(body).firstIndex { $0.hasPrefix("Needs you") && $0.contains(question.message) })
                let cell = try XCTUnwrap(body.outline.view(atColumn: 0, row: row, makeIfNecessary: true))
                let reply = try XCTUnwrap(UIFlowHarness.button(titled: "Reply…", in: cell))
                XCTAssertFalse(reply.isHidden)
                reply.performClick(nil)
                let editor = try XCTUnwrap(UIFlowHarness.descendant(of: body, as: TaskThreadReplyView.self))
                XCTAssertEqual(editor.questionID, question.id)
                XCTAssertTrue(harness.window.firstResponder === editor.field)
                return editor
            }

            try harness.withApp {
                let editor = try openReply(second)
                XCTAssertTrue(shell.isOverlayActive, "the terminal interceptor leaves these keys to AppKit")
                // XCTest has no key window. Deliver AppKit’s key to this window’s first responder.
                @MainActor func type(_ text: String, code: UInt16, modifiers: NSEvent.ModifierFlags = []) throws {
                    let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
                        timestamp: 0, windowNumber: harness.window.windowNumber, context: nil, characters: text,
                        charactersIgnoringModifiers: text, isARepeat: false, keyCode: code))
                    harness.window.sendEvent(event)
                }
                try type("y", code: 0x10)
                XCTAssertEqual(editor.field.string, "y")
                try type("\r", code: 0x24, modifiers: .command)
                XCTAssertEqual(store.response(to: second.id)?.message, "y")
                XCTAssertEqual(store.response(to: second.id)?.answeredByUser, true)
                XCTAssertNil(store.response(to: first.id))
                XCTAssertNil(editor.superview)
                XCTAssertTrue(shell.sidebar.taskPreview.card === card)
                XCTAssertEqual(shell.activeWorkspace?.id, activeID)
            }

            let answered = try openReply(first)
            answered.field.string = "My draft"
            let replacement = try ask("Which schema?")
            XCTAssertNotNil(store.respond(to: first.id, message: "Already decided", enabled: true))
            try XCTUnwrap(UIFlowHarness.button(titled: "Send ⌘↩", in: answered)).performClick(nil)
            XCTAssertEqual(store.response(to: first.id)?.message, "Already decided")
            XCTAssertNil(store.response(to: replacement.id))
            XCTAssertFalse(answered.field.isEditable)
            XCTAssertEqual(answered.field.string, "My draft")
            try XCTUnwrap(UIFlowHarness.button(titled: "Done", in: answered)).performClick(nil)

            shell.refreshPinnedTaskThread()
            let retired = try openReply(replacement)
            retired.field.string = "Draft for the retired question"
            let newest = try ask("Which version?")
            // The ledger as written by #691 when a new prompt retires a question.
            var missions = store.missions
            let index = try XCTUnwrap(missions.firstIndex { $0.id == mission.id })
            let event = try XCTUnwrap(missions[index].events.firstIndex { $0.id == replacement.id })
            let now = Date().timeIntervalSince1970
            missions[index].events[event].retiredAt = now
            missions[index].events[event].parentConsumedAt = now
            try JSONEncoder().encode(missions).write(to: store.fileURL, options: .atomic)
            XCTAssertTrue(store.load())
            XCTAssertEqual(store.missions[index].events[event].retiredAt, now)
            retired.field.onCommandReturn?()
            XCTAssertNil(store.response(to: replacement.id))
            XCTAssertNil(store.response(to: newest.id))
            XCTAssertFalse(retired.field.isEditable)
            shell.refreshPinnedTaskThread()
            harness.waitUntil("the replacement question is visible while the draft stays put") {
                self.labels(body).contains { $0.hasPrefix("Needs you") && $0.contains(newest.message) }
            }
            XCTAssertEqual(retired.field.string, "Draft for the retired question")
            XCTAssertFalse(try XCTUnwrap(UIFlowHarness.button(titled: "Send ⌘↩", in: retired)).isEnabled)
            XCTAssertFalse(self.labels(body).contains { $0.hasPrefix("Needs you") && $0.contains(replacement.message) })
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
