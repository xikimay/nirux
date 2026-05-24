import AppKit

@MainActor
final class NameInputPanel {
    var onSubmit: ((String) -> Void)?

    private var panel: NSPanel?
    private var field: NSTextField?

    private static let size = NSSize(width: 520, height: 56)

    func show(relativeTo window: NSWindow, currentValue: String, placeholder: String) {
        if panel == nil { createPanel() }
        guard let panel, let field else { return }

        field.placeholderString = placeholder
        field.stringValue = currentValue
        RaycastPanel.show(panel, relativeTo: window, size: Self.size)
        panel.makeFirstResponder(field)
        field.selectText(nil)
    }

    private func createPanel() {
        let built = RaycastPanel.build(
            RaycastPanel.Config(
                width: Self.size.width,
                height: Self.size.height,
                icon: "\u{270F}\u{FE0F}",
                placeholder: "Name"
            ),
            fieldTarget: self,
            fieldAction: #selector(fieldAction)
        )
        panel = built.panel
        field = built.field
    }

    @objc private func fieldAction() {
        guard let value = field?.stringValue.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty
        else { return }
        panel?.orderOut(nil)
        onSubmit?(value)
    }
}
