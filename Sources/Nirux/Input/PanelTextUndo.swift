import AppKit

/// Target of Edit > Undo and Redo. It acts only on a native text field or
/// text view in a panel (palette, rename, workspace context, settings…).
///
/// The main window is left out on purpose: WebKit records the edits of every
/// browser and editor column on the main window's single undo manager, so a
/// window-level undo there could revert text in a column other than the
/// focused one. Monaco and web pages receive Cmd+Z directly instead (see
/// WebContentKeyRouting).
@MainActor
final class PanelTextUndo: NSObject, NSMenuItemValidation {
    static let shared = PanelTextUndo()

    private let keyWindow: @MainActor () -> NSWindow?

    init(keyWindow: @escaping @MainActor () -> NSWindow? = { NSApp.keyWindow }) {
        self.keyWindow = keyWindow
        super.init()
    }

    private var undoManager: UndoManager? {
        guard let panel = keyWindow() as? NSPanel,
              let textView = panel.firstResponder as? NSTextView
        else { return nil }
        return textView.undoManager
    }

    @objc func undo(_ sender: Any?) {
        undoManager?.undo()
    }

    @objc func redo(_ sender: Any?) {
        undoManager?.redo()
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(undo(_:)): undoManager?.canUndo == true
        case #selector(redo(_:)): undoManager?.canRedo == true
        default: false
        }
    }
}
