import AppKit

// MARK: - Command Palette rows

extension NiruxShellView {
    func columnPaletteActions() -> [PaletteAction] {
        let openBrowser = PaletteAction(
            icon: .symbol("globe"), title: "Open Browser", subtitle: "Open a URL in a new WebView column",
            shortcut: .openBrowser
        ) { [weak self] in
            self?.commandPalette?.switchToURLMode()
        }
        // Offered only with a Chromium browser to import from.
        let browsers = sideEffects.cookieBrowsers()
        let importCookies = browsers.isEmpty ? [] : [
            PaletteAction(
                icon: .symbol("key"), title: "Import Browser Cookies",
                subtitle: "From " + browsers.map(\.rawValue).joined(separator: ", "), shortcut: nil
            ) { [weak self] in
                self?.importBrowserCookies()
            }
        ]
        return [openBrowser] + importCookies + [
            PaletteAction(
                icon: .symbol("terminal"), title: "New Terminal", subtitle: "Open a new terminal column",
                shortcut: .newTerminal
            ) { [weak self] in
                self?.addColumn()
            },
            PaletteAction(
                icon: .symbol("arrow.left.and.right"), title: "Resize Column (Cycle Width)",
                subtitle: "Snap the focused column through width presets",
                shortcut: .cycleWidth
            ) { [weak self] in
                self?.cycleActiveColumnWidth()
            },
            PaletteAction(
                icon: .symbol("chevron.left.forwardslash.chevron.right"), title: "Open Editor",
                subtitle: "Edit files in the current workspace", shortcut: nil
            ) { [weak self] in
                self?.openEditorColumn()
            },
            PaletteAction(
                icon: .symbol("tablecells"), title: "Open Project Board",
                subtitle: "Branches, agents and pull requests of the current project",
                shortcut: nil
            ) { [weak self] in
                self?.openProjectBoard()
            },
            PaletteAction(
                icon: .symbol("magnifyingglass"), title: "Search Workspace", subtitle: "Find text across files in the current workspace",
                shortcut: .searchWorkspace
            ) { [weak self] in
                self?.showWorkspaceSearch()
            },
            PaletteAction(
                icon: .symbol("text.magnifyingglass"), title: "Search Everywhere",
                subtitle: "Find text in every terminal's scrollback, across workspaces and projects",
                shortcut: .searchEverywhere
            ) { [weak self] in
                self?.showGlobalSearch()
            },
            PaletteAction(
                icon: .symbol("plus.forwardslash.minus"), title: "Toggle Editor Diff", subtitle: "Show the diff for the active editor file",
                shortcut: .toggleEditorDiff
            ) { [weak self] in
                self?.toggleEditorDiff()
            },
            PaletteAction(
                icon: .symbol("ladybug"), title: "Toggle Web Inspector", subtitle: "Inspect the focused browser column",
                shortcut: .webInspector
            ) { [weak self] in
                self?.toggleDevTools()
            }
        ]
    }

    func agentPaletteActions() -> [PaletteAction] {
        [
            PaletteAction(
                icon: .agent("claude"), title: "Open Claude Code",
                subtitle: "Launch Claude Code in a new terminal", shortcut: nil
            ) { [weak self] in
                self?.openClaudeCode()
            },
            PaletteAction(
                icon: .agent("codex"), title: "Open Codex",
                subtitle: "Launch OpenAI Codex in a new terminal", shortcut: nil
            ) { [weak self] in
                self?.openCodex()
            },
            PaletteAction(
                icon: .symbol("hourglass"), title: "Next Waiting Agent",
                subtitle: "Jump to the agent blocked on you the longest, then the next",
                shortcut: .nextWaitingAgent
            ) { [weak self] in
                self?.jumpToNextWaitingAgent()
            },
            PaletteAction(
                icon: .symbol("playpause"), title: "Resume All Agents", subtitle: resumeAllAgentsSubtitle(), shortcut: nil
            ) { [weak self] in
                if self?.resumeAllDeferredAgents() != true { NSSound.beep() }
            }
        ]
    }

    private func resumeAllAgentsSubtitle() -> String {
        switch deferredAgentCount {
        case 0: return "Every restored agent is running"
        case 1: return "Start the restored agent that hasn't resumed yet"
        case let count: return "Start the \(count) restored agents that haven't resumed yet"
        }
    }

    func workspacePaletteActions() -> [PaletteAction] {
        [
            PaletteAction(
                icon: .symbol("plus.rectangle.on.rectangle"), title: "New Workspace", subtitle: "Create a new workspace",
                shortcut: .newWorkspace
            ) { [weak self] in
                self?.showNewWorkspacePanel()
            },
            PaletteAction(
                icon: .symbol("square.and.pencil"), title: "New Task…",
                subtitle: "Describe a task: Nirux makes its worktree and hands it to an agent",
                shortcut: nil
            ) { [weak self] in
                self?.showNewTaskPanel()
            },
            PaletteAction(
                icon: .symbol("arrow.triangle.branch"), title: "New Worktree",
                subtitle: "Create a git worktree + workspace", shortcut: nil
            ) { [weak self] in
                self?.showWorktreePanel()
            },
            PaletteAction(
                icon: .symbol("folder"), title: "Open Worktree",
                subtitle: "Open an existing worktree, or go back to its workspace", shortcut: nil
            ) { [weak self] in
                self?.showWorktreeListPalette()
            },
            PaletteAction(
                icon: .symbol("trash"), title: "Clean Up Merged Worktrees…",
                subtitle: "Delete worktrees and local branches whose pull request is merged",
                shortcut: nil
            ) { [weak self] in
                self?.showWorktreeCleanupPanel()
            },
            PaletteAction(
                icon: .symbol("sidebar.left"), title: "Show/Hide Sidebar", subtitle: "Toggle the workspace sidebar",
                shortcut: .toggleSidebar
            ) { [weak self] in
                self?.toggleSidebar()
            },
            PaletteAction(
                icon: .symbol("archivebox"), title: "Show/Hide Inactive Workspaces", subtitle: "Unfold or fold the sidebar's INACTIVE section",
                shortcut: nil
            ) { [weak self] in
                self?.sidebar.toggleInactiveSection()
            },
            PaletteAction(
                icon: .symbol("pencil"), title: "Rename Workspace",
                subtitle: "Change the name of the current workspace", shortcut: nil
            ) { [weak self] in
                self?.showRenamePanel()
            },
            PaletteAction(
                icon: .symbol("puzzlepiece.extension"),
                title: "Install Agent Skills",
                subtitle: "Worktree workspaces + open code in the editor from agents",
                shortcut: nil
            ) { [weak self] in
                self?.installAgentSkills()
            },
            PaletteAction(
                icon: .symbol("checklist"),
                title: "Show Getting Started",
                subtitle: "Checklist: agent CLIs, skills, status hooks and shortcuts",
                shortcut: nil
            ) { [weak self] in
                self?.showOnboardingChecklist()
            },
            PaletteAction(
                icon: .symbol("gearshape"), title: "Open Settings", subtitle: "Agent launch modes, remote access and experiments",
                shortcut: .settings
            ) {
                NSApp.sendAction(#selector(NiruxApp.showSettings(_:)), to: nil, from: nil)
            }
        ]
    }
}
