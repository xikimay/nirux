import AppKit

// MARK: - Command Palette rows

extension NiruxShellView {
    func columnPaletteActions() -> [PaletteAction] {
        [
            PaletteAction(
                icon: "🌐", title: "Open Browser", subtitle: "Open a URL in a new WebView column",
                shortcut: .openBrowser
            ) { [weak self] in
                self?.commandPalette?.switchToURLMode()
            },
            PaletteAction(icon: "🔑", title: "Import Browser Cookies", subtitle: importCookieSubtitle(), shortcut: nil) { [weak self] in
                self?.importBrowserCookies()
            },
            PaletteAction(
                icon: "▶", title: "New Terminal", subtitle: "Open a new terminal column",
                shortcut: .newTerminal
            ) { [weak self] in
                self?.addColumn()
            },
            PaletteAction(
                icon: "↔", title: "Resize Column (Cycle Width)", subtitle: "Snap the focused column through width presets",
                shortcut: .cycleWidth
            ) { [weak self] in
                self?.cycleActiveColumnWidth()
            },
            PaletteAction(icon: "📝", title: "Open Editor", subtitle: "Edit files in the current workspace", shortcut: nil) { [weak self] in
                self?.openEditorColumn()
            },
            PaletteAction(
                icon: "📋", title: "Open Project Board",
                subtitle: "Branches, agents and pull requests of the current project",
                shortcut: nil
            ) { [weak self] in
                self?.openProjectBoard()
            },
            PaletteAction(
                icon: "🔎", title: "Search Workspace", subtitle: "Find text across files in the current workspace",
                shortcut: .searchWorkspace
            ) { [weak self] in
                self?.showWorkspaceSearch()
            },
            PaletteAction(
                icon: "🔦", title: "Search Everywhere",
                subtitle: "Find text in every terminal's scrollback, across workspaces and projects",
                shortcut: .searchEverywhere
            ) { [weak self] in
                self?.showGlobalSearch()
            },
            PaletteAction(
                icon: "🔀", title: "Toggle Editor Diff", subtitle: "Show the diff for the active editor file",
                shortcut: .toggleEditorDiff
            ) { [weak self] in
                self?.toggleEditorDiff()
            },
            PaletteAction(
                icon: "🔬", title: "Toggle Web Inspector", subtitle: "Inspect the focused browser column",
                shortcut: .webInspector
            ) { [weak self] in
                self?.toggleDevTools()
            }
        ]
    }

    func agentPaletteActions() -> [PaletteAction] {
        [
            PaletteAction(icon: "🤖", title: "Open Claude Code", subtitle: "Launch Claude Code in a new terminal", shortcut: nil) { [weak self] in
                self?.openClaudeCode()
            },
            PaletteAction(icon: "📦", title: "Open Codex", subtitle: "Launch OpenAI Codex in a new terminal", shortcut: nil) { [weak self] in
                self?.openCodex()
            },
            PaletteAction(
                icon: "⏳", title: "Next Waiting Agent",
                subtitle: "Jump to the agent blocked on you the longest, then the next",
                shortcut: .nextWaitingAgent
            ) { [weak self] in
                self?.jumpToNextWaitingAgent()
            }
        ]
    }

    func workspacePaletteActions() -> [PaletteAction] {
        [
            PaletteAction(
                icon: "📂", title: "New Workspace", subtitle: "Create a new workspace",
                shortcut: .newWorkspace
            ) { [weak self] in
                self?.showNewWorkspacePanel()
            },
            PaletteAction(
                icon: "🚀", title: "New Task…",
                subtitle: "Describe a task: Nirux makes its worktree and hands it to an agent",
                shortcut: nil
            ) { [weak self] in
                self?.showNewTaskPanel()
            },
            PaletteAction(icon: "🌳", title: "New Worktree", subtitle: "Create a git worktree + workspace", shortcut: nil) { [weak self] in
                self?.showWorktreePanel()
            },
            PaletteAction(icon: "🌿", title: "Open Worktree", subtitle: "Open an existing worktree, or go back to its workspace", shortcut: nil) { [weak self] in
                self?.showWorktreeListPalette()
            },
            PaletteAction(
                icon: "🧹", title: "Clean Up Merged Worktrees…",
                subtitle: "Delete worktrees and local branches whose pull request is merged",
                shortcut: nil
            ) { [weak self] in
                self?.showWorktreeCleanupPanel()
            },
            PaletteAction(
                icon: "◧", title: "Show/Hide Sidebar", subtitle: "Toggle the workspace sidebar",
                shortcut: .toggleSidebar
            ) { [weak self] in
                self?.toggleSidebar()
            },
            PaletteAction(
                icon: "▸", title: "Show/Hide Inactive Workspaces", subtitle: "Unfold or fold the sidebar's INACTIVE section",
                shortcut: nil
            ) { [weak self] in
                self?.sidebar.toggleInactiveSection()
            },
            PaletteAction(icon: "✏", title: "Rename Workspace", subtitle: "Change the name of the current workspace", shortcut: nil) { [weak self] in
                self?.showRenamePanel()
            },
            PaletteAction(
                icon: "⚙",
                title: "Install Agent Skills",
                subtitle: "Worktree workspaces + open code in the editor from agents",
                shortcut: nil
            ) { [weak self] in
                self?.installAgentSkills()
            },
            PaletteAction(
                icon: "🧭",
                title: "Show Getting Started",
                subtitle: "Checklist: agent CLIs, skills, status hooks and shortcuts",
                shortcut: nil
            ) { [weak self] in
                self?.showOnboardingChecklist()
            },
            PaletteAction(
                icon: "🛠", title: "Open Settings", subtitle: "Agent launch modes, remote access and experiments",
                shortcut: .settings
            ) {
                NSApp.sendAction(#selector(NiruxApp.showSettings(_:)), to: nil, from: nil)
            }
        ]
    }
}
