import AppKit

private final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(title: String, keyEquivalent: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(performAction(_:)), keyEquivalent: keyEquivalent)
        target = self
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError() }

    @objc private func performAction(_ sender: Any?) {
        handler()
    }
}

extension NSMenu {
    /// `keyEquivalent` is display-only here (matching the main-menu shortcut);
    /// the default ⌘ modifier applies when non-empty.
    @discardableResult
    func addClosureItem(title: String, keyEquivalent: String = "", handler: @escaping () -> Void) -> NSMenuItem {
        let item = ClosureMenuItem(title: title, keyEquivalent: keyEquivalent, handler: handler)
        addItem(item)
        return item
    }
}

extension SidebarView {
    /// "Clean Up Worktree…", for a workspace open in a linked worktree or
    /// in a folder that's gone.
    func addWorktreeCleanupItem(to menu: NSMenu, workspaceIndex: Int) {
        guard offersWorktreeCleanup?(workspaceIndex) == true else { return }
        menu.addClosureItem(title: "Clean Up Worktree…") { [weak self] in
            self?.onWorkspaceAction?(.cleanUpWorktree, workspaceIndex)
        }
    }

    /// The two CI failure actions, while the workspace's pull request is red
    /// (docs/ci-failure-actions.md). A rerun needs a GitHub Actions run.
    func addCIFailureItems(to menu: NSMenu, pullRequest: PRInfo?, workspaceIndex: Int) {
        guard let pullRequest, !CIFailure.redChecks(pullRequest).isEmpty else { return }
        menu.addClosureItem(title: "Ask Agent Why CI Failed") { [weak self] in
            self?.onWorkspaceAction?(.askWhyCIFailed, workspaceIndex)
        }
        menu.addClosureItem(title: "Rerun Failed CI Jobs…") { [weak self] in
            self?.onWorkspaceAction?(.rerunFailedCI, workspaceIndex)
        }.isEnabled = !CIFailure.runs(pullRequest).isEmpty
    }
}
