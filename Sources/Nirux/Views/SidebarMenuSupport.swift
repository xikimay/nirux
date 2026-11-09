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
    /// "Clean Up Worktree…" (see WorktreeCleanupMenuOffer).
    func addWorktreeCleanupItem(to menu: NSMenu, act: @escaping (WorkspaceSidebarAction) -> Void) {
        menu.addClosureItem(title: "Clean Up Worktree…") { act(.cleanUpWorktree) }
    }

    /// The two CI failure actions, while the workspace's pull request is red
    /// (docs/ci-failure-actions.md). A rerun needs a GitHub Actions run.
    func addCIFailureItems(to menu: NSMenu, pullRequest: PRInfo?, act: @escaping (WorkspaceSidebarAction) -> Void) {
        guard let pullRequest, !CIFailure.redChecks(pullRequest).isEmpty else { return }
        menu.addClosureItem(title: "Ask Agent Why CI Failed") { act(.askWhyCIFailed) }
        menu.addClosureItem(title: "Rerun Failed CI Jobs…") { act(.rerunFailedCI) }
            .isEnabled = !CIFailure.runs(pullRequest).isEmpty
    }
}
