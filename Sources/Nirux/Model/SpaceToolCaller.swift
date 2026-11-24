import Foundation

/// Who calls a space tool (`LeadTools.spaceNames`, and `list_tasks` with
/// `space`): a space's Lead, or the agent of a task whose space lets its
/// tasks manage spaces (`SpaceDefaults.tasksManageSpaces`). Both go
/// through the same checks (NiruxShellView+LeadSpaces); what differs is
/// what they may do to their own space and workspace. A task may move
/// itself, or delete its space with the tasks moving out, and hears it
/// moved; it may not leave its own task or repository behind.
struct SpaceToolCaller: Equatable, Sendable {
    let workspaceID: String
    /// The space it is in now.
    let spaceID: String
    let isLead: Bool
    /// The repository a task works in (`SpaceAnchor.key`), if its space has it.
    var anchorKey: String?
    /// The task a task is a sub-task of, in the same space.
    var parentTaskID: String?

    static func lead(workspaceID: String, spaceID: String) -> SpaceToolCaller {
        SpaceToolCaller(workspaceID: workspaceID, spaceID: spaceID, isLead: true)
    }

    /// It is the Lead of `spaceID`, which organizes that space's tasks.
    func leads(_ spaceID: String) -> Bool {
        isLead && spaceID == self.spaceID
    }

    /// What reaches the tasks of a space it reads.
    var reach: String {
        isLead ? "Your tell, reply and close_task reach your own space only." : "Your tell and reply reach your sub-tasks only."
    }

    /// Why it may not delete `space`; nil when it may. A Lead's space goes
    /// only with its Lead; a task's moves it out with the other tasks.
    func deletionRefusal(of space: WorkspaceProfile) -> String? {
        guard leads(space.id) else { return nil }
        return "“\(MissionPromptText.quoted(space.name))” is your own space: you can't delete it."
    }

    /// Why `moving` (workspace ids) may not move together; nil when they
    /// may. A sub-task moved without its task would be listed under none.
    func moveRefusal(moving: [String]) -> String? {
        guard let parentTaskID, moving.contains(workspaceID), !moving.contains(parentTaskID) else { return nil }
        return "You are a sub-task: moved without your task, you would be listed under none. Move your task, which takes you along."
    }

    /// Why `anchors` may not leave `spaceID`, removed or moved to another
    /// space; nil when they may. A task's own repository stays in its space.
    func anchorLossRefusal(_ anchors: [SpaceAnchor], from spaceID: String) -> String? {
        guard spaceID == self.spaceID, let anchorKey, let own = anchors.first(where: { $0.key == anchorKey }) else { return nil }
        return "You work in “\(MissionPromptText.quoted(own.name))”: taking it out of your space would leave you outside "
            + "its repositories. Ask the user."
    }

    /// What a move of `moved` (workspace ids) to `destination` did to the
    /// caller, for its answer; nil when it stayed.
    func movedNote(moved: [String], to destination: WorkspaceProfile, tasksManageSpacesThere: Bool) -> String? {
        guard moved.contains(workspaceID) else { return nil }
        let note = "You moved too: you are in “\(MissionPromptText.quoted(destination.name))” (\(LeadTools.spaceIDPrefix)\(destination.id)) now"
        return tasksManageSpacesThere ? note + "." : note + ", whose tasks can't manage spaces: these tools refuse your calls from now on."
    }
}
