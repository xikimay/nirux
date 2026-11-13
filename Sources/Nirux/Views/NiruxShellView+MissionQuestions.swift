import AppKit

// MARK: - Mission questions: the child's card, the hand-off to the user, the reply popover

extension NiruxShellView {
    /// How long a parent may show no Claude, a Claude that took no prompt
    /// yet, or sit idle after it took the question, before the question
    /// comes to the user: a `claude` restarted, its first prompt on its way,
    /// a `reply` Nirux hasn't drained yet. In the background the stuck watch
    /// samples every 30 s, so it takes up to a minute there.
    nonisolated static let missionParentGrace: TimeInterval = 20

    /// What Nirux saw of a question's parent across refreshes.
    struct MissionParentWatch: Equatable {
        /// Since when its column can't take the question: no Claude, one
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
            guard foregroundKnown else { return settled ?? .claude }
            var state = observed
            switch observed {
            case .notClaude, .notAtPrompt, .restartedSinceTyped:
                absentSince = absentSince ?? now
                if now - (absentSince ?? now) < NiruxShellView.missionParentGrace { state = .claude }
            case .claude, .stoppedWithoutAnswer:
                absentSince = nil
            case .closed:
                break
            }
            if state == .stoppedWithoutAnswer, !skipped {
                stoppedSince = stoppedSince ?? now
                skipped = now - (stoppedSince ?? now) >= NiruxShellView.missionParentGrace
            } else if state == .claude, !skipped {
                stoppedSince = nil
            }
            if skipped, state == .claude || state == .stoppedWithoutAnswer { state = .stoppedWithoutAnswer }
            else if state == .stoppedWithoutAnswer { state = .claude }
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
        for mission in store.missions where mission.status == .active {
            guard let workspace = workspaces.first(where: { $0.id == mission.childWorkspaceID }),
                  workspace.carriesMissions,
                  let column = workspace.columns.first(where: { $0.agentUUID == mission.childAgentUUID }),
                  result[ObjectIdentifier(column)] == nil
            else { continue }
            let parentWorkspace = workspaces.first { $0.id == mission.parentWorkspaceID }
            let parentTitle = parentWorkspace?.title ?? "the parent agent"
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
            let parent = parentWorkspace?.columns.first { $0.agentUUID == mission.parentAgentUUID }
            var parentState: SidebarMissionQuestion.Parent
            var foregroundKnown = true
            if let parent {
                if let pty = parent.pty, !pty.hasExited {
                    let process = foreground(parent)
                    foregroundKnown = process != nil
                    parentState = Self.missionParent(
                        foreground: process, typedAt: question.parentTypedAt,
                        finishedTurnAfterTyping: pty.finishedTurn(afterTypingAt:), tookPrompt: pty.agentTookPrompt(since:)
                    )
                } else {
                    parentState = .notClaude
                }
            } else {
                parentState = .closed
            }
            var watch = missionParentWatch[question.id] ?? MissionParentWatch()
            parentState = watch.settle(parentState, foregroundKnown: foregroundKnown, now: now)
            let handOff = watch.hold(
                question.handedToUserBecause.map { .lead(why: $0) } ?? SidebarMissionQuestion.handOff(
                    parent: parentState, askedAt: question.timestamp,
                    threshold: stuckAgentWaitThreshold ?? MissionEventCLI.parentMessageLifetime, now: now
                ),
                typedAt: question.parentTypedAt
            )
            missionParentWatch[question.id] = watch
            result[ObjectIdentifier(column)] = SidebarMissionQuestion(
                questionID: question.id, parentTitle: parentTitle, text: question.message, handOff: handOff
            )
        }
        return result
    }

    /// What a parent whose terminal runs can do with a question, from its
    /// foreground process (nil: a process-table miss, which `settle` reads
    /// as nothing new) and when Nirux typed the question into it, if it
    /// did. Typed already, it went to a `claude` that could take it: one
    /// started since never gets it (a question is typed once). Not typed
    /// yet, a `claude` that took no prompt since it started can't take it:
    /// Nirux types nothing into one before that. `tookPrompt` is nil while
    /// its hooks never reported: nothing tells, and it may take it.
    static func missionParent(
        foreground: ForegroundProcess?, typedAt: TimeInterval?,
        finishedTurnAfterTyping: (TimeInterval) -> Bool, tookPrompt: (ForegroundProcess) -> Bool?
    ) -> SidebarMissionQuestion.Parent {
        guard let foreground else { return .claude }
        guard foreground.name == "claude", !AgentHookCenter.isHeadlessClaude(foreground) else { return .notClaude }
        if let typedAt {
            if foreground.instance.startedAt > typedAt { return .restartedSinceTyped }
            return finishedTurnAfterTyping(typedAt) ? .stoppedWithoutAnswer : .claude
        }
        return tookPrompt(foreground) == false ? .notAtPrompt : .claude
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
                sideEffects.notifyMissionQuestion(workspace.id, workspace.title, columnIndex, question.text)
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
        showToast("That question was answered")
    }

    /// The card's question row was clicked: the whole question and a reply
    /// field, anchored to the row.
    func showMissionReplyPopover(workspaceIndex: Int, columnIndex: Int, anchor: NSView) {
        let snapshot = ProcessSnapshot()
        guard let workspace = workspaces[safe: workspaceIndex],
              let column = workspace.columns[safe: columnIndex],
              let question = missionQuestions(
                  foreground: { $0.pty?.foregroundProcess(snapshot: snapshot) },
                  now: Date().timeIntervalSince1970
              )[ObjectIdentifier(column)], !question.isAnswered
        else { return showToast("That question was already answered") }
        closeMissionReply()
        let controller = MissionReplyViewController(
            childTitle: workspace.title, question: question,
            onSend: { [weak self] text in
                self?.answerMissionQuestion(question.questionID, text: text) ?? false
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
        let host = anchor.superview ?? anchor
        popover.show(relativeTo: host === anchor ? anchor.bounds : anchor.frame, of: host, preferredEdge: .maxX)
        missionReplyPopover = popover
        missionReplyQuestionID = question.questionID
        controller.focusReplyField()
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
        guard reply.count <= MissionEventCLI.maxMessageLength else {
            showToast("Answers are limited to \(MissionEventCLI.maxMessageLength) characters")
            return false
        }
        let store = MissionStore.shared
        let enabled = Self.currentMissionHandoffsEnabled()
        // A Lead's task is answered whatever the setting.
        guard enabled || store.missions.contains(where: { mission in
            mission.reportsToLead == true && mission.events.contains { $0.id == questionID }
        }) else {
            showToast("Mission handoffs are off in Settings")
            return false
        }
        guard let accepted = store.respond(to: questionID, message: reply, enabled: enabled) else {
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
        // The Lead that handed it over hears the answer too.
        if let question = accepted.mission.events.first(where: { $0.id == questionID }), question.handedToUserBecause != nil {
            let childTitle = workspaces.first { $0.id == accepted.mission.childWorkspaceID }?.title ?? accepted.mission.branch
            pendingLeadNotices.append(LeadNotice(
                workspaceID: accepted.mission.parentWorkspaceID, agentUUID: accepted.mission.parentAgentUUID,
                text: "\(MissionPromptText.prefix) The user answered “\(childTitle)”: \(reply)",
                queuedAt: Date().timeIntervalSince1970
            ))
        }
        // Before the sidebar refresh, which would read it as answered by
        // someone else.
        closeMissionReply()
        if handleMissionEvent(accepted.mission, event: accepted.event) {
            store.markDelivered(eventID: accepted.event.id)
        }
        typeLeadNotices()
        return true
    }

    private func closeMissionReply() {
        missionReplyPopover?.close()
        missionReplyPopover = nil
        missionReplyQuestionID = nil
    }
}
