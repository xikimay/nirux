import Foundation

// MARK: - The merge queue on the Board as stages (docs/design/board-stages.md, section 7)

extension BoardStagesView {
    /// What a repository's header says of its queue, by the table's rules
    /// (`ProjectBoardView.queueHeader`), `proposed` being the pull requests
    /// of the next Start's list the Board shows a place for: one merged
    /// counts for none (`BoardStages.queue(of:head:in:merged:)`).
    nonisolated static func sectionQueue(_ state: ProjectBoard.QueueState, proposed: Int) -> SectionQueue {
        // The Board shows a place for some of the list, never more.
        let proposed = min(proposed, state.selection.count)
        let header = ProjectBoardView.queueHeader(state)
        var queue = SectionQueue(
            tone: tone(of: header.tone), dryRun: state.isDryRun ? ProjectBoardView.dryRunTooltip(reason: state.dryRunReason) : nil
        )
        let queued = "\(proposed) pull request\(proposed == 1 ? "" : "s") queued"
        switch state.run {
        case .running:
            queue.status = state.status ?? "Running"
            queue.stop = header.stop.map(button)
            return queue
        case .elsewhere:
            queue.status = elsewhere(state)
            queue.start = header.start.map(button)
            if proposed > 0 { queue.start?.title += " · \(proposed)" }
            return queue
        case .ended:
            // A problem's words alone in red: what is queued is on Start.
            let said = state.statusIsFailure ? [] : (proposed > 0 ? [queued] : [])
            queue.status = ([state.status ?? "Ended"] + said).joined(separator: " · ")
        case .none:
            queue.status = proposed > 0 ? queued : nil
        }
        // The table gives Start at rest and once a queue ended.
        guard var start = header.start.map(button) else { return queue }
        if proposed > 0 { start.title += " · \(proposed)" }
        // Only merged ones left in the list: nothing to start, as the Start sheet would say.
        if state.startProblems.isEmpty, !state.isConfirming, proposed == 0 {
            start.isEnabled = false
            start.tooltip = "Add pull requests to the queue first."
        }
        queue.start = start
        return queue
    }

    /// The line a queue keeps at the Board's foot while it runs, here or
    /// in another Nirux; nil otherwise.
    nonisolated static func runningQueue(id: String, title: String, tooltip: String? = nil, state: ProjectBoard.QueueState) -> RunningQueue? {
        switch state.run {
        case .running(let isStopping):
            return RunningQueue(
                id: id, title: title, tooltip: tooltip, status: state.status ?? "Running", tone: isStopping ? .normal : .working,
                stop: ProjectBoardView.queueHeader(state).stop.map(button)
            )
        case .elsewhere:
            return RunningQueue(id: id, title: title, tooltip: tooltip, status: elsewhere(state), tone: .normal)
        case .none, .ended:
            return nil
        }
    }

    private nonisolated static func elsewhere(_ state: ProjectBoard.QueueState) -> String {
        (["Running in another Nirux"] + (state.status.map { [$0] } ?? [])).joined(separator: " · ")
    }

    private nonisolated static func button(_ button: ProjectBoardView.QueueButton) -> QueueButton {
        QueueButton(title: button.title, isEnabled: button.isEnabled, tooltip: button.tooltip)
    }

    private nonisolated static func tone(of tone: ProjectBoardView.QueueTone) -> QueueTone {
        switch tone {
        case .normal: return .normal
        case .active, .success: return .working
        case .failure: return .failed
        }
    }
}
