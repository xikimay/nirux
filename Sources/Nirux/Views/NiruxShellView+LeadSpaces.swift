import AppKit

// MARK: - The space tools (LeadTools.spaceNames), a Lead's or a task's

extension WorkspaceProfile {
    var leadSpaceReference: String { LeadTools.spaceIDPrefix + id }
}

extension NiruxShellView {
    /// A space tool call (`LeadTools.isSpaceCall`) from `caller`, in
    /// `space`, its own: the same checks for a Lead and a task, the
    /// caller's own space and workspace aside (SpaceToolCaller).
    func handleSpaceTool(
        _ tool: String, _ arguments: [String: Any], caller: SpaceToolCaller, in space: WorkspaceProfile, answer: @escaping LeadAnswer
    ) {
        switch tool {
        case LeadTools.listTasks: leadListTasks(LeadTools.string(arguments, "space") ?? "", caller: caller, answer: answer)
        case LeadTools.listSpaces: answer(leadSpaceList(currentSpace: space), false)
        case LeadTools.createSpace: leadCreateSpace(arguments, caller: caller, answer: answer)
        case LeadTools.editSpace: leadEditSpace(arguments, caller: caller, answer: answer)
        case LeadTools.deleteSpace: leadDeleteSpace(arguments, caller: caller, answer: answer)
        case LeadTools.moveTaskToSpace: leadMoveTaskToSpace(arguments, caller: caller, in: space, answer: answer)
        default: answer("Unknown tool: \(tool)", true)
        }
    }

    /// What the space tools' checks need of `workspace`, the caller.
    func spaceToolCaller(_ workspace: WorkspaceState) -> SpaceToolCaller {
        if workspace.isLead { return .lead(workspaceID: workspace.id, spaceID: workspace.profileID) }
        let parent = workspaces.first {
            $0.id == workspace.parentWorkspaceID && $0.profileID == workspace.profileID && !$0.isLead && !$0.isClosing
        }
        return SpaceToolCaller(
            workspaceID: workspace.id, spaceID: workspace.profileID, isLead: false,
            anchorKey: subtaskRepositoryKey(of: workspace), parentTaskID: parent?.id
        )
    }

    /// Space Settings › Defaults, "Tasks can manage spaces".
    func tasksManageSpaces(inSpace spaceID: String) -> Bool {
        SpaceDefaultsStore.defaults(forSpace: spaceID).tasksCanManageSpaces(inSpace: spaceID)
    }

    // MARK: list_tasks with space

    private func leadListTasks(_ requested: String, caller: SpaceToolCaller, answer: @escaping LeadAnswer) {
        switch resolveSpace(requested) {
        case .success(let target) where caller.leads(target.id):
            answer(leadTaskList(in: target, lead: caller.workspaceID), false)
        case .success(let target):
            // As its own Lead reads it: whose each task is, and what it asks.
            let owner = leadWorkspace(inSpace: target.id)
            let name = MissionPromptText.quoted(target.name)
            let view = owner == nil ? "“\(name)” has no Lead." : "As the Lead of “\(name)” sees it (“you” below is that Lead)."
            answer(view + " " + caller.reach + "\n" + leadTaskList(in: target, lead: owner?.id ?? ""), false)
        case .failure(let refusal):
            answer(refusal.message, true)
        }
    }

    // MARK: list_spaces

    func leadSpaceList(currentSpace: WorkspaceProfile) -> String {
        let header = profiles.count == 1 ? "1 space:" : "\(profiles.count) spaces:"
        let lines = profiles.map { space -> String in
            let isDefault = space.id == WorkspaceProfile.defaultID
            let isCurrent = space.id == currentSpace.id
            let tasks = workspaces.filter { $0.profileID == space.id && !$0.isLead && !$0.isClosing }
            let openCount = tasks.filter { !$0.isInactive }.count
            let archivedCount = tasks.filter(\.isInactive).count
            let hasLead = leadWorkspace(inSpace: space.id) != nil
            let queueRunning = hasRunningMergeQueue(inSpace: space.id)
            var parts = [
                "“\(MissionPromptText.quoted(space.name))”",
                space.leadSpaceReference,
                space.colorHex
            ]
            if isDefault { parts.append("default") }
            if isCurrent { parts.append("current space") }
            parts.append("\(openCount) open, \(archivedCount) archived")
            parts.append(hasLead ? "Lead active" : "no Lead")
            parts.append(queueRunning ? "merge queue running" : "no merge queue")
            var line = "- " + parts.joined(separator: " · ")
            let anchors = space.anchors.filter(\.isKnown)
            if !anchors.isEmpty {
                let described = anchors.map(Self.describeAnchor)
                line += "\n  anchors: " + described.joined(separator: ", ")
            } else if !isDefault {
                line += "\n  anchors: none"
            }
            return line
        }
        return ([header] + lines).joined(separator: "\n")
    }

    // MARK: create_space

    private func leadCreateSpace(_ arguments: [String: Any], caller: SpaceToolCaller, answer: @escaping LeadAnswer) {
        // LeadTools.problem checked the arguments.
        let name = LeadTools.string(arguments, "name") ?? ""
        if let duplicate = duplicateSpace(named: name, excluding: nil) { return answer(Self.duplicateSpaceMessage(duplicate), true) }
        let colorHex = LeadTools.string(arguments, "color").flatMap(LeadTools.normalizedColorHex) ?? workspaceStore.unusedColorHex()
        let paths = LeadTools.stringArray(arguments, "anchors") ?? []
        let movesAnchors = LeadTools.optionalFlag(arguments, "move_anchors") == true
        guard !paths.isEmpty else {
            return finishCreateSpace(name: name, colorHex: colorHex, anchors: [], movesAnchors: false, caller: caller, answer: answer)
        }
        guard projectStore.availability == .writable else { return answer(Self.anchorsLockedMessage, true) }
        resolveAnchors(paths) { result in
            switch result {
            case .failure(let refusal): answer(refusal.message, true)
            case .success(let anchors):
                self.finishCreateSpace(name: name, colorHex: colorHex, anchors: anchors, movesAnchors: movesAnchors, caller: caller, answer: answer)
            }
        }
    }

    private func finishCreateSpace(
        name: String, colorHex: String, anchors: [SpaceAnchor], movesAnchors: Bool, caller: SpaceToolCaller, answer: @escaping LeadAnswer
    ) {
        if let duplicate = duplicateSpace(named: name, excluding: nil) { return answer(Self.duplicateSpaceMessage(duplicate), true) }
        if !anchors.isEmpty {
            guard projectStore.availability == .writable else { return answer(Self.anchorsLockedMessage, true) }
            if let conflict = anchorOwnershipConflict(for: anchors, joining: nil, movesAnchors: movesAnchors, caller: caller) {
                return answer(conflict, true)
            }
        }
        let created = workspaceStore.createProfile(named: name, colorHex: colorHex, anchors: anchors, select: false)
        refreshAfterLeadSpaceChange(anchors: !anchors.isEmpty)
        let with = anchors.isEmpty ? "" : " with " + anchors.map(Self.anchorPhrase).joined(separator: ", ")
        answer("Created space “\(MissionPromptText.quoted(created.name))” (\(created.leadSpaceReference), \(created.colorHex))\(with).", false)
    }

    // MARK: edit_space

    private struct SpaceEdit: Sendable {
        let name: String?
        let colorHex: String?
        let removing: [String]
        let movesAnchors: Bool
        let caller: SpaceToolCaller
    }

    private func leadEditSpace(_ arguments: [String: Any], caller: SpaceToolCaller, answer: @escaping LeadAnswer) {
        let target: WorkspaceProfile
        switch resolveSpace(LeadTools.string(arguments, "space") ?? "") {
        case .success(let resolved): target = resolved
        case .failure(let refusal): return answer(refusal.message, true)
        }
        let edit = SpaceEdit(
            name: LeadTools.string(arguments, "name"),
            colorHex: LeadTools.string(arguments, "color").flatMap(LeadTools.normalizedColorHex),
            removing: LeadTools.stringArray(arguments, "remove_anchors") ?? [],
            movesAnchors: LeadTools.optionalFlag(arguments, "move_anchors") == true,
            caller: caller
        )
        let paths = LeadTools.stringArray(arguments, "add_anchors") ?? []
        if let refusal = editSpaceRefusal(target, edit, addsAnchors: !paths.isEmpty) { return answer(refusal, true) }
        let spaceID = target.id
        guard !paths.isEmpty else { return finishEditSpace(spaceID, edit, adding: [], answer: answer) }
        resolveAnchors(paths) { result in
            switch result {
            case .failure(let refusal): answer(refusal.message, true)
            case .success(let anchors): self.finishEditSpace(spaceID, edit, adding: anchors, answer: answer)
            }
        }
    }

    private func editSpaceRefusal(_ target: WorkspaceProfile, _ edit: SpaceEdit, addsAnchors: Bool) -> String? {
        if let name = edit.name {
            // Launch names it General again.
            if target.id == WorkspaceProfile.defaultID, name == WorkspaceProfile.legacyDefaultName {
                return "The default space can't be named “\(name)”: Nirux names it General again at launch."
            }
            if let duplicate = duplicateSpace(named: name, excluding: target.id) { return Self.duplicateSpaceMessage(duplicate) }
        }
        guard addsAnchors || !edit.removing.isEmpty else { return nil }
        if target.id == WorkspaceProfile.defaultID {
            return "The default space “\(MissionPromptText.quoted(target.name))” has no repositories or folders."
        }
        // As for taking one (anchorOwnershipConflict).
        if !edit.removing.isEmpty, leadWorkspace(inSpace: target.id) != nil || hasRunningMergeQueue(inSpace: target.id) {
            return "“\(MissionPromptText.quoted(target.name))” has a Lead or a running merge queue that works from its repositories: "
                + "only the user can remove one, in Space Settings."
        }
        return projectStore.availability == .writable ? nil : Self.anchorsLockedMessage
    }

    /// Checked again: the space may have changed while git named the folders.
    private func finishEditSpace(_ spaceID: String, _ edit: SpaceEdit, adding added: [SpaceAnchor], answer: @escaping LeadAnswer) {
        guard let target = profiles.first(where: { $0.id == spaceID }) else { return answer("That space was deleted meanwhile.", true) }
        if let refusal = editSpaceRefusal(target, edit, addsAnchors: !added.isEmpty) { return answer(refusal, true) }
        let removed: [SpaceAnchor]
        switch anchorsToRemove(edit.removing, in: target) {
        case .success(let found): removed = found
        case .failure(let refusal): return answer(refusal.message, true)
        }
        if let refusal = edit.caller.anchorLossRefusal(removed, from: spaceID) { return answer(refusal, true) }
        if let conflict = anchorOwnershipConflict(for: added, joining: spaceID, movesAnchors: edit.movesAnchors, caller: edit.caller) {
            return answer(conflict, true)
        }

        var changes: [String] = []
        if let name = edit.name, name != target.name, workspaceStore.renameProfile(id: spaceID, to: name) {
            changes.append("renamed from “\(MissionPromptText.quoted(target.name))”")
        }
        if let colorHex = edit.colorHex, colorHex.caseInsensitiveCompare(target.colorHex) != .orderedSame,
           workspaceStore.setProfileColor(id: spaceID, colorHex: colorHex) {
            changes.append("color \(colorHex)")
        }
        var anchorsChanged = false
        for anchor in removed {
            guard let key = anchor.key, workspaceStore.removeAnchor(key: key, fromProfile: spaceID) else { continue }
            changes.append("removed " + Self.anchorPhrase(anchor))
            anchorsChanged = true
        }
        for anchor in added {
            let has = profiles.first { $0.id == spaceID }?.anchors.contains { $0.key == anchor.key } == true
            guard !has, workspaceStore.addAnchor(anchor, toProfile: spaceID) else { continue }
            changes.append("added " + Self.anchorPhrase(anchor))
            anchorsChanged = true
        }
        let updated = profiles.first { $0.id == spaceID } ?? target
        let reference = "“\(MissionPromptText.quoted(updated.name))” (\(updated.leadSpaceReference))"
        guard !changes.isEmpty else { return answer("Nothing changed in \(reference): it was so already.", false) }
        refreshAfterLeadSpaceChange(anchors: anchorsChanged)
        answer("Updated \(reference): \(changes.joined(separator: ", ")).", false)
    }

    // MARK: delete_space

    private func leadDeleteSpace(_ arguments: [String: Any], caller: SpaceToolCaller, answer: @escaping LeadAnswer) {
        let target: WorkspaceProfile
        switch resolveSpace(LeadTools.string(arguments, "space") ?? "") {
        case .success(let resolved): target = resolved
        case .failure(let refusal): return answer(refusal.message, true)
        }
        var destination: WorkspaceProfile?
        if let query = LeadTools.string(arguments, "move_tasks_to") {
            switch resolveSpace(query) {
            case .success(let resolved): destination = resolved
            case .failure(let refusal): return answer(refusal.message, true)
            }
        }
        if let refusal = deleteRefusal(target, movingTo: destination, caller: caller) { return answer(refusal, true) }
        let (spaceID, destinationID, callerID) = (target.id, destination?.id, caller.workspaceID)
        // Its defaults and setup scripts go: the user decides, as from the sidebar.
        runFromRunLoop { [weak self] in
            guard let self else { return answer("Nirux closed meanwhile: nothing changed.", true) }
            let current = { (id: String?) in id.flatMap { id in self.profiles.first { $0.id == id } } }
            guard let target = current(spaceID) else { return answer("That space was deleted meanwhile.", true) }
            guard let asker = self.workspaces.first(where: { $0.id == callerID && !$0.isClosing }) else {
                return answer("Your workspace closed meanwhile: nothing changed.", true)
            }
            let tasks = self.workspaceStore.visibleWorkspaceIndices(in: spaceID)
            let destination = current(destinationID)
            let askedBy = asker.isLead ? "The Lead" : "The task “\(asker.title)”"
            guard self.confirmSpaceDeletion(target, movingTo: destination?.name ?? "", count: tasks.count, askedBy: askedBy) else {
                return answer("The user kept “\(MissionPromptText.quoted(target.name))”: nothing changed.", true)
            }
            // Checked again: the spaces, or where the caller is, may have changed while the user read.
            let caller = self.spaceToolCaller(asker)
            if let refusal = self.deleteRefusal(target, movingTo: destination, caller: caller) { return answer(refusal, true) }
            answer(self.deleteSpace(target, movingTasksTo: destination, caller: caller), false)
        }
    }

    /// Why `caller` may not delete `target`, its tasks moving to `destination`; nil when it may.
    private func deleteRefusal(_ target: WorkspaceProfile, movingTo destination: WorkspaceProfile?, caller: SpaceToolCaller) -> String? {
        if let refusal = deleteSpaceRefusal(target, caller: caller) { return refusal }
        // Sub-tasks after their task, as the sidebar lists them.
        let tasks = workspaceStore.visibleWorkspaceIndices(in: target.id).map { workspaces[$0] }
        guard !tasks.isEmpty else { return nil }
        guard let destination else {
            let count = tasks.count == 1 ? "1 task" : "\(tasks.count) tasks"
            return "“\(MissionPromptText.quoted(target.name))” still has \(count): pass move_tasks_to to move them first."
        }
        guard destination.id != target.id else { return "move_tasks_to must name another space." }
        return spaceMoveRefusal(of: tasks, to: destination, caller: caller)
    }

    /// What it did, for the answer; checked by `deleteRefusal`.
    private func deleteSpace(_ target: WorkspaceProfile, movingTasksTo destination: WorkspaceProfile?, caller: SpaceToolCaller) -> String {
        let name = "“\(MissionPromptText.quoted(target.name))” (\(target.leadSpaceReference))"
        let tasks = workspaceStore.visibleWorkspaceIndices(in: target.id).map { workspaces[$0] }
        var moved = ""
        var note: String?
        if let destination, !tasks.isEmpty {
            for task in tasks { moveWorkspaceToSpace(workspaceID: task.id, profileID: destination.id, refocusing: false) }
            let count = tasks.count == 1 ? "1 task" : "\(tasks.count) tasks"
            moved = "Moved \(count) to “\(MissionPromptText.quoted(destination.name))” (\(destination.leadSpaceReference)), then "
            note = caller.movedNote(moved: tasks.map(\.id), to: destination, tasksManageSpacesThere: tasksManageSpaces(inSpace: destination.id))
        }
        // Refused only for a queue started meanwhile, which deleteRefusal saw.
        deleteSpace(profileID: target.id, refocusing: false)
        let done = moved + (moved.isEmpty ? "Deleted \(name)." : "deleted \(name).")
        return [done, note].compactMap { $0 }.joined(separator: " ")
    }

    private func deleteSpaceRefusal(_ target: WorkspaceProfile, caller: SpaceToolCaller) -> String? {
        let name = "“\(MissionPromptText.quoted(target.name))”"
        if target.id == WorkspaceProfile.defaultID { return "The default space \(name) can't be deleted." }
        if let refusal = caller.deletionRefusal(of: target) { return refusal }
        // Deleting it would move their selection and keyboard.
        if target.id == activeProfileID { return "The user has \(name) on screen: leave it to them, or ask them to delete it." }
        // What they typed there would go.
        if spaceSettings?.spaceID == target.id { return "The user has the Space Settings of \(name) open: ask them to close them first." }
        if projectStore.availability != .writable {
            return "Spaces can't be deleted now: a newer Nirux saved them, or projects.json can't be read."
        }
        if hasRunningMergeQueue(inSpace: target.id) { return "\(name) has a running merge queue: stop it before deleting the space." }
        if leadWorkspace(inSpace: target.id) != nil { return "\(name) has a Lead: the user can turn it off in Space Settings › Lead first." }
        if workspaces.contains(where: { $0.profileID == target.id && $0.isClosing }) {
            return "A workspace of \(name) is closing: call again in a moment."
        }
        return nil
    }

    // MARK: move_task_to_space

    private func leadMoveTaskToSpace(
        _ arguments: [String: Any], caller: SpaceToolCaller, in callerSpace: WorkspaceProfile, answer: @escaping LeadAnswer
    ) {
        let source: WorkspaceProfile
        switch LeadTools.string(arguments, "from_space").map(resolveSpace) ?? .success(callerSpace) {
        case .success(let resolved): source = resolved
        case .failure(let refusal): return answer(refusal.message, true)
        }
        // Its Lead tells and closes its tasks, and only there.
        if !caller.leads(source.id), leadWorkspace(inSpace: source.id) != nil {
            return answer("“\(MissionPromptText.quoted(source.name))” has a Lead of its own, which organizes its tasks: ask the user.", true)
        }
        let destination: WorkspaceProfile
        switch resolveSpace(LeadTools.string(arguments, "to_space") ?? "") {
        case .success(let resolved): destination = resolved
        case .failure(let refusal): return answer(refusal.message, true)
        }
        let task: WorkspaceState
        switch resolveTaskForSpaceMove(LeadTools.string(arguments, "task") ?? "", in: source) {
        case .success(let found): task = found
        case .failure(let refusal): return answer(refusal.message, true)
        }
        let title = "“\(MissionPromptText.quoted(task.title))”"
        let to = "“\(MissionPromptText.quoted(destination.name))” (\(destination.leadSpaceReference))"
        guard task.profileID != destination.id else { return answer("\(title) is already in \(to).", false) }
        let tree = withSubtasks(task)
        if let refusal = spaceMoveRefusal(of: tree, to: destination, caller: caller) { return answer(refusal, true) }
        for moving in tree { moveWorkspaceToSpace(workspaceID: moving.id, profileID: destination.id, refocusing: false) }
        let subtasks = tree.count == 1 ? "" : tree.count == 2 ? " and its sub-task" : " and its \(tree.count - 1) sub-tasks"
        let moved = "Moved \(title)\(subtasks) from “\(MissionPromptText.quoted(source.name))” to \(to)."
        let note = caller.movedNote(moved: tree.map(\.id), to: destination, tasksManageSpacesThere: tasksManageSpaces(inSpace: destination.id))
        answer([moved, note].compactMap { $0 }.joined(separator: " "), false)
    }

    /// The task, then the sub-tasks under it, which move with it.
    private func withSubtasks(_ task: WorkspaceState) -> [WorkspaceState] {
        var tree = [task]
        var ids: Set = [task.id]
        var next = 0
        while next < tree.count {
            let parentID = tree[next].id
            let children = workspaces.filter { $0.profileID == task.profileID && $0.parentWorkspaceID == parentID && !ids.contains($0.id) }
            tree += children
            ids.formUnion(children.map(\.id))
            next += 1
        }
        return tree
    }

    /// Why `caller` may not move `tasks`, together, to `space`; nil when it may.
    private func spaceMoveRefusal(of tasks: [WorkspaceState], to space: WorkspaceProfile, caller: SpaceToolCaller) -> String? {
        if let refusal = caller.moveRefusal(moving: tasks.map(\.id)) { return refusal }
        _ = MissionStore.shared.ensureLoaded()
        let staying = Set(workspaces.map(\.id)).subtracting(tasks.map(\.id))
        for task in tasks {
            let title = "“\(MissionPromptText.quoted(task.title))”"
            // Moving it would move their selection and keyboard.
            if task === activeWorkspace { return "The user has \(title) on screen: leave it to them, or ask them to move it." }
            if task.isClosing { return "\(title) is closing: call again in a moment." }
            // Its start or held message reads the space it is in once the pull request merges.
            if let wait = task.mergeWaits.first { return "\(title) waits for \(wait.awaitedLongName) to merge: move it after that." }
            // The Lead's and a task's tools reach a Mission's other end in their own space only.
            let splitsMission = MissionStore.shared.missions.contains { mission in
                mission.status == .active && mission.oneWay != true
                    && (mission.childWorkspaceID == task.id && staying.contains(mission.parentWorkspaceID)
                        || mission.parentWorkspaceID == task.id && staying.contains(mission.childWorkspaceID))
            }
            if splitsMission {
                return "\(title) reports to a Lead or a task that stays, or one that stays reports to it: move it once its result is in."
            }
            if let refusal = moveRefusal(workspaceID: task.id, profileID: space.id) { return refusal }
        }
        return nil
    }

    // MARK: - Helpers

    private struct SpaceRefusal: Error {
        let message: String
    }

    private func resolveSpace(_ query: String) -> Result<WorkspaceProfile, SpaceRefusal> {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.lowercased().hasPrefix(LeadTools.spaceIDPrefix) {
            let id = String(trimmed.dropFirst(LeadTools.spaceIDPrefix.count))
            let matches = profiles.filter { $0.id.caseInsensitiveCompare(id) == .orderedSame }
            if matches.count == 1 { return .success(matches[0]) }
            return .failure(SpaceRefusal(message: "No space matches “\(trimmed)”: call list_spaces for names and space:<id> references."))
        }
        let exact = profiles.filter { $0.name == trimmed }
        if exact.count == 1 { return .success(exact[0]) }
        let insensitive = profiles.filter { $0.name.caseInsensitiveCompare(trimmed) == .orderedSame }
        if insensitive.count == 1 { return .success(insensitive[0]) }
        if insensitive.count > 1 {
            return .failure(SpaceRefusal(message: "Several spaces match “\(trimmed)”: use its space:<id> from list_spaces."))
        }
        return .failure(SpaceRefusal(message: "No space is named “\(trimmed)”: call list_spaces for names and space:<id> references."))
    }

    private func duplicateSpace(named name: String, excluding spaceID: String?) -> WorkspaceProfile? {
        profiles.first { $0.id != spaceID && $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }

    private static func duplicateSpaceMessage(_ space: WorkspaceProfile) -> String {
        "A space named “\(MissionPromptText.quoted(space.name))” already exists (\(space.leadSpaceReference))."
    }

    private func hasRunningMergeQueue(inSpace profileID: String) -> Bool {
        mergeQueues(of: profileID).contains { queue in
            queue.refreshSavedForLead()
            return queue.isRunning || queue.runsElsewhere
        }
    }

    /// The sidebar, the saved state and an open Space Settings show the
    /// change; an open New sheet shows its space's repositories again.
    private func refreshAfterLeadSpaceChange(anchors: Bool) {
        updateSidebar()
        saveState()
        spaceSettingsSpacesChanged()
        if anchors { refreshNewTaskPanelRepositories() }
    }

    private func resolveTaskForSpaceMove(_ query: String, in space: WorkspaceProfile) -> Result<WorkspaceState, SpaceRefusal> {
        if let found = spaceTask(query, in: space) { return .success(found) }
        let inSpace = workspaces.filter { $0.profileID == space.id }
        if let lead = matchingWorkspace(query, among: inSpace.filter { $0.isLead && !$0.isClosing }) {
            return .failure(SpaceRefusal(message: "“\(MissionPromptText.quoted(lead.title))” is a space's Lead workspace and cannot be moved."))
        }
        if let closing = matchingWorkspace(query, among: inSpace.filter(\.isClosing)) {
            return .failure(SpaceRefusal(message: "“\(MissionPromptText.quoted(closing.title))” is closing and cannot be moved."))
        }
        return .failure(SpaceRefusal(message: noSpaceTask(query, in: space)))
    }

    private func matchingWorkspace(_ query: String, among candidates: [WorkspaceState]) -> WorkspaceState? {
        if query.lowercased().hasPrefix(LeadTools.taskIDPrefix) {
            let id = String(query.dropFirst(LeadTools.taskIDPrefix.count))
            return candidates.first { $0.id.caseInsensitiveCompare(id) == .orderedSame }
        }
        return candidates.first { Self.answers($0, to: query) }
    }

    private static func describeAnchor(_ anchor: SpaceAnchor) -> String {
        switch anchor.kind {
        case .gitRepository(let commonDir):
            let suffix = anchor.isDefault ? ", default" : ""
            return "\(anchor.name) (repository\(suffix): \(anchor.folder ?? commonDir))"
        case .folder(let path):
            let suffix = anchor.isDefault ? ", default" : ""
            return "\(anchor.name) (folder\(suffix): \(path))"
        case .unknown:
            return anchor.name
        }
    }

    private static func anchorPhrase(_ anchor: SpaceAnchor) -> String {
        switch anchor.kind {
        case .folder: "folder “\(MissionPromptText.quoted(anchor.name))”"
        default: "repository “\(MissionPromptText.quoted(anchor.name))”"
        }
    }

    /// The anchors `paths` name, in their order, identified side by side off
    /// the main thread: a path in a git repository names that repository.
    private func resolveAnchors(
        _ paths: [String], then done: @escaping @MainActor @Sendable (Result<[SpaceAnchor], SpaceRefusal>) -> Void
    ) {
        let folders = paths.map { ($0 as NSString).expandingTildeInPath }
        let deadline = Date().addingTimeInterval(sideEffects.leadAnchorWait)
        Self.identifyAllOffMain(folders, timeout: Self.anchorPickTimeout) { [weak self] identities in
            guard let self else { return done(.failure(SpaceRefusal(message: "Nirux closed meanwhile: nothing changed."))) }
            // Past the call's wait, the Lead heard nothing came back: nothing may change then.
            guard Date() < deadline else { return done(.failure(SpaceRefusal(message: "git took too long to name the folders: nothing changed."))) }
            done(self.anchors(of: folders, identities: identities))
        }
    }

    private func anchors(of folders: [String], identities: [String: FolderIdentity]) -> Result<[SpaceAnchor], SpaceRefusal> {
        var anchors: [SpaceAnchor] = []
        for folder in folders {
            guard let identity = identities[folder] else { return .failure(SpaceRefusal(message: "No folder at \(folder).")) }
            let anchor = identity.anchor
            // A repository holding the home folder would take in every folder under it too.
            let top = anchor.folder ?? identity.topLevel ?? identity.path
            if isTooBroadForAFolderAnchor(top) { return .failure(SpaceRefusal(message: tooBroadFolderMessage(top))) }
            if !anchors.contains(where: { $0.key == anchor.key }) { anchors.append(anchor) }
        }
        return .success(anchors)
    }

    /// Why `anchors` can't join the space `spaceID` (nil: a new one), or
    /// nil. A repository or folder belongs to one space: the caller moves one
    /// only when asked to, never from a space whose Lead or merge queue works
    /// from it, nor a task's own out of its space.
    private func anchorOwnershipConflict(
        for anchors: [SpaceAnchor], joining spaceID: String?, movesAnchors: Bool, caller: SpaceToolCaller
    ) -> String? {
        for anchor in anchors {
            guard let key = anchor.key, let owner = workspaceStore.profile(anchoring: key), owner.id != spaceID else { continue }
            let belongs = "“\(MissionPromptText.quoted(anchor.name))” belongs to “\(MissionPromptText.quoted(owner.name))” "
                + "(\(owner.leadSpaceReference))"
            if leadWorkspace(inSpace: owner.id) != nil || hasRunningMergeQueue(inSpace: owner.id) {
                return belongs + ", whose Lead or merge queue works from it: only the user can move it, in Space Settings."
            }
            if let refusal = caller.anchorLossRefusal([anchor], from: owner.id) { return refusal }
            if !movesAnchors { return belongs + ": pass move_anchors: true to move it, if the user asked to." }
        }
        return nil
    }

    private func anchorsToRemove(_ queries: [String], in space: WorkspaceProfile) -> Result<[SpaceAnchor], SpaceRefusal> {
        let known = space.anchors.filter(\.isKnown)
        let spaceName = MissionPromptText.quoted(space.name)
        var found: [SpaceAnchor] = []
        for query in queries {
            let matches = matchingAnchors(query, in: known)
            guard let anchor = matches.first, matches.count == 1 else {
                return .failure(SpaceRefusal(message: matches.isEmpty
                    ? "No repository or folder of “\(spaceName)” matches “\(query)”."
                    : "Several repositories or folders of “\(spaceName)” match “\(query)”: pass its full path."))
            }
            if !found.contains(where: { $0.key == anchor.key }) { found.append(anchor) }
        }
        return .success(found)
    }

    /// By path (its folder, or a repository's git folder), else by name.
    private func matchingAnchors(_ query: String, in anchors: [SpaceAnchor]) -> [SpaceAnchor] {
        let path = (query as NSString).expandingTildeInPath
        let real = path.realPath ?? path
        let byPath = anchors.filter { anchor in
            var paths = [anchor.folder]
            if case .gitRepository(let commonDir) = anchor.kind { paths.append(commonDir) }
            return paths.compactMap { $0 }.contains { $0 == path || ($0.realPath ?? $0) == real }
        }
        return byPath.isEmpty ? anchors.filter { $0.name.caseInsensitiveCompare(query) == .orderedSame } : byPath
    }
}
