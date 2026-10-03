import AppKit

// MARK: - Branch Review (docs/branch-review.md)

/// The Branch Review columns: opening one per worktree, from the palette or
/// a workspace's menu, next to the agent that works there.
extension NiruxShellView {
    struct BranchReviewLocation {
        let workspace: WorkspaceState
        let column: ColumnState
        let review: BranchReviewController
    }

    /// Every review, in sidebar order.
    var branchReviewLocations: [BranchReviewLocation] {
        workspaces.filter { !$0.isClosing }.flatMap { workspace in
            workspace.columns.compactMap { column in
                guard !column.isClosing, let review = column.branchReview else { return nil }
                return BranchReviewLocation(workspace: workspace, column: column, review: review)
            }
        }
    }

    func branchReviewLocation(worktree: String) -> BranchReviewLocation? {
        branchReviewLocations.first { Self.isSameFolder($0.review.worktree, worktree) }
    }

    /// "Review Branch": the branch checked out in the workspace's folder,
    /// next to its focused column, at two-thirds of the width so the
    /// agent's terminal stays in view. A worktree has one review: if it has
    /// one already, that one comes to the front.
    func openBranchReview(in workspace: WorkspaceState?) {
        guard let workspace, !workspace.isClosing else { return }
        if let existing = branchReviewLocation(worktree: workspace.cwd) {
            focusBranchReview(existing)
            return
        }
        let review = makeBranchReview(worktree: workspace.cwd, branch: nil)
        workspace.addBranchReviewColumn(review)
        workspace.columns[safe: workspace.focusedIndex]?.widthFraction = ColumnWidth.twoThirds.fraction
        if workspace === activeWorkspace {
            relayout(animated: false)
            updateSidebar()
            focusActiveTerminal(in: window)
        } else {
            // From the menu of a workspace in the background.
            focusWorkspace(id: workspace.id, column: workspace.focusedIndex)
        }
        saveState()
        review.start()
    }

    func focusBranchReview(_ location: BranchReviewLocation) {
        guard let columnIndex = location.workspace.columns.firstIndex(where: { $0 === location.column }) else { return }
        focusWorkspace(id: location.workspace.id, column: columnIndex)
    }

    /// The reviews of the workspace on screen start once it has stayed
    /// there a moment, as restored agents resume: launch doesn't read every
    /// saved review's branch or load its page, and moving through
    /// workspaces (⌘↓ ⌘↓) doesn't start the reviews on the way.
    func scheduleBranchReviewsOnScreen() {
        guard activeWorkspace?.columns.contains(where: { $0.branchReview?.isStarted == false }) == true else { return }
        NSObject.cancelPreviousPerformRequests(withTarget: self, selector: #selector(startBranchReviewsOnScreen), object: nil)
        perform(#selector(startBranchReviewsOnScreen), with: nil, afterDelay: Self.onScreenResumeDelay)
    }

    @objc func startBranchReviewsOnScreen() {
        activeWorkspace?.columns.forEach { $0.branchReview?.start() }
    }

    /// A review for a new column or a restored one. It reads nothing before
    /// `start`.
    func makeBranchReview(worktree: String, branch: String?) -> BranchReviewController {
        BranchReviewController(worktree: worktree, branch: branch, reader: branchReviewReader)
    }

    /// The same folder, whatever symlinks, case (APFS) or trailing slash
    /// lead there.
    static func isSameFolder(_ first: String, _ second: String) -> Bool {
        let resolve = { (path: String) in path.realPath ?? URL(fileURLWithPath: path).standardizedFileURL.path }
        return resolve(first) == resolve(second)
    }
}
