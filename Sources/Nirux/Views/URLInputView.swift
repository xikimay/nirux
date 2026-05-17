import AppKit

/// Raycast-style floating input panel for entering URLs
@MainActor
final class URLInputPanel {
    var onSubmit: ((String) -> Void)?

    private var panel: NSPanel?
    private var field: NSTextField?

    private static let size = NSSize(width: 500, height: 48)

    func show(relativeTo window: NSWindow) {
        if panel == nil { createPanel() }
        guard let panel, let field else { return }

        field.stringValue = ""
        RaycastPanel.show(panel, relativeTo: window, size: Self.size)
        panel.makeFirstResponder(field)
    }

    private func createPanel() {
        let built = RaycastPanel.build(
            RaycastPanel.Config(
                width: Self.size.width, height: Self.size.height,
                icon: "🌐", placeholder: "Enter URL or search..."
            ),
            fieldTarget: self, fieldAction: #selector(fieldAction)
        )
        panel = built.panel
        field = built.field
    }

    @objc private func fieldAction() {
        guard let text = field?.stringValue.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else { return }
        panel?.orderOut(nil)
        onSubmit?(text)
    }
}
