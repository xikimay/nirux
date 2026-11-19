import AppKit

/// Files with unsaved edits never close unasked: a tab, a column, a
/// workspace and the app ask Save, Cancel or Don't Save first. close_task
/// refuses instead: that choice is the user's.
extension NiruxShellView {
    /// Asks about `paths` in an app-modal alert, through `sideEffects`.
    func askAboutUnsavedEdits(_ paths: [String]) -> UnsavedEditsChoice {
        UnsavedEditsChoice(runModal(UnsavedEditsChoice.alert(for: paths)))
    }

    /// `proceed` runs once the unsaved edits of `columns`' editors are
    /// saved or discarded: at once when there are none, never on Cancel nor
    /// when a save fails (the editor says why).
    func afterUnsavedEdits(in columns: [ColumnState], _ proceed: @escaping () -> Void) {
        if settleUnsavedEdits(of: Self.unsavedEditors(in: columns), afterSaving: proceed) { proceed() }
    }

    /// `applicationShouldTerminate`: true to quit now. After Save, the quit
    /// comes again once every file is written.
    func editorsAllowQuit() -> Bool {
        settleUnsavedEdits(of: Self.unsavedEditors(in: openWorkspaceColumns)) { [weak self] in
            self?.sideEffects.requestQuit()
        }
    }

    var hasUnsavedEditors: Bool { !Self.unsavedEditors(in: openWorkspaceColumns).isEmpty }

    private var openWorkspaceColumns: [ColumnState] {
        workspaces.filter { !$0.isClosing }.flatMap(\.openColumns)
    }

    /// True to go on at once: nothing unsaved, or Don't Save. On Save,
    /// false, and `afterSaving` runs once every file is written.
    private func settleUnsavedEdits(of editors: [EditorColumn], afterSaving: @escaping () -> Void) -> Bool {
        guard !editors.isEmpty else { return true }
        switch askAboutUnsavedEdits(editors.flatMap(\.unsavedPaths)) {
        case .save:
            Self.save(editors[...], then: afterSaving)
            return false
        case .discard:
            return true
        case .cancel:
            return false
        }
    }

    private static func unsavedEditors(in columns: [ColumnState]) -> [EditorColumn] {
        columns.compactMap(\.editorColumn).filter { !$0.unsavedPaths.isEmpty }
    }

    /// One editor after the other; the first that fails stops the rest.
    private static func save(_ editors: ArraySlice<EditorColumn>, then proceed: @escaping () -> Void) {
        guard let editor = editors.first else { return proceed() }
        editor.saveAll { written in
            if written { save(editors.dropFirst(), then: proceed) }
        }
    }
}
