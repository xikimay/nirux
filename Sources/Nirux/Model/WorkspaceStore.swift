import Foundation

@MainActor
final class WorkspaceStore {
    private(set) var workspaces: [WorkspaceState] = []
    private(set) var profiles: [WorkspaceProfile] = [WorkspaceProfile.defaultProfile]
    private(set) var activeProfileID: String = WorkspaceProfile.defaultID
    private(set) var activeWorkspaceID: String?

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

    var navigableProfiles: [WorkspaceProfile] {
        let profileIDsWithWorkspaces = Set(workspaces.map { $0.profileID })
        return profiles.filter { profileIDsWithWorkspaces.contains($0.id) }
    }

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

    @discardableResult
    func selectProfile(_ profileID: String) -> Bool {
        guard profiles.contains(where: { $0.id == profileID }),
              let first = visibleWorkspaceIndices(in: profileID).first
        else { return false }
        activeProfileID = profileID
        activeWorkspaceID = workspaces[first].id
        return true
    }

    @discardableResult
    func selectAdjacentProfile(delta: Int) -> WorkspaceProfile? {
        let candidates = navigableProfiles
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

    func fallbackIndexAfterClosingWorkspace(at index: Int) -> Int? {
        let visible = visibleWorkspaceIndices.filter { $0 != index }
        return visible.last(where: { $0 < index }) ?? visible.first ?? fallbackGlobalIndex(excluding: index)
    }

    @discardableResult
    func moveWorkspace(at index: Int, delta: Int) -> Bool {
        guard workspaces.indices.contains(index), delta != 0 else { return false }
        let isInactive = workspaces[index].isInactive
        let candidates = visibleWorkspaceIndices.filter { workspaces[$0].isInactive == isInactive }
        guard let position = candidates.firstIndex(of: index) else { return false }
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
        let profile = WorkspaceProfile(
            id: UUID().uuidString,
            name: name,
            colorHex: WorkspaceProfile.colorHex(for: profiles.count)
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
        workspaces.indices.first { $0 != index }
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
