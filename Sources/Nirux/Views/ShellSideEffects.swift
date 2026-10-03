import AppKit

/// What shell commands do outside Nirux's own window: type an agent's
/// launch line into a terminal, write the agent skills into the home
/// folder, read browser cookies through the Keychain, wait on an app-modal
/// alert, open a link, rerun CI jobs on GitHub. Tests swap members for
/// doubles, so every palette command can run in CI without launching an
/// agent, touching the real ~/.claude, asking for the Keychain, waiting on
/// a click or reaching GitHub.
@MainActor
struct ShellSideEffects {
    /// Types an agent's launch command into a new terminal column.
    var launchAgent: @MainActor (_ column: ColumnState, _ command: String) -> Void = { column, command in
        // After the column's shell has started (0.5 s, see ColumnState).
        // Weak: a column closed meanwhile neither starts a shell nor gets
        // the command.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak column] in
            column?.pty?.sendRaw("\(command)\n")
        }
    }

    /// Starts a restored agent column's shell with the agent's launch
    /// command (see `DeferredAgentLaunch`).
    var startRestoredAgent: @MainActor (_ column: ColumnState, _ command: String) -> Void = { column, command in
        column.startShell(command: command)
    }

    /// The home folder: agent skills install into it, the Getting Started
    /// checklist reads it, a workspace with no folder of its own opens in it.
    var homeDirectory: @MainActor () -> String = { NSHomeDirectory() }

    /// Chromium browsers with a cookie database.
    var cookieBrowsers: @MainActor () -> [CookieImporter.Browser] = { CookieImporter.availableBrowsers }

    /// Reads the browser's key from the Keychain and imports its cookies.
    var importCookies: @MainActor (CookieImporter.Browser) async throws -> CookieImporter.ImportResult = { browser in
        try await CookieImporter.importCookies(from: browser, into: WebViewColumn.sharedDataStore)
    }

    /// Opens a link in the default browser.
    var openURL: @MainActor (URL) -> Void = { NSWorkspace.shared.open($0) }

    /// Reruns the failed jobs of a GitHub Actions run: nil once GitHub
    /// accepted it, else why not. Called off the main thread.
    var rerunFailedJobs: @Sendable (CIFailure.Run) -> String? = { CIFailure.rerun($0) }

    /// Shows an app-modal alert and waits for its answer.
    var runModal: @MainActor (NSAlert) -> NSApplication.ModalResponse = { $0.runModal() }

    /// Quits Nirux, through `applicationShouldTerminate`, from the next
    /// turn of the run loop. Never from a main-queue block: a quit that waits
    /// (`.terminateLater`) runs AppKit's modal loop inside it, and the main
    /// queue never runs another block until that one ends, so the answer it
    /// waits for would never come.
    var requestQuit: @MainActor () -> Void = {
        // The main run loop runs it on the main thread; Swift 6.1 types the
        // block as nonisolated.
        RunLoop.main.perform(inModes: [.default, .modalPanel]) {
            MainActor.assumeIsolated { NSApp.terminate(nil) }
        }
    }

    /// Asks whether to stop the running merge queues and quit, `confirm`
    /// on the destructive button: a sheet on the window when it is on
    /// screen, else an alert. `answer` gets true to quit. Never waits in
    /// the caller: AppKit waits for the answer.
    var confirmQuitWithMergeQueue: @MainActor (
        _ message: String, _ details: String, _ confirm: String, _ window: NSWindow?,
        _ answer: @escaping @MainActor (Bool) -> Void
    ) -> Void = { message, details, confirm, window, answer in
        // Quit from the Dock while Nirux is hidden: the question must show.
        NSApp.unhide(nil)
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = message
        alert.informativeText = details
        alert.addButton(withTitle: "Keep Running")
        alert.addButton(withTitle: confirm).hasDestructiveAction = true
        guard let window, window.isVisible, !window.isMiniaturized, window.attachedSheet == nil else {
            answer(alert.runModal() == .alertSecondButtonReturn)
            return
        }
        alert.beginSheetModal(for: window) { response in
            answer(response == .alertSecondButtonReturn)
        }
    }
}

extension NiruxShellView {
    /// An app-modal alert, through `sideEffects` so tests can answer it.
    @discardableResult
    func runModal(_ alert: NSAlert) -> NSApplication.ModalResponse {
        sideEffects.runModal(alert)
    }
}
