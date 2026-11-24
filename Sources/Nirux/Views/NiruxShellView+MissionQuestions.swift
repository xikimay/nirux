import AppKit

// MARK: - Mission questions: the child's card, the hand-off to the user, the reply popover

extension NiruxShellView {
    /// How long a parent may be absent, have taken no prompt
    /// yet, or sit idle after it took the question, before the question
    /// comes to the user: an agent restarted, its first prompt on its way,
    /// a `reply` Nirux hasn't drained yet. In the background the stuck watch
    /// samples every 30 s, so it takes up to a minute there.
    nonisolated static let missionParentGrace: TimeInterval = 20

    /// What Nirux saw of a question's parent across refreshes.
    struct MissionParentWatch: Equatable {
        /// Since when its column can't take the question: no agent, one
        /// that took no prompt, or one restarted since it took it.
        var absentSince: TimeInterval?
        /// Since when it sits idle after it took the question.
        var stoppedSince: TimeInterval?
        /// It took the question and stopped without `reply`: the question
        /// stays with the user, whatever the parent does next.
        var skipped = false
        /// What the last refresh that knew the parent's foreground settled.
        var settled: SidebarMissionQuestion.Parent?
        /// The hand-off shown last, and when the question was typed into the
        /// parent by then (nil: not yet).
        var handOff: SidebarMissionQuestion.HandOff?
        var handOffTypedAt: TimeInterval?

        /// The parent state the hand-off goes by, from what a refresh
        /// observed: a parent that can't take the question (whatever the
        /// reason, one wait for all), or one idle after taking it, counts
        /// only past the grace; once it stopped without answering, it stays
        /// so. `foregroundKnown` false (a process-table miss) proves
        /// nothing: what the last refresh found stands.
        mutating func settle(
            _ observed: SidebarMissionQuestion.Parent, foregroundKnown: Bool, now: TimeInterval
        ) -> SidebarMissionQuestion.Parent {
            guard foregroundKnown else { return settled ?? .available }
            var state = observed
            switch observed {
            case .unavailable, .notAtPrompt, .restartedSinceTyped:
                absentSince = absentSince ?? now
                if now - (absentSince ?? now) < NiruxShellView.missionParentGrace { state = .available }
            case .available, .stoppedWithoutAnswer:
                absentSince = nil
            case .closed:
                break
            }
            if state == .stoppedWithoutAnswer, !skipped {
                stoppedSince = stoppedSince ?? now
                skipped = now - (stoppedSince ?? now) >= NiruxShellView.missionParentGrace
            } else if state == .available, !skipped {
                stoppedSince = nil
            }
            if skipped, state == .available || state == .stoppedWithoutAnswer { state = .stoppedWithoutAnswer }
            else if state == .stoppedWithoutAnswer { state = .available }
            settled = state
            return state
        }

        /// Once a question came to the user, it stays with them until
        /// someone answers it (it no longer waits, and its watch goes) or
        /// Nirux types it into the parent's prompt: a parent that takes a
        /// prompt, or wobbles back for a refresh, hasn't got it. A new
        /// reason only changes the words, so the hand-off alerts once.
        mutating func hold(
            _ handOff: SidebarMissionQuestion.HandOff?, typedAt: TimeInterval?
        ) -> SidebarMissionQuestion.HandOff? {
            if handOff == nil, self.handOff != nil, typedAt == handOffTypedAt { return self.handOff }
            (self.handOff, handOffTypedAt) = (handOff, typedAt)
            return handOff
        }
    }

    /// The question each Mission child column waits on, keyed by the
    /// column, with why it now waits on the user if it does: its parent
    /// was closed, can't take it (`missionParent`), or nobody answered
    /// within the stuck-agent threshold (an hour with the check off); once
    /// handed over, until answered or typed (`MissionParentWatch.hold`). Else the answer
    /// still waiting to be typed into the child's prompt. `foreground` gives
    /// a column's foreground process.
    func missionQuestions(
        foreground: (ColumnState) -> ForegroundProcess?, now: TimeInterval
    ) -> [ObjectIdentifier: SidebarMissionQuestion] {
        var result: [ObjectIdentifier: SidebarMissionQuestion] = [:]
        var waiting = Set<String>()
        defer { missionParentWatch = missionParentWatch.filter { waiting.contains($0.key) } }
        let store = MissionStore.shared
        // A Lead's one-way Mission names the Lead, whom the child doesn't ask.
        for mission in store.missions where mission.status == .active && mission.oneWay != true {
            guard let (workspace, childColumn) = missionEnd(mission, parent: false), workspace.carriesMissions,
                  let column = childColumn, result[ObjectIdentifier(column)] == nil
            else { continue }
            let parentEnd = missionEnd(mission, parent: true)
            let parentTitle = parentEnd?.workspace.title ?? "the parent agent"
            guard let question = store.waitingQuestion(
                childWorkspaceID: mission.childWorkspaceID, childAgentUUID: mission.childAgentUUID
            )?.event else {
                if let answer = store.pendingAnswer(
                    childWorkspaceID: mission.childWorkspaceID, childAgentUUID: mission.childAgentUUID
                )?.event {
                    result[ObjectIdentifier(column)] = SidebarMissionQuestion(
                        questionID: answer.inReplyTo ?? answer.id,
                        parentTitle: answer.answeredByUser == true ? "you" : parentTitle,
                        text: answer.message, handOff: nil, isAnswered: true
                    )
                }
                continue
            }
            waiting.insert(question.id)
            let parent = parentEnd?.column
            var parentState: SidebarMissionQuestion.Parent
            var foregroundKnown = true
            if let parent {
                if let pty = parent.pty, !pty.hasExited {
                    let process = foreground(parent)
                    foregroundKnown = process != nil
                    var typedAt = question.parentTypedAt
                    if let process, let previous = typedAt, previous < process.instance.startedAt,
                       parentEnd?.workspace.runsRestartedLead(process) == true {
                        typedAt = nil
                    }
                    parentState = Self.missionParent(
                        foreground: process, typedAt: typedAt,
                        finishedTurnAfterTyping: { pty.finishedMissionTurn(in: $0, after: $1) },
                        tookPrompt: { process in
                            switch process.interactiveAgent {
                            case .codex:
                                guard let status = pty.codexStatus(of: process.instance) else { return false }
                                // The first turn proves its thread when Codex reports its end.
                                if [.working, .blocked].contains(status.state) { return CodexLaunch.canProve(process) }
                                return parent.provenCodexSessionID(of: process) != nil
                            case .agy: return pty.hasAgyPrompt(process)
                            default:
                                return pty.agentTookPrompt(since: process).map {
                                    $0 || pty.sitsAtFirstPrompt(process, now: now, record: sessionRecord(of:))
                                }
                            }
                        }
                    )
                } else {
                    parentState = .unavailable
                }
            } else {
                parentState = .closed
            }
            var watch = missionParentWatch[question.id] ?? MissionParentWatch()
            parentState = watch.settle(parentState, foregroundKnown: foregroundKnown, now: now)
            let handOff = watch.hold(
                question.handedToUserBecause.map { .handedOver(why: $0) } ?? SidebarMissionQuestion.handOff(
                    parent: parentState, askedAt: question.timestamp,
                    threshold: stuckAgentWaitThreshold ?? MissionEventCLI.parentMessageLifetime, now: now
                ),
                typedAt: question.parentTypedAt
            )
            missionParentWatch[question.id] = watch
            result[ObjectIdentifier(column)] = SidebarMissionQuestion(
                questionID: question.id, parentTitle: parentTitle, text: question.message, handOff: handOff,
                askedAt: question.timestamp, kind: question.questionKind, recommendation: question.recommendation
            )
        }
        return result
    }

    /// The user typed a prompt to a column's agent: the Mission questions it
    /// asked before are behind it, and stop waiting on its parent or the
    /// user.
    func retireMissionQuestions(
        of column: ColumnState, in workspace: WorkspaceState, promptedAt: TimeInterval, store: MissionStore = .shared
    ) {
        guard let agentUUID = column.agentUUID,
              store.retireQuestions(childWorkspaceID: workspace.id, childAgentUUID: agentUUID, before: promptedAt)
        else { return }
        scheduleMetadataRefresh()
    }

    /// A Mission child's turn ended on a question its parent sent the prompt
    /// for: the last prompt typed to it was Nirux's (a Mission message, a
    /// notice), or none was and the parent started it. The question goes to
    /// the parent as the child's question, which the parent answers or hands
    /// to the user, and the row says "Asking …". False, and the user is
    /// asked, when the user typed that prompt or started the task, is at its
    /// prompt, or the turn may go on (a Stop hook), or when the ledger takes
    /// no question (the Mission completed, handoffs are off).
    func askParent(
        for resolution: AgentHookCenter.Resolution, _ request: TurnEndRequest, asking question: TurnEndQuestion?,
        store: MissionStore = .shared
    ) -> Bool {
        guard let pty = resolution.column.pty, let agentUUID = resolution.column.agentUUID, store.ensureLoaded(),
              let mission = store.missions.last(where: {
                  $0.oneWay != true && $0.childWorkspaceID == resolution.workspace.id && $0.childAgentUUID == agentUUID
              })
        else { return false }
        let handoffs = Self.currentMissionHandoffsEnabled()
        guard mission.isCarried(handoffsEnabled: handoffs) else { return false }
        // Who sent the turn's prompt: its transcript line may be unread yet.
        pty.readTranscriptPrompts()
        switch pty.agentLastPromptTyper {
        case .user: return false
        case .nobody where mission.startedByParent != true: return false
        case .nobody, .nirux: break
        }
        guard pty.mayAskParent(endingTurnAt: request.turnEndedAt) else { return false }
        // It asked with `--mission ask` meanwhile: it waits on that one.
        if store.waitingQuestion(childWorkspaceID: mission.childWorkspaceID, childAgentUUID: agentUUID) != nil { return true }
        guard let message = TurnEndText.questionForParent(request.message, asking: question),
              let asked = store.accept(MissionEvent(
                  id: UUID().uuidString, missionID: mission.id, childWorkspaceID: mission.childWorkspaceID,
                  childAgentUUID: agentUUID, kind: .question, message: message, timestamp: request.turnEndedAt
              ), enabled: handoffs)
        else { return false }
        if handleMissionEvent(asked.mission, event: asked.event) { store.markDelivered(eventID: asked.event.id) }
        return true
    }

    static func missionParent(
        foreground: ForegroundProcess?, typedAt: TimeInterval?,
        finishedTurnAfterTyping: (ForegroundProcess, TimeInterval) -> Bool, tookPrompt: (ForegroundProcess) -> Bool?
    ) -> SidebarMissionQuestion.Parent {
        guard let foreground else { return .available }
        guard foreground.interactiveAgent?.isLaunchable == true else { return .unavailable }
        if let typedAt {
            if foreground.instance.startedAt > typedAt { return .restartedSinceTyped }
            return finishedTurnAfterTyping(foreground, typedAt) ? .stoppedWithoutAnswer : .available
        }
        return tookPrompt(foreground) == false ? .notAtPrompt : .available
    }

    /// A question that just came to the user lights its workspace (the
    /// ring, the Dock badge) and, with Nirux in the background, bounces the
    /// Dock icon and posts a notification: once per hand-off. A hand-off
    /// that ended (answered, retired, typed into the parent's prompt) puts
    /// that out.
    func noteMissionQuestionHandOffs(_ questions: [ObjectIdentifier: SidebarMissionQuestion]) {
        var handedOff: [String: String] = [:]
        for workspace in workspaces {
            for (columnIndex, column) in workspace.columns.enumerated() {
                guard let question = questions[ObjectIdentifier(column)], question.handOff != nil else { continue }
                handedOff[question.questionID] = workspace.id
                guard missionQuestionsHandedToUser[question.questionID] == nil else { continue }
                workspace.raiseNotification(.waiting)
                workspace.onMetadataChanged?()
                if !NSApp.isActive { NSApp.requestUserAttention(.informationalRequest) }
                let body = [question.recommendationLine, question.text].compactMap { $0 }.joined(separator: "\n")
                sideEffects.notifyMissionQuestion(workspace.id, workspace.title, columnIndex, body)
            }
        }
        for (questionID, workspaceID) in missionQuestionsHandedToUser where handedOff[questionID] == nil {
            guard let workspace = workspaces.first(where: { $0.id == workspaceID }), workspace.notification == .waiting
            else { continue }
            workspace.notification = nil
            workspace.onMetadataChanged?()
        }
        missionQuestionsHandedToUser = handedOff
        closeAnsweredMissionReply(questions)
    }

    /// Someone else answered the question the popover shows (the parent,
    /// or the child's `completed` retired it): the popover goes.
    private func closeAnsweredMissionReply(_ questions: [ObjectIdentifier: SidebarMissionQuestion]) {
        guard let shown = missionReplyQuestionID, let popover = missionReplyPopover else { return }
        guard popover.isShown else {
            missionReplyPopover = nil
            missionReplyQuestionID = nil
            return
        }
        guard !questions.values.contains(where: { $0.questionID == shown && !$0.isAnswered }) else { return }
        popover.close()
        missionReplyPopover = nil
        missionReplyQuestionID = nil
        showToast("That question was answered, or its task moved on")
    }

    /// The card's question row was clicked: the whole question and a reply
    /// field, anchored to the row. `questionID`, from the inbox or the
    /// callout: the question the card showed, which another may have
    /// replaced in the column meanwhile.
    func showMissionReplyPopover(workspaceIndex: Int, columnIndex: Int, anchor: NSView?, questionID: String? = nil) {
        let snapshot = ProcessSnapshot()
        guard let workspace = workspaces[safe: workspaceIndex],
              let column = workspace.columns[safe: columnIndex],
              let question = missionQuestions(
                  foreground: { $0.pty?.foregroundProcess(snapshot: snapshot) },
                  now: Date().timeIntervalSince1970
              )[ObjectIdentifier(column)], !question.isAnswered, questionID.map({ $0 == question.questionID }) ?? true
        else { return showToast("That question was already answered") }
        closeMissionReply()
        let controller = MissionReplyViewController(
            childTitle: workspace.title, question: question,
            onSend: { [weak self] text in
                self?.answerMissionQuestion(question.questionID, text: text) ?? false
            },
            onAccept: question.acceptableRecommendation == nil ? nil : { [weak self] in
                self?.acceptMissionRecommendation(question.questionID) ?? false
            },
            onOpenTask: { [weak self, weak workspace] in
                guard let self, let workspace else { return }
                self.closeMissionReply()
                self.focusWorkspace(id: workspace.id, column: columnIndex)
            }
        )
        let popover = NSPopover()
        popover.contentViewController = controller
        popover.behavior = .transient
        popover.appearance = Theme.appearance
        controller.popover = popover
        // The sidebar rebuilds its rows; the document view under them stays.
        // A row's button a rebuild took away (nil): the pointer, in the rows.
        if let anchor {
            guard anchor.window != nil else { return NSSound.beep() }
            let host = anchor.superview ?? anchor
            popover.show(relativeTo: host === anchor ? anchor.bounds : anchor.frame, of: host, preferredEdge: .maxX)
        } else if let pointer = sidebar.anchorAtPointer() {
            popover.show(relativeTo: pointer.rect, of: pointer.view, preferredEdge: .maxX)
        } else {
            return NSSound.beep()
        }
        missionReplyPopover = popover
        missionReplyQuestionID = question.questionID
        controller.focusReplyField()
    }

    func replyToThreadQuestion(_ id: String, in workspaceID: String, text: String) -> TaskThreadContentView.ReplyResult {
        let store = MissionStore.shared
        guard store.ensureLoaded() else {
            showToast("Couldn’t read the Mission. Try again.", tone: .error)
            return .retry
        }
        guard store.missions.contains(where: { mission in
            mission.childWorkspaceID == workspaceID && mission.status == .active
                && mission.events.contains { $0.kind == .question && $0.id == id && $0.retiredAt == nil && $0.parentConsumedAt == nil }
        }), store.response(to: id) == nil else { return .noLongerOpen }
        guard answerMissionQuestion(id, text: text) else { return .retry }
        refreshPinnedTaskThread()
        return .sent
    }

    /// The user's answer from the popover, as if the parent had sent it:
    /// Nirux types it into the child's prompt. False keeps the popover
    /// open (the toast says why).
    func answerMissionQuestion(_ questionID: String, text: String) -> Bool {
        let reply = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !reply.isEmpty else {
            showToast("Type an answer first")
            return false
        }
        guard MissionEventCLI.fits(reply, limit: MissionEventCLI.maxInstructionLength) else {
            showToast(reply.count > MissionEventCLI.maxInstructionLength
                ? "Answers are limited to \(MissionEventCLI.maxInstructionLength) characters"
                : "Answers hold at most \(MissionEventCLI.maxScalars) Unicode scalars: an emoji or an accent can take several")
            return false
        }
        return sendUserAnswer(reply, to: questionID, accepted: false)
    }

    /// Accept, in the popover or on the row: the question's recommendation
    /// goes to the child as the user's answer.
    func acceptMissionRecommendation(_ questionID: String) -> Bool {
        guard let question = MissionStore.shared.missions.lazy.flatMap(\.events)
            .first(where: { $0.id == questionID && $0.kind == .question })
        else {
            showToast("That question was already answered, or its Mission ended", tone: .error)
            return false
        }
        guard let recommendation = question.acceptableRecommendation else {
            showToast("That question has no recommendation to accept", tone: .error)
            return false
        }
        return sendUserAnswer(recommendation, to: questionID, accepted: true)
    }

    private func sendUserAnswer(_ reply: String, to questionID: String, accepted: Bool) -> Bool {
        let store = MissionStore.shared
        let enabled = Self.currentMissionHandoffsEnabled()
        // A Lead's task, or a sub-task a task's agent started with its
        // tools, is answered whatever the setting.
        guard enabled || store.missions.contains(where: { mission in
            mission.isAlwaysCarried && mission.events.contains { $0.id == questionID }
        }) else {
            showToast("Mission handoffs are off in Settings")
            return false
        }
        guard let response = store.respond(to: questionID, message: reply, acceptingRecommendation: accepted, enabled: enabled) else {
            let stillWaiting = store.response(to: questionID) == nil && store.missions.contains { mission in
                mission.status == .active && mission.events.contains { $0.id == questionID && $0.kind == .question }
            }
            if stillWaiting {
                // The ledger couldn't be saved: keep what the user wrote.
                showToast("Couldn’t save the answer. Try again.", tone: .error)
                return false
            }
            showToast("That question was already answered, or its Mission ended", tone: .error)
            closeMissionReply()
            updateSidebar()
            return false
        }
        // The parent that saw the question, a Lead or a task's agent, hears
        // the answer too: the agent that last took it into its prompt or
        // handed it over, not one started since, unless Restart Lead started
        // it. One that never saw it hears nothing.
        if let question = response.mission.events.first(where: { $0.id == questionID }),
           let seenAt = [question.parentTypedAt, question.handedToUserAt].compactMap({ $0 }).max() {
            let childTitle = workspaces.first { $0.id == response.mission.childWorkspaceID }?.title ?? response.mission.branch
            pendingLeadNotices.append(LeadNotice(
                workspaceID: response.mission.parentWorkspaceID, agentUUID: response.mission.parentAgentUUID,
                text: "\(MissionPromptText.prefix) The user answered “\(childTitle)”: \(reply)"
                    + (accepted ? " (its recommendation)" : ""),
                queuedAt: Date().timeIntervalSince1970,
                forAgentStartedBy: seenAt
            ))
        }
        // Before the sidebar refresh, which would read it as answered by
        // someone else.
        closeMissionReply()
        if handleMissionEvent(response.mission, event: response.event) {
            store.markDelivered(eventID: response.event.id)
        }
        typeLeadNotices()
        return true
    }

    func closeMissionReply() {
        missionReplyPopover?.close()
        missionReplyPopover = nil
        missionReplyQuestionID = nil
    }
}
