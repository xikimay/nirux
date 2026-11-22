import AppKit

// MARK: - Branch Review (docs/design/branch-review.md)

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

    /// "Review Branch": the branch checked out in the workspace's folder
    /// (or `folder`, the editor's), next to its focused column, at
    /// two-thirds of the width so the agent's terminal stays in view. A
    /// worktree has one review: if it has one already, that one comes to
    /// the front.
    func openBranchReview(in workspace: WorkspaceState?, folder: String? = nil) {
        guard let workspace, !workspace.isClosing, !workspace.isWaitingTask else { return }
        let worktree = folder ?? workspace.cwd
        if let existing = branchReviewLocation(worktree: worktree) {
            focusBranchReview(existing)
            return
        }
        let review = makeBranchReview(worktree: worktree, branch: nil, workspaceID: workspace.id)
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
    func makeBranchReview(worktree: String, branch: String?, workspaceID: String? = nil) -> BranchReviewController {
        let review = BranchReviewController(
            worktree: worktree, branch: branch, workspaceID: workspaceID, reader: branchReviewReader,
            reviewOpener: branchReviewOpener, branchCheck: branchReviewBranchCheck,
            explainChecker: sideEffects.checkExplain
        )
        review.isOnScreen = { [weak self, weak review] in
            guard let self, let review else { return false }
            return self.isBranchReviewOnScreen(review)
        }
        review.confirmExplain = { [weak self, weak review] account, files, settings in
            guard let self, let review else { return false }
            return self.confirmExplain(for: review, account: account, files: files, settings: settings)
        }
        review.sendToAgent = { [weak self] review in self?.sendReviewComments(from: review) }
        return review
    }

    /// Explain's first-use notice: once per project (space) and account,
    /// asked again when the account changes, and every time for an account
    /// billed per call (docs/design/branch-review.md, section 4.3).
    func confirmExplain(
        for review: BranchReviewController, account: BranchReview.ExplainAccount, files: Int,
        settings: BranchReview.ExplainSettings = .init()
    ) -> Bool {
        let project = workspaces.first { $0.columns.contains { $0.branchReview === review } }?.profileID
            ?? WorkspaceProfile.defaultID
        if !account.isBilledPerCall,
           Persistence.load()?.settings?.explainNoticeAccounts[project] == account.identity {
            return true
        }
        let alert = BranchReviewController.explainAlert(account: account, files: files, settings: settings)
        guard sideEffects.runModal(alert) == .alertFirstButtonReturn else { return false }
        if !account.isBilledPerCall {
            // Unsaved, it asks again next time: nothing worse.
            _ = Persistence.updateSettings(liveLayout: persistedState()) { $0.explainNoticeAccounts[project] = account.identity }
        }
        return true
    }

    /// Its column shows: in the workspace in front, inside the viewport
    /// (as restored agents count it), in a window the user can see. Off
    /// screen, a review only marks itself stale.
    func isBranchReviewOnScreen(_ review: BranchReviewController) -> Bool {
        guard let window, window.occlusionState.contains(.visible), let workspace = activeWorkspace,
              let index = workspace.columns.firstIndex(where: { $0.branchReview === review && !$0.isClosing })
        else { return false }
        return index == workspace.focusedIndex || workspace.showsColumn(at: index)
    }

    /// The started reviews on screen read their branch again if it changed
    /// while they were hidden. Cheap when nothing is stale: the metadata
    /// refresh, several times a second, calls it too.
    func refreshStaleBranchReviewsOnScreen() {
        activeWorkspace?.columns.forEach { $0.branchReview?.becameVisible() }
    }

    /// Attaches an isolated browser capture to `workspace`'s Branch Review.
    /// Completes with `true` when the review column is already visible on screen.
    func attachBrowserCapture(
        _ input: BranchReview.BrowserReceipt.Input,
        in workspace: WorkspaceState,
        completion: @escaping @MainActor (Result<Bool, Error>) -> Void
    ) {
        guard let targetID = UUID(uuidString: workspace.id),
              let inputID = UUID(uuidString: input.workspaceID),
              targetID == inputID else {
            completion(.failure(BranchReview.BrowserReceipt.Problem.crossWorkspaceCapture))
            return
        }
        if let review = workspace.columns.compactMap(\.branchReview).first(where: {
            !$0.worktree.isEmpty && Self.isSameFolder($0.worktree, workspace.cwd)
        }) ?? workspace.columns.compactMap(\.branchReview).first, review.snapshot != nil {
            review.attachBrowserCapture(input) { [weak review] result in
                completion(result.map { review?.isOnScreen() ?? false })
            }
            return
        }
        let worktree = workspace.cwd
        let workspaceID = workspace.id
        let stateDirectory = Persistence.stateDirectory
        let reader = branchReviewReader
        let opener = branchReviewOpener
        let branchCheck = branchReviewBranchCheck
        BranchReviewController.inBackground(on: .global(qos: .userInitiated), {
            Self.attachBrowserCaptureInStore(
                input, worktree: worktree, workspaceID: workspaceID,
                stateDirectory: stateDirectory, reader: reader, opener: opener, branchCheck: branchCheck
            )
        }) { [weak workspace] result in
            if case .success = result, let workspace {
                workspace.columns.compactMap(\.branchReview).forEach { $0.reloadReview() }
            }
            completion(result.map { false })
        }
    }

    private nonisolated static func attachBrowserCaptureInStore(
        _ input: BranchReview.BrowserReceipt.Input,
        worktree: String,
        workspaceID: String,
        stateDirectory: URL,
        reader: BranchReviewController.Reader,
        opener: BranchReviewController.ReviewOpener,
        branchCheck: BranchReviewController.BranchCheck
    ) -> Result<Void, Error> {
        let (outcome, _) = reader(worktree, false, nil)
        let snapshot: BranchReview.Snapshot
        switch outcome {
        case .snapshot(let found): snapshot = found
        case .paused(let operation):
            return .failure(BranchReview.BrowserReceipt.MessageError(message: BranchReviewController.pauseMessage(operation)))
        case .unavailable(let message):
            return .failure(BranchReview.BrowserReceipt.MessageError(message: message))
        }
        do {
            let receipt = try BranchReview.BrowserReceipt.receipt(
                from: input, for: snapshot, workspaceID: workspaceID, stateDirectory: stateDirectory
            )
            guard let (store, loaded) = opener(snapshot) else {
                return .failure(BranchReview.BrowserReceipt.MessageError(
                    message: "Nirux couldn’t open this branch’s review file: git couldn’t tell its repository."
                ))
            }
            guard let access = loaded.access else {
                let message: String
                if case .readOnly(let reason) = loaded.status {
                    message = reason.message
                } else {
                    message = "This review can’t be changed."
                }
                return .failure(BranchReview.BrowserReceipt.MessageError(message: message))
            }
            if access.createsReview {
                switch branchCheck(store) {
                case true?: break
                case false?:
                    return .failure(BranchReview.BrowserReceipt.MessageError(
                        message: "\(store.branch) was deleted: Nirux won’t create its review."
                    ))
                case nil:
                    return .failure(BranchReview.BrowserReceipt.MessageError(
                        message: "Nirux couldn’t check that \(store.branch) still exists. Try again."
                    ))
                }
            }
            let written = try store.update(access, createsEmpty: false) { $0.addReceipt(receipt) }.get()
            guard written.record.receipts.contains(where: { $0.id == receipt.id }) else {
                return .failure(BranchReview.BrowserReceipt.MessageError(
                    message: "This review’s receipt format cannot be updated by this version of Nirux."
                ))
            }
            return .success(())
        } catch {
            return .failure(error)
        }
    }

    /// The same folder, whatever symlinks, case (APFS) or trailing slash
    /// lead there.
    static func isSameFolder(_ first: String, _ second: String) -> Bool {
        let resolve = { (path: String) in path.realPath ?? URL(fileURLWithPath: path).standardizedFileURL.path }
        return resolve(first) == resolve(second)
    }
}
