import Foundation

@MainActor
final class WorkspaceStore {
    private(set) var workspaces: [WorkspaceState] = []
    private(set) var profiles: [WorkspaceProfile] = [WorkspaceProfile.defaultProfile]
    private(set) var activeProfileID: String = WorkspaceProfile.defaultID
    private(set) var activeWorkspaceID: String?
    /// Deleted spaces' ids (see ProjectStore). Shells started in them keep the
    /// id in NIRUX_PROFILE_ID, so a request naming one goes to the default
    /// space, where their workspaces moved.
    var deletedProfileIDs: Set<String> = []
    /// -1 while no workspace is active: the active space is empty and
    /// shows `EmptySpaceView`. Keys, ⌘W and notifications then reach no
    /// workspace, not the first one of another space.
    var activeWorkspaceIndex: Int {
        get {
            guard let activeWorkspaceID,
                  let index = workspaces.firstIndex(where: { $0.id == activeWorkspaceID })
            else { return -1 }
            return index
        }
        set { selectWorkspace(at: newValue) }
    }

    var activeWorkspace: WorkspaceState? {
        guard workspaces.indices.contains(activeWorkspaceIndex) else { return nil }
        return workspaces[activeWorkspaceIndex]
    }

    var activeProfile: WorkspaceProfile {
        profiles.first { $0.id == activeProfileID } ?? WorkspaceProfile.defaultProfile
    }

    /// Every space, empty ones included: spaces persist (see `ProjectStore`),
    /// and selecting an empty one shows `EmptySpaceView`.
    var navigableProfiles: [WorkspaceProfile] { profiles }

    var visibleWorkspaceIndices: [Int] {
        visibleWorkspaceIndices(in: activeProfileID)
    }

    var activeVisibleWorkspacePosition: Int? {
        visibleWorkspaceIndices.firstIndex(of: activeWorkspaceIndex)
    }

    func replaceProfiles(_ newProfiles: [WorkspaceProfile], activeProfileID requestedActiveProfileID: String?) {
        profiles = Self.normalizedProfiles(newProfiles)
        let validIDs = Set(profiles.map { $0.id })
        activeProfileID = validIDs.contains(requestedActiveProfileID ?? "")
            ? (requestedActiveProfileID ?? WorkspaceProfile.defaultID)
            : WorkspaceProfile.defaultID
        reconcileSelection(preferActiveProfile: true)
    }

    func replaceWorkspaces(_ newWorkspaces: [WorkspaceState]) {
        workspaces = newWorkspaces
        for profileID in Set(workspaces.map(\.profileID)) { keepTreeOrder(in: profileID) }
        reconcileSelection(preferActiveProfile: true)
    }

    func appendWorkspace(_ workspace: WorkspaceState, activate: Bool = true) {
        workspaces.append(workspace)
        keepTreeOrder(in: workspace.profileID)
        if activate { selectWorkspace(id: workspace.id) }
    }

    func targetProfileID(for requestedProfileID: String?) -> String {
        guard let requestedProfileID = requestedProfileID?.trimmingCharacters(in: .whitespacesAndNewlines),
              !requestedProfileID.isEmpty
        else { return activeProfileID }
        if deletedProfileIDs.contains(requestedProfileID) { return WorkspaceProfile.defaultID }
        return profiles.contains { $0.id == requestedProfileID } ? requestedProfileID : activeProfileID
    }

    @discardableResult
    func removeWorkspace(_ workspace: WorkspaceState) -> WorkspaceState? {
        guard let index = workspaces.firstIndex(where: { $0 === workspace }) else { return nil }
        let removed = workspaces.remove(at: index)
        reconcileSelection(preferActiveProfile: true)
        return removed
    }

    @discardableResult
    func selectWorkspace(at index: Int) -> Bool {
        guard workspaces.indices.contains(index) else { return false }
        activeWorkspaceID = workspaces[index].id
        activeProfileID = workspaces[index].profileID
        return true
    }

    @discardableResult
    func selectWorkspace(id: String) -> Bool {
        guard let index = workspaces.firstIndex(where: { $0.id == id }) else { return false }
        return selectWorkspace(at: index)
    }

    /// Selects a space. An empty one is selected with no active workspace,
    /// and stays so until a workspace opens or moves in. So is one whose
    /// last workspace is closing.
    @discardableResult
    func selectProfile(_ profileID: String) -> Bool {
        guard profiles.contains(where: { $0.id == profileID }) else { return false }
        activeProfileID = profileID
        activeWorkspaceID = visibleWorkspaceIndices(in: profileID)
            .first { !workspaces[$0].isClosing }
            .map { workspaces[$0].id }
        return true
    }

    /// ⌘⌥←/→ cycles through spaces that have workspaces: an empty one
    /// shows only `EmptySpaceView`, where cycling would stop.
    @discardableResult
    func selectAdjacentProfile(delta: Int) -> WorkspaceProfile? {
        let candidates = profiles.filter { $0.id == activeProfileID || hasWorkspaces(in: $0.id) }
        guard candidates.count > 1,
              let current = candidates.firstIndex(where: { $0.id == activeProfileID })
        else { return nil }
        let nextIndex = (current + delta + candidates.count) % candidates.count
        let profile = candidates[nextIndex]
        selectProfile(profile.id)
        return profile
    }

    @discardableResult
    func selectAdjacentWorkspace(delta: Int) -> Int? {
        guard let index = adjacentWorkspaceIndex(delta: delta) else { return nil }
        selectWorkspace(at: index)
        return index
    }

    /// The workspace `selectAdjacentWorkspace` selects: the visible one
    /// `delta` places from the selected one, or the first visible one when
    /// the selected one isn't.
    func adjacentWorkspaceIndex(delta: Int) -> Int? {
        let visible = visibleWorkspaceIndices
        guard let current = visible.firstIndex(of: activeWorkspaceIndex) else { return visible.first }
        return visible.indices.contains(current + delta) ? visible[current + delta] : nil
    }

    /// Workspaces left once the closes in flight finish.
    var remainingWorkspaceCount: Int { workspaces.filter { !$0.isClosing }.count }

    /// The workspace to select when the one at `index` closes: the nearest
    /// active card in its space's sidebar list, below it first, then above;
    /// else the top active card of the first space that has one, in the
    /// space order `reconcileSelection` follows. Inactive workspaces are
    /// parked work: one takes over only when no active one is left, its own
    /// space's first. Workspaces with a close in flight don't count.
    func fallbackIndexAfterClosingWorkspace(at index: Int) -> Int? {
        guard workspaces.indices.contains(index) else { return nil }
        let isOpen = { (candidate: Int) in candidate != index && !self.workspaces[candidate].isClosing }
        let isActive = { (candidate: Int) in !self.workspaces[candidate].isInactive }
        let profileID = workspaces[index].profileID
        let list = visibleWorkspaceIndices(in: profileID)
        let position = list.firstIndex(of: index) ?? list.count
        let neighbours = (Array(list[position...]) + list[..<position].reversed()).filter(isOpen)
        if let neighbour = neighbours.first(where: isActive) { return neighbour }
        let otherSpaces = profiles.filter { $0.id != profileID }
            .flatMap { visibleWorkspaceIndices(in: $0.id) }
            .filter(isOpen)
        return otherSpaces.first(where: isActive)
            ?? neighbours.first
            ?? otherSpaces.first
            ?? workspaces.indices.first(where: isOpen)
    }

    @discardableResult
    func moveWorkspace(at index: Int, delta: Int) -> Bool {
        guard delta != 0, let (candidates, position) = visibleGroupPosition(of: index) else { return false }
        let newPosition = position + delta
        guard candidates.indices.contains(newPosition) else { return false }

        let workspace = workspaces[index]
        let targetWorkspace = workspaces[candidates[newPosition]]
        workspaces.remove(at: index)
        let adjustedTarget = workspaces.firstIndex { $0 === targetWorkspace } ?? workspaces.count
        let insertIndex = delta > 0 ? adjustedTarget + 1 : adjustedTarget
        workspaces.insert(workspace, at: min(insertIndex, workspaces.count))
        // Its children follow it.
        keepTreeOrder(in: workspace.profileID)
        reconcileSelection(preferActiveProfile: true)
        return true
    }

    /// Move a workspace to an absolute position within its own
    /// active/inactive group (0 = top of group). The position is clamped to
    /// the group's bounds; a move never crosses the active/inactive boundary.
    @discardableResult
    func moveWorkspace(at index: Int, toPosition targetPosition: Int) -> Bool {
        guard let (candidates, position) = visibleGroupPosition(of: index) else { return false }
        let clamped = max(0, min(targetPosition, candidates.count - 1))
        guard clamped != position else { return false }
        return moveWorkspace(at: index, delta: clamped - position)
    }

    /// A workspace's same-group neighbours within the visible (active
    /// profile) list, plus its position among them. The Lead is a group of
    /// its own: it stays on top, and nothing moves above it.
    private func visibleGroupPosition(of index: Int) -> (candidates: [Int], position: Int)? {
        guard workspaces.indices.contains(index) else { return nil }
        let isInactive = workspaces[index].isInactive
        let isLead = workspaces[index].isLead
        // Among its siblings: a child moves under its parent, a card with
        // children among the cards with none above them.
        let parents = activeParents(in: workspaces[index].profileID)
        let candidates = visibleWorkspaceIndices.filter {
            workspaces[$0].isInactive == isInactive && workspaces[$0].isLead == isLead && parents[$0] == parents[index]
        }
        guard let position = candidates.firstIndex(of: index) else { return nil }
        return (candidates, position)
    }

    /// The Lead is never parked.
    @discardableResult
    func setWorkspaceInactive(at index: Int, _ isInactive: Bool) -> Bool {
        guard workspaces.indices.contains(index), !(isInactive && workspaces[index].isLead) else { return false }
        workspaces[index].isInactive = isInactive
        // The top card takes over, not the Lead above the cards: keys typed
        // next would go into its prompt.
        let isActiveCard = { (candidate: Int) in !self.workspaces[candidate].isInactive }
        keepTreeOrder(in: workspaces[index].profileID)
        if activeWorkspaceIndex == index,
           isInactive,
           let firstActive = visibleWorkspaceIndices.first(where: { isActiveCard($0) && !self.workspaces[$0].isLead })
               ?? visibleWorkspaceIndices.first(where: isActiveCard) {
            activeWorkspaceID = workspaces[firstActive].id
        }
        reconcileSelection(preferActiveProfile: true)
        return true
    }

    /// A new space, in the color asked for or one no space uses. Its
    /// anchors are taken from the spaces that had them (one space per
    /// anchor). `select` makes it the active space, with no workspace yet.
    @discardableResult
    func createProfile(
        named baseName: String, colorHex: String? = nil, anchors: [SpaceAnchor] = [], select: Bool = true
    ) -> WorkspaceProfile {
        let name = uniqueProfileName(baseName)
        let profile = WorkspaceProfile(id: UUID().uuidString, name: name, colorHex: colorHex ?? unusedColorHex())
        profiles.append(profile)
        setAnchors(anchors, forProfile: profile.id)
        if select {
            activeProfileID = profile.id
            activeWorkspaceID = nil
        }
        return profiles.first { $0.id == profile.id } ?? profile
    }

    /// The first palette color no space uses, else the next in turn.
    func unusedColorHex() -> String {
        let usedColors = Set(profiles.map { $0.colorHex.uppercased() })
        return WorkspaceProfile.palette.first { !usedColors.contains($0.hex.uppercased()) }?.hex
            ?? WorkspaceProfile.colorHex(for: profiles.count)
    }

    // MARK: - Anchors (see SpaceAnchor)

    /// The space a repository or folder (`SpaceAnchor.key`) belongs to.
    func profile(anchoring key: String) -> WorkspaceProfile? {
        profiles.first { $0.anchors.contains { $0.key == key } }
    }

    /// Replaces a space's anchors, taking each from the space that had it.
    /// The default space has none: refused. Unknown kinds it already had
    /// stay.
    @discardableResult
    func setAnchors(_ anchors: [SpaceAnchor], forProfile id: String) -> Bool {
        guard id != WorkspaceProfile.defaultID, let index = profiles.firstIndex(where: { $0.id == id }) else { return false }
        let known = anchors.filter(\.isKnown)
        let keys = Set(known.compactMap(\.key))
        for other in profiles.indices where other != index {
            profiles[other].anchors.removeAll { $0.key.map(keys.contains) ?? false }
            profiles[other].anchors = profiles[other].anchors.normalizedAnchors()
        }
        profiles[index].anchors = (known + profiles[index].anchors.filter { !$0.isKnown }).normalizedAnchors()
        return true
    }

    /// Adds a repository or folder to a space, taking it from the space that
    /// had it. The first one becomes the default.
    @discardableResult
    func addAnchor(_ anchor: SpaceAnchor, toProfile id: String) -> Bool {
        guard anchor.isKnown, let profile = profiles.first(where: { $0.id == id }) else { return false }
        var anchors = profile.anchors.filter { $0.key != anchor.key }
        var added = anchor
        added.isDefault = !anchors.contains(where: \.isKnown)
        anchors.append(added)
        return setAnchors(anchors, forProfile: id)
    }

    /// Removes one; the next one becomes the default if it was.
    @discardableResult
    func removeAnchor(key: String, fromProfile id: String) -> Bool {
        guard let index = profiles.firstIndex(where: { $0.id == id }),
              profiles[index].anchors.contains(where: { $0.key == key })
        else { return false }
        profiles[index].anchors.removeAll { $0.key == key }
        profiles[index].anchors = profiles[index].anchors.normalizedAnchors()
        return true
    }

    @discardableResult
    func makeDefaultAnchor(key: String, inProfile id: String) -> Bool {
        guard let index = profiles.firstIndex(where: { $0.id == id }),
              profiles[index].anchors.contains(where: { $0.key == key })
        else { return false }
        for anchor in profiles[index].anchors.indices where profiles[index].anchors[anchor].isKnown {
            profiles[index].anchors[anchor].isDefault = profiles[index].anchors[anchor].key == key
        }
        return true
    }

    @discardableResult
    func renameProfile(id: String, to newName: String) -> Bool {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let index = profiles.firstIndex(where: { $0.id == id })
        else { return false }

        profiles[index].name = uniqueProfileName(trimmed, excluding: id)
        return true
    }

    /// Deletes a space. Its workspaces move to the default space, which can't
    /// be deleted. Returns false for the default or an unknown space.
    @discardableResult
    func deleteProfile(id: String) -> Bool {
        guard id != WorkspaceProfile.defaultID,
              let index = profiles.firstIndex(where: { $0.id == id })
        else { return false }
        for workspace in workspaces where workspace.profileID == id {
            workspace.profileID = WorkspaceProfile.defaultID
            // General has no Lead: it becomes a plain workspace there.
            workspace.isLead = false
        }
        profiles.remove(at: index)
        deletedProfileIDs.insert(id)
        keepTreeOrder(in: WorkspaceProfile.defaultID)
        reconcileSelection(preferActiveProfile: true)
        return true
    }

    @discardableResult
    func setProfileColor(id: String, colorHex: String) -> Bool {
        guard let index = profiles.firstIndex(where: { $0.id == id }) else { return false }
        profiles[index].colorHex = colorHex
        return true
    }

    /// Moves a workspace to the end of another space. Moving the active
    /// workspace selects its neighbour in the space it leaves, or follows it
    /// when that space is left empty.
    @discardableResult
    func moveWorkspace(at index: Int, toProfile profileID: String) -> Bool {
        guard workspaces.indices.contains(index),
              profiles.contains(where: { $0.id == profileID }),
              workspaces[index].profileID != profileID,
              // A Lead sees only its own space.
              !workspaces[index].isLead
        else { return false }
        let workspace = workspaces[index]
        let wasActive = workspace.id == activeWorkspaceID
        // The card above it in the sidebar, else the one below.
        let visible = visibleWorkspaceIndices(in: workspace.profileID)
        let position = visible.firstIndex(of: index) ?? 0
        let isCandidate = { (candidate: Int) in candidate != index && !self.workspaces[candidate].isClosing }
        let neighbourIndex = visible[..<position].last(where: isCandidate)
            ?? visible[position...].first(where: isCandidate)
        let neighbourID = neighbourIndex.map { workspaces[$0].id }

        workspace.profileID = profileID
        workspaces.remove(at: index)
        workspaces.append(workspace)
        keepTreeOrder(in: profileID)
        if wasActive { selectWorkspace(id: neighbourID ?? workspace.id) }
        reconcileSelection(preferActiveProfile: true)
        return true
    }

    /// Organize › Move Out of “<task>”: a sub-task listed under its task
    /// becomes a task of its own, listed after that task's other sub-tasks,
    /// for good.
    @discardableResult
    func moveOutOfParent(at index: Int) -> Bool {
        guard workspaces.indices.contains(index), activeParents(in: workspaces[index].profileID)[index] != nil else { return false }
        workspaces[index].parentWorkspaceID = nil
        keepTreeOrder(in: workspaces[index].profileID)
        return true
    }

    /// The sidebar's order: the Lead, the active workspaces, each followed
    /// by its sub-tasks (depth first), the inactive ones.
    func visibleWorkspaceIndices(in profileID: String) -> [Int] {
        let matching = workspaces.indices.filter { workspaces[$0].profileID == profileID }
        let active = matching.filter { !workspaces[$0].isLead && !workspaces[$0].isInactive }
        return matching.filter { workspaces[$0].isLead }
            + treeOrder(active, parents: activeParents(in: profileID)).map(\.index)
            + matching.filter { !workspaces[$0].isLead && workspaces[$0].isInactive }
    }

    /// Each active workspace listed under a parent (drawn indented), and
    /// that parent, by index: the task it is a sub-task of
    /// (`WorkspaceState.parentWorkspaceID`) when that one is open in the
    /// same space, active, and not the Lead (the Lead's tasks are the
    /// space's list itself).
    func activeParents(in profileID: String) -> [Int: Int] {
        let active = workspaces.indices.filter {
            workspaces[$0].profileID == profileID && !workspaces[$0].isLead && !workspaces[$0].isInactive
        }
        let byID = Dictionary(active.map { (workspaces[$0].id, $0) }, uniquingKeysWith: { first, _ in first })
        var parents: [Int: Int] = [:]
        for index in active {
            if let parentID = workspaces[index].parentWorkspaceID, let parent = byID[parentID], parent != index {
                parents[index] = parent
            }
        }
        // A loop of parents (a hand-edited state) lists at the top level.
        let tree = treeOrder(active, parents: parents)
        let nested = Set(tree.filter(\.nested).map(\.index))
        return parents.filter { nested.contains($0.key) }
    }

    /// The store keeps a space's active workspaces in the sidebar's order,
    /// each followed by its children: a child its parent lets go (closed,
    /// archived, moved away) stays where it was listed.
    private func keepTreeOrder(in profileID: String) {
        let active = workspaces.indices.filter {
            workspaces[$0].profileID == profileID && !workspaces[$0].isLead && !workspaces[$0].isInactive
        }
        let order = treeOrder(active, parents: activeParents(in: profileID)).map(\.index)
        guard order != active else { return }
        let reordered = order.map { workspaces[$0] }
        for (slot, index) in active.enumerated() { workspaces[index] = reordered[slot] }
    }

    /// Roots in store order, each followed by its children, depth first. A
    /// loop of parents (a hand-edited state) lists at the top level.
    private func treeOrder(_ indices: [Int], parents: [Int: Int]) -> [(index: Int, nested: Bool)] {
        var children: [Int: [Int]] = [:]
        for index in indices { if let parent = parents[index] { children[parent, default: []].append(index) } }
        var result: [(index: Int, nested: Bool)] = []
        var visited = Set<Int>()
        func visit(_ index: Int, nested: Bool) {
            guard visited.insert(index).inserted else { return }
            result.append((index, nested))
            for child in children[index] ?? [] { visit(child, nested: true) }
        }
        for index in indices where parents[index] == nil { visit(index, nested: false) }
        for index in indices where !visited.contains(index) { visit(index, nested: false) }
        return result
    }

    /// The space's Lead, unless it is closing (docs/spaces.md, "The Lead").
    func leadWorkspace(inSpace profileID: String) -> WorkspaceState? {
        workspaces.first { $0.profileID == profileID && $0.isLead && !$0.isClosing }
    }

    private func reconcileSelection(preferActiveProfile: Bool) {
        let activeSpaceIsGone = !profiles.contains { $0.id == activeProfileID }
        if activeSpaceIsGone { activeProfileID = WorkspaceProfile.defaultID }

        // An empty space on screen stays there while workspaces elsewhere
        // close or move, until one opens or moves in. Once it is deleted,
        // the selection goes where the work is.
        if !activeSpaceIsGone, activeWorkspaceID == nil, !hasWorkspaces(in: activeProfileID) { return }

        if preferActiveProfile,
           !hasWorkspaces(in: activeProfileID),
           let profileID = firstProfileIDWithWorkspaces() {
            activeProfileID = profileID
        }

        if let activeWorkspaceID,
           let index = workspaces.firstIndex(where: { $0.id == activeWorkspaceID }) {
            if !preferActiveProfile || workspaces[index].profileID == activeProfileID { return }
        }

        if preferActiveProfile, let first = visibleWorkspaceIndices.first {
            activeWorkspaceID = workspaces[first].id
            return
        }

        if let first = workspaces.indices.first {
            activeWorkspaceID = workspaces[first].id
            activeProfileID = workspaces[first].profileID
        } else {
            activeWorkspaceID = nil
        }
    }

    private func hasWorkspaces(in profileID: String) -> Bool {
        workspaces.contains { $0.profileID == profileID }
    }

    private func firstProfileIDWithWorkspaces() -> String? {
        let profileIDs = Set(workspaces.map { $0.profileID })
        return profiles.first { profileIDs.contains($0.id) }?.id ?? workspaces.first?.profileID
    }

    private func uniqueProfileName(_ base: String, excluding excludedID: String? = nil) -> String {
        let trimmed = base.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallback = trimmed.isEmpty ? "space" : trimmed
        let existing = Set(profiles.compactMap { profile in
            profile.id == excludedID ? nil : profile.name
        })
        guard existing.contains(fallback) else { return fallback }
        var idx = 2
        while existing.contains("\(fallback) \(idx)") { idx += 1 }
        return "\(fallback) \(idx)"
    }

    /// The default space (General) always exists and comes first, so every
    /// list of spaces starts with it: the switcher, the menus, Move to Space,
    /// New Space…. It has no repositories or folders; each other one
    /// belongs to the first space listing it, and each space has one default
    /// anchor (a hand-edited or merged file may break all three).
    private static func normalizedProfiles(_ profiles: [WorkspaceProfile]) -> [WorkspaceProfile] {
        var general = profiles.first { $0.id == WorkspaceProfile.defaultID } ?? WorkspaceProfile.defaultProfile
        general.anchors.removeAll(where: \.isKnown)
        var result = [general] + profiles.filter { $0.id != WorkspaceProfile.defaultID }
        var claimed = Set<String>()
        for index in result.indices {
            result[index].anchors = result[index].anchors.filter { anchor in
                anchor.key.map { claimed.insert($0).inserted } ?? true
            }.normalizedAnchors()
        }
        return result
    }
}
