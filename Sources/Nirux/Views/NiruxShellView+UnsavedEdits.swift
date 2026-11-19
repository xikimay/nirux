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
    /// when a save fails (its editor shows, saying why).
    func afterUnsavedEdits(in columns: [ColumnState], _ proceed: @escaping () -> Void) {
        let editors = Self.unsavedEditors(in: columns)
        guard !editors.isEmpty else { return proceed() }
        switch askAboutUnsavedEdits(Self.unsavedPaths(of: editors)) {
        case .save:
            save(editors[...]) { written in
                if written { proceed() }
            }
        case .discard:
            proceed()
        case .cancel:
            break
        }
    }

    /// `applicationShouldTerminate`: changes typed in Space Settings or an
    /// editor ask first, then a running merge queue. On Save, the quit
    /// waits for the files (`.terminateLater`); `reply` gets the decision
    /// then, never before this returns.
    func terminateReply(reply: @escaping @MainActor (Bool) -> Void) -> NSApplication.TerminateReply {
        guard spaceSettingsAllowQuit() else { return .terminateCancel }
        let editors = Self.unsavedEditors(in: openWorkspaceColumns)
        guard !editors.isEmpty else { return mergeQueueTerminateReply(reply: reply) }
        // Quit from the Dock while Nirux is hidden: the question must show.
        sideEffects.comeToFront()
        switch askAboutUnsavedEdits(Self.unsavedPaths(of: editors)) {
        case .save:
            save(editors[...]) { [weak self] written in
                // Through the run loop AppKit's wait runs: a save refused at
                // once must not answer before `.terminateLater` is returned.
                let answer: @Sendable () -> Void = {
                    MainActor.assumeIsolated {
                        guard written, let self else { return reply(false) }
                        switch self.mergeQueueTerminateReply(reply: reply) {
                        case .terminateNow: reply(true)
                        case .terminateCancel: reply(false)
                        // The queue answers through `reply`.
                        default: break
                        }
                    }
                }
                RunLoop.main.perform(inModes: [.default, .modalPanel], block: answer)
            }
            return .terminateLater
        case .discard:
            return mergeQueueTerminateReply(reply: reply)
        case .cancel:
            return .terminateCancel
        }
    }

    var hasUnsavedEditors: Bool { !Self.unsavedEditors(in: openWorkspaceColumns).isEmpty }

    private var openWorkspaceColumns: [ColumnState] {
        workspaces.filter { !$0.isClosing }.flatMap(\.openColumns)
    }

    private static func unsavedEditors(in columns: [ColumnState]) -> [EditorColumn] {
        columns.compactMap(\.editorColumn).filter { !$0.unsavedPaths.isEmpty }
    }

    /// A file open in two editors is named once.
    private static func unsavedPaths(of editors: [EditorColumn]) -> [String] {
        var named = Set<String>()
        return editors.flatMap(\.unsavedPaths).filter { named.insert($0).inserted }
    }

    /// One editor after the other; the first that fails stops the rest and
    /// shows.
    private func save(_ editors: ArraySlice<EditorColumn>, then completion: @escaping (Bool) -> Void) {
        guard let editor = editors.first else { return completion(true) }
        editor.saveAll { [weak self] written in
            guard let self else { return completion(false) }
            guard written else {
                self.reveal(editor)
                return completion(false)
            }
            self.save(editors.dropFirst(), then: completion)
        }
    }

    private func reveal(_ editor: EditorColumn) {
        guard let workspace = workspaces.first(where: { $0.columns.contains { $0.editorColumn === editor } }) else { return }
        focusWorkspace(id: workspace.id, column: workspace.columns.firstIndex { $0.editorColumn === editor })
    }
}
