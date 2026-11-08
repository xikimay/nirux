import AppKit

// MARK: - Title bar: New, Board, Search

extension NiruxApp {
    /// First of the trailing accessories, so it keeps the window's edge:
    /// the plan usage limits and the keep-awake cup go on its left. The
    /// buttons do what their menu items do.
    func setUpTitleBarActions(window: NSWindow) {
        let actions = TitleBarActions()
        actions.onAction = { [weak self] action in
            switch action {
            case .new: self?.newWorkspace(nil)
            case .board: self?.openBoard(nil)
            case .search: self?.showCommandPalette(nil)
            }
        }
        window.addTitlebarAccessoryViewController(actions)
    }
}
