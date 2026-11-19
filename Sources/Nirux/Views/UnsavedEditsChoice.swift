import AppKit

/// The answer to "Save the changes…?", asked before files with unsaved
/// edits close, as macOS document apps ask.
enum UnsavedEditsChoice {
    case save, cancel, discard

    /// The question about `paths`: Save on Return, Cancel on Escape.
    @MainActor
    static func alert(for paths: [String]) -> NSAlert {
        var names = paths.map { ($0 as NSString).lastPathComponent }
        // Files of the same name: their folders tell them apart.
        if Set(names).count < names.count {
            names = paths.map { path in
                let folder = ((path as NSString).deletingLastPathComponent as NSString).lastPathComponent
                return "\(folder)/\((path as NSString).lastPathComponent)"
            }
        }
        let alert = NSAlert()
        if names.count == 1 {
            alert.messageText = "Save the changes to “\(names[0])”?"
            alert.informativeText = "Your changes are lost if you don’t save them."
        } else {
            alert.messageText = "Save the changes to \(names.count) files?"
            alert.informativeText = "\(WorktreeCleanupCandidate.quotedList(names)) have changes that are lost if you don’t save them."
        }
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Don’t Save").hasDestructiveAction = true
        return alert
    }

    /// The choice an answer to `alert(for:)` means.
    init(_ response: NSApplication.ModalResponse) {
        switch response {
        case .alertFirstButtonReturn: self = .save
        case .alertThirdButtonReturn: self = .discard
        default: self = .cancel
        }
    }
}
