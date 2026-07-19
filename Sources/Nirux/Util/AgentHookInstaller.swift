import Foundation

/// Installs Nirux's agent-status hooks into the agents' own config files:
/// - Claude Code: `hooks` entries in ~/.claude/settings.json
/// - Codex: the `notify` program in ~/.codex/config.toml
///
/// Both agents then invoke `Nirux --hook <kind>` on lifecycle events, which
/// is how `AgentHookCenter` gets exact working/attention signals instead of
/// guessing from terminal output.
///
/// Idempotent and non-destructive: user-defined hooks are preserved, stale
/// Nirux entries (old app path) are refreshed, foreign Codex `notify`
/// configs are left untouched (with a log line). Runs at every launch —
/// cheap (a few KB of I/O) and self-healing after app updates/moves.
enum AgentHookInstaller {
    /// Substring identifying Nirux-owned hook commands in existing configs.
    private static let claudeMarker = "--hook claude"

    /// Absolute path the hook commands invoke. Inside the app bundle this is
    /// the bundle executable; fall back to the standard install location.
    static var defaultExecutablePath: String {
        Bundle.main.executableURL?.path ?? "/Applications/Nirux.app/Contents/MacOS/Nirux"
    }

    static func installAll(executablePath: String = defaultExecutablePath) {
        installClaudeHooks(executablePath: executablePath)
        installCodexNotify(executablePath: executablePath)
    }

    // MARK: - Claude Code (~/.claude/settings.json)

    /// Events Nirux listens to. All sync: sync hooks run in order with the
    /// agent loop (a PreToolUse can never land after its turn's Stop), which
    /// keeps the status machine's event stream deterministic. The receiver
    /// exits in single-digit milliseconds, well under tool-call latency.
    static let claudeHookEvents = [
        "SessionStart",
        "UserPromptSubmit",
        "PreToolUse",
        "Notification",
        "Stop",
        "SessionEnd"
    ]

    /// The command claude invokes on every hook event. Guarded by `test -x`
    /// so a deleted/moved Nirux binary (app uninstalled, dev build cleaned)
    /// makes the hook a silent no-op instead of an error on every tool call.
    static func claudeHookCommand(executablePath: String) -> String {
        "if [ -x \"\(executablePath)\" ]; then \"\(executablePath)\" --hook claude; fi"
    }

    static func installClaudeHooks(
        executablePath: String = defaultExecutablePath,
        home: URL = URL(fileURLWithPath: NSHomeDirectory())
    ) {
        let dir = home.appendingPathComponent(".claude")
        let url = dir.appendingPathComponent("settings.json")
        let command = claudeHookCommand(executablePath: executablePath)

        var root: [String: Any] = [:]
        if let data = try? Data(contentsOf: url) {
            guard let parsed = try? JSONSerialization.jsonObject(with: data),
                  let dict = parsed as? [String: Any] else {
                // Don't clobber a settings file we can't parse (JSON5-ish
                // user edits, corruption). Hook status just stays off.
                NSLog("[AgentHooks] ~/.claude/settings.json unparsable — skipping hook install")
                return
            }
            root = dict
        }

        var hooks = root["hooks"] as? [String: Any] ?? [:]
        for event in claudeHookEvents {
            var groups = hooks[event] as? [[String: Any]] ?? []
            // Drop Nirux-owned hook entries (any stale path); drop groups
            // left empty by that removal. User hooks in mixed groups survive.
            for index in groups.indices.reversed() {
                var list = groups[index]["hooks"] as? [[String: Any]] ?? []
                list.removeAll { ($0["command"] as? String)?.contains(claudeMarker) == true }
                if list.isEmpty {
                    groups.remove(at: index)
                } else {
                    groups[index]["hooks"] = list
                }
            }
            let entry: [String: Any] = ["type": "command", "command": command]
            groups.append(["matcher": "", "hooks": [entry]])
            hooks[event] = groups
        }
        root["hooks"] = hooks

        // Skip the write when nothing changed (NSDictionary comparison works
        // for JSON value types).
        if let existing = try? Data(contentsOf: url),
           let old = (try? JSONSerialization.jsonObject(with: existing)) as? [String: Any],
           NSDictionary(dictionary: old).isEqual(to: root) {
            return
        }

        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: url, options: .atomic)
        } catch {
            NSLog("[AgentHooks] failed to write ~/.claude/settings.json: %@", error.localizedDescription)
        }
    }

    // MARK: - Codex (~/.codex/config.toml)

    /// Codex has a single `notify = ["program", "args…"]` hook: the program
    /// gets the notification JSON as its last argv on every completed turn.
    static func installCodexNotify(
        executablePath: String = defaultExecutablePath,
        home: URL = URL(fileURLWithPath: NSHomeDirectory())
    ) {
        let dir = home.appendingPathComponent(".codex")
        let url = dir.appendingPathComponent("config.toml")
        let escapedPath = executablePath
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let notifyLine = "notify = [\"\(escapedPath)\", \"--hook\", \"codex\"]"

        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            // No config yet — create a minimal one.
            do {
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                try (notifyLine + "\n").write(to: url, atomically: true, encoding: .utf8)
            } catch {
                NSLog("[AgentHooks] failed to create ~/.codex/config.toml: %@", error.localizedDescription)
            }
            return
        }

        var lines = text.components(separatedBy: "\n")
        let notifyPattern = #"^\s*notify\s*="#
        if let index = lines.firstIndex(where: { $0.range(of: notifyPattern, options: .regularExpression) != nil }) {
            if lines[index].contains("--hook") && lines[index].contains("codex") {
                // Ours — refresh the path if the app moved.
                if lines[index] != notifyLine {
                    lines[index] = notifyLine
                    write(lines: lines, to: url)
                }
            } else {
                NSLog("[AgentHooks] ~/.codex/config.toml already has a foreign notify — turn-complete status for codex stays heuristic")
            }
            return
        }

        // Insert at top level: before the first [table] header, else append.
        let insertAt = lines.firstIndex(where: {
            $0.range(of: #"^\s*\["#, options: .regularExpression) != nil
        }) ?? lines.count
        lines.insert(notifyLine, at: insertAt)
        write(lines: lines, to: url)
    }

    private static func write(lines: [String], to url: URL) {
        do {
            try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        } catch {
            NSLog("[AgentHooks] failed to write %@: %@", url.path, error.localizedDescription)
        }
    }
}
