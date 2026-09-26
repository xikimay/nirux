import AppKit

// MARK: - URL Scheme

extension NiruxApp {
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            handleURL(url)
        }
    }

    private func handleURL(_ url: URL) {
        guard url.scheme == "nirux" else { return }
        guard let request = NiruxURLRequest(url: url) else {
            NSLog("[URL] Ignored malformed or unknown nirux:// request (host: \(url.host ?? "none"))")
            return
        }
        if case .openEditor = request.action {
            openEditor(from: url)
            return
        }
        // Starting a shell or an agent needs this launch's ID (exported to
        // Nirux terminals as NIRUX_LAUNCH_ID) or an explicit yes from the user.
        if request.requiresAuthorization,
           !NiruxLaunchAuthorization.isValid(request.launchID),
           !confirmUnauthenticatedRequest(request) {
            return
        }
        perform(request)
        NSApp.activate(ignoringOtherApps: true)
        mainWindow?.makeKeyAndOrderFront(nil)
    }

    private func perform(_ request: NiruxURLRequest) {
        switch request.action {
        case let .newWorkspace(cwd, title, agent):
            shell?.addWorkspace(title: title, cwd: cwd, agent: agent, profileID: request.profileID)
        case .newWorktree(let worktree):
            shell?.createWorktreeWorkspace(
                branch: worktree.branch,
                repoRoot: worktree.repo,
                agent: worktree.agent,
                handoverPath: worktree.handoverPath,
                profileID: request.profileID,
                parentWorkspaceID: worktree.parentWorkspaceID,
                parentAgentUUID: worktree.parentAgentUUID
            )
        case .openEditor:
            break
        }
    }

    /// Returns true only when the user explicitly clicks the confirm button.
    private func confirmUnauthenticatedRequest(_ request: NiruxURLRequest) -> Bool {
        // One prompt at a time: a page looping on the URL can't stack alerts.
        guard !isConfirmingURLRequest else {
            NSLog("[URL] Dropped a nirux:// request while another one awaits confirmation")
            return false
        }
        guard let text = request.confirmation(
            claudeMode: NiruxShellView.currentClaudeLaunchMode(),
            codexMode: NiruxShellView.currentCodexLaunchMode()
        ) else { return false }

        isConfirmingURLRequest = true
        defer { isConfirmingURLRequest = false }
        NSApp.activate(ignoringOtherApps: true)
        mainWindow?.makeKeyAndOrderFront(nil)

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = text.message
        alert.informativeText = text.details
        let confirm = alert.addButton(withTitle: text.confirmButton)
        alert.addButton(withTitle: "Cancel")
        // No default button: a stray Return must not approve an action that
        // someone else requested. Escape still cancels.
        confirm.keyEquivalent = ""
        return alert.runModal() == .alertFirstButtonReturn
    }

    // nirux://open-editor?file=<absolute path>&line=42&endLine=57&workspace=<id>
    // Validation stats (and prefix-reads) the file, which can block on a dead
    // network mount — run it off the main actor, then hop back. Activation is
    // gated on acceptance so a rejected request can't be used to yank Nirux
    // frontmost.
    private func openEditor(from url: URL) {
        let urlString = url.absoluteString
        Task { [weak self] in
            let request = await Task.detached {
                OpenEditorRequest(queryItems: URLComponents(string: urlString)?.queryItems)
            }.value
            guard let request else {
                NSLog("[OpenEditor] rejected open-editor URL (missing/non-regular/oversized/binary file?)")
                return
            }
            guard let self else { return }
            self.shell?.openEditorFromURL(request)
            NSApp.activate(ignoringOtherApps: true)
            self.mainWindow?.makeKeyAndOrderFront(nil)
        }
    }
}
