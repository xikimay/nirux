import AppKit

// MARK: - URL Scheme

extension NiruxApp {
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            handleURL(url)
        }
    }

    /// URLs that launched the app arrive before applicationDidFinishLaunching
    /// has built the window; replay them once it has.
    func drainLaunchURLBacklog() {
        let backlog = launchURLBacklog
        launchURLBacklog = []
        backlog.forEach(handleURL)
    }

    private func handleURL(_ url: URL) {
        guard url.scheme == "nirux" else { return }
        guard shell != nil, mainWindow != nil else {
            if launchURLBacklog.count < URLConfirmationQueue.capacity { launchURLBacklog.append(url) }
            return
        }
        guard let request = NiruxURLRequest(url: url) else {
            NSLog("[URL] Ignored malformed or unknown nirux:// request (host: \(url.host ?? "none"))")
            return
        }
        if request.disposition() == .openEditor {
            openEditor(from: url, activate: request.hasValidLaunchID())
            return
        }
        // realpath/stat can block on a dead network mount: resolve off the
        // main actor, then gate on the resolved request so the confirmation
        // shows exactly the folder the action will use.
        Task { [weak self] in
            let resolved = await Task.detached { request.resolvingPaths() }.value
            guard let self else { return }
            guard let resolved else {
                NSLog("[URL] Ignored nirux:// request: folder not found")
                if request.hasValidLaunchID() {
                    self.shell?.presentProblem("Nirux couldn’t open that folder", "It doesn’t exist or isn’t a folder.")
                }
                return
            }
            self.route(resolved)
        }
    }

    private func route(_ request: NiruxURLRequest) {
        switch request.disposition() {
        case .perform:
            perform(request)
        case .confirm:
            let now = ProcessInfo.processInfo.systemUptime
            guard urlConfirmations.enqueue(request, now: now) else {
                NSLog("[URL] Dropped an unconfirmed nirux:// request (queue full or just cancelled)")
                return
            }
            presentNextURLConfirmation()
        case .openEditor:
            break
        }
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
            return
        }
        NSApp.activate(ignoringOtherApps: true)
        mainWindow?.makeKeyAndOrderFront(nil)
    }

    /// Window-modal sheet, one at a time: unlike an app-modal alert it
    /// doesn't stall the heartbeat timer (state saves, sidebar refresh).
    private func presentNextURLConfirmation() {
        guard let window = mainWindow else { return }
        guard let request = urlConfirmations.startNext() else { return }
        guard let text = request.confirmation(
            claudeMode: NiruxShellView.currentClaudeLaunchMode(),
            codexMode: NiruxShellView.currentCodexLaunchMode()
        ) else {
            urlConfirmations.finish(confirmed: true, now: ProcessInfo.processInfo.systemUptime)
            presentNextURLConfirmation()
            return
        }

        // Give focus back to whatever the user was in if they decline.
        let previousApp = NSWorkspace.shared.frontmostApplication
            .flatMap { $0 == NSRunningApplication.current ? nil : $0 }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = text.message
        alert.informativeText = text.details
        let confirm = alert.addButton(withTitle: text.confirmButton)
        let cancel = alert.addButton(withTitle: "Cancel")
        // No default button: a stray Return must not approve an action that
        // someone else requested (Escape still cancels). Cancel takes the
        // initial focus so Space with keyboard navigation declines too, and
        // the confirm button arms after a beat so a click aimed at whatever
        // was under the pointer can't land on it.
        confirm.keyEquivalent = ""
        confirm.isEnabled = false
        alert.layout()
        alert.window.initialFirstResponder = cancel
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(750))
            confirm.isEnabled = true
        }

        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        alert.beginSheetModal(for: window) { [weak self] response in
            MainActor.assumeIsolated {
                guard let self else { return }
                let confirmed = response == .alertFirstButtonReturn
                self.urlConfirmations.finish(confirmed: confirmed, now: ProcessInfo.processInfo.systemUptime)
                if confirmed {
                    self.perform(request)
                } else {
                    previousApp?.activate()
                }
                self.presentNextURLConfirmation()
            }
        }
    }

    // nirux://open-editor?file=<absolute path>&line=42&endLine=57&workspace=<id>
    // Validation stats (and prefix-reads) the file, which can block on a dead
    // network mount — run it off the main actor, then hop back. Activation is
    // gated on acceptance so a rejected request can't be used to yank Nirux
    // frontmost, and on the launch ID so a web page can't raise a file it
    // picked (say, a credentials file) over whatever is on screen.
    private func openEditor(from url: URL, activate: Bool) {
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
            if activate {
                NSApp.activate(ignoringOtherApps: true)
                self.mainWindow?.makeKeyAndOrderFront(nil)
            }
        }
    }
}
