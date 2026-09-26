import Foundation

/// Binds an agent conversation ID to the exact process instance running it,
/// so a persisted ID never outlives the process that proved it: a replaced
/// or exited agent drops its binding instead of lending its ID to the next
/// one. Shared core of the Codex and Claude trackers.
struct AgentSessionBinding {
    private struct Binding: Equatable {
        let sessionID: String
        let process: ProcessInstance
    }

    /// Foreground process name of the agent (`codex`, `claude`).
    let processName: String
    /// Argument preceding the session ID in a restore launch
    /// (`codex resume <id>`, `claude --resume <id>`).
    let resumeArgument: String

    private var binding: Binding?
    private var pendingResumeSessionID: String?

    init(processName: String, resumeArgument: String) {
        self.processName = processName
        self.resumeArgument = resumeArgument
    }

    /// Session bound to `process`, nil when none is or another process owns it.
    func sessionID(boundTo process: ProcessInstance) -> String? {
        binding?.process == process ? binding?.sessionID : nil
    }

    mutating func prepareResume(sessionID: String) {
        binding = nil
        pendingResumeSessionID = sessionID
    }

    /// Returns true when the binding changed and should be persisted.
    @discardableResult
    mutating func bind(sessionID: String, process: ProcessInstance) -> Bool {
        let next = Binding(sessionID: sessionID, process: process)
        guard binding != next || pendingResumeSessionID != nil else { return false }
        binding = next
        pendingResumeSessionID = nil
        return true
    }

    /// The ID to persist for this foreground process. A restored column that
    /// has not emitted its first event yet is proved by its launch arguments
    /// (`<resumeArgument> <pending id>`) instead.
    mutating func sessionID(for foregroundProcess: ForegroundProcess?) -> String? {
        _ = invalidateBinding(ifProcessChangedTo: foregroundProcess)
        guard let foregroundProcess, foregroundProcess.name == processName else {
            binding = nil
            pendingResumeSessionID = nil
            return nil
        }
        if binding?.process == foregroundProcess.instance {
            return binding?.sessionID
        }
        binding = nil
        guard let pendingResumeSessionID else { return nil }
        guard let resumeIndex = foregroundProcess.arguments.firstIndex(of: resumeArgument),
              foregroundProcess.arguments.indices.contains(resumeIndex + 1),
              foregroundProcess.arguments[resumeIndex + 1] == pendingResumeSessionID else {
            if !foregroundProcess.arguments.isEmpty {
                self.pendingResumeSessionID = nil
            }
            return nil
        }
        binding = Binding(
            sessionID: pendingResumeSessionID,
            process: foregroundProcess.instance
        )
        self.pendingResumeSessionID = nil
        return pendingResumeSessionID
    }

    @discardableResult
    mutating func invalidateBinding(ifProcessChangedTo foregroundProcess: ForegroundProcess?) -> Bool {
        guard let binding, let foregroundProcess,
              binding.process != foregroundProcess.instance else { return false }
        self.binding = nil
        return true
    }
}

struct CodexSessionTracker {
    private var session = AgentSessionBinding(processName: "codex", resumeArgument: "resume")

    mutating func prepareResume(sessionID: String) {
        session.prepareResume(sessionID: sessionID)
    }

    @discardableResult
    mutating func capture(
        sessionID: String?,
        emitterBelongsToForegroundJob: Bool,
        foregroundProcess: ForegroundProcess?
    ) -> Bool {
        guard let sessionID, !sessionID.isEmpty,
              let foregroundProcess, foregroundProcess.name == session.processName,
              emitterBelongsToForegroundJob else {
            return false
        }
        return session.bind(sessionID: sessionID, process: foregroundProcess.instance)
    }

    mutating func sessionID(for foregroundProcess: ForegroundProcess?) -> String? {
        session.sessionID(for: foregroundProcess)
    }

    @discardableResult
    mutating func invalidateBinding(ifProcessChangedTo foregroundProcess: ForegroundProcess?) -> Bool {
        session.invalidateBinding(ifProcessChangedTo: foregroundProcess)
    }
}

/// Which Claude conversation a column's foreground `claude` runs, and which
/// hook events belong to it.
///
/// Every process started from a column inherits its NIRUX_AGENT_UUID, so a
/// `claude -p` launched by the column's agent (Bash tool, scripts, review
/// pipelines) reports hooks under the same UUID with its own session_id.
/// The receiver records the process that fired each hook (see
/// `ProcessInstance.hookEmitter`); only the column's foreground `claude`
/// may bind its session, and nothing outside the terminal's foreground job
/// — the Bash tool runs commands in detached process groups — may drive
/// the column.
struct ClaudeSessionTracker {
    enum Admission: Equatable {
        /// Another Claude process under this column (a nested `claude -p`,
        /// or a session the foreground `claude` already left). Must not
        /// touch the column's status, activity or notifications.
        case rejected
        /// The column's agent — route it.
        case accepted
        /// Accepted, and what restore would do changed (another session,
        /// or its first prompt): persist it.
        case restoreChanged
    }

    /// How a restore brings the column's Claude back.
    enum Restore: Equatable {
        case resume(String)
        /// The bound session was never prompted (a fresh start or /clear):
        /// Claude has no conversation to resume, and `--resume` would fail.
        case fresh

        var sessionID: String? {
            if case .resume(let sessionID) = self { return sessionID }
            return nil
        }
    }

    private var session = AgentSessionBinding(processName: "claude", resumeArgument: "--resume")
    /// Bound session known to have no conversation yet. Decided from hook
    /// evidence, not the transcript file: Claude writes that lazily, and a
    /// session resumed from another directory reports a path that doesn't
    /// exist yet.
    private var unpromptedSessionID: String?
    /// Bound session the foreground `claude` itself confirmed through a
    /// hook. From then on, another member of its job reporting a different
    /// session is nested (an MCP server running `claude -p`).
    private var confirmedSessionID: String?

    mutating func prepareResume(sessionID: String) {
        session.prepareResume(sessionID: sessionID)
    }

    // swiftlint:disable:next function_parameter_count
    mutating func admit(
        _ name: AgentHookEvent.Name,
        sessionID: String?,
        source: String?,
        emitter: ProcessInstance?,
        emitterInForegroundJob: Bool,
        foregroundProcess: ForegroundProcess?
    ) -> Admission {
        // No agent in the foreground: this is the column's own finished run
        // (a quick top-level `claude -p`) or a replay queued while Nirux was
        // closed. Route it as before; there is no live process to bind.
        guard let foregroundProcess,
              AgentStatusMachine.isRecognizedAgentProcess(foregroundProcess.name) else { return .accepted }
        // A Claude hook under a Codex column comes from a `claude` Codex ran.
        guard foregroundProcess.name == "claude" else { return .rejected }
        let sessionID = sessionID.flatMap { $0.isEmpty ? nil : $0 }
        let boundSessionID = session.sessionID(boundTo: foregroundProcess.instance)
        guard emitter == foregroundProcess.instance else {
            // A receiver without emitter identity (an older Nirux build still
            // registered as the hook command) can't prove anything: route,
            // never bind. Outside the foreground job is nested. Another
            // member of the job (a launcher's child, an MCP server's
            // `claude`) routes unless it contradicts a confirmed session.
            guard let emitter else { return .accepted }
            guard emitterInForegroundJob else { return .rejected }
            if let boundSessionID, boundSessionID == confirmedSessionID,
               let sessionID, sessionID != boundSessionID { return .rejected }
            return .accepted
        }
        guard let sessionID else { return .accepted }
        if sessionID == boundSessionID {
            confirmedSessionID = sessionID
            let isPrompted = name == .userPromptSubmit || name == .stop || name == .preToolUse
                || (name == .sessionStart && source == "compact")
            guard isPrompted, unpromptedSessionID == sessionID else { return .accepted }
            unpromptedSessionID = nil
            return .restoreChanged
        }
        // The foreground `claude` reports another conversation. /clear,
        // /resume and /branch switch through SessionStart. Turn events only
        // adopt a column that is unbound or was never prompted: otherwise a
        // different ID there may be an in-process teammate's. PreToolUse may
        // come from a subagent. A SessionEnd is the straggler of the session
        // just left.
        switch name {
        case .sessionStart:
            break
        case .userPromptSubmit, .notification, .stop:
            guard boundSessionID == nil || boundSessionID == unpromptedSessionID else { return .accepted }
        case .sessionEnd:
            return boundSessionID == nil ? .accepted : .rejected
        case .preToolUse, .turnComplete:
            return .accepted
        }
        let changed = session.bind(sessionID: sessionID, process: foregroundProcess.instance)
        confirmedSessionID = sessionID
        unpromptedSessionID = name == .sessionStart && (source == "startup" || source == "clear")
            ? sessionID
            : nil
        return changed ? .restoreChanged : .accepted
    }

    /// Nil when no session is bound to this foreground process — restore
    /// then asks through the picker.
    mutating func restore(for foregroundProcess: ForegroundProcess?) -> Restore? {
        guard let sessionID = session.sessionID(for: foregroundProcess) else { return nil }
        return sessionID == unpromptedSessionID ? .fresh : .resume(sessionID)
    }

    @discardableResult
    mutating func invalidateBinding(ifProcessChangedTo foregroundProcess: ForegroundProcess?) -> Bool {
        session.invalidateBinding(ifProcessChangedTo: foregroundProcess)
    }
}

extension ProcessInstance {
    /// The agent process that fired the hook this receiver serves. Codex
    /// runs `notify` directly. Claude runs each hook under a detached
    /// `sh -c`, so its emitter is the first ancestor that is not a shell —
    /// found by position rather than by name, so a nested Claude whose argv
    /// doesn't read `claude` (an Agent SDK `node cli.js`) is still told
    /// apart from the column's own.
    static func hookEmitter(for kind: AgentHookEvent.Kind) -> ProcessInstance? {
        switch kind {
        case .codex: return running(pid: getppid())
        case .claude: return firstNonShellAncestor(from: getppid())
        }
    }

    private static let shellNames: Set<String> = ["sh", "bash", "zsh", "dash", "ksh", "mksh", "fish", "tcsh", "csh"]

    /// `pid` itself when it is not a shell. Nil once the walk reaches
    /// launchd — an orphaned hook shell whose emitter already exited.
    static func firstNonShellAncestor(from pid: pid_t, maxDepth: Int = 8) -> ProcessInstance? {
        var current = pid
        for _ in 0..<maxDepth {
            guard current > 1, let entry = kernelEntry(pid: current) else { return nil }
            let name = ProcessSnapshot.execName(from: ProcessSnapshot.arguments(of: current, maxArgs: 2))
                ?? entry.name
            let isShell = shellNames.contains(name.hasPrefix("-") ? String(name.dropFirst()) : name)
            if !isShell { return entry.instance }
            current = entry.parentPID
        }
        return nil
    }

    private static func kernelEntry(pid: pid_t) -> (instance: ProcessInstance, parentPID: pid_t, name: String)? {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var process = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.size
        guard sysctl(&mib, 4, &process, &size, nil, 0) == 0,
              size == MemoryLayout<kinfo_proc>.size,
              process.kp_proc.p_pid == pid else { return nil }
        let startTime = process.kp_proc.p_starttime
        let name = withUnsafePointer(to: &process.kp_proc.p_comm) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: Int(MAXCOMLEN)) {
                String(cString: $0)
            }
        }
        return (
            ProcessInstance(
                pid: pid,
                startedAt: TimeInterval(startTime.tv_sec)
                    + TimeInterval(startTime.tv_usec) / 1_000_000
            ),
            process.kp_eproc.e_ppid,
            name
        )
    }
}
