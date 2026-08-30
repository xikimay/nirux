import AppKit

// MARK: - External Tools, Cookie Import, URL Input

extension NiruxShellView {
    enum CodexResumeTarget: Equatable {
        /// No stored thread ID (state written by an older Nirux, or a Codex
        /// session that has not completed a turn yet). Let the user choose;
        /// silently using `--last` can attach several columns to one thread.
        case picker
        case session(String)
    }

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
    /// Restores use either an exact thread ID or Codex's interactive picker;
    /// they deliberately never guess with `resume --last`.
    /// `handoverPrompt` is appended as a single-quoted positional prompt
    /// (used by the worktree handover flow).
    ///
    /// `command` prefix mirrors `claudeCommand` so any user alias on `codex`
    /// can't override the launch flags Nirux selected.
    static func codexCommand(
        resume: CodexResumeTarget? = nil,
        mode: CodexLaunchMode,
        handoverPrompt: String? = nil
    ) -> String {
        var parts = ["command", "codex"]
        if let resume {
            parts.append("resume")
            if case .session(let sessionID) = resume {
                parts.append(Self.shellQuotedArgument(sessionID))
            }
        }
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

    // Generated shell commands must stay on one line in the installed skill.
    // swiftlint:disable line_length
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
           the same agent. Nirux terminals expose `NIRUX_PROFILE_ID`; preserve it in the URL so
           the new workspace opens in the same Nirux session/space even if the user has focused a
           different one:
           ```bash
           profile_query=""
           if [ -n "${NIRUX_PROFILE_ID:-}" ]; then
             profile_query="&profile=${NIRUX_PROFILE_ID}"
           fi
           open "nirux://new-worktree?branch=<url-encoded-branch>&repo=<url-encoded-repo-root>&agent=<claude-or-codex>&handover=<url-encoded-temp-path>${profile_query}"
           ```
           Nirux moves the handover file into the worktree on launch; no manual cleanup is needed.

        Do NOT run git worktree commands directly — Nirux handles worktree creation natively.
        """
    // swiftlint:enable line_length

    // MARK: - Show-Code Skill

    private static let showCodeSkillContent = """
        ---
        name: nirux-show-code
        description: >
          This skill should be used when the user asks to SEE code — "show me the code",
          "montre-moi le code", "show me where X is defined", "ouvre ce fichier",
          "fais voir cette fonction", "where is this handled", "open that file",
          "let me see that function", "où est défini X" — while the session runs inside
          a Nirux terminal (the NIRUX_WORKSPACE_ID environment variable is set). Opens
          the snippet in the Nirux editor column instead of pasting it into the terminal.
          Not intended for editing code or for sessions outside Nirux.
        metadata:
          author: nirux
        ---

        ## Overview

        Nirux (the terminal app hosting this session) has a built-in code editor column.
        Instead of quoting a long snippet in the reply, open the file directly in the
        editor at the right lines via the `nirux://open-editor` URL scheme. The editor
        reveals and highlights the range; the terminal reply stays to one line.

        ## Preconditions

        Only use this when `$NIRUX_WORKSPACE_ID` is set (the session runs inside Nirux):

        ```bash
        [ -n "$NIRUX_WORKSPACE_ID" ] && echo inside-nirux
        ```

        If it is unset, do NOT use the URL — quote the relevant code in the reply as usual.

        ## Steps

        1. **Locate the code** with Grep/Read: absolute file path, start line, and end
           line of the relevant snippet. Verify the file exists (`[ -f "$path" ]`) —
           Nirux silently ignores requests for missing files, so a bad path would
           leave the user staring at nothing.
        2. **Open it in the editor**:
           ```bash
           encoded=$(python3 -c 'import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1]))' "$abs_path")
           open "nirux://open-editor?file=${encoded}&line=<start>&endLine=<end>&workspace=$NIRUX_WORKSPACE_ID"
           ```
           - `file` is required and must be an **absolute** path, URL-encoded. Files
             larger than 5 MB are refused — quote the snippet in the reply instead.
           - `line` is optional (1-based). `endLine` is optional; when present the
             editor selects/highlights the whole `line..endLine` range — prefer passing
             both so the user sees the snippet boundaries.
           - `workspace=$NIRUX_WORKSPACE_ID` makes Nirux switch to this session's
             workspace before opening; keep it in the command.
        3. **Still answer in the terminal**, one line: what it is and where, e.g.
           `AgentHookCenter.swift:44 — parsing du workspaceID`. The editor shows the
           code; the reply gives the pointer.

        Requires a Nirux build from 2026-07-20 or newer — on older builds the URL
        only brings Nirux forward without opening anything. If nothing opens, fall
        back to quoting the code in the reply.

        ## Multiple matches

        Open the most relevant snippet in the editor, and mention the others as
        `path/file.swift:123` references in the reply — file:line references are
        clickable in the Nirux terminal.
        """

    /// Name → content of every skill Nirux ships. Installed together: the
    /// set is small and versioned with the app, so partial installs would
    /// only create confusion about which copy is current.
    private static let agentSkills = [
        "nirux-worktree": worktreeSkillContent,
        "nirux-show-code": showCodeSkillContent
    ]

    func installAgentSkills() {
        // Swift multiline strings already normalize indentation. Preserve the
        // authored content verbatim so YAML front matter stays valid.
        let roots = [
            NSHomeDirectory() + "/.agents/skills",  // Codex, Cursor, Copilot, etc.
            NSHomeDirectory() + "/.claude/skills"  // Claude Code
        ]

        do {
            for (name, content) in Self.agentSkills {
                for root in roots {
                    let dir = root + "/" + name
                    try FileManager.default.createDirectory(
                        atPath: dir, withIntermediateDirectories: true)
                    try (content + "\n").write(toFile: dir + "/SKILL.md", atomically: true, encoding: .utf8)
                }
            }

            let alert = NSAlert()
            alert.messageText = "Agent Skills Installed"
            let names = Self.agentSkills.keys.sorted().joined(separator: ", ")
            alert.informativeText = "Installed \(names) to ~/.agents/skills/ and ~/.claude/skills/\nAll agents will auto-detect them."
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
        guard !browsers.isEmpty else { return }

        guard browsers.count > 1 else {
            runCookieImport(from: browsers[0])
            return
        }

        // Several Chromium browsers installed — let the user pick the source.
        let alert = NSAlert()
        alert.messageText = "Import Cookies"
        alert.informativeText = "Choose a browser to import cookies from."
        for browser in browsers {
            alert.addButton(withTitle: browser.rawValue)
        }
        alert.addButton(withTitle: "Cancel")
        let response = alert.runModal()
        let index = response.rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
        guard browsers.indices.contains(index) else { return }
        runCookieImport(from: browsers[index])
    }

    private func runCookieImport(from browser: CookieImporter.Browser) {
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

    func openWebView(url: String, in workspace: WorkspaceState? = nil) {
        guard let workspace = workspace ?? activeWorkspace else { return }
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
        // Keep the sidebar's file name + dirty dot in sync with the active
        // tab instead of waiting out the 2s heartbeat.
        editor.onPathChanged = { [weak self] in self?.updateSidebar() }
        editor.onDirtyChanged = { [weak self] in self?.updateSidebar() }
        editor.onSendSelectionShortcut = { [weak self] in self?.sendEditorSelectionToAgent() }
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

    /// Open a file in an editor column at an optional line. If the target
    /// workspace doesn't yet have an editor column, one is added; otherwise
    /// the existing one is reused so search results don't pile up new
    /// columns. Used by the workspace-wide search panel and terminal
    /// file: links (which pass the workspace the link was clicked in).
    func openInEditorColumn(
        path: String, line: Int? = nil, endLine: Int? = nil, workspaceCwd: String? = nil,
        takeFocus: Bool = true, interactive: Bool = true,
        in targetWorkspace: WorkspaceState? = nil
    ) {
        guard let workspace = targetWorkspace ?? activeWorkspace else { return }
        let editorRoot = workspaceCwd ?? currentWorkspaceCwd(for: workspace)
        let existingEditor = workspace.columns
            .compactMap { $0.editorColumn }
            .first { $0.workspaceCwd == editorRoot }
            ?? (workspaceCwd == nil ? workspace.columns.compactMap { $0.editorColumn }.first : nil)

        // focusedIndex moves even for takeFocus:false opens: the camera
        // only keeps the FOCUSED column visible, so leaving it put could
        // reveal entirely off-screen in wide layouts. Keyboard focus is
        // protected separately (the focus:false bridge flag) — the trade
        // is that column-level commands (Cmd+W etc.) now target the
        // agent-opened editor, which conveniently makes Cmd+W a dismiss.
        if let existing = existingEditor {
            existing.open(path: path, line: line, endLine: endLine, takeFocus: takeFocus, interactive: interactive)
            if let idx = workspace.columns.firstIndex(where: { $0.editorColumn === existing }) {
                workspace.focusedIndex = idx
                relayout(animated: false)
                updateSidebar()
            }
            return
        }
        // Column first, single open after wiring — an initialFile + second
        // line-targeted open would run the failure alert / large-file
        // confirmation twice for the same file.
        workspace.addEditorColumn(workspaceCwd: editorRoot)
        if let editor = workspace.columns[safe: workspace.focusedIndex]?.editorColumn {
            wireEditor(editor)
            editor.open(path: path, line: line, endLine: endLine, takeFocus: takeFocus, interactive: interactive)
        }
        relayout(animated: false)
        updateSidebar()
    }

    /// Entry point for `nirux://open-editor` (agents opening a snippet from
    /// the terminal). Switches to the requested workspace when it resolves;
    /// an unknown or absent workspace falls through to the active one.
    /// Non-interactive and unfocused: a URL-triggered open must never pop a
    /// blocking modal (any app can fire the URL) nor move keyboard focus
    /// into the buffer while the user is typing elsewhere.
    func openEditorFromURL(_ request: OpenEditorRequest) {
        var target: WorkspaceState?
        if let id = request.workspaceID,
           let index = workspaces.firstIndex(where: { $0.id == id }) {
            target = workspaces[index]
            switchToWorkspace(index)
        }
        openInEditorColumn(
            path: request.file, line: request.line, endLine: request.endLine,
            takeFocus: false, interactive: false, in: target
        )
    }

    /// Send the editor's current selection into a terminal column of the
    /// same workspace as a `path:Lx-Ly` header plus fenced excerpt, so the
    /// user can point the agent at code without retyping paths. Prefers the
    /// focused column on both ends: the focused editor (else the first
    /// editor column) supplies the selection, the focused terminal (else
    /// the first live terminal column) receives it. No-op with a log when
    /// either side is missing or nothing is selected.
    func sendEditorSelectionToAgent() {
        guard let workspace = activeWorkspace else { return }
        let focused = workspace.columns[safe: workspace.focusedIndex]
        guard let editor = focused?.editorColumn
            ?? workspace.columns.compactMap({ $0.editorColumn }).first else {
            NiruxDebugLog.log("sendSelectionToAgent: no editor column in workspace")
            return
        }
        let terminal = (focused?.pty?.hasExited == false ? focused : nil)
            ?? workspace.columns.first { $0.pty?.hasExited == false }
        guard let pty = terminal?.pty, !pty.hasExited else {
            NiruxDebugLog.log("sendSelectionToAgent: no live terminal column in workspace")
            return
        }

        editor.requestSelection { [weak editor, weak pty] selection in
            guard let editor, let pty else { return }
            // Path mismatch means the reply is stale (e.g. a diff-group tab
            // is showing while the hidden editor still holds an old model).
            guard let selection, selection.path == editor.currentPath else {
                NiruxDebugLog.log("sendSelectionToAgent: no selection")
                return
            }
            let cwdPrefix = editor.workspaceCwd + "/"
            let path = selection.path.hasPrefix(cwdPrefix)
                ? String(selection.path.dropFirst(cwdPrefix.count))
                : selection.path
            let excerpt = AgentExcerpt.format(
                path: path,
                startLine: selection.startLine,
                endLine: selection.endLine,
                text: selection.text
            )
            // Bracketed paste: the multiline excerpt lands in the agent's
            // input as one paste instead of the first newline submitting a
            // half-built prompt.
            pty.sendRaw("\u{1B}[200~\(excerpt)\u{1B}[201~")
        }
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

    /// Toggle word wrap on the focused editor column. No-op elsewhere.
    func toggleWordWrap() {
        guard let workspace = activeWorkspace,
              let editor = workspace.columns[safe: workspace.focusedIndex]?.editorColumn
        else { return }
        editor.toggleWordWrap()
    }

    /// Save all dirty buffers in the focused editor column. No-op elsewhere.
    func saveAllInEditor() {
        guard let workspace = activeWorkspace,
              let editor = workspace.columns[safe: workspace.focusedIndex]?.editorColumn
        else { return }
        editor.saveAll()
    }

    /// Toggle the minimap on the focused editor column. No-op elsewhere.
    func toggleMinimap() {
        guard let workspace = activeWorkspace,
              let editor = workspace.columns[safe: workspace.focusedIndex]?.editorColumn
        else { return }
        editor.toggleMinimap()
    }

    /// Open the Web Inspector on the focused browser column. No-op elsewhere.
    func toggleDevTools() {
        guard let workspace = activeWorkspace,
              let web = workspace.columns[safe: workspace.focusedIndex]?.webViewColumn
        else { return }
        web.toggleInspector()
    }

    /// Focus the URL field of the focused browser column (Cmd+L). No-op
    /// elsewhere so terminal Cmd+L keeps its terminal meaning.
    func focusAddressBar() {
        guard let workspace = activeWorkspace,
              let web = workspace.columns[safe: workspace.focusedIndex]?.webViewColumn
        else { return }
        web.focusAddressBar()
    }

    /// Focus a column by 1-based number (Cmd+1…9). Out-of-range no-ops.
    func focusColumn(number: Int) {
        guard let workspace = activeWorkspace,
              workspace.columns.indices.contains(number - 1)
        else { return }
        focusColumnByIndex(number - 1)
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
