import AppKit

// MARK: - Title bar: New, Board, Search

extension NiruxApp {
    /// First of the trailing accessories, so it keeps the window's edge:
    /// the plan usage limits and the keep-awake cup, set up after it, go on
    /// its left.
    func setUpTitleBarActions(window: NSWindow) {
        let actions = TitleBarActions()
        actions.onAction = { [weak self] action in self?.shell?.performTitleBarAction(action) }
        window.addTitlebarAccessoryViewController(actions)
    }
}
