import Foundation

// MARK: - The merge queue on the Board as stages (docs/design/board-stages.md, section 7)

extension BoardStagesView {
    /// What a repository's header says of its queue, `proposed` being the
    /// pull requests of the next Start's list the Board shows a place for:
    /// one merged counts for none (`BoardStages.nextStartList`).
    nonisolated static func sectionQueue(
        _ state: ProjectBoard.QueueState, proposed: Int, timeout: BoardStages.CheckTimeout? = nil
    ) -> SectionQueue {
        // The Board shows a place for some of the list, never more.
        let proposed = min(proposed, state.selection.count)
        var queue = SectionQueue(tone: tone(of: state), dryRun: state.isDryRun ? MergeQueue.dryRunTooltip(reason: state.dryRunReason) : nil)
        let queued = "\(proposed) pull request\(proposed == 1 ? "" : "s") queued"
        let count = proposed > 0 ? " · \(proposed)" : ""
        switch state.run {
        case .running:
            queue.status = state.status ?? "Running"
            queue.stop = stopButton(state)
            return queue
        case .elsewhere:
            queue.status = elsewhere(state)
            queue.start = QueueButton(
                title: startTitle(state) + count, isEnabled: false, tooltip: "Another Nirux runs this repository’s queue: Start once it ends there."
            )
            return queue
        case .ended:
            // A problem's words alone in red: what is queued is on Start.
            let said = state.statusIsFailure ? [] : (proposed > 0 ? [queued] : [])
            queue.status = ([state.status ?? "Ended"] + said).joined(separator: " · ")
        case .none:
            queue.status = proposed > 0 ? queued : nil
        }
        // At rest, and once a queue ended: Start, or why it can't. Only merged ones left in the list: nothing to start, as
        // the Start sheet would say.
        var start = QueueButton(title: startTitle(state) + count)
        if !state.startProblems.isEmpty {
            start.isEnabled = false
            start.tooltip = state.startProblems.joined(separator: "\n")
        } else if state.selection.isEmpty || !state.isConfirming && proposed == 0 {
            start.isEnabled = false
            start.tooltip = "Add pull requests to the queue first."
        } else if state.isConfirming {
            start.isEnabled = false
            start.tooltip = "The confirmation sheet is open."
        } else {
            start.tooltip = "Read the queued pull requests on GitHub, then confirm what the queue will do"
        }
        if let timeout, state.run == .ended {
            queue.status = timeout.status
            queue.detail = [timeout.status, state.status].compactMap { $0 }.joined(separator: "\n")
            queue.tone = timeout.reading == .failed ? .failed : .normal
            if timeout.canRetry, state.selection == [timeout.number], proposed == 1, start.isEnabled {
                start.title = (state.isDryRun ? "Retry Dry Run #" : "Retry #") + "\(timeout.number)…"
                start.tooltip = "Read #\(timeout.number) again and review the confirmation."
            }
        }
        queue.start = start
        return queue
    }

    /// The line a queue keeps at the Board's foot while it runs, here or
    /// in another Nirux; nil otherwise.
    nonisolated static func runningQueue(id: String, title: String, tooltip: String? = nil, state: ProjectBoard.QueueState) -> RunningQueue? {
        switch state.run {
        // Green, as its header says it.
        case .running:
            return RunningQueue(id: id, title: title, tooltip: tooltip, status: state.status ?? "Running", stop: stopButton(state))
        case .elsewhere:
            return RunningQueue(id: id, title: title, tooltip: tooltip, status: elsewhere(state))
        case .none, .ended:
            return nil
        }
    }

    private nonisolated static func elsewhere(_ state: ProjectBoard.QueueState) -> String {
        (["Running in another Nirux"] + (state.status.map { [$0] } ?? [])).joined(separator: " · ")
    }

    private nonisolated static func startTitle(_ state: ProjectBoard.QueueState) -> String {
        state.isDryRun ? "Start Dry Run…" : "Start…"
    }

    /// Stop while the queue runs here: before the next command.
    private nonisolated static func stopButton(_ state: ProjectBoard.QueueState) -> QueueButton? {
        guard case .running(let isStopping) = state.run else { return nil }
        return QueueButton(
            title: isStopping ? "Stopping…" : "Stop", isEnabled: !isStopping,
            tooltip: "Stop before the next command; a call already sent to GitHub finishes"
        )
    }

    /// Green while it works, here or elsewhere; red when a problem stopped
    /// it; never amber.
    private nonisolated static func tone(of state: ProjectBoard.QueueState) -> QueueTone {
        switch state.run {
        case .running, .elsewhere: return .working
        case .ended: return state.statusIsFailure ? .failed : .normal
        case .none: return .normal
        }
    }
}
