import Foundation

/// Installs Nirux's agent-status hooks into the agents' own config files:
/// - Claude Code: `hooks` entries in ~/.claude/settings.json
/// - Codex: the `notify` program in ~/.codex/config.toml
///
/// Both agents then invoke `Nirux --hook <kind>` on lifecycle events, which
/// is how `AgentHookCenter` gets exact working/attention signals instead of
/// guessing from terminal output.
///
/// Both configs are global, so every agent session on the machine runs
/// these hooks. The commands are shell-guarded on NIRUX_AGENT_UUID, which
/// only Nirux terminals export: sessions anywhere else never launch the
/// Nirux binary (it links AppKit and WebKit).
///
/// Idempotent and non-destructive: user-defined hooks are preserved, stale
/// Nirux entries (old app path, older command format) are refreshed,
/// foreign Codex `notify` configs are left untouched (with a log line), and
/// symlinked configs (dotfiles) are written through, not replaced. Runs at
/// every launch — cheap (a few KB of I/O) and self-healing after app
/// updates/moves. `NIRUX_SKIP_HOOK_INSTALL=1` turns it off.
enum AgentHookInstaller {
    /// Substring identifying Nirux-owned hook commands in existing configs.
    private static let claudeMarker = "--hook claude"

    /// Absolute path the hook commands invoke. Inside the app bundle this is
    /// the bundle executable; fall back to the standard install location.
    static var defaultExecutablePath: String {
        Bundle.main.executableURL?.path ?? "/Applications/Nirux.app/Contents/MacOS/Nirux"
    }

    /// NIRUX_SKIP_HOOK_INSTALL: any value but empty or "0" leaves the agent
    /// configs alone. Dev smoke runs use it so a debug build doesn't point
    /// the real hooks at its own binary.
    static func isInstallDisabled(environment: [String: String]) -> Bool {
        guard let value = environment["NIRUX_SKIP_HOOK_INSTALL"] else { return false }
        return !value.isEmpty && value != "0"
    }

    static func installAll(
        executablePath: String = defaultExecutablePath,
        home: URL = URL(fileURLWithPath: NSHomeDirectory()),
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        if isInstallDisabled(environment: environment) {
            NSLog("[AgentHooks] NIRUX_SKIP_HOOK_INSTALL set — leaving agent configs untouched")
            return
        }
        installClaudeHooks(executablePath: executablePath, home: home)
        installCodexNotify(executablePath: executablePath, home: home)
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

    /// The command claude runs (via `sh -c`) on every hook event. The
    /// NIRUX_AGENT_UUID guard makes it a shell builtin test outside Nirux
    /// terminals; `test -x` makes a deleted/moved binary (app uninstalled,
    /// dev build cleaned) a silent no-op instead of an error on every tool
    /// call. `if` rather than `&&` so a false guard still exits 0.
    static func claudeHookCommand(executablePath: String) -> String {
        let path = shellQuoted(executablePath)
        return #"if [ -n "$NIRUX_AGENT_UUID" ] && [ -x \#(path) ]; then \#(path) --hook claude; fi"#
    }

    static func installClaudeHooks(
        executablePath: String = defaultExecutablePath,
        home: URL = URL(fileURLWithPath: NSHomeDirectory())
    ) {
        let dir = home.appendingPathComponent(".claude")
        guard let url = resolvingSymlinks(dir.appendingPathComponent("settings.json")) else {
            NSLog("[AgentHooks] ~/.claude/settings.json is a symlink loop — skipping hook install")
            return
        }
        let command = claudeHookCommand(executablePath: executablePath)

        var root: [String: Any] = [:]
        var existing: [String: Any]?
        if FileManager.default.fileExists(atPath: url.path) {
            guard let data = try? Data(contentsOf: url),
                  let parsed = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                // Don't clobber a settings file we can't read or parse
                // (permissions, JSON5-ish user edits, corruption). Hook
                // status just stays off.
                NSLog("[AgentHooks] ~/.claude/settings.json unreadable or unparsable — skipping hook install")
                return
            }
            root = parsed
            existing = parsed
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
        if let existing, NSDictionary(dictionary: existing).isEqual(to: root) {
            return
        }

        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            // Sorted keys: deterministic output, so relaunches never churn
            // a settings file kept under version control.
            let data = try JSONSerialization.data(
                withJSONObject: root,
                options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            )
            try data.write(to: url, options: .atomic)
        } catch {
            NSLog("[AgentHooks] failed to write ~/.claude/settings.json: %@", error.localizedDescription)
        }
    }

    // MARK: - Codex (~/.codex/config.toml)

    /// Codex has a single `notify = ["program", "args…"]` hook: it runs the
    /// argv directly (no shell) on every completed turn, appending the
    /// notification JSON as the last argument. The NIRUX_AGENT_UUID guard
    /// therefore goes through `sh -c`, which sees the Nirux path as $0 and
    /// the payload as $1. `exec` keeps codex the receiver's parent: the
    /// receiver records its parent process, and Codex session capture checks
    /// it against the column's foreground job.
    static let codexNotifyScript =
        #"if [ -n "$NIRUX_AGENT_UUID" ] && [ -x "$0" ]; then exec "$0" --hook codex "$@"; fi"#

    static func codexNotifyLine(executablePath: String) -> String {
        let escapedPath = executablePath
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        // The script goes in a TOML literal string: it holds no `'`, and
        // its double quotes then need no escaping.
        return #"notify = ["/bin/sh", "-c", '\#(codexNotifyScript)', "\#(escapedPath)"]"#
    }

    static func installCodexNotify(
        executablePath: String = defaultExecutablePath,
        home: URL = URL(fileURLWithPath: NSHomeDirectory())
    ) {
        let dir = home.appendingPathComponent(".codex")
        guard let url = resolvingSymlinks(dir.appendingPathComponent("config.toml")) else {
            NSLog("[AgentHooks] ~/.codex/config.toml is a symlink loop — skipping notify install")
            return
        }
        let notifyLine = codexNotifyLine(executablePath: executablePath)

        guard FileManager.default.fileExists(atPath: url.path) else {
            // No config yet — create a minimal one.
            do {
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                try (notifyLine + "\n").write(to: url, atomically: true, encoding: .utf8)
            } catch {
                NSLog("[AgentHooks] failed to create ~/.codex/config.toml: %@", error.localizedDescription)
            }
            return
        }
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            // Never replace a config we couldn't read with a minimal one.
            NSLog("[AgentHooks] ~/.codex/config.toml unreadable — skipping notify install")
            return
        }

        var lines = text.components(separatedBy: "\n")
        let notifyPattern = #"^\s*notify\s*="#
        if let index = lines.firstIndex(where: { $0.range(of: notifyPattern, options: .regularExpression) != nil }) {
            if lines[index].contains("--hook") && lines[index].contains("codex") {
                // Ours — refresh the path if the app moved, and the format
                // if an older build wrote the unguarded one.
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

    // MARK: - Helpers

    /// POSIX single-quoting: the path stays one inert word whatever it holds
    /// (spaces, `$`, quotes).
    static func shellQuoted(_ string: String) -> String {
        "'" + string.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
    }

    /// Dotfiles setups symlink these configs into a repo. An atomic write
    /// renames a temp file over the path it's given, which would replace the
    /// link with a plain file — so follow the link chain to the real file.
    /// Unlike `resolvingSymlinksInPath()`, also follows a dangling link (the
    /// write then creates its target). Nil on a symlink loop.
    static func resolvingSymlinks(_ url: URL) -> URL? {
        var current = url
        for _ in 0..<32 {
            guard let destination = try? FileManager.default.destinationOfSymbolicLink(atPath: current.path) else {
                return current
            }
            current = destination.hasPrefix("/")
                ? URL(fileURLWithPath: destination)
                : current.deletingLastPathComponent().appendingPathComponent(destination)
        }
        return nil
    }
}
