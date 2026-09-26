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
        let restoreApp = appToRestoreOnCancel(now: ProcessInfo.processInfo.systemUptime)
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
        // realpath/stat and the editor file checks can block on a dead
        // network mount: resolve off the main actor, then gate on the
        // resolved request so a confirmation shows exactly what will be used.
        Task { [weak self] in
            let resolved = await Task.detached { request.resolvingPaths() }.value
            guard let self else { return }
            guard let resolved else {
                NSLog("[URL] Ignored nirux:// request: folder or file not usable")
                if request.hasValidLaunchID() {
                    self.shell?.presentProblem(Self.unusableTargetMessage(for: request.action), "")
                }
                return
            }
            self.route(resolved, restoreApp: restoreApp)
        }
    }

    private static func unusableTargetMessage(for action: NiruxURLRequest.Action) -> String {
        switch action {
        case .newWorkspace, .newWorktree:
            return "Nirux couldn’t open that folder: it doesn’t exist or isn’t a folder."
        case .openEditor:
            return "Nirux couldn’t show that file: it’s missing, not a text file, or larger than 5 MB."
        }
    }

    private func route(_ request: NiruxURLRequest, restoreApp: NSRunningApplication?) {
        let now = ProcessInfo.processInfo.systemUptime
        if InAppWorktreeTickets.redeem(request, now: now) || request.disposition() == .perform {
            perform(request)
            return
        }
        let wasIdle = urlConfirmations.isIdle
        guard urlConfirmations.enqueue(request.restrictedForConfirmation(), now: now) else {
            NSLog("[URL] Dropped an unconfirmed nirux:// request (queue full or just cancelled)")
            return
        }
        if wasIdle { urlConfirmationRestoreApp = restoreApp }
        presentNextURLConfirmation()
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
        case .openEditor(_, let target):
            guard let target else { return }
            shell?.openEditorFromURL(target)
        }
        NSApp.activate(ignoringOtherApps: true)
        mainWindow?.makeKeyAndOrderFront(nil)
    }

    /// Window-modal sheet, one at a time: unlike an app-modal alert it
    /// doesn't stall the heartbeat timer (state saves, sidebar refresh).
    private func presentNextURLConfirmation() {
        guard let window = mainWindow else { return }
        guard let request = urlConfirmations.startNext() else { return }
        let settings = Persistence.load()?.settings
        let text = request.confirmation(
            claudeMode: settings?.claudeLaunchMode ?? .default,
            codexMode: settings?.codexLaunchMode ?? .default
        )

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = text.message
        alert.informativeText = text.details
        let confirm = alert.addButton(withTitle: text.confirmButton)
        let cancel = alert.addButton(withTitle: "Cancel")
        // No default button: a stray Return must not approve an action that
        // someone else requested (Escape still cancels). Cancel takes the
        // initial focus so Space with keyboard navigation declines too. The
        // confirm button arms a beat after the sheet is on screen with Nirux
        // active (it may wait behind another sheet, and activation can be
        // refused), so a click aimed at whatever was there can't land on it.
        confirm.keyEquivalent = ""
        confirm.isEnabled = false
        alert.layout()
        alert.window.initialFirstResponder = cancel
        let sheet = alert.window
        let lifetime = SheetLifetime()
        Task { @MainActor in
            while !lifetime.ended, !(sheet.isVisible && NSApp.isActive) {
                try? await Task.sleep(for: .milliseconds(100))
            }
            try? await Task.sleep(for: .milliseconds(750))
            if !lifetime.ended { confirm.isEnabled = true }
        }

        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        alert.beginSheetModal(for: window) { [weak self] response in
            MainActor.assumeIsolated {
                lifetime.ended = true
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
}

/// Lets the arming task stop once its sheet has been answered.
@MainActor
private final class SheetLifetime {
    var ended = false
}
