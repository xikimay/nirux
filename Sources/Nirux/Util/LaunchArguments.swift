import Foundation

/// What `Nirux` does with the arguments no command-line mode took (see
/// `NiruxApp.main`). Only a launch without arguments, or with the ones
/// macOS and Cocoa add, opens the app. Any other argument used to open it
/// too: an agent trying `"$NIRUX_CLI_PATH" --help`, or a command it
/// guessed to start a task, got a second Nirux on the user's workspaces,
/// which restored them and relaunched their agent sessions.
enum LaunchArguments {
    enum Decision: Equatable {
        /// Opens the app.
        case launchApp
        /// Prints `usage` and exits 0.
        case help
        /// `--hook` with a kind or a flag this build doesn't know: a hook a
        /// newer build installed, run by this one after a rollback. Exits 0
        /// and prints nothing, as a hook that has nothing to report: any
        /// other status would show in the agent, and 2 would block its tool
        /// call.
        case ignoredHook
        /// Prints the argument and `usage` on stderr and exits 2.
        case unknown(String)
    }

    /// `arguments` as `CommandLine.arguments` gives them, the executable
    /// first.
    static func decision(for arguments: [String]) -> Decision {
        let rest = Array(arguments.dropFirst())
        guard let first = rest.first else { return .launchApp }
        if first == "--hook" { return .ignoredHook }
        if helpArguments.contains(first) { return .help }
        var index = rest.startIndex
        while index < rest.endIndex {
            let argument = rest[index]
            if argument.hasPrefix("-psn_") {
                index += 1
            } else if isCocoaDefault(argument), index + 1 < rest.endIndex {
                index += 2
            } else {
                return .unknown(argument)
            }
        }
        return .launchApp
    }

    static let helpArguments: Set<String> = ["--help", "-help", "-h", "help"]

    /// `-NSKey value` or `-AppleKey value`: Cocoa reads these pairs as user
    /// defaults for this launch (`-AppleLanguages "(fr)"`,
    /// `-NSShowAllViews YES`). Other keys are no setting of Nirux's.
    static func isCocoaDefault(_ argument: String) -> Bool {
        guard argument.hasPrefix("-") else { return false }
        let key = argument.dropFirst()
        return key.hasPrefix("NS") || key.hasPrefix("Apple")
    }

    static let usage = """
        Usage:
          Nirux                                  Opens Nirux. Only the installed app opens your workspaces.
          Nirux --mission <command> [options]    Mission messages between an agent and a task it started:
                                                 ask, completed, reply, tell, receive (see the nirux-worktree skill).
          Nirux --check-terminal-runtime         Checks that the terminal engine loads (release checks).
          Nirux --check-release-signature [app]  Checks a release's signature (release checks).
        Agents' hooks, status line and tools run it with --hook: not for direct use.
        No command of this binary starts a task. From an agent, a space's Lead starts one with its
        start_task tool; any other agent with the nirux-worktree skill.

        """

    /// What goes to stderr for an argument nothing takes.
    static func unknownArgumentMessage(_ argument: String) -> String {
        "Nirux: unknown argument “\(argument)”. Nirux opens only without arguments.\n\n" + usage
    }
}
