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

    var activeWorkspaceIndex: Int {
        get {
            guard let activeWorkspaceID,
                  let index = workspaces.firstIndex(where: { $0.id == activeWorkspaceID })
            else { return workspaces.indices.first ?? 0 }
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
    /// and selecting an empty one opens a workspace in it.
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
        reconcileSelection(preferActiveProfile: true)
    }

    func appendWorkspace(_ workspace: WorkspaceState, activate: Bool = true) {
        workspaces.append(workspace)
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

    /// Selects a space. An empty one is selected with no active workspace:
    /// the caller opens one in it.
    @discardableResult
    func selectProfile(_ profileID: String) -> Bool {
        guard profiles.contains(where: { $0.id == profileID }) else { return false }
        activeProfileID = profileID
        activeWorkspaceID = visibleWorkspaceIndices(in: profileID).first.map { workspaces[$0].id }
        return true
    }

    /// ⌘⌥←/→ cycles through spaces that have workspaces: stepping onto an
    /// empty one would open a workspace each time it passes.
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
        let visible = visibleWorkspaceIndices
        guard let current = visible.firstIndex(of: activeWorkspaceIndex) else {
            if let first = visible.first { selectWorkspace(at: first); return first }
            return nil
        }
        let next = current + delta
        guard visible.indices.contains(next) else { return nil }
        let index = visible[next]
        selectWorkspace(at: index)
        return index
    }

    /// Workspaces left once the closes in flight finish.
    var remainingWorkspaceCount: Int { workspaces.filter { !$0.isClosing }.count }

    func fallbackIndexAfterClosingWorkspace(at index: Int) -> Int? {
        let visible = visibleWorkspaceIndices.filter { $0 != index && !workspaces[$0].isClosing }
        return visible.last(where: { $0 < index }) ?? visible.first ?? fallbackGlobalIndex(excluding: index)
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
    /// profile) list, plus its position among them.
    private func visibleGroupPosition(of index: Int) -> (candidates: [Int], position: Int)? {
        guard workspaces.indices.contains(index) else { return nil }
        let isInactive = workspaces[index].isInactive
        let candidates = visibleWorkspaceIndices.filter { workspaces[$0].isInactive == isInactive }
        guard let position = candidates.firstIndex(of: index) else { return nil }
        return (candidates, position)
    }

    @discardableResult
    func setWorkspaceInactive(at index: Int, _ isInactive: Bool) -> Bool {
        guard workspaces.indices.contains(index) else { return false }
        workspaces[index].isInactive = isInactive
        if activeWorkspaceIndex == index,
           isInactive,
           let firstActive = visibleWorkspaceIndices.first(where: { !workspaces[$0].isInactive }) {
            activeWorkspaceID = workspaces[firstActive].id
        }
        reconcileSelection(preferActiveProfile: true)
        return true
    }

    func createProfile(named baseName: String) -> WorkspaceProfile {
        let name = uniqueProfileName(baseName)
        let usedColors = Set(profiles.map { $0.colorHex.uppercased() })
        let profile = WorkspaceProfile(
            id: UUID().uuidString,
            name: name,
            colorHex: WorkspaceProfile.palette.first { !usedColors.contains($0.hex.uppercased()) }?.hex
                ?? WorkspaceProfile.colorHex(for: profiles.count)
        )
        profiles.append(profile)
        activeProfileID = profile.id
        activeWorkspaceID = nil
        return profile
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
        }
        profiles.remove(at: index)
        deletedProfileIDs.insert(id)
        if activeProfileID == id { activeProfileID = WorkspaceProfile.defaultID }
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
              workspaces[index].profileID != profileID
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
        if wasActive { selectWorkspace(id: neighbourID ?? workspace.id) }
        reconcileSelection(preferActiveProfile: true)
        return true
    }

    func visibleWorkspaceIndices(in profileID: String) -> [Int] {
        let matching = workspaces.indices.filter { workspaces[$0].profileID == profileID }
        return matching.filter { !workspaces[$0].isInactive } + matching.filter { workspaces[$0].isInactive }
    }

    private func reconcileSelection(preferActiveProfile: Bool) {
        if !profiles.contains(where: { $0.id == activeProfileID }) {
            activeProfileID = WorkspaceProfile.defaultID
        }

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

    private func fallbackGlobalIndex(excluding index: Int) -> Int? {
        workspaces.indices.first { $0 != index && !workspaces[$0].isClosing }
    }

    private func uniqueProfileName(_ base: String, excluding excludedID: String? = nil) -> String {
        let trimmed = base.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallback = trimmed.isEmpty ? "profile" : trimmed
        let existing = Set(profiles.compactMap { profile in
            profile.id == excludedID ? nil : profile.name
        })
        guard existing.contains(fallback) else { return fallback }
        var idx = 2
        while existing.contains("\(fallback) \(idx)") { idx += 1 }
        return "\(fallback) \(idx)"
    }

    private static func normalizedProfiles(_ profiles: [WorkspaceProfile]) -> [WorkspaceProfile] {
        var result = profiles.isEmpty ? [WorkspaceProfile.defaultProfile] : profiles
        if !result.contains(where: { $0.id == WorkspaceProfile.defaultID }) {
            result.insert(WorkspaceProfile.defaultProfile, at: 0)
        }
        return result
    }
}
