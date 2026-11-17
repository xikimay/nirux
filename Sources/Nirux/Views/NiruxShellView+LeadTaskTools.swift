import AppKit

// MARK: - The Lead tidies its space's list (see LeadTools)

/// `close_task` and `move_task`: any task of the Lead's space, the user's
/// too. Closing runs Clean Up Worktree…'s checks and deletes the worktree
/// and its branch only when they all pass: the Lead's call stands in for
/// the alert's click.
extension NiruxShellView {
    /// The task of `space` named `name`, whoever started it.
    func spaceTask(_ name: String, in space: WorkspaceProfile) -> WorkspaceState? {
        namedWorkspace(name, among: workspaces.filter { $0.profileID == space.id && !$0.isLead && !$0.isClosing })
    }

    private func noSpaceTask(_ name: String, in space: WorkspaceProfile) -> String {
        "No task in \(space.name) is named “\(name)”, or several share that name: use its title or branch from list_tasks "
            + "(its folder, for a task without a repository)."
    }

    // MARK: close_task

    func leadCloseTask(_ arguments: [String: Any], in space: WorkspaceProfile, answer: @escaping LeadAnswer) {
        let name = LeadTools.string(arguments, "task") ?? ""
        guard let task = spaceTask(name, in: space) else { return answer(noSpaceTask(name, in: space), true) }
        let title = MissionPromptText.quoted(task.title)
        // A task whose folder is gone only closes (see finishLeadClose).
        guard Self.isTask(task) || !FileManager.default.fileExists(atPath: task.cwd) else {
            return answer("“\(title)” isn't a task (a worktree of one of the space's repositories, or a task's folder): "
                + "ask the user to close it.", true)
        }
        let snapshot = ProcessSnapshot()
        if let refusal = leadCloseRefusal(of: task, snapshot: snapshot) { return answer(refusal, true) }
        if let folder = task.taskFolder { return closeFolderTask(task, folder: folder, snapshot: snapshot, answer: answer) }
        guard let path = Self.worktreeCleanupPath(forCwd: task.cwd) else {
            closeLeadTask(task)
            return answer("Closed “\(title)”. Nirux found no worktree of it to clean up.", false)
        }
        let key = Self.comparablePath(path)
        guard worktreeCleanupsInFlight.insert(key).inserted else {
            return answer("A clean-up of “\(title)”'s worktree is already running: call again in a minute.", true)
        }
        let others = worktreeMembers(path).filter { $0 !== task }
        guard others.isEmpty else {
            worktreeCleanupsInFlight.remove(key)
            closeLeadTask(task)
            return answer(Self.closedKeeping(title, because: Self.openInIt(others)), false)
        }
        let (taskID, spaceID, agentFolders, tools) = (task.id, space.id, [task.cwd], worktreeCleanupTools())
        Self.offMain({ WorktreeCleanup.inspect(path: path, agentFolders: agentFolders, tools: tools) }) { [weak self] inspection in
            guard let self else { return answer("Nirux closed meanwhile: nothing was cleaned up.", true) }
            self.finishLeadClose(taskID: taskID, spaceID: spaceID, path: path, inspection: inspection, answer: answer)
        }
    }

    /// GitHub and git answered: cleans up when every check passed, the
    /// task closed first (no turn starts in a folder going away), else
    /// closes the task alone.
    private func finishLeadClose(
        taskID: String, spaceID: String, path: String, inspection: WorktreeCleanup.Inspection, answer: @escaping LeadAnswer
    ) {
        let key = Self.comparablePath(path)
        guard let task = workspaces.first(where: { $0.id == taskID && $0.profileID == spaceID && !$0.isClosing }) else {
            worktreeCleanupsInFlight.remove(key)
            return answer("The task was closed or moved to another space meanwhile: nothing was cleaned up.", true)
        }
        // Its agent may have taken a prompt while GitHub answered.
        let snapshot = ProcessSnapshot()
        if let refusal = leadCloseRefusal(of: task, snapshot: snapshot) {
            worktreeCleanupsInFlight.remove(key)
            return answer(refusal, true)
        }
        let title = MissionPromptText.quoted(task.title)
        var candidate = worktreeCleanupCandidate(path: path, snapshot: snapshot)
        candidate.inspection = inspection
        let others = candidate.workspaces.filter { $0.id != taskID }
        let availability = others.isEmpty ? candidate.availability : .blocked([Self.openInIt(others.map(\.title))])
        closeLeadTask(task)
        // A folder named for another branch may be a base reused across
        // branches, which the alert warns about.
        guard case .ready(let plan, _) = availability, plan.worktree.folderMatchesBranch else {
            worktreeCleanupsInFlight.remove(key)
            return answer(Self.closedWithout(title, availability), false)
        }
        executeWorktreeCleanup(plan, of: candidate) { [weak self] outcome in
            self?.worktreeCleanupsInFlight.remove(key)
            answer(Self.cleanedUp(title, plan: plan, outcome: outcome), outcome?.succeeded != true)
        }
    }

    /// A task without a repository: its folder goes to the Trash, where
    /// the user can put it back, unless someone still works in it.
    private func closeFolderTask(_ task: WorkspaceState, folder: String, snapshot: ProcessSnapshot, answer: @escaping LeadAnswer) {
        let title = MissionPromptText.quoted(task.title)
        guard FileManager.default.fileExists(atPath: folder) else {
            closeLeadTask(task)
            return answer("Closed “\(title)”: its folder was already gone.", false)
        }
        let candidate = worktreeCleanupCandidate(path: folder, snapshot: snapshot)
        let others = candidate.workspaces.filter { $0.id != task.id }
        // A sub-task's folder is in its task's, which works there too.
        let holders = workspaces.filter { holder in
            holder !== task && !holder.isClosing && holder.taskFolder.map { Self.containment(in: $0)(folder) } ?? false
        }
        let problems = (others.isEmpty ? [] : [Self.openInIt(others.map(\.title))])
            + (holders.isEmpty ? [] : ["It is in the folder of \(WorktreeCleanupCandidate.quotedList(holders.map(\.title)))."])
            + candidate.inUseProblems
        guard problems.isEmpty else {
            closeLeadTask(task)
            return answer("Closed “\(title)”. Its folder stays (\(folder)): " + problems.joined(separator: " "), false)
        }
        let tools = worktreeCleanupTools()
        // Once its terminals are gone: nothing writes in it as it moves.
        closeLeadTask(task) {
            Self.offMain({ () -> String? in
                do {
                    _ = try tools.trash(URL(fileURLWithPath: folder))
                    return nil
                } catch {
                    return error.localizedDescription
                }
            }) { problem in
                answer(problem.map { "Closed “\(title)”, but its folder couldn't go to the Trash (\($0)): it stays at \(folder)." }
                    ?? "Closed “\(title)” and moved its folder to the Trash (\(folder)): the user can put it back from there.", false)
            }
        }
    }

    private static func openInIt(_ titles: [String]) -> String {
        "Other workspaces are open in it: \(WorktreeCleanupCandidate.quotedList(titles))."
    }

    private static func openInIt(_ workspaces: [WorkspaceState]) -> String {
        openInIt(workspaces.map(\.title))
    }

    private static func closedKeeping(_ title: String, because reason: String) -> String {
        "Closed “\(title)”. Its worktree and branch stay: \(reason)"
    }

    /// The answer when the checks didn't all pass: the task closed alone.
    private static func closedWithout(_ title: String, _ availability: WorktreeCleanupCandidate.Availability) -> String {
        switch availability {
        case .ready: closedKeeping(title, because: "Its folder isn't named for its branch: it may be a base reused across branches.")
        case .closeOnly: "Closed “\(title)”: its folder was already gone (its branch stays)."
        case .notMerged(let reason): closedKeeping(title, because: "It isn't merged (\(reason)).")
        case .blocked(let problems): closedKeeping(title, because: problems.joined(separator: " "))
        case .checking: closedKeeping(title, because: "Nirux couldn't check it.")
        }
    }

    /// The answer once git ran: what's left is on disk to see.
    private static func cleanedUp(_ title: String, plan: WorktreeCleanup.Plan, outcome: CleanupOutcome?) -> String {
        guard let outcome else { return "Nirux closed during the clean-up of “\(title)”: check its worktree, \(plan.worktree.path)." }
        let kept = outcome.keptOpen.isEmpty ? "" : " " + keptOpenText(outcome.keptOpen) + "."
        if outcome.succeeded {
            return "Closed “\(title)” and cleaned it up (pull request #\(plan.pullRequest.number) merged): \(outcome.message).\(kept)"
        }
        if FileManager.default.fileExists(atPath: plan.worktree.path) {
            return "Closed “\(title)”, but the clean-up failed, so its worktree and branch stay: \(outcome.message)\(kept)"
        }
        return "Closed “\(title)” and deleted its folder, but its branch stays: \(outcome.message)\(kept)"
    }

    /// Why the Lead may not close `task` now, nil when it may: closing
    /// would end work, or drop what the user hasn't settled.
    func leadCloseRefusal(of task: WorkspaceState, snapshot: ProcessSnapshot) -> String? {
        let title = MissionPromptText.quoted(task.title)
        // Closing it would move their selection and keyboard.
        if task === activeWorkspace, NSApp.isActive {
            return "The user has “\(title)” on screen: leave it to them, or ask them to close it."
        }
        let readings = agentReadings(of: task, snapshot: snapshot)
        // A turn that just ended reads "needs the user" until they look:
        // only what they must answer counts.
        if let dialog = readings.lazy.compactMap(\.dialog).first {
            return "“\(title)” waits for the user (\(dialog)): leave it to them."
        }
        if readings.contains(where: { $0.status == .working }) {
            return "“\(title)”'s agent is working: wait for its turn to end, then close it."
        }
        let columns = task.openColumns
        if columns.contains(where: { $0.pty?.awaitsTurnVerdict == true }) {
            return "“\(title)”'s last turn is still being read (it may ask the user something): call again in a moment."
        }
        if let paused = columns.compactMap(\.deferredAgent).first(where: { [.working, .needsAttention].contains($0.lastStatus) }) {
            return "“\(title)” hasn't resumed since Nirux restarted, \(paused.lastStatusText ?? ""): leave it to the user."
        }
        // Idle is only known from Claude's hooks (see WorkspaceClosePolicy).
        if let unknown = columns.compactMap({ $0.liveAgent(snapshot: snapshot) }).first(where: { $0.status == nil }) {
            return "Nirux can't tell whether “\(title)”'s \(unknown.displayName) is done: ask the user to close it."
        }
        // A dev server or a test run in a terminal of its own.
        let programs = columns.compactMap { column -> String? in
            guard let pty = column.pty, pty.runningAgentName(snapshot: snapshot) == nil,
                  let name = pty.foregroundProcess(snapshot: snapshot)?.name else { return nil }
            return Self.interactiveShells.contains(name.hasPrefix("-") ? String(name.dropFirst()) : name) ? nil : name
        }
        if let program = programs.first {
            return "“\(title)” runs \(program) in a terminal: ask the user to close it."
        }
        let store = MissionStore.shared
        _ = store.ensureLoaded()
        let handedOver = columns.contains { column in
            column.agentUUID.flatMap { store.waitingQuestion(childWorkspaceID: task.id, childAgentUUID: $0) }?
                .event.handedToUserBecause != nil
        }
        if handedOver {
            return "“\(title)” waits for the user's answer to the question you handed them: close it once they answered."
        }
        if columns.contains(where: { !($0.editorColumn?.unsavedPaths.isEmpty ?? true) }) {
            return "“\(title)” has unsaved editor changes: ask the user to save or discard them first."
        }
        let waitingParent = store.missions.first { mission in
            mission.childWorkspaceID == task.id && mission.reportsToTask == true && mission.status == .active
                && workspaces.contains { $0.id == mission.parentWorkspaceID && !$0.isClosing }
        }.flatMap { mission in workspaces.first { $0.id == mission.parentWorkspaceID } }
        if let waitingParent {
            return "“\(title)” is a sub-task “\(MissionPromptText.quoted(waitingParent.title))”'s agent waits for: "
                + "tell that task instead."
        }
        let subtasks = subtasks(of: task).filter { !$0.isInactive }
        if !subtasks.isEmpty {
            return "“\(title)” still has sub-tasks (\(WorktreeCleanupCandidate.quotedList(subtasks.map(\.title)))): close them first."
        }
        return nil
    }

    /// Closes `task` as Close Workspace does once confirmed, leaving the
    /// keyboard where it is; once it's gone, saves and runs `then`.
    private func closeLeadTask(_ task: WorkspaceState, then: (@MainActor () -> Void)? = nil) {
        guard let index = workspaces.firstIndex(where: { $0 === task }) else { return }
        closeWorkspace(at: index, refocusing: false)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.saveState()
            then?()
        }
    }

    // MARK: move_task

    func leadMoveTask(_ arguments: [String: Any], in space: WorkspaceProfile, answer: @escaping LeadAnswer) {
        let name = LeadTools.string(arguments, "task") ?? ""
        let position = LeadTools.positiveInteger(arguments["position"]) ?? 1
        guard let task = spaceTask(name, in: space), let index = workspaces.firstIndex(where: { $0 === task }) else {
            return answer(noSpaceTask(name, in: space), true)
        }
        let moved = workspaceStore.moveWorkspace(at: index, toPosition: position - 1)
        if moved { refreshAfterWorkspaceMutation(refocusing: false) }
        guard let now = workspaces.firstIndex(where: { $0 === task }), let (siblings, place) = workspaceStore.siblingGroup(of: now)
        else { return answer("Nirux lost “\(MissionPromptText.quoted(task.title))” in the sidebar: call list_tasks.", true) }
        let parent = workspaceStore.activeParents(in: space.id)[now].map { MissionPromptText.quoted(workspaces[$0].title) }
        let group = task.isInactive ? "the archived tasks" : parent.map { "the sub-tasks of “\($0)”" } ?? "the tasks of \(space.name)"
        answer("“\(MissionPromptText.quoted(task.title))” is \(place + 1) of \(siblings.count) among \(group)"
            + (moved ? "." : ", as it was."), false)
    }
}
