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
