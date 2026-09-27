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
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            column.pty?.sendRaw("\(command)\n")
        }
    }

    /// The home folder agent skills install into and the Getting Started
    /// checklist reads.
    var homeDirectory: @MainActor () -> String = { NSHomeDirectory() }

    /// Chromium browsers with a cookie database.
    var cookieBrowsers: @MainActor () -> [CookieImporter.Browser] = { CookieImporter.availableBrowsers }

    /// Reads the browser's key from the Keychain and imports its cookies.
    var importCookies: @MainActor (CookieImporter.Browser) async throws -> CookieImporter.ImportResult = { browser in
        try await CookieImporter.importCookies(from: browser, into: WebViewColumn.sharedDataStore)
    }

    var runModal: @MainActor (NSAlert) -> NSApplication.ModalResponse = { $0.runModal() }
}

extension NiruxShellView {
    /// An app-modal alert, through `sideEffects` so tests can answer it.
    @discardableResult
    func runModal(_ alert: NSAlert) -> NSApplication.ModalResponse {
        sideEffects.runModal(alert)
    }
}
