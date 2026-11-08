import AppKit

// MARK: - Mission questions: the child's card, the hand-off to the user, the reply popover

extension NiruxShellView {
    /// The question each Mission child column waits on, keyed by the
    /// column, with why it now waits on the user if it does: its parent
    /// was closed or doesn't run Claude Code, or nobody answered within the
    /// stuck-agent threshold. `foreground` gives a column's foreground
    /// process.
    func missionQuestions(
        foreground: (ColumnState) -> ForegroundProcess?, now: TimeInterval
    ) -> [ObjectIdentifier: SidebarMissionQuestion] {
        var result: [ObjectIdentifier: SidebarMissionQuestion] = [:]
        for mission in MissionStore.shared.missions where mission.status == .active {
            guard let workspace = workspaces.first(where: { $0.id == mission.childWorkspaceID }),
                  workspace.missionHandoffsEnabled,
                  let column = workspace.columns.first(where: { $0.agentUUID == mission.childAgentUUID }),
                  result[ObjectIdentifier(column)] == nil,
                  let question = MissionStore.shared.waitingQuestion(
                      childWorkspaceID: mission.childWorkspaceID, childAgentUUID: mission.childAgentUUID
                  )?.event
            else { continue }
            let parentWorkspace = workspaces.first { $0.id == mission.parentWorkspaceID }
            let parent = parentWorkspace?.columns.first { $0.agentUUID == mission.parentAgentUUID }
            let parentState: SidebarMissionQuestion.Parent
            if let parent, let pty = parent.pty, !pty.hasExited {
                let process = foreground(parent)
                parentState = process.map { $0.name == "claude" && !AgentHookCenter.isHeadlessClaude($0) } == true
                    ? .claude : .notClaude
            } else {
                parentState = .closed
            }
            result[ObjectIdentifier(column)] = SidebarMissionQuestion(
                questionID: question.id,
                parentTitle: parentWorkspace?.title ?? "the parent agent",
                text: question.message,
                handOff: SidebarMissionQuestion.handOff(
                    parent: parentState, askedAt: question.timestamp, threshold: stuckAgentWaitThreshold, now: now
                )
            )
        }
        return result
    }

    /// A question that just came to the user lights its workspace (the
    /// ring, the Dock badge) and, with Nirux in the background, posts a
    /// notification: once per question.
    func noteMissionQuestionHandOffs(_ questions: [ObjectIdentifier: SidebarMissionQuestion]) {
        for workspace in workspaces {
            for (columnIndex, column) in workspace.columns.enumerated() {
                guard let question = questions[ObjectIdentifier(column)], question.handOff != nil,
                      missionQuestionsHandedToUser.insert(question.questionID).inserted
                else { continue }
                workspace.raiseNotification(.waiting)
                NiruxNotifier.shared.postMissionEvent(
                    workspaceID: workspace.id,
                    workspaceTitle: workspace.title,
                    columnIndex: columnIndex,
                    kind: .question,
                    message: question.text
                )
            }
        }
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
              )[ObjectIdentifier(column)]
        else { return showToast("That question was already answered") }
        missionReplyPopover?.close()
        let controller = MissionReplyViewController(
            childTitle: workspace.title, question: question,
            onSend: { [weak self, weak workspace] text in
                guard let self, let workspace else { return false }
                return self.answerMissionQuestion(question.questionID, text: text, childWorkspace: workspace)
            },
            onOpenTask: { [weak self, weak workspace] in
                guard let self, let workspace else { return }
                self.missionReplyPopover?.close()
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
        controller.focusReplyField()
    }

    /// The user's answer from the popover, as if the parent had sent it:
    /// Nirux types it into the child's prompt. False keeps the popover
    /// open (the toast says why).
    func answerMissionQuestion(_ questionID: String, text: String, childWorkspace: WorkspaceState) -> Bool {
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
        guard let accepted = MissionStore.shared.respond(to: questionID, message: reply, enabled: enabled) else {
            showToast("That question was already answered, or its Mission ended", tone: .error)
            missionReplyPopover?.close()
            updateSidebar()
            return false
        }
        if handleMissionEvent(accepted.mission, event: accepted.event) {
            MissionStore.shared.markDelivered(eventID: accepted.event.id)
        }
        missionReplyPopover?.close()
        return true
    }
}
