import AppKit

// MARK: - The Lead's space management tools (see LeadTools)

extension WorkspaceProfile {
    var leadSpaceReference: String { LeadTools.spaceIDPrefix + id }
}

extension NiruxShellView {
    // MARK: list_tasks (with optional space)

    func leadListTasks(_ arguments: [String: Any], in callerSpace: WorkspaceProfile, lead leadID: String, answer: @escaping LeadAnswer) {
        guard let requested = LeadTools.string(arguments, "space") else {
            return answer(leadTaskList(in: callerSpace, lead: leadID), false)
        }
        switch resolveSpace(requested) {
        case .success(let target):
            answer(leadTaskList(in: target, lead: leadID), false)
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

    func leadCreateSpace(_ arguments: [String: Any], answer: @escaping LeadAnswer) {
        guard let name = LeadTools.string(arguments, "name") else {
            return answer("name must be a non-empty single-line string.", true)
        }
        if let duplicate = duplicateSpace(named: name, excluding: nil) {
            return answer("A space named “\(MissionPromptText.quoted(duplicate.name))” already exists.", true)
        }
        let colorHex: String
        if let rawColor = LeadTools.string(arguments, "color") {
            guard let normalized = LeadTools.normalizedColorHex(rawColor) else {
                return answer("color must be a valid #RRGGBB hex color.", true)
            }
            colorHex = normalized
        } else {
            colorHex = workspaceStore.unusedColorHex()
        }
        let anchorPaths = (LeadTools.stringArray(arguments, "anchors") ?? .some([])) ?? []
        let moveAnchors = LeadTools.optionalFlag(arguments, "move_anchors") == true
        guard !anchorPaths.isEmpty else {
            return finishCreateSpace(name: name, colorHex: colorHex, anchors: [], moveAnchors: false, answer: answer)
        }
        guard projectStore.availability == .writable else {
            return answer(Self.anchorsLockedMessage, true)
        }
        resolveAnchorPathsOffMain(anchorPaths) { [weak self] resolved in
            guard let self else { return answer("Nirux closed meanwhile: nothing was created.", true) }
            switch self.validateResolvedAnchors(resolved) {
            case .failure(let refusal):
                answer(refusal.message, true)
            case .success(let anchors):
                self.finishCreateSpace(name: name, colorHex: colorHex, anchors: anchors, moveAnchors: moveAnchors, answer: answer)
            }
        }
    }

    private func finishCreateSpace(
        name: String, colorHex: String, anchors: [SpaceAnchor], moveAnchors: Bool, answer: @escaping LeadAnswer
    ) {
        if let duplicate = duplicateSpace(named: name, excluding: nil) {
            return answer("A space named “\(MissionPromptText.quoted(duplicate.name))” already exists.", true)
        }
        if !anchors.isEmpty {
            guard projectStore.availability == .writable else { return answer(Self.anchorsLockedMessage, true) }
            if let conflict = anchorOwnershipConflict(for: anchors, targetSpaceID: nil, moveAnchors: moveAnchors) {
                return answer(conflict, true)
            }
        }
        let created = workspaceStore.createProfile(named: name, colorHex: colorHex, anchors: anchors, select: false)
        updateSidebar()
        saveState()
        spaceSettingsSpacesChanged()
        let anchorSummary = created.anchors.filter(\.isKnown).isEmpty
            ? ""
            : " with anchors: " + created.anchors.filter(\.isKnown).map(\.name).joined(separator: ", ")
        answer(
            "Created space “\(MissionPromptText.quoted(created.name))” (\(created.leadSpaceReference), \(created.colorHex))\(anchorSummary).",
            false
        )
    }

    // MARK: edit_space

    func leadEditSpace(_ arguments: [String: Any], answer: @escaping LeadAnswer) {
        let spaceQuery = LeadTools.string(arguments, "space") ?? ""
        let target: WorkspaceProfile
        switch resolveSpace(spaceQuery) {
        case .success(let resolved): target = resolved
        case .failure(let refusal): return answer(refusal.message, true)
        }
        let newName = LeadTools.string(arguments, "name")
        let newColor = LeadTools.string(arguments, "color").flatMap(LeadTools.normalizedColorHex)
        let addPaths = (LeadTools.stringArray(arguments, "add_anchors") ?? .some([])) ?? []
        let removeQueries = (LeadTools.stringArray(arguments, "remove_anchors") ?? .some([])) ?? []
        let moveAnchors = LeadTools.optionalFlag(arguments, "move_anchors") == true

        if let refusal = editSpaceRefusal(
            target: target, newName: newName, addPaths: addPaths, removeQueries: removeQueries
        ) {
            return answer(refusal, true)
        }
        let targetID = target.id
        guard !addPaths.isEmpty else {
            return finishEditSpace(
                spaceID: targetID, newName: newName, newColor: newColor,
                anchorsToAdd: [], removeQueries: removeQueries, moveAnchors: moveAnchors, answer: answer
            )
        }
        resolveAnchorPathsOffMain(addPaths) { [weak self] resolved in
            guard let self else { return answer("Nirux closed meanwhile: nothing was changed.", true) }
            switch self.validateResolvedAnchors(resolved) {
            case .failure(let refusal):
                answer(refusal.message, true)
            case .success(let anchors):
                self.finishEditSpace(
                    spaceID: targetID, newName: newName, newColor: newColor,
                    anchorsToAdd: anchors, removeQueries: removeQueries, moveAnchors: moveAnchors, answer: answer
                )
            }
        }
    }

    private func editSpaceRefusal(
        target: WorkspaceProfile, newName: String?, addPaths: [String], removeQueries: [String]
    ) -> String? {
        if let newName {
            if target.id == WorkspaceProfile.defaultID, newName == WorkspaceProfile.legacyDefaultName {
                return "The default space cannot be named “\(WorkspaceProfile.legacyDefaultName)” (Nirux renames it back to General on launch)."
            }
            if let duplicate = duplicateSpace(named: newName, excluding: target.id) {
                return "A space named “\(MissionPromptText.quoted(duplicate.name))” already exists."
            }
        }
        if !addPaths.isEmpty || !removeQueries.isEmpty {
            if target.id == WorkspaceProfile.defaultID {
                return "The default space “\(MissionPromptText.quoted(target.name))” cannot have repositories or folders."
            }
            guard projectStore.availability == .writable else { return Self.anchorsLockedMessage }
        }
        return nil
    }

    // swiftlint:disable:next function_parameter_count
    private func finishEditSpace(
        spaceID: String, newName: String?, newColor: String?,
        anchorsToAdd: [SpaceAnchor], removeQueries: [String], moveAnchors: Bool, answer: @escaping LeadAnswer
    ) {
        guard let target = profiles.first(where: { $0.id == spaceID }) else {
            return answer("That space no longer exists.", true)
        }
        if let refusal = editSpaceRefusal(
            target: target, newName: newName, addPaths: anchorsToAdd.isEmpty ? [] : ["pending"], removeQueries: removeQueries
        ) {
            return answer(refusal, true)
        }
        let keysToRemove: [(key: String, name: String)]
        switch resolveAnchorsToRemove(removeQueries, in: target) {
        case .failure(let refusal): return answer(refusal.message, true)
        case .success(let matches): keysToRemove = matches
        }
        if let conflict = anchorOwnershipConflict(for: anchorsToAdd, targetSpaceID: target.id, moveAnchors: moveAnchors) {
            return answer(conflict, true)
        }

        var changes: [String] = []
        let oldName = target.name
        if let newName, newName != oldName {
            _ = workspaceStore.renameProfile(id: target.id, to: newName)
            changes.append("renamed from “\(MissionPromptText.quoted(oldName))” to “\(MissionPromptText.quoted(newName))”")
        }
        if let newColor, newColor.caseInsensitiveCompare(target.colorHex) != .orderedSame {
            _ = workspaceStore.setProfileColor(id: target.id, colorHex: newColor)
            changes.append("color \(newColor)")
        }
        for item in keysToRemove {
            if workspaceStore.removeAnchor(key: item.key, fromProfile: target.id) {
                changes.append("removed anchor “\(MissionPromptText.quoted(item.name))”")
            }
        }
        for anchor in anchorsToAdd {
            let current = profiles.first { $0.id == target.id }
            if current?.anchors.contains(where: { $0.key == anchor.key }) == true { continue }
            if workspaceStore.addAnchor(anchor, toProfile: target.id) {
                changes.append("added anchor “\(MissionPromptText.quoted(anchor.name))”")
            }
        }
        guard !changes.isEmpty else {
            let currentName = profiles.first { $0.id == target.id }?.name ?? target.name
            return answer("No changes made to “\(MissionPromptText.quoted(currentName))” (\(target.leadSpaceReference)).", false)
        }
        updateSidebar()
        saveState()
        spaceSettingsSpacesChanged()
        let updated = profiles.first { $0.id == target.id } ?? target
        answer("Updated “\(MissionPromptText.quoted(updated.name))” (\(updated.leadSpaceReference)): \(changes.joined(separator: ", ")).", false)
    }

    // MARK: delete_space

    func leadDeleteSpace(_ arguments: [String: Any], callerSpace: WorkspaceProfile, answer: @escaping LeadAnswer) {
        let query = LeadTools.string(arguments, "space") ?? ""
        let target: WorkspaceProfile
        switch resolveSpace(query) {
        case .success(let resolved): target = resolved
        case .failure(let refusal): return answer(refusal.message, true)
        }
        let targetName = MissionPromptText.quoted(target.name)
        guard target.id != WorkspaceProfile.defaultID else {
            return answer("The default space “\(targetName)” cannot be deleted.", true)
        }
        guard target.id != callerSpace.id else {
            return answer("You cannot delete your own space “\(targetName)”.", true)
        }
        guard projectStore.availability == .writable else {
            return answer("Spaces can't be deleted right now: \(Self.anchorsLockedMessage).", true)
        }
        guard !hasRunningMergeQueue(inSpace: target.id) else {
            return answer("“\(targetName)” has a running merge queue: stop it before deleting the space.", true)
        }
        if leadWorkspace(inSpace: target.id) != nil {
            return answer("“\(targetName)” has an active Lead workspace: turn off its Lead in Space Settings before deleting the space.", true)
        }
        if workspaces.contains(where: { $0.profileID == target.id && $0.isClosing }) {
            return answer("“\(targetName)” has a workspace that is closing: try again in a moment.", true)
        }

        let destination: WorkspaceProfile?
        if let moveTarget = LeadTools.string(arguments, "move_tasks_to") {
            switch resolveSpace(moveTarget) {
            case .success(let resolved):
                guard resolved.id != target.id else {
                    return answer("move_tasks_to must name a different space than “\(targetName)”.", true)
                }
                destination = resolved
            case .failure(let refusal):
                return answer(refusal.message, true)
            }
        } else {
            destination = nil
        }

        let remaining = workspaceStore.visibleWorkspaceIndices(in: target.id)
            .map { workspaces[$0] }
            .filter { !$0.isLead && !$0.isClosing }
        if !remaining.isEmpty {
            guard let destination else {
                let countText = remaining.count == 1 ? "1 task" : "\(remaining.count) tasks"
                return answer("“\(targetName)” still has \(countText): pass move_tasks_to to move them before deleting.", true)
            }
            for task in remaining {
                if let refusal = moveRefusal(workspaceID: task.id, profileID: destination.id) {
                    return answer(refusal, true)
                }
            }
            for task in remaining {
                moveWorkspaceToSpace(workspaceID: task.id, profileID: destination.id, refocusing: false)
            }
        }

        guard deleteSpace(profileID: target.id, refocusing: false) else {
            return answer("Could not delete space “\(targetName)”.", true)
        }
        if !remaining.isEmpty, let destination {
            let countText = remaining.count == 1 ? "1 task" : "\(remaining.count) tasks"
            return answer(
                "Moved \(countText) to “\(MissionPromptText.quoted(destination.name))” (\(destination.leadSpaceReference)) "
                    + "and deleted space “\(targetName)” (\(target.leadSpaceReference)).",
                false
            )
        }
        answer("Deleted space “\(targetName)” (\(target.leadSpaceReference)).", false)
    }

    // MARK: move_task_to_space

    func leadMoveTaskToSpace(_ arguments: [String: Any], callerSpace: WorkspaceProfile, answer: @escaping LeadAnswer) {
        let taskQuery = LeadTools.string(arguments, "task") ?? ""
        let toQuery = LeadTools.string(arguments, "to_space") ?? ""
        let sourceSpace: WorkspaceProfile
        if let fromQuery = LeadTools.string(arguments, "from_space") {
            switch resolveSpace(fromQuery) {
            case .success(let resolved): sourceSpace = resolved
            case .failure(let refusal): return answer(refusal.message, true)
            }
        } else {
            sourceSpace = callerSpace
        }
        let targetSpace: WorkspaceProfile
        switch resolveSpace(toQuery) {
        case .success(let resolved): targetSpace = resolved
        case .failure(let refusal): return answer(refusal.message, true)
        }

        let task: WorkspaceState
        switch resolveTaskForSpaceMove(taskQuery, in: sourceSpace) {
        case .success(let found): task = found
        case .failure(let refusal): return answer(refusal.message, true)
        }
        let title = MissionPromptText.quoted(task.title)
        if task.profileID == targetSpace.id {
            return answer("“\(title)” is already in “\(MissionPromptText.quoted(targetSpace.name))” (\(targetSpace.leadSpaceReference)).", false)
        }
        if let refusal = moveRefusal(workspaceID: task.id, profileID: targetSpace.id) {
            return answer(refusal, true)
        }
        guard let index = workspaces.firstIndex(where: { $0 === task }),
              workspaceStore.canMoveWorkspace(at: index, toProfile: targetSpace.id)
        else {
            return answer("“\(title)” cannot be moved to “\(MissionPromptText.quoted(targetSpace.name))”.", true)
        }
        moveWorkspaceToSpace(workspaceID: task.id, profileID: targetSpace.id, refocusing: false)
        answer(
            "Moved “\(title)” from “\(MissionPromptText.quoted(sourceSpace.name))” "
                + "to “\(MissionPromptText.quoted(targetSpace.name))” (\(targetSpace.leadSpaceReference)).",
            false
        )
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

    private func hasRunningMergeQueue(inSpace profileID: String) -> Bool {
        mergeQueues(of: profileID).contains { queue in
            queue.refreshSavedForLead()
            return queue.isRunning || queue.runsElsewhere
        }
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

    private struct ResolvedAnchorPath: Sendable {
        let raw: String
        let identity: FolderIdentity?
    }

    private func resolveAnchorPathsOffMain(
        _ paths: [String], then done: @escaping @MainActor @Sendable ([ResolvedAnchorPath]) -> Void
    ) {
        let timeout = Self.anchorPickTimeout
        Self.offMain({
            paths.map { raw in
                let expanded = (raw as NSString).expandingTildeInPath
                return ResolvedAnchorPath(raw: raw, identity: FolderIdentity.identify(expanded, timeout: timeout))
            }
        }, then: done)
    }

    private func validateResolvedAnchors(_ resolved: [ResolvedAnchorPath]) -> Result<[SpaceAnchor], SpaceRefusal> {
        var anchors: [SpaceAnchor] = []
        var seenKeys = Set<String>()
        for entry in resolved {
            guard let identity = entry.identity else {
                return .failure(SpaceRefusal(message: "Path does not exist or is not a directory: \(entry.raw)"))
            }
            let anchor = identity.anchor
            if case .folder(let path) = anchor.kind, isTooBroadForAFolderAnchor(path) {
                return .failure(SpaceRefusal(message: tooBroadFolderMessage(path)))
            }
            if let key = anchor.key, seenKeys.insert(key).inserted {
                anchors.append(anchor)
            }
        }
        return .success(anchors)
    }

    private func anchorOwnershipConflict(for anchors: [SpaceAnchor], targetSpaceID: String?, moveAnchors: Bool) -> String? {
        guard !moveAnchors else { return nil }
        for anchor in anchors {
            guard let key = anchor.key, let owner = workspaceStore.profile(anchoring: key), owner.id != targetSpaceID else { continue }
            return "“\(MissionPromptText.quoted(anchor.name))” already belongs to “\(MissionPromptText.quoted(owner.name))” "
                + "(\(owner.leadSpaceReference)): remove it there first or pass move_anchors: true."
        }
        return nil
    }

    private func resolveAnchorsToRemove(
        _ queries: [String], in space: WorkspaceProfile
    ) -> Result<[(key: String, name: String)], SpaceRefusal> {
        let known = space.anchors.filter(\.isKnown)
        var matched: [(key: String, name: String)] = []
        var seen = Set<String>()
        for raw in queries {
            let matches = matchingAnchors(raw, in: known)
            if matches.isEmpty {
                return .failure(SpaceRefusal(message: "No anchor matching “\(raw)” in “\(MissionPromptText.quoted(space.name))”."))
            }
            if matches.count > 1 {
                return .failure(SpaceRefusal(
                    message: "Several anchors in “\(MissionPromptText.quoted(space.name))” match “\(raw)”: pass the anchor's full path."
                ))
            }
            if let key = matches[0].key, seen.insert(key).inserted {
                matched.append((key: key, name: matches[0].name))
            }
        }
        return .success(matched)
    }

    private func matchingAnchors(_ raw: String, in anchors: [SpaceAnchor]) -> [SpaceAnchor] {
        let expanded = (raw as NSString).expandingTildeInPath
        let standardized = URL(fileURLWithPath: expanded).standardizedFileURL.path
        let real = expanded.realPath ?? standardized
        let byPath = anchors.filter { anchor in
            if anchor.key == raw { return true }
            let paths = anchorComparablePaths(anchor)
            return paths.contains(raw) || paths.contains(expanded) || paths.contains(standardized) || paths.contains(real)
        }
        if !byPath.isEmpty { return byPath }
        return anchors.filter { $0.name.caseInsensitiveCompare(raw) == .orderedSame }
    }

    private func anchorComparablePaths(_ anchor: SpaceAnchor) -> Set<String> {
        var paths: Set<String> = []
        if let folder = anchor.folder {
            paths.insert(folder)
            paths.insert(URL(fileURLWithPath: folder).standardizedFileURL.path)
            if let real = folder.realPath { paths.insert(real) }
        }
        switch anchor.kind {
        case .gitRepository(let commonDir):
            paths.insert(commonDir)
            if let real = commonDir.realPath { paths.insert(real) }
        case .folder(let path):
            paths.insert(path)
            if let real = path.realPath { paths.insert(real) }
        case .unknown:
            break
        }
        return paths
    }
}
