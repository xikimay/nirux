import Foundation

// MARK: - What the Board's clicks run, and its queues (docs/design/board-stages.md, section 8)

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

    /// A queue of a Board: a repository's, or one left running on a
    /// repository the Board no longer has.
    struct QueueLine: Equatable {
        /// Its section's id, or the orphan's.
        let id: String
        var title: String
        var tooltip: String?
        var queue: QueueState
    }
}

extension MergeQueue {
    /// What a dry run is, for the DRY RUN badge and the status bar.
    static let dryRunTooltip = "This build can’t change GitHub: its queue reads GitHub, then stops before its first "
        + "branch update, rerun or merge. Only the notarized release, on the real state, runs a real queue."

    /// The tooltip, with why this build is a dry run when it is known.
    static func dryRunTooltip(reason: String?) -> String {
        dryRunTooltip + (reason.map { "\nThis build: \($0)." } ?? "")
    }
}
