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
              let foregroundProcess, foregroundProcess.name == "codex",
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

/// Which Claude conversation a column's top-level `claude` runs, and which
/// hook events belong to it.
///
/// Every process started from a column inherits its NIRUX_AGENT_UUID, so a
/// `claude -p` launched by the column's agent (Bash tool, scripts, review
/// pipelines) reports hooks under the same UUID with its own session_id.
/// Hooks run as children of the `claude` that fired them; the receiver
/// records that nearest `claude` ancestor as `emitterProcess`, and only the
/// column's foreground `claude` may drive the column or bind its session.
struct ClaudeSessionTracker {
    enum Admission: Equatable {
        /// Another Claude process under this column (a nested `claude -p`,
        /// or a session the foreground `claude` already replaced). Must not
        /// touch the column's status, activity or notifications.
        case rejected
        /// The column's agent — route it.
        case accepted
        /// Accepted, and the column's bound session changed: persist it.
        case adopted
    }

    private var session = AgentSessionBinding(processName: "claude", resumeArgument: "--resume")

    mutating func prepareResume(sessionID: String) {
        session.prepareResume(sessionID: sessionID)
    }

    mutating func admit(
        _ name: AgentHookEvent.Name,
        sessionID: String?,
        emitter: ProcessInstance?,
        foregroundProcess: ForegroundProcess?
    ) -> Admission {
        // No `claude` in the foreground: a nested session cannot outlive its
        // parent, so this is the column's own finished run (a quick
        // top-level `claude -p`) or a replay queued while Nirux was closed.
        // Route it as before, but there is no live process to bind.
        guard let foregroundProcess, foregroundProcess.name == "claude" else { return .accepted }
        let sessionID = sessionID.flatMap { $0.isEmpty ? nil : $0 }
        let boundSessionID = session.sessionID(boundTo: foregroundProcess.instance)

        guard let emitter else {
            // Queued by a receiver predating emitter identity: ownership is
            // unprovable, so only drop what contradicts a verified binding.
            if let boundSessionID, let sessionID, sessionID != boundSessionID { return .rejected }
            return .accepted
        }
        guard emitter == foregroundProcess.instance else { return .rejected }
        guard let sessionID, sessionID != boundSessionID else { return .accepted }
        // The foreground `claude` reports another conversation. /clear,
        // /resume and /branch switch through SessionStart (and a hookless
        // start is recovered by its first prompt or turn end). A SessionEnd
        // is the straggler of the session it left, and PreToolUse may come
        // from an in-process subagent — neither may rebind.
        switch name {
        case .sessionEnd, .preToolUse, .turnComplete:
            return .accepted
        case .sessionStart, .userPromptSubmit, .notification, .stop:
            return session.bind(sessionID: sessionID, process: foregroundProcess.instance)
                ? .adopted
                : .accepted
        }
    }

    mutating func sessionID(for foregroundProcess: ForegroundProcess?) -> String? {
        session.sessionID(for: foregroundProcess)
    }

    @discardableResult
    mutating func invalidateBinding(ifProcessChangedTo foregroundProcess: ForegroundProcess?) -> Bool {
        session.invalidateBinding(ifProcessChangedTo: foregroundProcess)
    }
}

extension ProcessInstance {
    /// Nearest ancestor of `pid` (inclusive) whose executable is `name`,
    /// named the way the foreground-process scan names it. Claude runs
    /// each hook under a detached `sh -c` child, so the receiver's parent
    /// is a transient shell and the `claude` that fired the hook sits
    /// above it.
    static func nearestAncestor(named name: String, from pid: pid_t, maxDepth: Int = 8) -> ProcessInstance? {
        var current = pid
        for _ in 0..<maxDepth {
            guard current > 1, let entry = kernelEntry(pid: current) else { return nil }
            let arguments = ProcessSnapshot.arguments(of: current, maxArgs: 2)
            if (ProcessSnapshot.execName(from: arguments) ?? entry.name) == name {
                return entry.instance
            }
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
