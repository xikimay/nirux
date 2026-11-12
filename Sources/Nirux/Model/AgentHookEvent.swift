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
        /// The turn ended on an API error (rate limit, auth, overload…):
        /// Claude fires it instead of Stop.
        case stopFailure
        case turnComplete // codex
        /// Not a Claude hook: the receiver reports what became of a
        /// PermissionRequest it held for a sidebar decision.
        case approvalResolved
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
    /// receiver, never the input itself (but what a question dialog asks:
    /// `dialog`).
    let toolName: String?
    let toolSummary: String?
    let toolKey: String?
    /// On the end of a Claude tool call (PostToolUse*), what tells an agent
    /// going in circles (`AgentCirclingWatch`): how the call ended when it
    /// didn't simply run (an `AgentToolEnd` raw value; a string, so an app
    /// older than its receiver skips an end it doesn't know, not the whole
    /// event), and the program a shell command ran ("swift build"; see
    /// `AgentShellCommand`), and for a command that counts by its exact
    /// text (nothing names it, or `python3 x.py`), what tells its text from
    /// another's (`repeatKey`). Nil from older receivers too.
    let toolEnd: String?
    let toolFamily: String?
    let toolCommandKey: String?
    /// Subagent the event came from (Claude `agent_id`); nil on the main
    /// thread.
    let agentID: String?
    /// Claude Notification `notification_type` (permission_prompt,
    /// idle_prompt…); nil from Claude versions that predate it.
    let notificationType: String?
    /// Claude StopFailure `error`: what ended the turn (`rate_limit`,
    /// `overloaded`, `authentication_failed`…). Its details go in `detail`.
    let errorKind: String?
    /// Claude `prompt_id` on UserPromptSubmit and StopFailure: tells the
    /// turn a late StopFailure was about.
    let promptID: String?
    /// Claude session transcript (`transcript_path`), on the turn-level
    /// events only (see `carriesTranscriptPath`): enough to follow the
    /// column's session usage without growing every tool event's line.
    let transcriptPath: String?
    /// Review passes the event starts (`ReviewPass` raw values): from the
    /// prompt on UserPromptSubmit, from the skill on a `Skill` call's
    /// PostToolUse. Only the passes are kept, never the prompt. Strings, so
    /// an app older than its receiver skips a pass it doesn't know, not
    /// the whole event.
    let reviewPasses: [String]?
    /// On UserPromptSubmit, the header line of a Branch Review message the
    /// prompt holds ("Review comments on … from Nirux:"): the comments
    /// pasted went to Claude (docs/design/branch-review.md, section 6.2). Only
    /// that line is kept of the prompt.
    let reviewHeader: String?
    /// On a main-thread Stop, Claude's final message
    /// (`last_assistant_message`), as `TurnEndText.excerpt` bounds it: what
    /// tells a turn that asks the user something from one that is done
    /// (see `TurnEndVerdict`). Nil elsewhere, from Claude versions without
    /// it, for an agent on another account (`TurnEndText.usesOtherAccount`),
    /// for a headless `claude -p` (`TurnEndText.isHeadless`), and when the
    /// receiver or the app drops it (see `TurnEndMarker`).
    var finalMessage: String?
    /// On a main-thread SessionStart or Stop: whether
    /// this `claude` runs on the login Nirux's own `claude -p` uses
    /// (`TurnEndText.agentOnNiruxAccount`), which only the receiver can
    /// tell, from the agent's environment. The CI failure triage sends
    /// nothing to a model for a workspace whose agent is elsewhere. Nil
    /// from older receivers and on other events: not known to be.
    var onNiruxAccount: Bool?
    /// On a Stop, Claude's `stop_hook_active`: the turn went on because a
    /// Stop hook blocked its end, and this is the end of that continuation
    /// (the end of the turn, unless a hook blocks again).
    let stopHookActive: Bool?
    /// Sidebar approval (see `PermissionApproval`): on a PermissionRequest,
    /// the request ID and deadline (epoch seconds) the receiver waits
    /// under; on approvalResolved, the request and what became of it.
    var approvalRequestID: String?
    var approvalDeadline: TimeInterval?
    /// The call's exact text, as the receiver checked it.
    var approvalText: String?
    var approvalOutcome: PermissionApproval.Outcome?
    /// On the PermissionRequest of a question dialog (AskUserQuestion):
    /// its questions and the options each offers, bounded, for the row of
    /// its task. Nil from older receivers.
    var dialog: AgentDialog?
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
                if name == .permissionRequest, toolName == "AskUserQuestion" {
                    dialog = AgentDialog(toolInput: input)
                }
            } else {
                toolSummary = nil
                toolKey = nil
            }
            if let toolName, name == .postToolUse {
                let command = AgentToolInput.shellTools.contains(toolName)
                    ? ((payload["tool_input"] as? [String: Any])?["command"] as? String).map(AgentShellCommand.init)
                    : nil
                toolEnd = AgentToolOutcome.end(hookName: hookName, payload: payload, command: command)?.rawValue
                toolFamily = command?.family
                toolCommandKey = command.flatMap { $0.countsByText ? $0.repeatKey : nil }
            } else {
                toolEnd = nil
                toolFamily = nil
                toolCommandKey = nil
            }
            transcriptPath = Self.carriesTranscriptPath(name)
                ? (payload["transcript_path"] as? String).flatMap(Self.validTranscriptPath)
                : nil
            notificationType = name == .notification ? payload["notification_type"] as? String : nil
            errorKind = name == .stopFailure
                ? (payload["error"] as? String).flatMap { AgentText.clean($0, maxLength: 40) }
                : nil
            promptID = [.userPromptSubmit, .stopFailure].contains(name)
                ? (payload["prompt_id"] as? String).flatMap { AgentText.clean($0, maxLength: 80) }
                : nil
            reviewHeader = name == .userPromptSubmit
                ? (payload["prompt"] as? String).flatMap(BranchReview.agentMessageHeader(in:))
                : nil
            finalMessage = name == .stop && agentID == nil && !TurnEndText.usesOtherAccount(env) && !TurnEndText.isHeadless(env)
                ? (payload["last_assistant_message"] as? String).flatMap { TurnEndText.excerpt($0) }
                : nil
            stopHookActive = name == .stop ? payload["stop_hook_active"] as? Bool : nil
            reviewPasses = switch name {
            case .userPromptSubmit:
                (payload["prompt"] as? String).flatMap(ReviewPass.passes(inPrompt:))?.map(\.rawValue)
            // A Skill call that failed (PostToolUseFailure) ran nothing.
            case .postToolUse where toolName == "Skill" && hookName == "PostToolUse":
                ((payload["tool_input"] as? [String: Any])?["skill"] as? String)
                    .flatMap(ReviewPass.passes(inSkill:))?.map(\.rawValue)
            default:
                nil
            }
            switch name {
            case .notification:
                detail = (payload["message"] as? String).flatMap { AgentText.clean($0, maxLength: 300) }
            case .stopFailure:
                // The error as the terminal showed it.
                detail = ((payload["error_details"] as? String) ?? (payload["last_assistant_message"] as? String))
                    .flatMap { AgentText.clean($0, maxLength: 300) }
            default:
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
            toolEnd = nil
            toolFamily = nil
            toolCommandKey = nil
            agentID = nil
            notificationType = nil
            errorKind = nil
            promptID = nil
            transcriptPath = nil
            reviewPasses = nil
            reviewHeader = nil
            finalMessage = nil
            stopHookActive = nil
        }
    }

    /// The main-thread SessionStart and Stop, where the receiver says which
    /// account the agent runs on (`onNiruxAccount`): a `claude` started
    /// before Nirux, which sends no SessionStart, says so at its first turn
    /// end. Not UserPromptSubmit: Claude waits for that hook before it goes
    /// on, and the check reads several files.
    var reportsAccount: Bool {
        kind == .claude && agentID == nil && [.sessionStart, .stop].contains(name)
    }

    /// What only the receiver can tell, from the agent's environment: on
    /// the events that report it, whether the agent runs on the login
    /// Nirux's own `claude -p` uses; and the final message kept only for
    /// such an agent, and a running Nirux that reads final messages.
    mutating func applyAccount(
        environment: [String: String], markers directory: URL = TurnEndMarker.directory,
        running: (pid_t) -> ProcessInstance? = ProcessInstance.running(pid:),
        read: (String) -> Data? = { FileManager.default.contents(atPath: $0) }
    ) {
        if reportsAccount {
            onNiruxAccount = TurnEndText.agentOnNiruxAccount(
                environment: environment, cwd: cwd, home: environment["HOME"] ?? NSHomeDirectory(),
                markers: directory, running: running, read: read
            )
        }
        if finalMessage != nil,
           onNiruxAccount != true || !TurnEndMarker.allowsMessage(environment: environment, in: directory, running: running) {
            finalMessage = nil
        }
    }

    /// Events that bind or confirm the column's session — where its
    /// transcript is worth knowing.
    static func carriesTranscriptPath(_ name: Name) -> Bool {
        [.sessionStart, .userPromptSubmit, .stop, .stopFailure].contains(name)
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
        case "StopFailure": return .stopFailure
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
        toolEnd: String? = nil,
        toolFamily: String? = nil,
        toolCommandKey: String? = nil,
        agentID: String? = nil,
        notificationType: String? = nil,
        errorKind: String? = nil,
        promptID: String? = nil,
        transcriptPath: String? = nil,
        reviewPasses: [String]? = nil,
        reviewHeader: String? = nil,
        finalMessage: String? = nil,
        stopHookActive: Bool? = nil,
        onNiruxAccount: Bool? = nil,
        approvalRequestID: String? = nil,
        approvalDeadline: TimeInterval? = nil,
        approvalText: String? = nil,
        approvalOutcome: PermissionApproval.Outcome? = nil,
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
        self.toolEnd = toolEnd
        self.toolFamily = toolFamily
        self.toolCommandKey = toolCommandKey
        self.agentID = agentID
        self.notificationType = notificationType
        self.errorKind = errorKind
        self.promptID = promptID
        self.transcriptPath = transcriptPath
        self.reviewPasses = reviewPasses
        self.reviewHeader = reviewHeader
        self.finalMessage = finalMessage
        self.stopHookActive = stopHookActive
        self.onNiruxAccount = onNiruxAccount
        self.approvalRequestID = approvalRequestID
        self.approvalDeadline = approvalDeadline
        self.approvalText = approvalText
        self.approvalOutcome = approvalOutcome
        self.timestamp = timestamp
    }

    /// The receiver's report on the sidebar approval of `request`.
    static func approvalResolved(
        _ request: AgentHookEvent,
        outcome: PermissionApproval.Outcome,
        now: TimeInterval
    ) -> AgentHookEvent {
        AgentHookEvent(
            kind: request.kind,
            name: .approvalResolved,
            agentUUID: request.agentUUID,
            workspaceID: request.workspaceID,
            sessionID: request.sessionID,
            emitterProcess: request.emitterProcess,
            cwd: request.cwd,
            detail: request.toolName,
            toolName: request.toolName,
            agentID: request.agentID,
            approvalRequestID: request.approvalRequestID,
            approvalOutcome: outcome,
            timestamp: now
        )
    }
}

/// Entry point for `Nirux --hook claude|codex [payload-json]` — the command
/// registered in ~/.claude/settings.json hooks and ~/.codex/config.toml
/// `notify`. Reads the payload, appends one JSON line to the events file,
/// exits. Must be fast and must NEVER fail loudly: a non-zero exit from a
/// sync hook surfaces inside the agent's UI.
enum AgentHookCLI {
    static func run(kind: AgentHookEvent.Kind, payload: String?) -> Int32 {
        // Claude runs each hook under a shell it kills when it gives up on
        // the hook (an interrupted turn): this process is then reparented.
        // Read first, before anything slow.
        let parent = getppid()
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
        let now = Date().timeIntervalSince1970
        guard var event = AgentHookEvent(
            kind: kind,
            payload: raw,
            env: env,
            now: now,
            emitterProcess: emitterProcess
        ) else { return 0 }
        event.applyAccount(environment: env)

        let channel = PermissionApprovalChannel.standard
        // The watch comes before the request shows in the queue: from then
        // on the app holds it, and Claude giving up on the hook must still
        // be reported. Without a watch the request isn't held.
        guard event.name == .permissionRequest, parent > 1,
              let wait = PermissionApprovalWait.prepare(payload: raw, env: env, now: now, isAppListening: {
                  channel.isAppListening()
              }),
              let termination = TerminationWatch()
        else {
            append(event)
            return 0
        }
        defer { termination.stop() }
        event.approvalRequestID = wait.requestID
        event.approvalDeadline = wait.deadline
        event.approvalText = wait.text
        append(event)

        let outcome = waitForDecision(wait, on: channel, parent: parent, terminated: termination.terminated)
        // Reported before the decision reaches Claude, so it precedes the
        // events the decision causes (PostToolUse) in the queue.
        append(.approvalResolved(event, outcome: outcome, now: Date().timeIntervalSince1970))
        let behavior: PermissionApproval.Behavior? = switch outcome {
        case .allow: .allow
        case .deny: .deny
        case .release, .expired, .invalid: nil
        }
        if let behavior, let output = PermissionApproval.hookOutput(for: behavior) {
            try? FileHandle.standardOutput.write(contentsOf: output)
        }
        return 0
    }

    /// Waits on a monotonic clock, so a wall-clock step never stretches
    /// the wait; stops early once Claude abandons the hook (see
    /// `TerminationWatch`) or the app that would answer is gone (checked
    /// about once a second).
    private static func waitForDecision(
        _ wait: PermissionApprovalWait,
        on channel: PermissionApprovalChannel,
        parent: pid_t,
        terminated: SignalFlag
    ) -> PermissionApproval.Outcome {
        let start = clock_gettime_nsec_np(CLOCK_MONOTONIC)
        var checks = 0
        return wait.waitForDecision(
            on: channel,
            now: { wait.startedAt + Double(clock_gettime_nsec_np(CLOCK_MONOTONIC) - start) / 1e9 },
            sleep: { Thread.sleep(forTimeInterval: $0) },
            isAbandoned: {
                checks += 1
                if terminated.isRaised || getppid() != parent { return true }
                return checks % 10 == 0 && !channel.isAppListening()
            }
        )
    }

    /// Claude abandons a hook with SIGTERM (then SIGKILL): caught, so the
    /// report still goes out and the app drops the request at once.
    private struct TerminationWatch {
        let terminated = SignalFlag()
        private let source: DispatchSourceSignal

        /// SIGTERM is ignored only once the source that sees it is
        /// registered: ignored any earlier, one could be lost, and the
        /// request held for a Claude that gave up. Until then it ends the
        /// process, with nothing queued. Nil if the source doesn't register
        /// in time (it takes microseconds; nothing here may hang the hook).
        init?() {
            source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .global())
            let registered = DispatchSemaphore(value: 0)
            source.setRegistrationHandler { registered.signal() }
            source.setEventHandler { [terminated] in terminated.raise() }
            source.resume()
            guard registered.wait(timeout: .now() + 1) == .success else {
                source.cancel()
                return nil
            }
            signal(SIGTERM, SIG_IGN)
        }

        func stop() {
            source.cancel()
        }
    }

    /// Set from a signal handler's queue, read by the waiting loop.
    private final class SignalFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var raised = false

        func raise() {
            lock.lock()
            raised = true
            lock.unlock()
        }

        var isRaised: Bool {
            lock.lock()
            defer { lock.unlock() }
            return raised
        }
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

    /// Append one JSON line in one `write`. O_APPEND keeps concurrent
    /// writers (several agents across columns) from interleaving mid-line:
    /// the file system serializes writes to one file (PIPE_BUF bounds
    /// pipes, not files). Lines are small, a Stop's final message excerpt
    /// (`TurnEndText.excerpt`, 3,000 characters) the largest.
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
