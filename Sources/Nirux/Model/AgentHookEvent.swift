import Foundation

/// One agent lifecycle event reported by a Claude Code hook or Codex's
/// `notify` command. Written as one JSON line per event to
/// `hook-events.jsonl` in the state directory by `Nirux --hook`, then
/// drained and routed by `AgentHookCenter`.
struct AgentHookEvent: Codable, Equatable {
    enum Kind: String, Codable {
        case claude, codex
    }

    /// Normalized event names. The Claude hooks map 1:1 (PostToolUse and
    /// PostToolUseFailure both mean "the tool call is over"); Codex only
    /// has a single "agent turn complete" notification.
    enum Name: String, Codable {
        case sessionStart, userPromptSubmit, preToolUse, notification, stop, sessionEnd
        case permissionRequest, postToolUse, subagentStop
        case turnComplete // codex
    }

    let kind: Kind
    let name: Name
    /// NIRUX_AGENT_UUID from the hook process's environment (inherited from
    /// the shell of the column that launched the agent). The receiver drops
    /// events without it (see `AgentHookCLI.isFromNiruxTerminal`); nil only
    /// in queue entries written by older builds.
    let agentUUID: String?
    /// NIRUX_WORKSPACE_ID from the same environment — lets notifications
    /// route events back to their workspace.
    let workspaceID: String?
    /// Claude session_id / Codex thread-id.
    let sessionID: String?
    /// Agent process that fired the hook (`ProcessInstance.hookEmitter`).
    /// Its identity proves the event comes from the column's foreground
    /// agent rather than a nested one sharing its NIRUX_AGENT_UUID. Legacy
    /// queue entries omit it.
    let emitterProcess: ProcessInstance?
    let cwd: String?
    /// Tool name (PreToolUse, PermissionRequest), notification message
    /// (Notification, cleaned), or final assistant message (Codex
    /// turnComplete, truncated).
    let detail: String?
    /// Claude SessionStart `source`: startup, resume, clear, compact, fork.
    let source: String?
    /// Claude tool events (PreToolUse, PermissionRequest, PostToolUse*):
    /// the tool, a short cleaned excerpt of its input (the command, file,
    /// question…), and a key matching a PermissionRequest to the
    /// PostToolUse of the same call. Only the excerpt and key leave the
    /// receiver, never the input itself.
    let toolName: String?
    let toolSummary: String?
    let toolKey: String?
    /// Subagent the event came from (Claude `agent_id`); nil on the main
    /// thread.
    let agentID: String?
    /// Claude Notification `notification_type` (permission_prompt,
    /// idle_prompt…); nil from Claude versions that predate it.
    let notificationType: String?
    /// Claude session transcript (`transcript_path`), on the turn-level
    /// events only (see `carriesTranscriptPath`): enough to follow the
    /// column's session usage without growing every tool event's line.
    let transcriptPath: String?
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
            guard let hookName = payload["hook_event_name"] as? String,
                  let name = Self.claudeName(hookName) else { return nil }
            self.name = name
            sessionID = payload["session_id"] as? String
            let cwd = payload["cwd"] as? String
            self.cwd = cwd
            source = name == .sessionStart ? payload["source"] as? String : nil
            agentID = (payload["agent_id"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            let toolName = [.preToolUse, .permissionRequest, .postToolUse].contains(name)
                ? payload["tool_name"] as? String
                : nil
            self.toolName = toolName
            if let toolName, name != .preToolUse {
                let input = payload["tool_input"] as? [String: Any] ?? [:]
                toolSummary = AgentToolInput.summary(
                    toolName: toolName, input: input, cwd: cwd, home: env["HOME"]
                )
                toolKey = AgentToolInput.key(toolName: toolName, input: input)
            } else {
                toolSummary = nil
                toolKey = nil
            }
            transcriptPath = Self.carriesTranscriptPath(name)
                ? (payload["transcript_path"] as? String).flatMap(Self.validTranscriptPath)
                : nil
            if name == .notification {
                notificationType = payload["notification_type"] as? String
                detail = (payload["message"] as? String).flatMap { AgentText.clean($0, maxLength: 300) }
            } else {
                notificationType = nil
                detail = toolName
            }
        case .codex:
            // notify receives e.g. {"type":"agent-turn-complete","thread-id":…,
            // "cwd":…,"last-assistant-message":…}
            guard let type = payload["type"] as? String, type == "agent-turn-complete" else { return nil }
            name = .turnComplete
            sessionID = payload["thread-id"] as? String
            cwd = payload["cwd"] as? String
            source = nil
            let message = payload["last-assistant-message"] as? String
            detail = message.map { String($0.prefix(500)) }
            toolName = nil
            toolSummary = nil
            toolKey = nil
            agentID = nil
            notificationType = nil
            transcriptPath = nil
        }
    }

    /// Events that bind or confirm the column's session — where its
    /// transcript is worth knowing.
    static func carriesTranscriptPath(_ name: Name) -> Bool {
        [.sessionStart, .userPromptSubmit, .stop].contains(name)
    }

    /// An absolute `.jsonl` path, or nil.
    static func validTranscriptPath(_ path: String) -> String? {
        path.hasPrefix("/") && path.hasSuffix(".jsonl") && !path.contains("\0") ? path : nil
    }

    private static func claudeName(_ hookName: String) -> Name? {
        switch hookName {
        case "SessionStart": return .sessionStart
        case "UserPromptSubmit": return .userPromptSubmit
        case "PreToolUse": return .preToolUse
        case "PermissionRequest": return .permissionRequest
        case "PostToolUse", "PostToolUseFailure": return .postToolUse
        case "Notification": return .notification
        case "SubagentStop": return .subagentStop
        case "Stop": return .stop
        case "SessionEnd": return .sessionEnd
        default: return nil
        }
    }

    /// Direct construction (tests, synthesized events).
    init(
        kind: Kind,
        name: Name,
        agentUUID: String? = nil,
        workspaceID: String? = nil,
        sessionID: String? = nil,
        emitterProcess: ProcessInstance? = nil,
        cwd: String? = nil,
        detail: String? = nil,
        source: String? = nil,
        toolName: String? = nil,
        toolSummary: String? = nil,
        toolKey: String? = nil,
        agentID: String? = nil,
        notificationType: String? = nil,
        transcriptPath: String? = nil,
        timestamp: TimeInterval = 0
    ) {
        self.kind = kind
        self.name = name
        self.agentUUID = agentUUID
        self.workspaceID = workspaceID
        self.sessionID = sessionID
        self.emitterProcess = emitterProcess
        self.cwd = cwd
        self.detail = detail
        self.source = source
        self.toolName = toolName
        self.toolSummary = toolSummary
        self.toolKey = toolKey
        self.agentID = agentID
        self.notificationType = notificationType
        self.transcriptPath = transcriptPath
        self.timestamp = timestamp
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
        guard isFromNiruxTerminal(env: env) else { return 0 }
        let emitterProcess = ProcessInstance.hookEmitter(for: kind)
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

    /// Only Nirux terminals export NIRUX_AGENT_UUID. An event without it
    /// can't be routed to a column; queueing it would only put an
    /// "External agent" row in the activity feed. The installed hook
    /// commands already skip launching Nirux then; this drops events from
    /// hook entries written by older builds (until the next launch
    /// refreshes them) and from manual invocations. Check it only after
    /// reading stdin: Claude reports a hook that exits before taking its
    /// whole payload as failed (EPIPE).
    static func isFromNiruxTerminal(env: [String: String]) -> Bool {
        env["NIRUX_AGENT_UUID"]?.isEmpty == false
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
