import AppKit

/// Whether the sidebar is unfolded: the user's choice (⌃⌘S, View › Toggle
/// Sidebar, ⌘P, saved with the state), unless the window is narrow. Below
/// `narrowWidth` the sidebar folds by itself, and it unfolds again when the
/// window widens if the user had it unfolded. A toggle while the window is
/// narrow is the user's choice again, until the window crosses the width
/// once more.
struct SidebarFold: Equatable {
    /// Under it, an unfolded sidebar (260 pt) leaves the columns less than
    /// about 640 pt.
    static let narrowWidth: CGFloat = 900

    /// The user's choice, saved.
    var chosenExpanded = false
    /// The window got narrow since the last choice.
    private(set) var autoFolded = false
    private var isNarrow = false

    init(chosenExpanded: Bool = false) {
        self.chosenExpanded = chosenExpanded
    }

    var isExpanded: Bool { chosenExpanded && !autoFolded }

    /// The window's width changed: crossing `narrowWidth` folds the sidebar,
    /// or gives it back to the user's choice.
    mutating func windowResized(to width: CGFloat) {
        let narrow = width < Self.narrowWidth
        guard narrow != isNarrow else { return }
        isNarrow = narrow
        autoFolded = narrow
    }

    /// The user unfolds or folds the sidebar, whatever the window's width.
    mutating func choose(_ expanded: Bool) {
        chosenExpanded = expanded
        autoFolded = false
    }
}

// MARK: - The sidebar folds and unfolds

extension NiruxShellView {
    /// Folds the sidebar when the window just got narrow, unfolds it back
    /// when it widened again: at once, as the window's own resize moves the
    /// columns. The rail comes before the sidebar narrows; the cards only
    /// once it is wide (`relayout` calls the returned unfold after laying
    /// the sidebar out), as `toggleSidebar` does, else they would be laid
    /// out at the rail's width first.
    func applySidebarAutoFold() -> (() -> Void)? {
        guard bounds.width > 0 else { return nil }
        let wasExpanded = isSidebarExpanded
        sidebarFold.windowResized(to: bounds.width)
        guard isSidebarExpanded != wasExpanded else { return nil }
        // An unfold under way (`toggleSidebar`) gives way.
        sidebarToggleGeneration += 1
        guard isSidebarExpanded else {
            sidebar.isExpanded = false
            return nil
        }
        let generation = sidebarToggleGeneration
        return { [weak self] in
            guard let self, sidebarToggleGeneration == generation, isSidebarExpanded else { return }
            refreshOnboardingChecklist()
            sidebar.isExpanded = true
        }
    }

    /// The rail's archived tasks: the sidebar unfolds with the archived
    /// list open, its header in view (folded, the list has nowhere to show).
    func showArchivedTasks() {
        guard sidebar.hasInactiveWorkspaces else { return }
        sidebar.showInactiveSection()
        if !isSidebarExpanded { toggleSidebar() }
    }

    /// View › Show Archived and ⌘P: the list folds or unfolds; folded, the
    /// sidebar unfolds with it open.
    func toggleArchivedTasks() {
        guard isSidebarExpanded else { return showArchivedTasks() }
        sidebar.toggleInactiveSection()
    }
}
