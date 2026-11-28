import AppKit

/// The user's own editor (Zed, Cursor, VS Code), where Settings › General's
/// "Open files in" sends a terminal's file link they ⌘-click, and which ⌘P
/// then offers for the workspace's folder. Everything else (Open Editor,
/// what an agent shows, drafts, diffs) stays in Nirux's.
extension NiruxShellView {
    /// The user's editors installed, in `ExternalEditor.all`'s order.
    var installedEditors: [ExternalEditor] {
        ExternalEditor.all.filter { sideEffects.applicationURL($0.bundleID) != nil }
    }

    /// "Open files in"'s editor; nil: Nirux's.
    var chosenEditor: ExternalEditor? { ExternalEditor.withBundleID(Persistence.load()?.settings?.openFilesIn) }

    /// Opens `path` in `editor`, else `otherwise`: it isn't installed, or
    /// couldn't open it.
    func open(
        _ path: String, line: Int?, column: Int?, in editor: ExternalEditor, otherwise: @escaping @MainActor @Sendable () -> Void
    ) {
        guard let application = sideEffects.applicationURL(editor.bundleID),
              let url = editor.url(path: path, line: line, column: column)
        else { return otherwise() }
        sideEffects.openInApplication(url, application) { opened in
            if !opened { otherwise() }
        }
    }

    /// A terminal's file link, ⌘-clicked: in "Open files in"'s editor, else
    /// in Nirux's. At a line and column always, so that a name ending in
    /// ":12" isn't read as one.
    func openFileFromTerminal(path: String, line: Int?, in workspace: WorkspaceState) {
        let inNirux: @MainActor @Sendable () -> Void = { [weak self, weak workspace] in
            guard let self, let workspace else { return }
            self.openInEditorColumn(path: path, line: line, in: workspace)
        }
        guard let editor = chosenEditor else { return inNirux() }
        open(path, line: line ?? 1, column: 1, in: editor, otherwise: inNirux)
    }

    /// ⌘P's Open in <editor>, for "Open files in"'s editor while installed:
    /// the workspace's folder there.
    func openInYourEditorAction() -> PaletteAction? {
        guard let editor = chosenEditor, installedEditors.contains(editor) else { return nil }
        return PaletteAction(
            icon: .symbol("arrow.up.forward.app"), title: "Open in \(editor.name)",
            subtitle: "Open the workspace’s folder in \(editor.name)", shortcut: nil
        ) { [weak self] in
            guard let self, let workspace = self.activeWorkspace else { return }
            self.open(workspace.focusedWorkingDirectory, line: nil, column: nil, in: editor) { [weak self] in
                self?.showToast("Couldn’t open the workspace in \(editor.name)", tone: .error)
            }
        }
    }

    /// The editor's ⋯: Open in each editor installed, Reveal in Finder.
    func wireOpenElsewhere(_ editor: EditorColumn) {
        editor.installedEditors = { [weak self] in self?.installedEditors ?? [] }
        editor.onOpenElsewhere = { [weak self] external, path, line, column in
            self?.open(path, line: line, column: column, in: external) { [weak self] in
                self?.showToast("Couldn’t open “\((path as NSString).lastPathComponent)” in \(external.name)", tone: .error)
            }
        }
        editor.onRevealInFinder = { [weak self] path in self?.sideEffects.revealInFinder(URL(fileURLWithPath: path)) }
    }
}
