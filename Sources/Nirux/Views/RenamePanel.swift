import AppKit

/// Raycast-style floating panel for renaming the active workspace
@MainActor
final class RenamePanel {
    var onRename: ((String) -> Void)?

    private var panel: NSPanel?
    private var field: NSTextField?

    private static let size = NSSize(width: 520, height: 56)

    func show(relativeTo window: NSWindow, currentTitle: String) {
        if panel == nil { createPanel() }
        guard let panel, let field else { return }

        field.stringValue = currentTitle
        RaycastPanel.show(panel, relativeTo: window, size: Self.size)
        panel.makeFirstResponder(field)
        field.selectText(nil)
    }

    private func createPanel() {
        let built = RaycastPanel.build(
            RaycastPanel.Config(
                width: Self.size.width, height: Self.size.height,
                icon: "\u{270F}\u{FE0F}", placeholder: "Workspace name"
            ),
            fieldTarget: self, fieldAction: #selector(fieldAction)
        )
        panel = built.panel
        field = built.field
    }

    @objc private func fieldAction() {
        guard let newTitle = field?.stringValue.trimmingCharacters(in: .whitespacesAndNewlines),
              !newTitle.isEmpty
        else { return }
        panel?.orderOut(nil)
        onRename?(newTitle)
    }
}
