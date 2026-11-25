import Foundation

/// Whether a task's worker can become its space's Lead now (Promote to
/// Lead, NiruxShellView+LeadPromotion). Its conversation goes on as the
/// Lead's, so only one at rest moves: a turn, a dialog or a draft would be
/// cut off with its process.
enum LeadPromotion {
    /// What the task's worker terminal shows.
    struct Worker: Equatable {
        /// The coding agent in front, if any.
        var agent: CodingAgent?
        /// Its Claude conversation, once its hooks proved it.
        var sessionID: String?
        /// Its terminal is starting or restarting.
        var isStarting = false
        /// Its agent's status reads idle.
        var isAtRest = false
        var hasDialog = false
        var hasDraft = false
        /// A program in front that is no agent.
        var otherProgram: String?
    }

    /// Nil when `worker` can be promoted. `openSubtasks`: the task's own
    /// open sub-tasks, whose parent it is.
    static func refusal(_ worker: Worker?, openSubtasks: Int) -> String? {
        guard let worker else { return "Nirux couldn’t find this task’s agent terminal." }
        if worker.isStarting { return "The task’s terminal is starting. Try again once it opens." }
        if let program = worker.otherProgram { return "\(program) runs in the task’s terminal. Finish it first." }
        guard let agent = worker.agent else { return "No agent runs in this task: there is no conversation to promote." }
        guard agent == .claude else { return "Only a Claude task can become the Lead for now." }
        guard worker.sessionID != nil else { return "Claude hasn’t recorded this conversation yet. Promote it after its first turn." }
        if !worker.isAtRest { return "The task’s agent is working. Promote it once its turn ends." }
        if worker.hasDialog { return "A dialog waits in the task’s terminal. Answer it first." }
        if worker.hasDraft { return "The task’s prompt holds a draft. Send or clear it first." }
        if openSubtasks > 0 { return "Close the task’s sub-tasks first: they can’t follow it to the Lead yet." }
        return nil
    }
}
