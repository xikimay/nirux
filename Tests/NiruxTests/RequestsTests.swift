import AppKit
import XCTest
@testable import Nirux

/// The requests of agents waiting for the user, as the inbox and the rail's
/// callout get them (docs/design/glass-interface.md, step 3.3).
@MainActor
final class RequestsTests: XCTestCase {
    private func mission(_ id: String, askedAt: TimeInterval) -> SidebarMissionQuestion {
        SidebarMissionQuestion(questionID: id, parentTitle: "Lead", text: "Which endpoint?", handOff: .parentClosed, askedAt: askedAt)
    }

    /// What a waiting column asks: the first that holds of a Mission
    /// question handed to the user, a permission the rows answer, its
    /// turn's question, a question dialog; else what only the terminal
    /// answers, worded from the wait.
    func testAColumnAsksTheFirstThatHolds() throws {
        let question = SidebarTurnQuestion(text: "Ship it?", turnEndedAt: 5, isYesNo: true, columnID: UUID())
        let approval = try XCTUnwrap(RequestCardViewTests.approval("npm test"))
        let dialog = AgentDialog(questions: [
            AgentDialog.Question(text: "Which one?", options: []), AgentDialog.Question(text: "And then?", options: []),
        ])
        let permission = AgentAttentionReason.permission(tool: "Bash", summary: "npm test")
        func kind(_ mission: SidebarMissionQuestion? = nil, _ approval: SidebarPermissionApproval? = nil,
                  _ question: SidebarTurnQuestion? = nil, _ dialog: AgentDialog? = nil,
                  reason: AgentAttentionReason = permission) -> WaitingRequest.Kind {
            NiruxShellView.requestKind(mission: mission, approval: approval, turnQuestion: question, dialog: dialog, reason: reason)
        }
        let asked = mission("q1", askedAt: 3)
        XCTAssertEqual(kind(asked, approval, question, dialog), .mission(asked))
        XCTAssertEqual(kind(nil, approval, question, dialog), .permission(approval))
        XCTAssertEqual(kind(nil, nil, question, dialog), .question(question))
        XCTAssertEqual(kind(nil, nil, nil, dialog), .dialog(question: "Which one?", more: 1))
        XCTAssertEqual(kind(), .terminal("Bash: npm test"), "approvals off: the terminal answers")
        XCTAssertEqual(kind(reason: AgentTrustPrompt.reason), .terminal("Trust this folder?"))
        XCTAssertEqual(kind(reason: .permission(tool: nil, summary: nil)), .terminal("A permission"))
    }

    /// ⌘J's queue holds the Mission questions handed to the user, at their
    /// time, beside the blocked agents; a column blocked otherwise counts
    /// once. Their requests say so, amber with a question.
    func testTheQueueHoldsHandedOffMissionQuestions() throws {
        let shell = NiruxShellView(frame: NSRect(x: 0, y: 0, width: 1200, height: 600))
        shell.stopHeartbeat()
        let workspace = try XCTUnwrap(shell.activeWorkspace)
        let column = try XCTUnwrap(workspace.columns.first)
        shell.addWorkspace(title: "blocked", cwd: NSTemporaryDirectory())
        let blocked = try XCTUnwrap(shell.workspaces.last?.columns.first)
        shell.quickSwitch.agentWait = { candidate, _, _, _ in
            candidate === blocked ? AgentWait(reason: .permission(tool: "Bash", summary: "rm"), since: 50) : nil
        }
        let asked = mission("q1", askedAt: 20)
        shell.requestsState.handedOff = [column.id: RequestsState.HandedOff(workspaceID: workspace.id, question: asked)]
        let queue = shell.waitingQueue(snapshot: ProcessSnapshot(entries: []), now: 100)
        XCTAssertEqual(queue.map(\.columnID), [column.id, blocked.id], "the oldest first")
        XCTAssertEqual(queue.first?.wait.since, 20)
        // Seen on screen, it stands after the waits not seen yet.
        shell.requestsState.seenHandedOff = ["q1"]
        XCTAssertEqual(shell.waitingQueue(snapshot: ProcessSnapshot(entries: []), now: 100).map(\.columnID), [blocked.id, column.id])
        shell.requestsState.seenHandedOff = []

        let requests = shell.waitingRequests(NiruxShellView.requestedAgents(in: queue, onScreen: nil), approvalHolds: [:], foregroundProcesses: [:])
        XCTAssertEqual(requests.map(\.kind), [.mission(asked), .terminal("Bash: rm")])
        XCTAssertEqual(requests.first?.taskID, workspace.id)
        XCTAssertEqual(requests.first?.icon, StateIcon(.needsYou(.question)))
        XCTAssertEqual(requests.last?.icon, StateIcon(.needsYou(.command)))
        XCTAssertEqual(requests.last?.taskTitle, "blocked")

        // Its agent waits on a permission meanwhile: that is what it asks.
        shell.quickSwitch.agentWait = { candidate, _, _, _ in
            candidate === column ? AgentWait(reason: .permission(tool: "Bash", summary: "ls"), since: 80) : nil
        }
        let permission = shell.waitingQueue(snapshot: ProcessSnapshot(entries: []), now: 100)
        XCTAssertEqual(permission.map(\.columnID), [column.id], "once")
        XCTAssertEqual(
            shell.waitingRequests(permission, approvalHolds: [:], foregroundProcesses: [:]).map(\.kind), [.terminal("Bash: ls")],
            "the permission, not the question behind it"
        )
        // Its agent stopped on an error: its question for the user stays.
        shell.quickSwitch.agentWait = { candidate, _, _, _ in
            candidate === column ? AgentWait(reason: .exitedMidTurn, since: 80) : nil
        }
        let stopped = NiruxShellView.requestedAgents(in: shell.waitingQueue(snapshot: ProcessSnapshot(entries: []), now: 100), onScreen: nil)
        XCTAssertEqual(shell.waitingRequests(stopped, approvalHolds: [:], foregroundProcesses: [:]).map(\.kind), [.mission(asked)])

        // Another space's request names its space (every Lead is "Lead").
        let work = shell.workspaceStore.createProfile(named: "Work", select: false)
        let blockedWorkspace = try XCTUnwrap(shell.workspaces.last)
        let home = shell.activeProfileID
        shell.moveWorkspaceToSpace(workspaceID: blockedWorkspace.id, profileID: work.id)
        shell.selectProfile(home)
        // (The moves refreshed the sidebar, which read no Mission: only the
        // blocked agent waits now.)
        shell.quickSwitch.agentWait = { candidate, _, _, _ in
            candidate === blocked ? AgentWait(reason: .permission(tool: "Bash", summary: "rm"), since: 50) : nil
        }
        let elsewhere = shell.waitingRequests(
            NiruxShellView.requestedAgents(in: shell.waitingQueue(snapshot: ProcessSnapshot(entries: []), now: 100), onScreen: nil),
            approvalHolds: [:], foregroundProcesses: [:]
        )
        XCTAssertEqual(elsewhere.last?.taskTitle, "blocked · Work")
    }

    /// A panel closes when Nirux stops being the active app, as a click
    /// elsewhere closes it: the keyboard isn't given back.
    func testAPanelClosesWhenNiruxIsLeft() {
        let parent = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: .titled, backing: .buffered, defer: true)
        parent.isReleasedWhenClosed = false
        defer { parent.close() }
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        let panel = RequestPanel(content: content)
        var closings: [RequestPanel.Closing] = []
        panel.onClose = { closing, _ in closings.append(closing) }
        panel.show(frame: NSRect(x: 10, y: 10, width: 100, height: 100), over: parent, responder: content)
        XCTAssertTrue(panel.isOpen)
        XCTAssertTrue(panel.panel.parent === parent, "over its window")
        NotificationCenter.default.post(name: NSApplication.didResignActiveNotification, object: NSApp)
        XCTAssertFalse(panel.isOpen)
        XCTAssertEqual(closings, [.byClickElsewhere])
        XCTAssertNil(panel.panel.parent)
        panel.close()
        XCTAssertEqual(closings.count, 1, "once")

        // ⌘W while it has the keyboard closes it, not the window behind.
        panel.show(frame: NSRect(x: 10, y: 10, width: 100, height: 100), over: parent, responder: content)
        panel.panel.performClose(nil)
        XCTAssertFalse(panel.isOpen)
        XCTAssertEqual(closings, [.byClickElsewhere, .byHost])
        XCTAssertEqual(panel.panel.appearance, Theme.appearance)
    }

    /// The callout sits right of its icon, centred on it, inside the window
    /// and the screen.
    func testTheCalloutSitsBesideItsIcon() {
        let window = NSRect(x: 0, y: 0, width: 1200, height: 800)
        let size = NSSize(width: RequestCalloutView.width, height: 200)
        let middle = NiruxShellView.calloutFrame(beside: NSRect(x: 7, y: 400, width: 38, height: 28), size: size, in: window, screen: nil)
        XCTAssertEqual(middle, NSRect(x: 45 + Theme.Space.sm, y: 314, width: size.width, height: 200))
        let low = NiruxShellView.calloutFrame(beside: NSRect(x: 7, y: 10, width: 38, height: 28), size: size, in: window, screen: nil)
        XCTAssertEqual(low.minY, Theme.Space.sm, "kept in the window")
        let screen = NSRect(x: 0, y: 100, width: 1200, height: 700)
        XCTAssertEqual(NiruxShellView.calloutFrame(beside: NSRect(x: 7, y: 10, width: 38, height: 28), size: size, in: window, screen: screen).minY,
                       100 + Theme.Space.sm, "and on the screen")
    }

    /// The inbox hangs under the bar as ⌘P does, at its own size.
    func testTheInboxHangsUnderTheBar() {
        let place = CommandPalette.place(
            underBar: NSRect(x: 400, y: 760, width: 400, height: 36), in: NSRect(x: 0, y: 0, width: 1200, height: 800),
            screen: nil, size: NSSize(width: RequestInboxView.width, height: 300)
        )
        XCTAssertEqual(place.frame, NSRect(x: 600 - RequestInboxView.width / 2, y: 760 - CommandPalette.barGap - 300, width: RequestInboxView.width, height: 300))
    }

    /// Allow / Deny are offered, so a request may be held: on a card while
    /// the sidebar shows the cards, in the inbox and the callout while it
    /// is folded; never for the column on screen or under VoiceOver.
    func testWhereTheButtonsAreOffered() {
        // A background subagent's request waits for the buttons drawn now:
        // folded, only while the inbox or the callout is open.
        XCTAssertTrue(NiruxShellView.showsApprovalButtonsNow(sidebarShowsCards: true, requestPanelOpen: false))
        XCTAssertTrue(NiruxShellView.showsApprovalButtonsNow(sidebarShowsCards: false, requestPanelOpen: true))
        XCTAssertFalse(NiruxShellView.showsApprovalButtonsNow(sidebarShowsCards: false, requestPanelOpen: false), "behind the count")
        func offers(cards: Bool, onScreen: Bool = false, buttons: Bool = true, voiceOver: Bool = false) -> Bool {
            NiruxShellView.offersApprovalButtons(sidebarShowsCards: cards, isOnScreen: onScreen, cardHasButtons: buttons, voiceOver: voiceOver)
        }
        XCTAssertTrue(offers(cards: true))
        XCTAssertFalse(offers(cards: true, buttons: false), "another space, the folded archived list")
        XCTAssertTrue(offers(cards: false, buttons: false), "folded: the inbox lists every space")
        XCTAssertFalse(offers(cards: false, onScreen: true), "its terminal answers")
        XCTAssertFalse(offers(cards: true, onScreen: true))
        XCTAssertFalse(offers(cards: false, voiceOver: true))
        XCTAssertFalse(offers(cards: true, voiceOver: true))
    }

    /// A request held for the inbox goes back to its terminal: when its
    /// column comes on screen, and when the sidebar unfolds and its card
    /// can't offer it (another space). While folded it stays held, in any
    /// space.
    func testAHeldRequestGoesBackToItsTerminal() throws {
        let shell = NiruxShellView(frame: NSRect(x: 0, y: 0, width: 1200, height: 600))
        shell.stopHeartbeat()
        let home = shell.activeProfileID
        let here = try XCTUnwrap(shell.activeWorkspace)
        shell.addWorkspace(title: "there", cwd: NSTemporaryDirectory())
        let there = try XCTUnwrap(shell.activeWorkspace)
        let pty = try XCTUnwrap(there.columns.first?.pty)
        shell.focusWorkspace(id: here.id)
        let now = Date().timeIntervalSince1970
        func hold(_ id: String) {
            func event(_ name: AgentHookEvent.Name, at offset: TimeInterval, requestID: String? = nil) -> AgentHookEvent {
                AgentHookEvent(
                    kind: .claude, name: name, sessionID: "s", detail: "Bash", toolName: "Bash", toolSummary: "npm test",
                    toolKey: "k", agentID: nil, approvalRequestID: requestID, approvalDeadline: requestID.map { _ in now + 56 },
                    approvalText: requestID.map { _ in "npm test" }, approvalOutcome: nil, timestamp: now + offset
                )
            }
            _ = pty.applyAgentHook(event(.sessionStart, at: -3), isUserFocused: false)
            _ = pty.applyAgentHook(event(.userPromptSubmit, at: -2), isUserFocused: false)
            _ = pty.applyAgentHook(event(.permissionRequest, at: -1, requestID: id), isUserFocused: false)
        }
        hold("r1")
        XCTAssertEqual(pty.sidebarApproval(now: now)?.approval?.requestID, "r1", "held")
        XCTAssertFalse(shell.sidebar.isExpanded)
        _ = shell.releaseApprovalsNotHeld()
        XCTAssertNotNil(pty.sidebarApproval(now: now), "folded, off screen: the inbox offers it")

        let work = shell.workspaceStore.createProfile(named: "Work", select: false)
        shell.moveWorkspaceToSpace(workspaceID: there.id, profileID: work.id)
        shell.selectProfile(home)
        _ = shell.releaseApprovalsNotHeld()
        XCTAssertNotNil(pty.sidebarApproval(now: now), "in another space too")

        shell.sidebar.isExpanded = true
        _ = shell.releaseApprovalsNotHeld()
        XCTAssertNil(pty.sidebarApproval(now: now), "unfolded, another space's has no card: its terminal answers")

        shell.sidebar.isExpanded = false
        hold("r2")
        _ = shell.releaseApprovalsNotHeld()
        XCTAssertEqual(pty.sidebarApproval(now: now)?.approval?.requestID, "r2")
        // Going there refreshes the sidebar, which hands it back at once.
        shell.focusWorkspace(id: there.id)
        XCTAssertNil(pty.sidebarApproval(now: now), "on screen: its terminal answers")
    }

    /// A ⌘ shortcut typed while a panel has the keyboard closes it first,
    /// so that what it moves gets the keyboard; ⌘J, which acts on the open
    /// inbox, leaves it open.
    func testAShortcutClosesThePanelButJ() throws {
        let parent = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: .titled, backing: .buffered, defer: true)
        parent.isReleasedWhenClosed = false
        defer { parent.close() }
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        let panel = RequestPanel(content: content)
        panel.keepsShortcut = { KeyChord($0.charactersIgnoringModifiers ?? "", $0.modifierFlags) == NiruxShortcuts.nextWaitingAgent.chord }
        panel.show(frame: NSRect(x: 10, y: 10, width: 100, height: 100), over: parent, responder: content)
        XCTAssertGreaterThan(panel.panel.windowNumber, 0, "on its own window: the events name it")
        func press(_ key: String) throws {
            NSApp.sendEvent(try XCTUnwrap(NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0, windowNumber: panel.panel.windowNumber,
                context: nil, characters: key, charactersIgnoringModifiers: key, isARepeat: false, keyCode: 0
            )))
        }
        try press("j")
        XCTAssertTrue(panel.isOpen, "⌘J acts on it")
        try press("2")
        XCTAssertFalse(panel.isOpen, "⌘2 moves the focus: it closes first")
    }

    private func shownPanel(over parent: NSWindow) -> (RequestPanel, NSView) {
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        let panel = RequestPanel(content: content)
        panel.show(frame: NSRect(x: 10, y: 10, width: 100, height: 100), over: parent, responder: content)
        return (panel, content)
    }

    private func parentWindow() -> NSWindow {
        let parent = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: .titled, backing: .buffered, defer: true)
        parent.isReleasedWhenClosed = false
        return parent
    }

    /// Escape and ⌘. close on their release, whatever has the keyboard in
    /// the panel (a card's button): held, their repeats stay there, never
    /// reaching the terminal that takes the keyboard back.
    func testEscapeClosesOnItsRelease() throws {
        let parent = parentWindow()
        defer { parent.close() }
        let (panel, _) = shownPanel(over: parent)
        let button = NSButton(frame: .zero)
        panel.panel.contentView?.addSubview(button)
        panel.panel.makeFirstResponder(button)
        var escapes = 0
        panel.onEscape = { escapes += 1 }
        func send(_ type: NSEvent.EventType, _ key: String, keyCode: UInt16, _ modifiers: NSEvent.ModifierFlags = [], repeat isRepeat: Bool = false) throws {
            NSApp.sendEvent(try XCTUnwrap(NSEvent.keyEvent(
                with: type, location: .zero, modifierFlags: modifiers, timestamp: 0, windowNumber: panel.panel.windowNumber,
                context: nil, characters: key, charactersIgnoringModifiers: key, isARepeat: isRepeat, keyCode: keyCode
            )))
        }
        try send(.keyDown, "\u{1b}", keyCode: 53)
        try send(.keyDown, "\u{1b}", keyCode: 53, repeat: true)
        XCTAssertEqual(escapes, 0, "held: nothing yet")
        try send(.keyUp, "\u{1b}", keyCode: 53)
        XCTAssertEqual(escapes, 1, "on its release")
        try send(.keyDown, ".", keyCode: 47, .command)
        try send(.keyUp, ".", keyCode: 47, .command)
        XCTAssertEqual(escapes, 2, "⌘. too")
        try send(.keyUp, "\u{1b}", keyCode: 53)
        XCTAssertEqual(escapes, 2, "a release without its press does nothing")
    }

    /// A click the panel let through (the badge) moves the keyboard to the
    /// window behind on its mouse-down: the panel waits for the press to
    /// end, then closes if it is still up without the keyboard (a press
    /// dragged off the badge), so no key goes to a terminal behind it.
    func testAPressDraggedOffClosesThePanelOnceItEnds() throws {
        let parent = parentWindow()
        defer { parent.close() }
        let (panel, _) = shownPanel(over: parent)
        var pressed = 1
        panel.pressedMouseButtons = { pressed }
        // The window behind took the keyboard on the press.
        panel.hasKeyboard = { _ in false }
        panel.keyWindow = { parent }
        panel.noteKeptClick()
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: panel.panel)
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        XCTAssertTrue(panel.isOpen, "the press goes on: its action may still come")
        pressed = 0
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        XCTAssertFalse(panel.isOpen, "released, no action closed it: it goes")
    }
}
