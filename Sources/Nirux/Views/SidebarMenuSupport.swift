import AppKit

private final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(title: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(performAction(_:)), keyEquivalent: "")
        target = self
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError() }

    @objc private func performAction(_ sender: Any?) {
        handler()
    }
}

extension NSMenu {
    func addClosureItem(title: String, handler: @escaping () -> Void) {
        addItem(ClosureMenuItem(title: title, handler: handler))
    }
}
