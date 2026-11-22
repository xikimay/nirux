import AppKit

// MARK: - Each task's Board station, its line's (docs/design/glass-interface.md, phase 5)

extension NiruxShellView {
    /// The station each task line of `content` stands at, its Board's own
    /// reading of it, in the sections read lately (`fresh`): none for a
    /// line without a rail (no repository), nor for one whose reading aged.
    static func taskStations(of content: BoardStagesView.Content, fresh: Set<String>) -> [String: SidebarBoardProgress] {
        let lines = content.sections.filter { fresh.contains($0.id) }.flatMap { $0.lines.units.flatMap(\.lines) }
        return Dictionary(lines.compactMap { line in
            guard line.hasTask, let rail = line.rail else { return nil }
            let merged = rail.marks.last == .done || line.state == .merged
            let mergeStep: SidebarTaskStep? = merged ? .merged : (line.state == .ready ? .ready : nil)
            return (line.id, SidebarBoardProgress(
                station: line.station, number: line.pullRequestNumber, mergeStep: mergeStep,
                readyApartFromLocalReviews: line.readyApartFromLocalReviews
            ))
        }, uniquingKeysWith: { first, _ in first })
    }

    /// `content`, its Board's, gives its space's tasks their stations
    /// (`taskStations`); a task it doesn't list on a rail, or whose section
    /// its Board hasn't read lately (`fresh`), has none. True when one
    /// changed.
    @discardableResult
    func noteTaskStations(
        of board: ProjectBoardController, content: BoardStagesView.Content, fresh: Set<String>? = nil
    ) -> Bool {
        let before = taskStations
        for workspace in projectWorkspaces(of: board.projectID) { taskStations[workspace.id] = nil }
        taskStations.merge(Self.taskStations(of: content, fresh: fresh ?? board.freshSections())) { $1 }
        return taskStations != before
    }
}
