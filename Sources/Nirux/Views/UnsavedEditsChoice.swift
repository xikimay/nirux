import AppKit

/// The answer to "Save the changes…?", asked before files with unsaved
/// edits close, as macOS document apps ask.
enum UnsavedEditsChoice {
    case save, cancel, discard

    /// The question about `paths`: Save on Return, Cancel on Escape.
    /// `shared`: those unsaved in several editors, which Save can't all
    /// write.
    @MainActor
    static func alert(for paths: [String], shared: [String] = []) -> NSAlert {
        let names = labels(for: paths)
        let alert = NSAlert()
        if names.count == 1 {
            alert.messageText = "Save the changes to “\(names[0])”?"
            alert.informativeText = "Your changes are lost if you don’t save them."
        } else {
            alert.messageText = "Save the changes to \(names.count) files?"
            alert.informativeText = "\(WorktreeCleanupCandidate.quotedList(names)) have changes that are lost if you don’t save them."
        }
        let sharedNames = shared.compactMap { path in paths.firstIndex(of: path).map { names[$0] } }
        if !sharedNames.isEmpty {
            alert.informativeText += " \(WorktreeCleanupCandidate.quotedList(sharedNames)) \(sharedNames.count == 1 ? "is" : "are") "
                + "unsaved in several editors: Save writes one, and the others show the conflict."
        }
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Don’t Save").hasDestructiveAction = true
        return alert
    }

    /// Each path's file name, with as many of its folders as tell it from
    /// the others'.
    static func labels(for paths: [String]) -> [String] {
        let components = paths.map { ($0 as NSString).pathComponents.filter { $0 != "/" } }
        var depths = Array(repeating: 1, count: paths.count)
        while true {
            let labels = paths.indices.map { components[$0].suffix(depths[$0]).joined(separator: "/") }
            let clashing = paths.indices.filter { index in
                depths[index] < components[index].count && labels.filter { $0 == labels[index] }.count > 1
            }
            guard !clashing.isEmpty else { return labels }
            for index in clashing { depths[index] += 1 }
        }
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
