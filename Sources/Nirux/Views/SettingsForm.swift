import AppKit

/// Building blocks of the Settings window's panes: section headers,
/// checkboxes with their hint underneath, labeled rows. A pane is a vertical
/// stack of sections, as wide as every other pane, as tall as its content
/// (the window fits each pane when its tab is picked).
@MainActor
enum SettingsForm {
    static let paneWidth: CGFloat = 560
    private static let insets = NSEdgeInsets(top: 20, left: 28, bottom: 24, right: 28)
    static let textWidth = paneWidth - insets.left - insets.right
    /// Hints under a checkbox start where its title does.
    private static let checkboxTextIndent: CGFloat = 20

    /// Sections stack with more room between them than between their rows.
    static func pane(_ sections: [[NSView]]) -> NSView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = insets
        stack.translatesAutoresizingMaskIntoConstraints = false
        for (index, section) in sections.enumerated() {
            section.forEach(stack.addArrangedSubview)
            if index < sections.count - 1, let last = section.last {
                stack.setCustomSpacing(22, after: last)
            }
        }
        let pane = NSView()
        pane.addSubview(stack)
        // The stack keeps to the top. While the window animates to another
        // pane's height, this one may be shorter than its content: below
        // windowSizeStayPut, it never pushes the window to its own height
        // mid-animation (which made the window jump).
        let holdsContent = pane.bottomAnchor.constraint(greaterThanOrEqualTo: stack.bottomAnchor)
        holdsContent.priority = NSLayoutConstraint.Priority(NSLayoutConstraint.Priority.windowSizeStayPut.rawValue - 10)
        let fill = pane.bottomAnchor.constraint(equalTo: stack.bottomAnchor)
        fill.priority = .defaultLow
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: pane.topAnchor),
            stack.leadingAnchor.constraint(equalTo: pane.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: pane.trailingAnchor),
            stack.widthAnchor.constraint(equalToConstant: paneWidth),
            holdsContent,
            fill
        ])
        return pane
    }

    static func header(_ title: String) -> NSTextField {
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
        label.textColor = .labelColor
        return label
    }

    static func checkbox(_ title: String, target: AnyObject, action: Selector) -> NSButton {
        let checkbox = NSButton(checkboxWithTitle: title, target: target, action: action)
        checkbox.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return checkbox
    }

    /// Secondary text under a section's controls.
    static func hint(_ text: String) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        label.textColor = .secondaryLabelColor
        label.isSelectable = false
        label.preferredMaxLayoutWidth = textWidth
        return label
    }

    /// A checkbox's hint, lined up with its title; VoiceOver reads it once,
    /// as the checkbox's help.
    static func hint(_ text: String, under checkbox: NSButton) -> NSView {
        checkbox.setAccessibilityHelp(text)
        let label = hint(text)
        label.setAccessibilityElement(false)
        label.preferredMaxLayoutWidth = textWidth - checkboxTextIndent
        let container = NSView()
        label.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(label)
        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: container.topAnchor),
            label.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            label.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: checkboxTextIndent),
            label.trailingAnchor.constraint(equalTo: container.trailingAnchor)
        ])
        return container
    }

    static func popup(target: AnyObject, action: Selector) -> NSPopUpButton {
        let popup = NSPopUpButton(frame: .zero, pullsDown: false)
        popup.target = target
        popup.action = action
        return popup
    }

    /// A label, then its control (a pop-up at its natural width, a text field
    /// up to an optional trailing button). The label titles the control for
    /// VoiceOver.
    static func row(_ title: String, _ control: NSView, trailing: NSView? = nil) -> NSView {
        let label = NSTextField(labelWithString: title)
        label.setContentHuggingPriority(.required, for: .horizontal)
        label.setContentCompressionResistancePriority(.required, for: .horizontal)
        control.setContentHuggingPriority(.defaultLow, for: .horizontal)
        control.setAccessibilityTitleUIElement(label)
        let row = NSStackView(views: [label, control] + (trailing.map { [$0] } ?? []))
        row.orientation = .horizontal
        row.alignment = .firstBaseline
        row.spacing = 8
        row.widthAnchor.constraint(equalToConstant: textWidth).isActive = true
        return row
    }

    /// Buttons side by side, at their natural width.
    static func buttons(_ views: [NSView]) -> NSView {
        let row = NSStackView(views: views)
        row.orientation = .horizontal
        row.spacing = 8
        return row
    }

    /// Selects the item whose represented object is `value`; an unknown
    /// value leaves the selection alone rather than blanking the pop-up.
    static func select(_ value: Any, in popup: NSPopUpButton) {
        let index = popup.indexOfItem(withRepresentedObject: value)
        if index >= 0 { popup.selectItem(at: index) }
    }
}

/// Toolbar tabs, one pane each. Picking a tab fits the window to that pane,
/// top edge fixed, as macOS Settings windows do: left alone, the tab view
/// controller grows the window for a taller pane but never shrinks it.
final class SettingsTabViewController: NSTabViewController {
    override func tabView(_ tabView: NSTabView, didSelect tabViewItem: NSTabViewItem?) {
        super.tabView(tabView, didSelect: tabViewItem)
        fitWindowToSelectedPane(animated: true)
    }

    /// Animates only in front of the user (xctest's app is never active).
    func fitWindowToSelectedPane(animated: Bool) {
        guard let window = view.window,
              tabViewItems.indices.contains(selectedTabViewItemIndex),
              let pane = tabViewItems[selectedTabViewItemIndex].viewController?.view
        else { return }
        var frame = window.frameRect(forContentRect: NSRect(origin: .zero, size: pane.fittingSize))
        frame.origin = NSPoint(x: window.frame.minX, y: window.frame.maxY - frame.height)
        guard frame != window.frame else { return }
        window.setFrame(frame, display: true, animate: animated && window.isVisible && NSApp.isActive)
    }
}
