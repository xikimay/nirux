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

    /// Where Claude Code's managed settings live (see ProjectMemory).
    var claudeManagedSettings: @MainActor () -> ProjectMemory.ManagedFolders = { .system }

    /// Moves a deleted memory's file to the Trash. Called off the main
    /// thread.
    var trash: ProjectMemory.Trash = ProjectMemory.systemTrash

    /// Chromium browsers to offer the cookie import for: those that ran
    /// here. The click says when none of their profiles has cookies.
    var cookieBrowsers: @MainActor () -> [CookieImporter.Browser] = { CookieImporter.browsersToOffer() }

    /// Their profiles with a cookie database, read once the user asked, off
    /// the main thread (a macOS privacy prompt or a stalled volume would
    /// hold it), handed back on it.
    var cookieSources: @MainActor (_ completion: @escaping @MainActor @Sendable ([CookieImporter.Source]) -> Void) -> Void = {
        ShellSideEffects.readCookieSources(then: $0)
    }

    /// How long reading the profiles may take before the import stops
    /// waiting and can be asked again.
    var cookieReadTimeout: TimeInterval = 20

    /// Reads the browser's key from the Keychain and imports the profile's
    /// cookies.
    var importCookies: @MainActor (CookieImporter.Source) async throws -> CookieImporter.ImportResult = { source in
        try await CookieImporter.importCookies(from: source, into: WebViewColumn.sharedDataStore)
    }

    /// macOS's "Reduce motion" (System Settings › Accessibility › Display).
    var reducesMotion: @MainActor () -> Bool = { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    /// Whether any of the window shows on screen: not minimized, not
    /// covered, its display not asleep.
    var windowShows: @MainActor (NSWindow?) -> Bool = { $0?.occlusionState.contains(.visible) ?? false }

    /// Calls back at each click or scroll the app receives, until stopped;
    /// the events go on as they were. Keys come through the app's key
    /// interceptor, which consumes the terminals' own. Tests watch
    /// nothing.
    var watchUserInput: @MainActor (@escaping @MainActor () -> Void) -> Any? = { seen in
        NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .scrollWheel]) { event in
            MainActor.assumeIsolated { seen() }
            return event
        }
    }
    var stopWatchingUserInput: @MainActor (Any) -> Void = { NSEvent.removeMonitor($0) }

    /// Tells a column's terminal whether it is on screen, so it draws or
    /// rests (see `NiruxShellView.syncTerminalOcclusion`).
    var setSurfaceVisible: @MainActor (ColumnState, Bool) -> Void = { column, visible in
        column.terminalView?.setSurfaceVisible(visible)
    }

    /// Opens a link in the default browser.
    var openURL: @MainActor (URL) -> Void = { NSWorkspace.shared.open($0) }

    /// Reruns the failed jobs of a GitHub Actions run: nil once GitHub
    /// accepted it, else why not. Called off the main thread.
    var rerunFailedJobs: @Sendable (CIFailure.Run) -> String? = { CIFailure.rerun($0) }

    /// Reads a failed run to tell a flaky failure from a real one (`gh`,
    /// the local repository, a model: see `CITriageInvestigation`). Tests
    /// replace it: a flow test reaches neither GitHub nor `claude`.
    /// The second parameter says, before anything goes to the model,
    /// whether the triage is still on.
    var investigateCIFailure: @Sendable (
        CITriageInvestigation.Request, _ isStillWanted: @escaping @Sendable () async -> Bool
    ) async -> CITriageInvestigation.Outcome = { request, isStillWanted in
        await CITriageInvestigation.investigate(request, isStillWanted: isStillWanted)
    }

    /// The native notification of a pull request whose checks failed, with
    /// why the failure looks flaky when it does. Tests replace it: xctest
    /// must never reach UNUserNotificationCenter.
    var notifyCIFailure: @MainActor (_ banner: CIFailureBanner, _ flakyReason: String?) -> Void = { banner, flakyReason in
        NiruxNotifier.shared.postCIFailure(
            workspaceID: banner.workspaceID, workspaceTitle: banner.workspaceTitle, pullRequest: banner.pullRequest,
            checkNames: banner.checkNames, flakyReason: flakyReason
        )
    }

    /// Looks for the claude Branch Review's Explain runs, and its account
    /// (`claude --help`, `claude auth status`). Called off the main thread.
    var checkExplain: @Sendable () -> BranchReview.ExplainAvailability = { BranchReview.ExplainAvailability.check() }

    /// How long routing a new workspace waits for git (see SpaceRouting).
    /// Tests on a busy machine wait longer.
    var routingTimeout: TimeInterval = FolderIdentity.routingTimeout

    /// The native notification for a setup script that failed (workspace
    /// id, workspace title). Tests replace it: xctest must never reach
    /// UNUserNotificationCenter.
    var notifySetupFailure: @MainActor (_ workspaceID: String, _ title: String) -> Void = { workspaceID, title in
        NiruxNotifier.shared.postSetupFailure(workspaceID: workspaceID, workspaceTitle: title)
    }

    /// Posts the notification of a Mission question that came to the user
    /// (workspace id, title, column, question). Tests replace it: xctest
    /// must never reach UNUserNotificationCenter.
    var notifyMissionQuestion: @MainActor (_ workspaceID: String, _ title: String, _ column: Int, _ question: String) -> Void = {
        workspaceID, title, column, question in
        NiruxNotifier.shared.postMissionEvent(
            workspaceID: workspaceID, workspaceTitle: title, columnIndex: column, kind: .question, message: question
        )
    }

    /// Through this nonisolated function's `@Sendable` parameter, so the
    /// read doesn't inherit the caller's main-actor isolation (see
    /// MergeQueueDriver.runOffMain).
    nonisolated static func readCookieSources(then completion: @escaping @MainActor @Sendable ([CookieImporter.Source]) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let sources = CookieImporter.availableSources()
            DispatchQueue.main.async { @MainActor in completion(sources) }
        }
    }

    /// Shows an app-modal alert and waits for its answer.
    var runModal: @MainActor (NSAlert) -> NSApplication.ModalResponse = { $0.runModal() }

    /// Asks for a folder ("Add Repository…", "Add Folder…"): a sheet on
    /// `window` when there is one. `completion` gets nil on Cancel.
    var chooseFolder: @MainActor (
        _ prompt: String, _ window: NSWindow?, _ completion: @escaping @MainActor (String?) -> Void
    ) -> Void = { prompt, window, completion in
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = prompt
        guard let window else {
            return completion(panel.runModal() == .OK ? panel.url?.path : nil)
        }
        panel.beginSheetModal(for: window) { response in
            completion(response == .OK ? panel.url?.path : nil)
        }
    }

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
