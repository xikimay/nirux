import Foundation

// MARK: - The merge queue on the board (docs/project-board.md, sections 2 and 3.6)

extension ProjectBoard {
    /// What the board shows of its project's merge queue, as the shell
    /// reads it from `MergeQueueController`.
    struct QueueState: Equatable, Sendable {
        enum Run: Equatable, Sendable {
            /// No queue ran, here or in the saved file.
            case none
            case running(isStopping: Bool)
            /// Ended this launch, or saved stopped or finished (an
            /// interrupted one included).
            case ended
            /// Another Nirux runs it: the board is read-only.
            case elsewhere
        }

        var run: Run = .none
        /// This build can't change GitHub: every queue is a dry run.
        var isDryRun: Bool
        /// "#52 waiting for the nightly, 3 of 7", "Stopped: …".
        var status: String?
        /// Stopped by a problem, not by the user.
        var statusIsFailure = false
        /// The queue shown: running, ended or saved.
        var entries: [MergeQueue.Entry] = []
        var workflow: String?
        /// What the next Start proposes, in order.
        var selection: [Int] = []
        /// Why board.json can't start a queue.
        var startProblems: [String] = []
        /// The confirmation sheet is open.
        var isConfirming = false

        var isRunning: Bool {
            if case .running = run { return true }
            return false
        }

        /// Adding, removing and starting wait for the queue to end, here
        /// and in another Nirux.
        var isLocked: Bool { isRunning || run == .elsewhere }
    }

    /// Why a row's pull request can't be added to the queue, for its Queue
    /// column: what the board knows without a call. The confirmation sheet
    /// checks the rest (section 4). Nil: it can.
    static func queueRefusal(_ row: Row, baseBranch: String?) -> String? {
        guard let pullRequest = row.pullRequest else { return "no pull request" }
        guard pullRequest.isOpen else { return pullRequest.state.lowercased() }
        if pullRequest.isDraft { return "draft" }
        if let base = pullRequest.baseRefName, let baseBranch, base != baseBranch { return "targets \(base)" }
        if pullRequest.isConflicting { return "conflict" }
        if let busy = MergeQueue.busyLabel(row.agent.state) { return "agent \(busy)" }
        return nil
    }

    /// A step as the Queue column says it: "waiting for nightly".
    static func queueStepLabel(_ step: MergeQueue.Step, workflow: String?) -> String {
        switch step {
        case .waiting: return "waiting"
        case .preflight: return "checking"
        case .updating: return "updating branch"
        case .waitingForChecks: return "waiting for checks"
        case .rerunning: return "rerunning checks"
        case .merging: return "merging"
        case .waitingForPostMerge: return "waiting for \(MergeQueue.workflowLabel(workflow))"
        case .done: return "merged ✓"
        case .stopped(let reason): return "stopped: \(queueStopLabel(reason, workflow: workflow))"
        }
    }

    /// Why an entry stopped, in a word or two; the tooltip has the rest.
    static func queueStopLabel(_ reason: MergeQueue.StopReason, workflow: String?) -> String {
        switch reason.kind {
        case .user: return "by you"
        case .interrupted: return "interrupted"
        case .dryRun: return "dry run"
        case .setup, .github: return "GitHub"
        case .notMergeable: return "can’t merge"
        case .changed: return "changed"
        case .conflict: return "conflict"
        case .agentBusy: return "agent busy"
        case .local: return "local changes"
        case .update: return "update failed"
        case .checks: return "checks"
        case .merge: return "merge failed"
        case .postMerge: return "\(MergeQueue.workflowLabel(workflow)) failed"
        }
    }
}

extension MergeQueue.StopReason {
    /// A stop that needs a look: not Stop pressed, nor a dry run reaching
    /// its first change, as it always does.
    var isProblem: Bool { kind != .user && kind != .dryRun }
}

extension MergeQueue.SavedQueue {
    /// What the board says of a saved queue: "Stopped: Interrupted while
    /// waiting for the nightly of #52: Nirux quit."
    var statusText: String {
        switch status {
        case .stopped: return "Stopped: " + (stopReason?.message ?? "no reason saved")
        case .finished: return "Finished: \(entries.filter { $0.step == .done }.count) merged"
        case .running, .stopping:
            let entry = current.flatMap { entries[safe: $0] }
            return (entry?.stepDescription(workflow: postMergeWorkflow) ?? "starting")
                + (current.map { ", \($0 + 1) of \(entries.count)" } ?? "")
        }
    }
}
