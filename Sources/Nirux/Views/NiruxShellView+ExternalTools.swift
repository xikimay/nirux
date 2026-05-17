import AppKit

// MARK: - External Tools, Cookie Import, URL Input

extension NiruxShellView {
    static func shellQuotedArgument(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Build a `claude …` shell command for the given launch mode.
    /// `handoverPrompt` is appended as a single-quoted positional argument
    /// (used by the worktree handover flow).
    ///
    /// Prefixed with `command` so a user alias like
    /// `alias claude="claude --dangerously-skip-permissions"` doesn't override
    /// the launch mode Nirux selected.
    static func claudeCommand(
        continueSession: Bool = false,
        mode: ClaudeLaunchMode,
        handoverPrompt: String? = nil
    ) -> String {
        var parts = ["command", "claude"]
        if continueSession { parts.append("--continue") }
        parts.append(contentsOf: mode.cliArgs)
        if let prompt = handoverPrompt {
            parts.append(Self.shellQuotedArgument(prompt))
        }
        return parts.joined(separator: " ")
    }

    static func currentClaudeLaunchMode() -> ClaudeLaunchMode {
        Persistence.load()?.settings?.claudeLaunchMode ?? .default
    }

    /// Build a `codex …` shell command for the given launch mode.
    /// `resumeLast` produces `codex resume --last` (used when restoring a
    /// previously-running Codex column).
    /// `handoverPrompt` is appended as a single-quoted positional prompt
    /// (used by the worktree handover flow).
    ///
    /// `command` prefix mirrors `claudeCommand` so any user alias on `codex`
    /// can't override the launch flags Nirux selected.
    static func codexCommand(
        resumeLast: Bool = false,
        mode: CodexLaunchMode,
        handoverPrompt: String? = nil
    ) -> String {
        var parts = ["command", "codex"]
        if resumeLast { parts.append(contentsOf: ["resume", "--last"]) }
        parts.append(contentsOf: mode.cliArgs)
        if let prompt = handoverPrompt {
            parts.append(Self.shellQuotedArgument(prompt))
        }
        return parts.joined(separator: " ")
    }

    static func currentCodexLaunchMode() -> CodexLaunchMode {
        Persistence.load()?.settings?.codexLaunchMode ?? .default
    }

    func openClaudeCode() {
        guard let workspace = activeWorkspace else { return }
        let cmd = Self.claudeCommand(mode: Self.currentClaudeLaunchMode())
        workspace.addColumn()
        relayout(animated: false)
        updateSidebar()
        // Send claude command to the new terminal after shell starts
        if let col = workspace.columns[safe: workspace.focusedIndex] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                col.pty?.sendRaw("\(cmd)\n")
            }
        }
        focusActiveTerminal(in: window)
    }

    func openCodex() {
        guard let workspace = activeWorkspace else { return }
        let cmd = Self.codexCommand(mode: Self.currentCodexLaunchMode())
        workspace.addColumn()
        relayout(animated: false)
        updateSidebar()
        if let col = workspace.columns[safe: workspace.focusedIndex] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                col.pty?.sendRaw("\(cmd)\n")
            }
        }
        focusActiveTerminal(in: window)
    }

    func openDiffInEditor(workspaceIndex: Int) {
        guard workspaces.indices.contains(workspaceIndex) else { return }
        openDiffInEditor(for: workspaces[workspaceIndex])
    }

    func openDiffInEditor(for workspace: WorkspaceState) {
        let cwd = currentWorkspaceCwd(for: workspace)
        PRDetect.diffPathsAsync(cwd: cwd) { [weak self, weak workspace] paths in
            guard let self, let workspace else { return }
            guard !paths.isEmpty else {
                NSSound.beep()
                return
            }

            guard let editor = self.editorColumn(in: workspace, cwd: cwd) else {
                NSSound.beep()
                return
            }
            editor.showDiffCollection(
                title: "Uncommitted Changes (\(paths.count))",
                paths: paths,
                mode: .head
            )

            if let columnIndex = workspace.columns.firstIndex(where: { $0.editorColumn === editor }) {
                workspace.focusedIndex = columnIndex
            }
            if let workspaceIndex = self.workspaces.firstIndex(where: { $0 === workspace }) {
                self.activeWSIndex = workspaceIndex
            }
            self.relayout(animated: false)
            self.updateSidebar()
        }
    }

    private func editorColumn(in workspace: WorkspaceState, cwd: String) -> EditorColumn? {
        if let existing = workspace.columns.compactMap({ $0.editorColumn }).first(where: { $0.workspaceCwd == cwd }) {
            return existing
        }
        workspace.addEditorColumn(workspaceCwd: cwd)
        guard let editor = workspace.columns[safe: workspace.focusedIndex]?.editorColumn else { return nil }
        wireEditor(editor)
        return editor
    }

    // MARK: - Worktree Skill

    private static let worktreeSkillContent = """
        ---
        name: nirux-worktree
        description: >
          This skill should be used when the user asks to "create a worktree", "crée un worktree",
          "new worktree", "start a new feature", "start working on X", "work on X in a separate
          workspace", "branch off for X", "spin up a workspace", "open a workspace for X",
          "work on this in parallel", "fix X separately", "isolate this change",
          "commencer une nouvelle feature", "travailler sur X en parallèle", or describes any
          task that should happen in isolation from the current branch. Not intended for simple
          branch switching in-place or questions about what worktrees are.
        metadata:
          author: nirux
        ---

        ## Overview

        Spawn a new Nirux workspace backed by a git worktree, with a session handover so the new
        workspace inherits context from the current session. The user does not need to say "worktree"
        explicitly — phrases like "start working on X", "create a branch for Y", or "fix this
        separately" all qualify.

        ## Steps

        1. **Determine the branch name** from the user's request. If not specified, check recent
           branch names (`git branch -a`) for a naming convention and follow it. Default to
           `feat/short-description` or `fix/short-description` if no convention is apparent.
        2. **Detect the git repo root**:
           ```bash
           git rev-parse --show-toplevel
           ```
        3. **Write a session handover** to a temp file so the new workspace inherits context.
           Use the current agent name (`claude` or `codex`) in the temp filename:
           ```bash
           cat > /tmp/nirux-handover-<agent>-<branch-with-slashes-replaced-by-dashes>.md << 'HANDOVER'
           # Session Handover
           ## Goal
           <what the user is trying to accomplish>
           ## Context
           <key decisions, relevant file paths, architecture notes>
           ## Done so far
           <what has been completed in this session>
           ## Next steps
           <what the new worktree session should focus on>
           HANDOVER
           ```
           Keep the handover concise but include enough context for a fresh session to continue
           without asking.
        4. **Open the worktree in Nirux** — Nirux handles git worktree creation, moves the handover
           file into the worktree as `.claude-handover.md` or `.codex-handover.md`, and launches
           the same agent:
           ```bash
           open "nirux://new-worktree?branch=<url-encoded-branch>&repo=<url-encoded-repo-root>&agent=<claude-or-codex>&handover=<url-encoded-temp-path>"
           ```
           Nirux moves the handover file into the worktree on launch; no manual cleanup is needed.

        Do NOT run git worktree commands directly — Nirux handles worktree creation natively.
        """

    func installWorktreeSkill() {
        // Swift multiline strings already normalize indentation. Preserve the
        // authored content verbatim so YAML front matter stays valid.
        let content = Self.worktreeSkillContent + "\n"

        let destinations = [
            NSHomeDirectory() + "/.agents/skills/nirux-worktree",  // Codex, Cursor, Copilot, etc.
            NSHomeDirectory() + "/.claude/skills/nirux-worktree"  // Claude Code
        ]

        do {
            for dir in destinations {
                try FileManager.default.createDirectory(
                    atPath: dir, withIntermediateDirectories: true)
                try content.write(toFile: dir + "/SKILL.md", atomically: true, encoding: .utf8)
            }

            let alert = NSAlert()
            alert.messageText = "Worktree Skill Installed"
            alert.informativeText = "Installed to ~/.agents/skills/ and ~/.claude/skills/\nAll agents will auto-detect it."
            alert.runModal()
        } catch {
            let alert = NSAlert()
            alert.messageText = "Install Failed"
            alert.informativeText = error.localizedDescription
            alert.alertStyle = .warning
            alert.runModal()
        }
    }

    // MARK: - Cookie Import

    func importCookieSubtitle() -> String {
        let browsers = CookieImporter.availableBrowsers.map(\.rawValue)
        return browsers.isEmpty ? "No Chromium browsers detected" : "From \(browsers.joined(separator: ", "))"
    }

    func importBrowserCookies() {
        let browsers = CookieImporter.availableBrowsers
        guard let browser = browsers.first else { return }

        Task {
            do {
                let result = try await CookieImporter.importCookies(from: browser, into: WebViewColumn.sharedDataStore)
                let alert = NSAlert()
                alert.messageText = "Cookies Imported"
                let failNote = result.failed > 0 ? " \(result.failed) failed." : ""
                alert.informativeText = "Imported \(result.imported) cookies from \(result.browser.rawValue).\(failNote)"
                alert.runModal()
            } catch {
                let alert = NSAlert()
                alert.messageText = "Import Failed"
                alert.informativeText = error.localizedDescription
                alert.alertStyle = .warning
                alert.runModal()
            }
        }
    }

    // MARK: - URL Input

    func showURLInput() {
        guard let window else { return }
        if urlPanel == nil {
            let panel = URLInputPanel()
            panel.onSubmit = { [weak self] url in
                self?.openWebView(url: url)
            }
            urlPanel = panel
        }
        urlPanel?.show(relativeTo: window)
    }

    func openWebView(url: String) {
        guard let workspace = activeWorkspace else { return }
        workspace.addColumn(webViewURL: url)
        relayout(animated: false)
        updateSidebar()
        focusActiveTerminal(in: window)
    }

    /// Open a Monaco editor column scoped to the active workspace's cwd.
    /// Picks a reasonable starter file (README, Package.swift, etc.) so the
    /// editor isn't blank on first open.
    func openEditorColumn() {
        guard let workspace = activeWorkspace else { return }
        let cwd = currentWorkspaceCwd(for: workspace)
        let starter = Self.pickStarterFile(in: cwd)
        workspace.addEditorColumn(initialFile: starter, workspaceCwd: cwd)

        if let editor = workspace.columns[safe: workspace.focusedIndex]?.editorColumn {
            wireEditor(editor)
        }

        relayout(animated: false)
        updateSidebar()
    }

    /// Wires every callback an `EditorColumn` needs back into the shell view.
    /// Called from both `openEditorColumn` (palette flow) and `restoreState`
    /// (relaunch flow), so the behavior is identical in both paths.
    func wireEditor(_ editor: EditorColumn) {
        editor.onFilePickerRequest = { [weak self] editor in
            self?.showFilePicker(for: editor)
        }
    }

    /// Show the workspace file picker, opening the chosen file in `editor`.
    func showFilePicker(for editor: EditorColumn) {
        guard let window else { return }
        if filePickerPanel == nil { filePickerPanel = FilePickerPanel() }
        filePickerPanel?.show(
            relativeTo: window,
            workspaceCwd: editor.workspaceCwd
        ) { [weak editor] absolutePath in
            editor?.open(path: absolutePath)
        }
    }

    /// Open a file in an editor column at an optional line. If the active
    /// workspace doesn't yet have an editor column, one is added; otherwise
    /// the existing one is reused so search results don't pile up new
    /// columns. Used by the workspace-wide search panel.
    func openInEditorColumn(path: String, line: Int? = nil, workspaceCwd: String? = nil) {
        guard let workspace = activeWorkspace else { return }
        let editorRoot = workspaceCwd ?? currentWorkspaceCwd(for: workspace)
        let existingEditor = workspace.columns
            .compactMap { $0.editorColumn }
            .first { $0.workspaceCwd == editorRoot }
            ?? (workspaceCwd == nil ? workspace.columns.compactMap { $0.editorColumn }.first : nil)

        if let existing = existingEditor {
            existing.open(path: path, line: line)
            if let idx = workspace.columns.firstIndex(where: { $0.editorColumn === existing }) {
                workspace.focusedIndex = idx
                relayout(animated: false)
                updateSidebar()
            }
            return
        }
        workspace.addEditorColumn(initialFile: path, workspaceCwd: editorRoot)
        if let editor = workspace.columns[safe: workspace.focusedIndex]?.editorColumn {
            wireEditor(editor)
            if let line { editor.open(path: path, line: line) }
        }
        relayout(animated: false)
        updateSidebar()
    }

    /// Toggle Monaco's selected diff view on the focused editor
    /// column. No-op when the focused column isn't an editor — the shortcut
    /// just gets swallowed.
    func toggleEditorDiff() {
        guard let workspace = activeWorkspace,
              let editor = workspace.columns[safe: workspace.focusedIndex]?.editorColumn
        else { return }
        editor.toggleDiff()
    }

    /// Open the workspace-wide search panel scoped to the active workspace
    /// cwd. Picking a result routes through `openInEditorColumn`.
    func showWorkspaceSearch() {
        guard let workspace = activeWorkspace, let window else { return }
        let cwd = currentWorkspaceCwd(for: workspace)
        if searchPanel == nil { searchPanel = EditorSearchPanel() }
        searchPanel?.show(
            relativeTo: window,
            workspaceCwd: cwd
        ) { [weak self] absPath, line in
            self?.openInEditorColumn(path: absPath, line: line, workspaceCwd: cwd)
        }
    }

    private func currentWorkspaceCwd(for workspace: WorkspaceState) -> String {
        guard let col = workspace.columns[safe: workspace.focusedIndex] else { return workspace.cwd }
        return col.pty?.childCwd ?? col.editorColumn?.workspaceCwd ?? workspace.cwd
    }

    private static let starterCandidates = [
        "README.md", "README", "readme.md",
        "Package.swift", "package.json", "Cargo.toml",
        "pyproject.toml", "go.mod"
    ]

    private static func pickStarterFile(in cwd: String) -> String? {
        let fm = FileManager.default
        for name in starterCandidates {
            let candidate = (cwd as NSString).appendingPathComponent(name)
            if fm.fileExists(atPath: candidate) { return candidate }
        }
        return nil
    }
}
