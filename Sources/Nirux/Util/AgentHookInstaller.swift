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
/// Nirux terminals export (and processes started from them inherit):
/// sessions anywhere else never launch the Nirux binary (it links AppKit
/// and WebKit).
///
/// Idempotent and non-destructive: user-defined hooks are preserved, stale
/// Nirux entries (old app path, older command format) are refreshed,
/// foreign Codex `notify` configs are left untouched (with a log line), and
/// symlinked configs (dotfiles) are written through, not replaced. Runs at
/// every launch of the app bundle — cheap (a few KB of I/O) and
/// self-healing after app updates/moves. See `shouldInstall` for dev builds.
enum AgentHookInstaller {
    /// Identifies Nirux-owned Claude hook commands in existing configs, in
    /// every format Nirux has written: `"<path>/Nirux" --hook claude`, and
    /// the guarded forms with the path in double or single quotes.
    private static let claudeCommandPattern = #"/Nirux["']? --hook claude"#

    /// Absolute path the hook commands invoke. Inside the app bundle this is
    /// the bundle executable; fall back to the standard install location.
    static var defaultExecutablePath: String {
        Bundle.main.executableURL?.path ?? "/Applications/Nirux.app/Contents/MacOS/Nirux"
    }

    /// Only a Nirux running from an app bundle installs the hooks. A dev
    /// build (`swift run`, `.build/debug/Nirux`) would point every agent
    /// session on the machine at a binary that goes away with its worktree.
    /// NIRUX_FORCE_HOOK_INSTALL=1 opts a dev build in (to test installer
    /// changes); NIRUX_SKIP_HOOK_INSTALL=1 opts any build out.
    static func shouldInstall(environment: [String: String], bundleURL: URL) -> Bool {
        if isEnabled(environment["NIRUX_SKIP_HOOK_INSTALL"]) { return false }
        return bundleURL.pathExtension == "app" || isEnabled(environment["NIRUX_FORCE_HOOK_INSTALL"])
    }

    private static func isEnabled(_ flag: String?) -> Bool {
        guard let flag else { return false }
        return ["1", "true", "yes"].contains(flag.lowercased())
    }

    /// `claudeVersion` is read only when the hooks are installed.
    static func installAll(
        executablePath: String = defaultExecutablePath,
        home: URL = URL(fileURLWithPath: NSHomeDirectory()),
        environment: [String: String] = ProcessInfo.processInfo.environment,
        bundleURL: URL = Bundle.main.bundleURL,
        claudeVersion: @autoclosure () -> ClaudeCodeVersion? = ClaudeCodeVersion.detect()
    ) {
        guard shouldInstall(environment: environment, bundleURL: bundleURL) else {
            NSLog("[AgentHooks] dev build or NIRUX_SKIP_HOOK_INSTALL — leaving agent configs untouched")
            return
        }
        installClaudeHooks(executablePath: executablePath, home: home, claudeVersion: claudeVersion())
        installCodexNotify(executablePath: executablePath, home: home)
    }

    // MARK: - Claude Code (~/.claude/settings.json)

    /// Events Nirux listens to. All sync: sync hooks run in order with the
    /// agent loop (a PreToolUse can never land after its turn's Stop), which
    /// keeps the status machine's event stream deterministic. The receiver
    /// exits in single-digit milliseconds, well under tool-call latency.
    ///
    /// PermissionRequest (a dialog opens, with the tool call it asks
    /// about), PostToolUse/PostToolUseFailure (the call ran: its dialog was
    /// answered, the agent works again) and SubagentStop (a subagent's
    /// dialogs are gone) need Claude Code 2.0.56 or later. Claude Code
    /// before 2.1.101 drops the whole settings file over an event name it
    /// doesn't know, so only long-established events belong here.
    static let claudeHookEvents = [
        "SessionStart",
        "UserPromptSubmit",
        "PreToolUse",
        "PermissionRequest",
        "PostToolUse",
        "PostToolUseFailure",
        "Notification",
        "SubagentStop",
        "Stop",
        "SessionEnd"
    ]

    /// Newer events, with the first Claude Code that knows each. They go in
    /// only when the `claude` Nirux terminals run is known to be at least
    /// that recent: an older one would drop the whole settings file (see
    /// above). Unknown version, no entry — and a refresh takes back an
    /// entry the version no longer allows.
    ///
    /// StopFailure (2.1.78) fires instead of Stop when a turn ends on an
    /// API error. Claude doesn't wait for it, so the receiver never slows
    /// the agent.
    static let versionedClaudeHookEvents: [(event: String, minimumVersion: ClaudeCodeVersion)] = [
        ("StopFailure", ClaudeCodeVersion(major: 2, minor: 1, patch: 78))
    ]

    /// Every event to install for a `claude` of `version`.
    static func claudeHookEvents(for version: ClaudeCodeVersion?) -> [String] {
        claudeHookEvents + versionedClaudeHookEvents.compactMap { entry in
            guard let version, version >= entry.minimumVersion else { return nil }
            return entry.event
        }
    }

    /// The command claude runs (via `sh -c`) on every hook event. The
    /// NIRUX_AGENT_UUID guard skips the binary outside Nirux terminals;
    /// `test -x` makes a deleted/moved binary (app uninstalled, dev build
    /// cleaned) a silent no-op instead of an error on every tool call. When
    /// skipping, `/bin/cat` (PATH-independent) still drains the payload:
    /// claude reports a hook that closes stdin before a large payload (over
    /// the 64 KB pipe buffer) is written as failed. `if` rather than `&&` so
    /// a false guard exits 0.
    static func claudeHookCommand(executablePath: String) -> String {
        let path = shellQuoted(executablePath)
        return #"if [ -n "$NIRUX_AGENT_UUID" ] && [ -x \#(path) ]; then \#(path) --hook claude; else /bin/cat >/dev/null; fi"#
    }

    static func installClaudeHooks(
        executablePath: String = defaultExecutablePath,
        home: URL = URL(fileURLWithPath: NSHomeDirectory()),
        claudeVersion: ClaudeCodeVersion? = nil
    ) {
        let dir = home.appendingPathComponent(".claude")
        guard let url = resolvingSymlinks(dir.appendingPathComponent("settings.json")) else {
            NSLog("[AgentHooks] ~/.claude/settings.json: symlink loop or chain too long — skipping hook install")
            return
        }
        let command = claudeHookCommand(executablePath: executablePath)
        let events = claudeHookEvents(for: claudeVersion)

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
        // Drop Nirux-owned entries under EVERY event, listed or not: an
        // event another build installed (older, or newer before a
        // downgrade) must not keep launching the binary.
        for event in hooks.keys.sorted() {
            guard let groups = hooks[event] as? [[String: Any]],
                  let cleaned = removingNiruxEntries(from: groups) else { continue }
            if cleaned.isEmpty, !events.contains(event) {
                hooks.removeValue(forKey: event)
            } else {
                hooks[event] = cleaned
            }
        }
        let entry: [String: Any] = ["type": "command", "command": command]
        for event in events {
            var groups = hooks[event] as? [[String: Any]] ?? []
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
            // Sorted keys keep the output deterministic (the check above
            // already skips rewriting an unchanged file).
            let data = try JSONSerialization.data(
                withJSONObject: root,
                options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            )
            try data.write(to: url, options: .atomic)
        } catch {
            NSLog("[AgentHooks] failed to write %@: %@", url.path, error.localizedDescription)
        }
    }

    /// `groups` without Nirux-owned hook entries (any stale path), and
    /// without groups that removal left empty; user hooks in mixed groups
    /// survive. Nil when nothing was Nirux's.
    private static func removingNiruxEntries(from groups: [[String: Any]]) -> [[String: Any]]? {
        var removed = false
        var result: [[String: Any]] = []
        for var group in groups {
            let list = group["hooks"] as? [[String: Any]] ?? []
            let kept = list.filter {
                ($0["command"] as? String)?.range(of: claudeCommandPattern, options: .regularExpression) == nil
            }
            guard kept.count != list.count else {
                result.append(group)
                continue
            }
            removed = true
            if !kept.isEmpty {
                group["hooks"] = kept
                result.append(group)
            }
        }
        return removed ? result : nil
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
            NSLog("[AgentHooks] ~/.codex/config.toml: symlink loop or chain too long — skipping notify install")
            return
        }
        let notifyLine = codexNotifyLine(executablePath: executablePath)

        guard FileManager.default.fileExists(atPath: url.path) else {
            // No config yet — create a minimal one.
            do {
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                try (notifyLine + "\n").write(to: url, atomically: true, encoding: .utf8)
            } catch {
                NSLog("[AgentHooks] failed to create %@: %@", url.path, error.localizedDescription)
            }
            return
        }
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            // Never replace a config we couldn't read with a minimal one.
            NSLog("[AgentHooks] ~/.codex/config.toml unreadable — skipping notify install")
            return
        }

        // Lines split on \n keep a CRLF file's \r. Every line written here is
        // followed by \n, so the \r it carries always completes a CRLF — a
        // bare \r (as the file's last byte) is invalid TOML.
        var lines = text.components(separatedBy: "\n")
        let cr = text.contains("\r\n") ? "\r" : ""
        if let index = lines.firstIndex(where: isNotifyLine) {
            guard isNiruxNotify(lines[index]) else {
                NSLog("[AgentHooks] ~/.codex/config.toml has a foreign or multi-line notify — codex turn status stays heuristic")
                return
            }
            // Ours — refresh the path if the app moved, and the format if an
            // older build wrote the unguarded one. Keep the line's ending.
            let refreshed = notifyLine + (lines[index].hasSuffix("\r") ? "\r" : "")
            if lines[index] != refreshed {
                lines[index] = refreshed
                write(lines: lines, to: url)
            }
            return
        }

        // Insert at top level: before the first [table] header, else as a
        // new last line (terminating the current last line if needed).
        if let table = lines.firstIndex(where: { $0.range(of: #"^\s*\["#, options: .regularExpression) != nil }) {
            lines.insert(notifyLine + cr, at: table)
        } else if lines.last == "" {
            lines.insert(notifyLine + cr, at: lines.count - 1)
        } else {
            lines[lines.count - 1] += cr
            lines += [notifyLine + cr, ""]
        }
        write(lines: lines, to: url)
    }

    private static func isNotifyLine(_ line: String) -> Bool {
        line.range(of: #"^\s*notify\s*="#, options: .regularExpression) != nil
    }

    /// Whether a `notify` line is one Nirux wrote: the unguarded
    /// `["<path>", "--hook", "codex"]` of older builds or the guarded form,
    /// whole on one line. A wrapped array counts as foreign: replacing its
    /// first line alone would leave invalid TOML behind.
    static func isNiruxNotify(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasSuffix("]") else { return false }
        return trimmed.hasSuffix(#""--hook", "codex"]"#) || trimmed.contains(#"exec "$0" --hook codex "$@""#)
    }

    private static func write(lines: [String], to url: URL) {
        do {
            try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        } catch {
            NSLog("[AgentHooks] failed to write %@: %@", url.path, error.localizedDescription)
        }
    }

    // MARK: - Status (first-launch checklist)

    static func status(
        home: URL = URL(fileURLWithPath: NSHomeDirectory()),
        environment: [String: String] = ProcessInfo.processInfo.environment,
        bundleURL: URL = Bundle.main.bundleURL
    ) -> AgentHooksStatus {
        AgentHooksStatus(
            claude: hasClaudeHooks(home: home),
            codex: hasCodexNotify(home: home),
            installsHooks: shouldInstall(environment: environment, bundleURL: bundleURL)
        )
    }

    /// Every event Nirux listens to has a Nirux entry, whichever app path it
    /// runs (the next launch of the app bundle refreshes the path).
    static func hasClaudeHooks(home: URL) -> Bool {
        guard let url = resolvingSymlinks(home.appendingPathComponent(".claude/settings.json")),
              let data = try? Data(contentsOf: url),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let hooks = root["hooks"] as? [String: Any] else { return false }
        return claudeHookEvents.allSatisfy { event in
            let groups = hooks[event] as? [[String: Any]] ?? []
            return groups.contains { group in
                (group["hooks"] as? [[String: Any]] ?? []).contains {
                    ($0["command"] as? String)?.range(of: claudeCommandPattern, options: .regularExpression) != nil
                }
            }
        }
    }

    /// Checks the first `notify` line, the one the installer manages.
    static func hasCodexNotify(home: URL) -> Bool {
        guard let url = resolvingSymlinks(home.appendingPathComponent(".codex/config.toml")),
              let text = try? String(contentsOf: url, encoding: .utf8),
              let line = text.components(separatedBy: "\n").first(where: isNotifyLine) else { return false }
        return isNiruxNotify(line)
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
    /// write then creates its target if the target's directory exists). Nil
    /// on a symlink loop or an implausibly long chain.
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
