import AppKit

/// What `Nirux` does with its arguments (see `NiruxApp.main`): a
/// command-line mode, or the app. The app opens with no argument, or with
/// `-Key value` defaults only. Any other argument used to open it too: an
/// agent trying `"$NIRUX_CLI_PATH" --help`, or a command it guessed to
/// start a task, got a second Nirux on the user's workspaces, which
/// restored them and relaunched their agent sessions.
enum LaunchArguments {
    /// The command-line modes, each run by `NiruxApp.main` and never
    /// launching the app UI. Agent hooks, `NIRUX_CLI_PATH` and the nightly
    /// run them from any copy and any parent, so they come before
    /// `RealStateGuard`.
    enum Mode: Equatable {
        /// `--hook claude --statusline`: Claude Code's status line, while the
        /// usage limits indicator is on. Spelled as a hook so that an older
        /// build at the same path (a rollback) reads a hook payload without
        /// an event and exits, instead of launching its UI on every response.
        case statusLine
        /// `--hook claude --mcp`: the tools server of the agents Nirux
        /// launches (NiruxMCPServer), spelled as a hook for the same reason.
        case toolsServer
        /// `--hook codex --setup-failed <workspace id>`: a setup script failed
        /// in a new worktree (SpaceSetupScript). An older build reads a Codex
        /// payload it can't parse and exits.
        case setupFailure(workspaceID: String)
        /// `--hook claude|codex [payload-json]`: Claude Code hooks and Codex's
        /// notify command append one event line and exit (AgentHookInstaller).
        case hook(AgentHookEvent.Kind, payload: String?)
        /// `--mission <command> [options]` (MissionEventCLI).
        case mission([String])
        /// `--check-terminal-runtime`: the nightly runs it on the app it
        /// packaged, before notarizing.
        case checkTerminalRuntime
        /// `--check-release-signature [app]`: the nightly checks the app it
        /// publishes, or another app (a downloaded nightly).
        case checkReleaseSignature([String])
    }

    enum Decision: Equatable {
        case mode(Mode)
        /// Opens the app.
        case launchApp
        /// Prints `usage` and exits 0.
        case help
        /// `--hook` with a kind or a flag this build doesn't know: a hook a
        /// newer build installed, run by this one after a rollback. Exits 0
        /// and prints nothing, as a hook that has nothing to report: any
        /// other status would show in the agent, and 2 would block its tool
        /// call. It reads its input to the end first, unless it is spelled as
        /// a stdio server (`--mcp`), whose input never ends.
        case ignoredHook(readsInput: Bool)
        /// Prints the argument and `usage` on stderr and exits 2.
        case unknown(String)
    }

    /// `arguments` as `CommandLine.arguments` gives them, the executable
    /// first.
    static func decision(for arguments: [String]) -> Decision {
        if let mode = mode(of: arguments) { return .mode(mode) }
        let rest = Array(arguments.dropFirst())
        guard let first = rest.first else { return .launchApp }
        if first == "--hook" { return .ignoredHook(readsInput: !rest.contains("--mcp")) }
        if helpArguments.contains(first) { return .help }
        var index = rest.startIndex
        while index < rest.endIndex {
            let argument = rest[index]
            if argument.hasPrefix("-psn_") {
                index += 1
            } else if isDefaultsKey(argument), index + 1 < rest.endIndex {
                index += 2
            } else {
                return .unknown(argument)
            }
        }
        return .launchApp
    }

    /// The mode `arguments` ask for, in the order `main` always tried them.
    static func mode(of args: [String]) -> Mode? {
        if args.count >= 4, args[1] == "--hook", args[2] == "claude", args[3] == "--statusline" { return .statusLine }
        if args.count >= 4, args[1] == "--hook", args[2] == "claude", args[3] == "--mcp" { return .toolsServer }
        if let workspaceID = SetupFailureSignal.workspaceID(in: args) { return .setupFailure(workspaceID: workspaceID) }
        if args.count >= 3, args[1] == "--hook", let kind = AgentHookEvent.Kind(rawValue: args[2]) {
            return .hook(kind, payload: args.count > 3 ? args.last : nil)
        }
        if args.count >= 2, args[1] == "--mission" { return .mission(Array(args.dropFirst(2))) }
        if args.count == 2, args[1] == "--check-terminal-runtime" { return .checkTerminalRuntime }
        if args.count >= 2, args[1] == "--check-release-signature" { return .checkReleaseSignature(Array(args.dropFirst(2))) }
        return nil
    }

    static let helpArguments: Set<String> = ["--help", "-help", "-h", "help"]

    /// `-Key value`, which macOS reads as a user default for this launch
    /// (the argument domain): Nirux's `-IgnoreGhosttyConfig YES`,
    /// `-AppleLanguages "(fr)"`, `-com.apple.CoreData.SQLDebug 1`. One
    /// dash, then a key.
    static func isDefaultsKey(_ argument: String) -> Bool {
        guard argument.hasPrefix("-") else { return false }
        let key = argument.dropFirst()
        return !key.isEmpty && !key.hasPrefix("-")
    }

    static let usage = """
        Usage:
          Nirux [-Key value ...]                 Opens Nirux, with these user defaults for this launch
                                                 (-IgnoreGhosttyConfig YES). Only the installed app opens your workspaces.
          Nirux --mission <command> [options]    Mission messages between an agent and a task it started:
                                                 ask, completed, reply, tell, receive (see the nirux-worktree skill).
          Nirux --check-terminal-runtime         Checks that the terminal engine loads (release checks).
          Nirux --check-release-signature [app]  Checks a release's signature (release checks).
        Agents' hooks, status line and tools run it with --hook: not for direct use.
        No command of this binary starts a task. An agent starts one with Nirux's start_task tool, or
        with the nirux-worktree skill.

        """

    /// What goes to stderr for an argument nothing takes.
    static func unknownArgumentMessage(_ argument: String) -> String {
        "Nirux: unknown argument “\(argument)”. Nirux takes only the commands below, or -Key value defaults.\n\n" + usage
    }

    /// Reads stdin to its end, as a hook must (see `Decision.ignoredHook`),
    /// unless it is a terminal: someone typed the command.
    static func readStandardInputToEnd() {
        guard isatty(STDIN_FILENO) == 0 else { return }
        _ = FileHandle.standardInput.readDataToEndOfFile()
    }

    /// Finder, the Dock, `open` or a `nirux://` link started this process:
    /// a child of launchd, in its session. One detached from a shell (`&`,
    /// nohup) keeps the shell's session. Its stderr goes nowhere.
    static var startedByLaunchServices: Bool { getppid() == 1 && getsid(0) == 1 }

    /// Says on stderr why Nirux won't open, and in an alert too when
    /// LaunchServices started it; then exits with `status`.
    @MainActor
    static func refuse(standardError: String, alertTitle: String, alertText: String, status: Int32) -> Never {
        FileHandle.standardError.write(Data(standardError.utf8))
        guard startedByLaunchServices else { exit(status) }
        let app = NSApplication.shared
        let delegate = LaunchRefusalDelegate(title: alertTitle, text: alertText, status: status)
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
        exit(status)
    }

    /// The alert for `argument`, when LaunchServices started Nirux.
    static func unknownArgumentAlertText(_ argument: String) -> String {
        "It was started with “\(argument)”, which it doesn't take. Open Nirux without arguments, "
            + "or with -Key value defaults only."
    }
}

/// A launch with arguments Nirux doesn't take, from LaunchServices
/// (`open -a Nirux --args --foo`): one alert, then quit, rather than a
/// Dock icon that bounces and goes.
@MainActor
final class LaunchRefusalDelegate: NSObject, NSApplicationDelegate {
    private let title: String
    private let text: String
    private let status: Int32

    init(title: String, text: String, status: Int32) {
        self.title = title
        self.text = text
        self.status = status
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = text
        alert.addButton(withTitle: "Quit")
        alert.runModal()
        exit(status)
    }
}
