import AppKit

// MARK: - The inbox, the callout, and ⌘J with them (step 3.3)

extension NiruxShellView {
    // MARK: Inbox

    /// ⌘J or the bar's badge, the sidebar folded: the inbox under the
    /// command bar, every request, the first chosen.
    func openInbox() {
        guard let window else { return }
        closeCallout(.toTask)
        let inbox = requestsState.inbox ?? makeInbox()
        inbox.show(requestsState.requests)
        requestsState.inboxPanel?.show(frame: inboxFrame(for: inbox, in: window), over: window, responder: inbox)
        inbox.opened()
        // Chosen where ⌘J's walk goes next (`WaitingAgentQueue.next`, ⌘J's
        // own rule): each request once a round, not the first two in turn.
        let current = activeWorkspace.flatMap { $0.columns[safe: $0.focusedIndex] }?.id
        requestsState.inboxWalk = quickSwitch.walk(from: current)
        requestsState.inboxPlan = nil
        let agents = requestsState.requests.map {
            WaitingAgent(workspaceID: $0.taskID, columnID: $0.columnID, wait: AgentWait(reason: .question(nil), since: 0))
        }
        if let (next, walked) = WaitingAgentQueue.next(from: current, walk: requestsState.inboxWalk, in: agents),
           let request = requestsState.requests.first(where: { $0.columnID == next.columnID }) {
            inbox.choose(request.id)
            requestsState.inboxPlan = (next.columnID, walked)
        }
    }

    func closeInbox(_ closing: RequestPanel.Closing = .byHost) {
        requestsState.inboxPanel?.close(closing)
    }

    private func makeInbox() -> RequestInboxView {
        let inbox = RequestInboxView(level: interfaceTransparency)
        inbox.resolveLevel = sideEffects.drawnTransparency
        inbox.onAnswer = { [weak self] request, choice, button in self?.answerRequest(request, choice, button: button) }
        inbox.onOpenTask = { [weak self] request in self?.goToRequest(request) }
        inbox.onClose = { [weak self] in self?.closeInbox() }
        let panel = RequestPanel(content: inbox)
        panel.onEscape = { [weak self] in self?.closeInbox() }
        panel.ownsWindow = { [weak self, weak panel] window in self?.isReplyPopoverWindow(window, of: panel) == true }
        panel.onClose = { [weak self, weak panel] closing, hadKeyboard in
            guard let self else { return }
            if let panel { closeReplyPopovers(of: panel) }
            if closing == .byHost, hadKeyboard { giveKeyboardBack() }
        }
        // Out of the bar's badge, back into it.
        panel.source = { [weak self] in (self?.commandBarToolbar?.bar.waitingButton).flatMap(Self.screenRect) }
        panel.animates = { [weak self] in self?.agentLightsMayMove == true }
        // The badge acts on the open inbox (⌘J again).
        panel.keepsOpen = { [weak self] event in self?.isOnWaitingSegment(event) == true }
        panel.closesOnClicks = { [weak self] window in window === self?.commandBarToolbar?.bar.window }
        panel.keepsShortcut = { [weak self, weak panel] event in
            KeyChord(event.charactersIgnoringModifiers ?? "", event.modifierFlags) == NiruxShortcuts.nextWaitingAgent.chord
                || self?.isReplying(panel) == true
        }
        requestsState.inbox = inbox
        requestsState.inboxPanel = panel
        return inbox
    }

    /// Under the command bar as ⌘P hangs there, as tall as its requests up
    /// to most of the window; under the window's top while no bar shows.
    func inboxFrame(for inbox: RequestInboxView, in window: NSWindow) -> NSRect {
        let size = NSSize(width: RequestInboxView.width, height: inbox.fittingHeight(maximum: window.frame.height * 0.7))
        if let bar = commandBarToolbar?.bar, let barWindow = bar.window, !bar.isHiddenOrHasHiddenAncestor {
            let barRect = barWindow.convertToScreen(bar.convert(bar.bounds, to: nil))
            let screen = (barWindow.screen ?? window.screen)?.visibleFrame
            return CommandPalette.place(underBar: barRect, in: window.frame, screen: screen, size: size).frame
        }
        // No bar: hung from the window's top, inside the window and then
        // the screen, as under the bar.
        let top = NSRect(x: window.frame.midX - 1, y: window.frame.maxY - CommandBarView.height, width: 2, height: 0)
        return CommandPalette.place(underBar: top, in: window.frame, screen: window.screen?.visibleFrame, size: size).frame
    }

    /// Where `view` shows, in screen coordinates; nil while it doesn't.
    static func screenRect(of view: NSView) -> NSRect? {
        guard let window = view.window, !view.isHiddenOrHasHiddenAncestor else { return nil }
        return window.convertToScreen(view.convert(view.bounds, to: nil))
    }

    private func isOnWaitingSegment(_ event: NSEvent) -> Bool {
        guard let button = commandBarToolbar?.bar.waitingButton, event.window === button.window else { return false }
        return button.bounds.contains(button.convert(event.locationInWindow, from: nil))
    }

    // MARK: Callout

    /// A click on an amber rail icon: that task's request beside it. False
    /// when the task has none to show (its waiting column is on screen):
    /// the click then goes to the task.
    func openCallout(taskID: String, anchor: NSView) -> Bool {
        // Its own icon again: it closes.
        if requestsState.isCalloutOpen, requestsState.calloutTaskID == taskID {
            closeCallout()
            return true
        }
        guard let window, let request = requestsState.requests.first(where: { $0.taskID == taskID }) else { return false }
        closeInbox(.toTask)
        let callout = requestsState.callout ?? makeCallout()
        callout.show(request, othersWaiting: requestsState.requests.count - 1)
        requestsState.calloutTaskID = taskID
        requestsState.calloutRequestID = request.id
        requestsState.inboxWalk = quickSwitch.walk(from: activeWorkspace.flatMap { $0.columns[safe: $0.focusedIndex] }?.id)
        requestsState.inboxPlan = nil
        requestsState.calloutAnchor = anchor
        followCalloutAnchor(anchor)
        requestsState.calloutPanel?.show(frame: calloutFrame(for: callout, anchor: anchor, in: window), over: window, responder: callout)
        callout.opened()
        return true
    }

    func closeCallout(_ closing: RequestPanel.Closing = .byHost) {
        requestsState.calloutPanel?.close(closing)
    }

    private func makeCallout() -> RequestCalloutView {
        let callout = RequestCalloutView(level: interfaceTransparency)
        callout.resolveLevel = sideEffects.drawnTransparency
        callout.onAnswer = { [weak self] request, choice, button in self?.answerRequest(request, choice, button: button) }
        callout.onOpenTask = { [weak self] request in self?.goToRequest(request) }
        callout.onClose = { [weak self] in self?.closeCallout() }
        let panel = RequestPanel(content: callout)
        panel.onEscape = { [weak self] in self?.closeCallout() }
        panel.ownsWindow = { [weak self, weak panel] window in self?.isReplyPopoverWindow(window, of: panel) == true }
        panel.keepsShortcut = { [weak self, weak panel] _ in self?.isReplying(panel) == true }
        panel.onClose = { [weak self, weak panel] closing, hadKeyboard in
            guard let self else { return }
            if let panel { closeReplyPopovers(of: panel) }
            if let observer = requestsState.calloutScrollObserver { NotificationCenter.default.removeObserver(observer) }
            requestsState.calloutScrollObserver = nil
            requestsState.calloutTaskID = nil
            if closing == .byHost, hadKeyboard { giveKeyboardBack() }
        }
        // Out of its rail icon, back into it.
        panel.source = { [weak self] in self?.requestsState.calloutAnchor.flatMap(Self.screenRect) }
        panel.animates = { [weak self] in self?.agentLightsMayMove == true }
        // A click on its own icon closes it there (`openCallout`), not here
        // and then open again.
        panel.keepsOpen = { [weak self] event in
            guard let anchor = self?.requestsState.calloutAnchor, event.window === anchor.window else { return false }
            return anchor.bounds.contains(anchor.convert(event.locationInWindow, from: nil))
        }
        requestsState.callout = callout
        requestsState.calloutPanel = panel
        return callout
    }

    /// The rail scrolls under the callout: it follows its icon.
    private func followCalloutAnchor(_ anchor: NSView) {
        if let observer = requestsState.calloutScrollObserver { NotificationCenter.default.removeObserver(observer) }
        requestsState.calloutScrollObserver = nil
        guard let clip = anchor.enclosingScrollView?.contentView else { return }
        clip.postsBoundsChangedNotifications = true
        requestsState.calloutScrollObserver = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification, object: clip, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshRequestPanels() }
        }
    }

    func calloutFrame(for callout: RequestCalloutView, anchor: NSView, in window: NSWindow) -> NSRect {
        let icon = anchor.window?.convertToScreen(anchor.convert(anchor.bounds, to: nil)) ?? .zero
        // Capped as the inbox is: the card scrolls past it.
        let height = min(callout.fittingHeight, window.frame.height * 0.7)
        return Self.calloutFrame(
            beside: icon, size: NSSize(width: RequestCalloutView.width, height: height),
            in: window.frame, screen: window.screen?.visibleFrame
        )
    }

    /// Right of the icon (screen coordinates), centred on it, inside the
    /// window and then the screen.
    static func calloutFrame(beside icon: NSRect, size: NSSize, in windowFrame: NSRect, screen: NSRect?) -> NSRect {
        let margin = Theme.Space.sm
        var y = icon.midY - size.height / 2
        y = max(min(y, windowFrame.maxY - margin - size.height), windowFrame.minY + margin)
        if let screen { y = max(min(y, screen.maxY - margin - size.height), screen.minY + margin) }
        return NSRect(x: icon.maxX + margin, y: y, width: size.width, height: size.height)
    }

    // MARK: Refresh, answers, the way to a task

    /// At each sidebar refresh: the inbox shows the requests as they are
    /// (it closes once none is left), the callout its task's request (it
    /// closes once that request is gone, answered or come on screen, or
    /// its icon went), each where it belongs now.
    func refreshRequestPanels() {
        // Unfolded, the requests stay in the rows.
        if sidebar.isExpanded {
            closeInbox()
            closeCallout()
            return
        }
        let requests = requestsState.requests
        // A reply being typed in a popover a card opened: its panel stays as
        // it is (the popover deals with a question gone stale).
        if requestsState.isInboxOpen, !isReplying(requestsState.inboxPanel), let inbox = requestsState.inbox, let window {
            if requests.isEmpty {
                closeInbox()
            } else if requests != inbox.requests || window.frame != requestsState.inboxPlacedFor {
                inbox.show(requests)
                requestsState.inboxPanel?.setFrame(inboxFrame(for: inbox, in: window))
                requestsState.inboxPlacedFor = window.frame
            }
        }
        if requestsState.isCalloutOpen, !isReplying(requestsState.calloutPanel), let callout = requestsState.callout, let window {
            // Its request, not its task's next one: answered, it closes.
            if let taskID = requestsState.calloutTaskID, let request = requests.first(where: { $0.id == requestsState.calloutRequestID }),
               let anchor = requestsState.calloutAnchor, anchor.window === window, !anchor.isHiddenOrHasHiddenAncestor,
               // Scrolled out of the rail's view: nothing left to sit by.
               sidebar.iconRail.iconFrame(of: taskID) != nil {
                if request != callout.request || requests.count - 1 != callout.othersWaiting {
                    callout.show(request, othersWaiting: requests.count - 1)
                }
                requestsState.calloutPanel?.setFrame(calloutFrame(for: callout, anchor: anchor, in: window))
            } else {
                closeCallout()
            }
        }
    }

    /// A card's answer, to the receiver the rows use, with its column.
    func answerRequest(_ request: WaitingRequest, _ choice: RequestChoice, button: NSView) {
        guard let (workspaceIndex, columnIndex) = indexOfColumn(request.columnID) else { return }
        switch (request.kind, choice) {
        case let (.permission(approval), .permission(behavior)):
            decidePermission(workspaceIndex: workspaceIndex, columnIndex: columnIndex, requestID: approval.requestID, behavior: behavior)
        case let (.question(question), .turn(answer)):
            requestsState.replyFrom = panel(holding: button)
            answerFromCard(answer, to: question, button: button)
        case let (.mission(question), .missionReply):
            requestsState.replyFrom = panel(holding: button)
            showMissionReplyPopover(workspaceIndex: workspaceIndex, columnIndex: columnIndex, anchor: button, questionID: question.questionID)
        default:
            break
        }
    }

    /// "Open task", ⌘J over the inbox: the column that asks, the panels
    /// closed.
    func goToRequest(_ request: WaitingRequest) {
        closeInbox(.toTask)
        closeCallout(.toTask)
        guard let place = liveColumn(where: { $0.id == request.columnID }) else { return giveKeyboardBack() }
        // The panel had the keyboard: the window takes it back first.
        window?.makeKey()
        focusWorkspace(id: place.workspace.id, column: place.columnIndex)
        // ⌘J's walk goes on from there: as `WaitingAgentQueue.next` planned
        // it, or with the request picked instead.
        if let plan = requestsState.inboxPlan, plan.column == request.columnID {
            quickSwitch.noteWalk(plan.walk)
        } else {
            quickSwitch.noteWalk(requestsState.inboxWalk + [request.columnID])
        }
    }

    /// The column with `id`, open and not closing, by its indexes.
    private func indexOfColumn(_ id: UUID) -> (Int, Int)? {
        guard let place = liveColumn(where: { $0.id == id }),
              let workspaceIndex = workspaces.firstIndex(where: { $0 === place.workspace }) else { return nil }
        return (workspaceIndex, place.columnIndex)
    }

    /// The panel whose window holds `view`: the card an answer came from.
    private func panel(holding view: NSView) -> RequestPanel? {
        [requestsState.inboxPanel, requestsState.calloutPanel].compactMap { $0 }.first { view.window === $0.panel }
    }

    /// A reply popover a card of `panel` opened is up: its keys, and the
    /// panel as it is.
    func isReplying(_ panel: RequestPanel?) -> Bool {
        guard let panel, requestsState.replyFrom === panel else { return false }
        return missionReplyPopover?.isShown == true || turnReplyPopover?.isShown == true
    }

    /// The window of a reply popover a card of `panel` opened.
    private func isReplyPopoverWindow(_ window: NSWindow, of panel: RequestPanel?) -> Bool {
        guard isReplying(panel) else { return false }
        return [missionReplyPopover, turnReplyPopover].contains { $0?.contentViewController?.view.window === window }
    }

    /// A reply popover a card of `panel` opened goes with it.
    private func closeReplyPopovers(of panel: RequestPanel) {
        guard requestsState.replyFrom === panel else { return }
        requestsState.replyFrom = nil
        closeMissionReply()
        closeTurnReply()
    }

    /// The panel that had the keyboard closed: the terminal on screen takes
    /// it back.
    func giveKeyboardBack() {
        guard let window else { return }
        window.makeKey()
        focusActiveTerminal(in: window)
    }
}
