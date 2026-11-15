import Foundation

// MARK: - What the Board's clicks run (docs/design/board-stages.md, section 8)

extension ProjectBoard {
    /// What a click on the Board runs (`NiruxShellView.performProjectBoardAction`).
    enum Action: Equatable {
        case focus(workspaceID: String, columnID: UUID?)
        case open(path: String, title: String)
        case cleanUp(path: String)
        case resumeFailed(workspaceID: String, columnID: UUID, failedAt: TimeInterval)
        case resumeExited(workspaceID: String, columnID: UUID)
        /// `section`: the repository's; nil on a Board with one.
        case addToQueue(number: Int, section: String? = nil)
        case removeFromQueue(number: Int, section: String? = nil)
        /// Its base's pull request merged: base it on that one's base.
        case retarget(number: Int, base: String, section: String? = nil)
    }
}
