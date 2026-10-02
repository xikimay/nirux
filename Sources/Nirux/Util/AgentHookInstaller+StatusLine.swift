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

    /// Guarded like `claudeHookCommand`: outside Nirux terminals, or with
    /// the binary gone, it drains the payload and prints nothing. The flags
    /// read as a hook to a build without the indicator (see `NiruxApp.main`).
    static func claudeStatusLineCommand(executablePath: String) -> String {
        let path = shellQuoted(executablePath)
        return statusLineCommandPrefix + path.dropFirst() + #" ]; then \#(path) --hook claude --statusline; "#
            + "else /bin/cat >/dev/null; fi"
    }

    /// Up to the path's opening quote.
    private static let statusLineCommandPrefix = #"if [ -n "$NIRUX_AGENT_UUID" ] && [ -x '"#

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
        case .unreadable(let reason):
            NSLog("[AgentHooks] ~/.claude/settings.json: %@ — leaving the status line alone", reason)
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

    /// Whether this Nirux keeps the status line in step with its option: a
    /// build that installs the hooks, on the real state. A copy run on a
    /// state of its own (NIRUX_STATE_DIR) has its own option, off at first,
    /// and must not take back the installed app's status line.
    static func managesClaudeStatusLine(environment: [String: String], bundleURL: URL) -> Bool {
        shouldInstall(environment: environment, bundleURL: bundleURL)
            && Persistence.stateDirectoryOverride(in: environment) == nil
    }

    /// At Save in Settings: the same as at launch. Nil when this Nirux
    /// leaves the status line alone (see `managesClaudeStatusLine`).
    @discardableResult
    static func applyClaudeStatusLine(
        enabled: Bool,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        bundleURL: URL = Bundle.main.bundleURL
    ) -> ClaudeStatusLineState? {
        guard managesClaudeStatusLine(environment: environment, bundleURL: bundleURL) else { return nil }
        return installClaudeStatusLine(enabled: enabled)
    }

    /// Nirux's only when it is exactly what Nirux writes, for some Nirux
    /// binary: a status line of the user's own that calls Nirux among other
    /// things (chaining it with their script, say) is theirs.
    private static func statusLineState(of value: Any?) -> ClaudeStatusLineState {
        guard let value, !(value is NSNull) else { return .none }
        guard let entry = value as? [String: Any], Set(entry.keys) == ["type", "command"],
              entry["type"] as? String == "command",
              let command = entry["command"] as? String,
              let path = quotedPath(after: statusLineCommandPrefix, in: command),
              path.hasSuffix("/Nirux"),
              command == claudeStatusLineCommand(executablePath: path) else { return .foreign }
        return .nirux
    }

    /// The path `shellQuoted` wrote right after `prefix` (whose last
    /// character is the opening quote), unquoted.
    private static func quotedPath(after prefix: String, in command: String) -> String? {
        guard command.hasPrefix(prefix) else { return nil }
        var rest = command.dropFirst(prefix.count)
        var path = ""
        while let character = rest.first {
            rest = rest.dropFirst()
            guard character == "'" else {
                path.append(character)
                continue
            }
            // `'\''` stands for a quote inside the path; any other quote ends it.
            guard rest.hasPrefix(#"\''"#) else { return path }
            path.append("'")
            rest = rest.dropFirst(3)
        }
        return nil
    }
}
