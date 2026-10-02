import Foundation

// MARK: - Claude Code status line (usage limits indicator)

/// Claude Code hands the plan usage limits only to its status line (see
/// `ClaudeUsageLimits`), and ~/.claude/settings.json holds a single
/// `statusLine`. While the indicator is on, and the user has no status line
/// of their own, Nirux installs one that records the limits and prints
/// nothing. A status line of the user's own is never touched: the indicator
/// then has no data.
///
/// Claude Code hides its "? for shortcuts" footer hint whenever a status line
/// is set, in every session (outside Nirux terminals the command stops at
/// the same NIRUX_AGENT_UUID guard as the hooks): hence opt-in.
extension AgentHookInstaller {
    enum ClaudeStatusLineState: Equatable {
        /// No status line.
        case none
        /// Nirux's, whichever app path it runs.
        case nirux
        /// The user's own: Nirux leaves it alone.
        case foreign
        /// settings.json can't be read or parsed, or its path can't be
        /// resolved: Nirux leaves it alone.
        case unreadable
    }

    /// Identifies Nirux's status line command, whichever app path it runs.
    private static let statusLineCommandPattern = #"/Nirux["']? --hook claude --statusline"#

    /// Guarded like `claudeHookCommand`: outside Nirux terminals, or with
    /// the binary gone, it drains the payload and prints nothing. The flags
    /// read as a hook to a build without the indicator (see `NiruxApp.main`).
    static func claudeStatusLineCommand(executablePath: String) -> String {
        let path = shellQuoted(executablePath)
        return #"if [ -n "$NIRUX_AGENT_UUID" ] && [ -x \#(path) ]; then \#(path) --hook claude --statusline; "#
            + "else /bin/cat >/dev/null; fi"
    }

    static func claudeStatusLineState(home: URL = URL(fileURLWithPath: NSHomeDirectory())) -> ClaudeStatusLineState {
        switch readClaudeSettings(home: home) {
        case .unreadable: return .unreadable
        case .missing: return .none
        case .parsed(let root, _): return statusLineState(of: root["statusLine"])
        }
    }

    /// Installs Nirux's status line (`enabled`) or takes it back. Refreshes
    /// its command when the app moved. Returns the state it leaves.
    @discardableResult
    static func installClaudeStatusLine(
        enabled: Bool,
        executablePath: String = defaultExecutablePath,
        home: URL = URL(fileURLWithPath: NSHomeDirectory())
    ) -> ClaudeStatusLineState {
        let url: URL
        var root: [String: Any]
        switch readClaudeSettings(home: home) {
        case .unreadable:
            NSLog("[AgentHooks] ~/.claude/settings.json unreadable or unparsable — leaving the status line alone")
            return .unreadable
        case .missing(let path):
            guard enabled else { return .none }
            url = path
            root = [:]
        case .parsed(let parsed, let path):
            url = path
            root = parsed
        }

        let state = statusLineState(of: root["statusLine"])
        switch (state, enabled) {
        case (.foreign, _), (.unreadable, _), (.none, false):
            return state
        case (.nirux, false):
            root.removeValue(forKey: "statusLine")
            return writeClaudeSettings(root, to: url, home: home) ? .none : .nirux
        case (.none, true), (.nirux, true):
            let entry: [String: Any] = ["type": "command", "command": claudeStatusLineCommand(executablePath: executablePath)]
            if state == .nirux, let current = root["statusLine"] as? [String: Any],
               NSDictionary(dictionary: current).isEqual(to: entry) {
                return .nirux
            }
            root["statusLine"] = entry
            return writeClaudeSettings(root, to: url, home: home) ? .nirux : state
        }
    }

    /// At Save in Settings: the same as at launch, for a build that installs
    /// the hooks. Nil when it doesn't (a dev build).
    @discardableResult
    static func applyClaudeStatusLine(
        enabled: Bool,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        bundleURL: URL = Bundle.main.bundleURL
    ) -> ClaudeStatusLineState? {
        guard shouldInstall(environment: environment, bundleURL: bundleURL) else { return nil }
        return installClaudeStatusLine(enabled: enabled)
    }

    private static func statusLineState(of value: Any?) -> ClaudeStatusLineState {
        guard let value, !(value is NSNull) else { return .none }
        guard let command = (value as? [String: Any])?["command"] as? String,
              command.range(of: statusLineCommandPattern, options: .regularExpression) != nil else { return .foreign }
        return .nirux
    }
}
