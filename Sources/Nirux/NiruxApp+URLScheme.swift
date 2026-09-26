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

    /// macOS usually activates Nirux itself when it hands over a URL, so the
    /// app to return to after a Cancel has to be remembered beforehand.
    /// Nirux's own activation is observed synchronously (NSApp posts it on
    /// the main thread) so its timestamp is current when the URL is handled.
    func startTrackingFrontmostApp() {
        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: NSApp, queue: nil
        ) { [weak self] _ in
            let now = ProcessInfo.processInfo.systemUptime
            MainActor.assumeIsolated { self?.niruxActivatedAt = now }
        }
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] notification in
            let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            MainActor.assumeIsolated {
                guard let app, app != NSRunningApplication.current else { return }
                self?.lastExternalApp = app
            }
        }
    }

    /// The app the user was in when the request arrived, or nil if they were
    /// already working in Nirux (then a Cancel simply leaves them there).
    private func appToRestoreOnCancel(now: TimeInterval) -> NSRunningApplication? {
        guard NSApp.isActive else {
            // LaunchServices may already have switched to Nirux without
            // Nirux having processed its activation yet.
            let front = NSWorkspace.shared.frontmostApplication
            return front == nil || front == NSRunningApplication.current ? lastExternalApp : front
        }
        return now - niruxActivatedAt < 2 ? lastExternalApp : nil
    }

    private func handleURL(_ url: URL) {
        guard url.scheme == "nirux" else { return }
        guard shell != nil, mainWindow != nil else {
            if launchURLBacklog.count < 8 { launchURLBacklog.append(url) }
            return
        }
        let arrivedAt = ProcessInfo.processInfo.systemUptime
        let restoreApp = appToRestoreOnCancel(now: arrivedAt)
        guard let request = NiruxURLRequest(url: url) else {
            NSLog("[URL] Ignored malformed or unknown nirux:// request (host: \(url.host ?? "none"))")
            if NiruxLaunchAuthorization.isValid(NiruxURLRequest.launchID(in: url)) {
                shell?.presentProblem(
                    "Nirux ignored a nirux:// request",
                    "“\(url.host ?? "")” is unknown, or a required parameter is missing or not an absolute path."
                )
            }
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
            self.route(resolved, restoreApp: restoreApp)
        }
    }

    private func route(_ request: NiruxURLRequest, restoreApp: NSRunningApplication?) {
        switch request.disposition() {
        case .perform:
            perform(request)
        case .confirm:
            let wasIdle = urlConfirmations.isIdle
            guard urlConfirmations.enqueue(request.droppingMissionLink(), now: ProcessInfo.processInfo.systemUptime) else {
                NSLog("[URL] Dropped an unconfirmed nirux:// request (queue full or just cancelled)")
                return
            }
            if wasIdle { urlConfirmationRestoreApp = restoreApp }
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

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = text.message
        alert.informativeText = text.details
        let confirm = alert.addButton(withTitle: text.confirmButton)
        let cancel = alert.addButton(withTitle: "Cancel")
        // No default button: a stray Return must not approve an action that
        // someone else requested (Escape still cancels). Cancel takes the
        // initial focus so Space with keyboard navigation declines too, and
        // the confirm button arms a beat after the sheet actually appears
        // (it may wait behind another sheet), so a click aimed at whatever
        // was there before can't land on it.
        confirm.keyEquivalent = ""
        confirm.isEnabled = false
        alert.layout()
        alert.window.initialFirstResponder = cancel
        let sheet = alert.window
        Task { @MainActor in
            while !sheet.isVisible {
                try? await Task.sleep(for: .milliseconds(100))
            }
            try? await Task.sleep(for: .milliseconds(750))
            confirm.isEnabled = true
        }

        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        alert.beginSheetModal(for: window) { [weak self] response in
            MainActor.assumeIsolated {
                guard let self else { return }
                let confirmed = response == .alertFirstButtonReturn
                // A Cancel also drops whatever else was queued.
                self.urlConfirmations.finish(confirmed: confirmed, now: ProcessInfo.processInfo.systemUptime)
                if confirmed {
                    self.perform(request)
                } else {
                    // Give focus back to whatever the user was in.
                    self.urlConfirmationRestoreApp?.activate()
                }
                if self.urlConfirmations.isIdle { self.urlConfirmationRestoreApp = nil }
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
