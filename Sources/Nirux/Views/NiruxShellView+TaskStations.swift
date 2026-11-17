import AppKit

// MARK: - Each task's Board station, its line's (docs/design/glass-interface.md, phase 5)

extension NiruxShellView {
    /// The station each task line of `content` stands at, its Board's own
    /// reading of it: none for a line without a rail (no repository).
    static func taskStations(of content: BoardStagesView.Content) -> [String: BoardStages.Station] {
        let lines = content.sections.flatMap { $0.lines.units.flatMap(\.lines) }
        return Dictionary(
            lines.filter { $0.hasTask && $0.rail != nil }.map { ($0.id, $0.station) }, uniquingKeysWith: { first, _ in first }
        )
    }

    /// `content`, its Board's, gives its space's tasks their stations
    /// (`taskStations`); a task it doesn't list on a rail has none. True
    /// when one changed.
    @discardableResult
    func noteTaskStations(of board: ProjectBoardController, content: BoardStagesView.Content) -> Bool {
        let before = taskStations
        for workspace in projectWorkspaces(of: board.projectID) { taskStations[workspace.id] = nil }
        taskStations.merge(Self.taskStations(of: content)) { $1 }
        return taskStations != before
    }
}
