import AppKit

// MARK: - Mission questions: the child's card, the hand-off to the user, the reply popover

extension NiruxShellView {
    /// How long a parent may show no Claude before its child's question
    /// comes to the user: a `claude` restarted, a process table misread.
    static let missionParentGrace: TimeInterval = 20

    /// The question each Mission child column waits on, keyed by the
    /// column, with why it now waits on the user if it does: its parent
    /// was closed or doesn't run Claude Code, or nobody answered within the
    /// stuck-agent threshold (an hour with the check off). Else the answer
    /// still waiting to be typed into the child's prompt. `foreground` gives
    /// a column's foreground process.
    func missionQuestions(
        foreground: (ColumnState) -> ForegroundProcess?, now: TimeInterval
    ) -> [ObjectIdentifier: SidebarMissionQuestion] {
        var result: [ObjectIdentifier: SidebarMissionQuestion] = [:]
        var waiting = Set<String>()
        defer { missionParentAbsentSince = missionParentAbsentSince.filter { waiting.contains($0.key) } }
        let store = MissionStore.shared
        for mission in store.missions where mission.status == .active {
            guard let workspace = workspaces.first(where: { $0.id == mission.childWorkspaceID }),
                  workspace.missionHandoffsEnabled,
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
                        questionID: answer.inReplyTo ?? answer.id, parentTitle: parentTitle, text: answer.message,
                        handOff: nil, isAnswered: true
                    )
                }
                continue
            }
            waiting.insert(question.id)
            let parent = parentWorkspace?.columns.first { $0.agentUUID == mission.parentAgentUUID }
            var parentState: SidebarMissionQuestion.Parent
            if let parent {
                if let pty = parent.pty, !pty.hasExited {
                    // An unreadable foreground (a process-table miss) isn't
                    // proof the parent quit Claude: the threshold applies.
                    if foreground(parent).map({ $0.name == "claude" && !AgentHookCenter.isHeadlessClaude($0) }) == false {
                        parentState = .notClaude
                    } else if let typedAt = question.parentTypedAt, pty.finishedTurn(afterTypingAt: typedAt) {
                        parentState = .stoppedWithoutAnswer
                    } else {
                        parentState = .claude
                    }
                } else {
                    parentState = .notClaude
                }
            } else {
                parentState = .closed
            }
            if parentState == .notClaude {
                let since = missionParentAbsentSince[question.id] ?? now
                missionParentAbsentSince[question.id] = since
                if now - since < Self.missionParentGrace { parentState = .claude }
            } else {
                missionParentAbsentSince[question.id] = nil
            }
            result[ObjectIdentifier(column)] = SidebarMissionQuestion(
                questionID: question.id,
                parentTitle: parentTitle,
                text: question.message,
                handOff: SidebarMissionQuestion.handOff(
                    parent: parentState, askedAt: question.timestamp,
                    threshold: stuckAgentWaitThreshold ?? MissionEventCLI.parentMessageLifetime, now: now
                )
            )
        }
        return result
    }

    /// A question that just came to the user lights its workspace (the
    /// ring, the Dock badge) and, with Nirux in the background, bounces the
    /// Dock icon and posts a notification: once per hand-off. A hand-off
    /// that ended (answered, retired, the parent back) puts that out.
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
                NiruxNotifier.shared.postMissionEvent(
                    workspaceID: workspace.id,
                    workspaceTitle: workspace.title,
                    columnIndex: columnIndex,
                    kind: .question,
                    message: question.text
                )
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
        let enabled = Self.currentMissionHandoffsEnabled()
        guard enabled else {
            showToast("Mission handoffs are off in Settings")
            return false
        }
        let store = MissionStore.shared
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
        // Before the sidebar refresh, which would read it as answered by
        // someone else.
        closeMissionReply()
        if handleMissionEvent(accepted.mission, event: accepted.event) {
            store.markDelivered(eventID: accepted.event.id)
        }
        return true
    }

    private func closeMissionReply() {
        missionReplyPopover?.close()
        missionReplyPopover = nil
        missionReplyQuestionID = nil
    }
}
