import Foundation

/// One agent lifecycle event reported by a Claude Code hook or Codex's
/// `notify` command. Written as one JSON line per event to
/// `hook-events.jsonl` in the state directory by `Nirux --hook`, then
/// drained and routed by `AgentHookCenter`.
struct AgentHookEvent: Codable, Equatable {
    enum Kind: String, Codable {
        case claude, codex
    }

    /// Normalized event names. The Claude hooks map 1:1; Codex only has a
    /// single "agent turn complete" notification.
    enum Name: String, Codable {
        case sessionStart, userPromptSubmit, preToolUse, notification, stop, sessionEnd
        case turnComplete // codex
    }

    let kind: Kind
    let name: Name
    /// NIRUX_AGENT_UUID from the hook process's environment (inherited from
    /// the shell of the column that launched the agent). Nil when the agent
    /// runs outside a Nirux terminal.
    let agentUUID: String?
    /// NIRUX_WORKSPACE_ID from the same environment — lets notifications
    /// route events back to their workspace.
    let workspaceID: String?
    /// Claude session_id / Codex thread-id.
    let sessionID: String?
    /// Parent of the Codex hook receiver. Its process identity proves that a
    /// reported thread belongs to the column's current foreground job. Legacy
    /// queue entries and Claude events omit it.
    let emitterProcess: ProcessInstance?
    let cwd: String?
    /// Tool name (PreToolUse), notification message (Notification), or final
    /// assistant message (Codex turnComplete, truncated).
    let detail: String?
    /// Receiver-side timestamp (epoch seconds) — the emitter's clock and
    /// timezone are irrelevant.
    let timestamp: TimeInterval

    /// Parse the JSON payload a hook receives (Claude: stdin, Codex: last
    /// argv) into an event. Returns nil for payloads we don't care about —
    /// unknown events are ignored, never errors.
    init?(
        kind: Kind,
        payload: [String: Any],
        env: [String: String],
        now: TimeInterval,
        emitterProcess: ProcessInstance? = nil
    ) {
        self.kind = kind
        agentUUID = env["NIRUX_AGENT_UUID"]
        workspaceID = env["NIRUX_WORKSPACE_ID"]
        timestamp = now
        self.emitterProcess = emitterProcess

        switch kind {
        case .claude:
            guard let hookName = payload["hook_event_name"] as? String else { return nil }
            switch hookName {
            case "SessionStart": name = .sessionStart
            case "UserPromptSubmit": name = .userPromptSubmit
            case "PreToolUse": name = .preToolUse
            case "Notification": name = .notification
            case "Stop": name = .stop
            case "SessionEnd": name = .sessionEnd
            default: return nil
            }
            sessionID = payload["session_id"] as? String
            cwd = payload["cwd"] as? String
            if name == .preToolUse {
                detail = payload["tool_name"] as? String
            } else if name == .notification {
                detail = payload["message"] as? String
            } else {
                detail = nil
            }
        case .codex:
            // notify receives e.g. {"type":"agent-turn-complete","thread-id":…,
            // "cwd":…,"last-assistant-message":…}
            guard let type = payload["type"] as? String, type == "agent-turn-complete" else { return nil }
            name = .turnComplete
            sessionID = payload["thread-id"] as? String
            cwd = payload["cwd"] as? String
            let message = payload["last-assistant-message"] as? String
            detail = message.map { String($0.prefix(500)) }
        }
    }
}

/// Entry point for `Nirux --hook claude|codex [payload-json]` — the command
/// registered in ~/.claude/settings.json hooks and ~/.codex/config.toml
/// `notify`. Reads the payload, appends one JSON line to the events file,
/// exits. Must be fast and must NEVER fail loudly: a non-zero exit from a
/// sync hook surfaces inside the agent's UI.
enum AgentHookCLI {
    static func run(kind: AgentHookEvent.Kind, payload: String?) -> Int32 {
        let raw: [String: Any]
        if kind == .codex {
            guard let payload,
                  let data = payload.data(using: .utf8),
                  let dict = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            else { return 0 }
            raw = dict
        } else {
            let data = FileHandle.standardInput.readDataToEndOfFile()
            guard let dict = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            else { return 0 }
            raw = dict
        }

        let env = ProcessInfo.processInfo.environment
        let emitterProcess = kind == .codex
            ? ProcessInstance.running(pid: getppid())
            : nil
        guard let event = AgentHookEvent(
            kind: kind,
            payload: raw,
            env: env,
            now: Date().timeIntervalSince1970,
            emitterProcess: emitterProcess
        ) else { return 0 }

        append(event)
        return 0
    }

    /// Append one JSON line. O_APPEND keeps concurrent writers (several
    /// agents across columns) from interleaving mid-line for lines under
    /// PIPE_BUF; lines are small.
    private static func append(_ event: AgentHookEvent) {
        guard var line = try? JSONEncoder().encode(event) else { return }
        line.append(0x0A) // \n
        let url = AgentHookCenter.eventsURL
        let fd = open(url.path, O_WRONLY | O_CREAT | O_APPEND, 0o600)
        guard fd >= 0 else { return }
        line.withUnsafeBytes { buf in
            guard let ptr = buf.baseAddress else { return }
            _ = write(fd, ptr, buf.count)
        }
        close(fd)
    }
}
