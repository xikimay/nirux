import AppKit

// MARK: - Title bar: New, Board, Search

extension NiruxApp {
    /// First of the trailing accessories, so it keeps the window's edge:
    /// the plan usage limits and the keep-awake cup go on its left. The
    /// buttons do what their menu items do; Search closes an open palette
    /// too, and Board beeps where there's no workspace to hold it (an empty
    /// space).
    func setUpTitleBarActions(window: NSWindow) {
        let actions = TitleBarActions()
        actions.onAction = { [weak self] action in
            guard let shell = self?.shell else { return }
            switch action {
            case .new: shell.showNewPanel()
            case .board:
                guard shell.activeWorkspace != nil else { return NSSound.beep() }
                shell.openProjectBoard()
            case .search: shell.toggleCommandPaletteFromTitleBar()
            }
        }
        window.addTitlebarAccessoryViewController(actions)
    }
}
