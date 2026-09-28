import AppKit

/// What shell commands do outside Nirux's own window: type an agent's
/// launch line into a terminal, write the agent skills into the home
/// folder, read browser cookies through the Keychain, wait on an app-modal
/// alert. Tests swap members for doubles, so every palette command can run
/// in CI without launching an agent, touching the real ~/.claude, asking
/// for the Keychain or waiting on a click.
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

    /// The home folder: agent skills install into it, the Getting Started
    /// checklist reads it, a workspace with no folder of its own opens in it.
    var homeDirectory: @MainActor () -> String = { NSHomeDirectory() }

    /// Chromium browsers with a cookie database.
    var cookieBrowsers: @MainActor () -> [CookieImporter.Browser] = { CookieImporter.availableBrowsers }

    /// Reads the browser's key from the Keychain and imports its cookies.
    var importCookies: @MainActor (CookieImporter.Browser) async throws -> CookieImporter.ImportResult = { browser in
        try await CookieImporter.importCookies(from: browser, into: WebViewColumn.sharedDataStore)
    }

    /// Shows an app-modal alert and waits for its answer.
    var runModal: @MainActor (NSAlert) -> NSApplication.ModalResponse = { $0.runModal() }

    /// Asks whether to stop the running merge queues and quit: a sheet on
    /// the window when it is on screen, else an alert. `answer` gets true
    /// to quit. Never waits in the caller: AppKit waits for the answer.
    var confirmQuitWithMergeQueue: @MainActor (
        _ message: String, _ details: String, _ window: NSWindow?, _ answer: @escaping @MainActor (Bool) -> Void
    ) -> Void = { message, details, window, answer in
        // Quit from the Dock while Nirux is hidden: the question must show.
        NSApp.unhide(nil)
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = message
        alert.informativeText = details
        alert.addButton(withTitle: "Keep Running")
        alert.addButton(withTitle: "Stop Queue and Quit").hasDestructiveAction = true
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
