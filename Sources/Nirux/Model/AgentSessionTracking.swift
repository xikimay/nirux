import CryptoKit
import Foundation

/// Binds an agent conversation ID to the exact process instance running it,
/// so a persisted ID never outlives the process that proved it: a replaced
/// or exited agent drops its binding instead of lending its ID to the next
/// one. Shared core of the Codex, Antigravity and Claude trackers.
struct AgentSessionBinding {
    private struct Binding: Equatable {
        let sessionID: String
        let process: ProcessInstance
    }

    let agent: CodingAgent

    private var binding: Binding?
    private var pendingResumeSessionID: String?

    init(agent: CodingAgent) {
        self.agent = agent
    }

    /// The session id a restore launch passes (`<resumeArgument> <id>`).
    func launchedSessionID(_ arguments: [String]) -> String? {
        if agent == .agy {
            return AgyLaunch.resumedConversation(in: arguments)
        }
        return agent.resumeArgument.flatMap(arguments.firstIndex(of:)).flatMap { arguments[safe: $0 + 1] }
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
        guard let foregroundProcess, foregroundProcess.agent == agent else {
            binding = nil
            pendingResumeSessionID = nil
            return nil
        }
        if binding?.process == foregroundProcess.instance {
            return binding?.sessionID
        }
        binding = nil
        guard let pendingResumeSessionID else { return nil }
        guard launchedSessionID(foregroundProcess.arguments) == pendingResumeSessionID else {
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

/// Which session a column's foreground agent runs, bound from its hooks:
/// Codex's thread, Antigravity's conversation.
struct ForegroundSessionTracker {
    private var session: AgentSessionBinding
    /// agy: a process's conversation is the one it was launched on, else the
    /// first it reports (its subagents report theirs from the same process,
    /// with nothing to tell them apart), and it stays while another process
    /// holds the terminal (Ctrl-Z).
    private let keepsProcessSession: Bool
    /// Codex: its notify also reports the threads it runs out of sight, such
    /// as the one that titles a new conversation (seen on codex 0.167). A
    /// thread is proven once its only message is the prompt that `codex`
    /// was launched with (a fork, `/side` or a forked sub-agent, holds the
    /// forked ones too), or once `codex resume <id>` named it: the first
    /// proof stands, no other thread replaces it, and with a launch prompt
    /// none binds before it.
    private let provesThread: Bool
    /// The thread its launch prompt started, and that `codex`.
    private var launched: (sessionID: String, process: ProcessInstance)?
    /// agy: subagent conversations that emitted `SessionStart` after this
    /// process already owned a conversation (or was launched with `--continue`),
    /// so their later `Stop` hooks never hijack the main conversation.
    private var startedSubagents: (process: ProcessInstance, ids: Set<String>)?

    static var codex: Self { Self(agent: .codex, provesThread: true) }
    static var agy: Self { Self(agent: .agy, keepsProcessSession: true) }

    init(agent: CodingAgent, keepsProcessSession: Bool = false, provesThread: Bool = false) {
        session = AgentSessionBinding(agent: agent)
        self.keepsProcessSession = keepsProcessSession
        self.provesThread = provesThread
    }

    mutating func prepareResume(sessionID: String) {
        session.prepareResume(sessionID: sessionID)
    }

    /// Binds `sessionID` to `process` when no conversation is bound to it yet
    /// (for example a manual `agy --conversation <uuid>` launch).
    mutating func bindIfUnbound(sessionID: String, process: ProcessInstance) {
        guard session.sessionID(boundTo: process) == nil else { return }
        _ = session.bind(sessionID: sessionID, process: process)
    }

    /// `soleInputDigest`: `CodexLaunch.promptDigest` of the thread's message,
    /// when it holds one.
    @discardableResult
    mutating func capture(
        sessionID: String?,
        eventName: AgentHookEvent.Name = .sessionStart,
        soleInputDigest: String? = nil,
        emitterBelongsToForegroundJob: Bool,
        foregroundProcess: ForegroundProcess?
    ) -> Bool {
        guard let sessionID, !sessionID.isEmpty,
              let foregroundProcess, foregroundProcess.agent == session.agent,
              emitterBelongsToForegroundJob else {
            return false
        }
        if provesThread {
            let prompt = CodexLaunch.prompt(of: foregroundProcess)
            if launched?.process != foregroundProcess.instance, let soleInputDigest, soleInputDigest == prompt.map(CodexLaunch.promptDigest) {
                launched = (sessionID, foregroundProcess.instance)
            }
            // The title's thread may end its turn first.
            guard provenSessionID(for: foregroundProcess).map({ $0 == sessionID }) ?? (prompt == nil) else { return false }
        }
        guard keepsProcessSession else { return session.bind(sessionID: sessionID, process: foregroundProcess.instance) }
        return captureAgy(sessionID: sessionID, eventName: eventName, foregroundProcess: foregroundProcess)
    }

    private mutating func captureAgy(
        sessionID: String,
        eventName: AgentHookEvent.Name,
        foregroundProcess: ForegroundProcess
    ) -> Bool {
        let process = foregroundProcess.instance
        if startedSubagents?.process != process {
            startedSubagents = nil
        }
        if eventName == .stop {
            guard startedSubagents?.ids.contains(sessionID) != true else { return false }
            return session.bind(sessionID: sessionID, process: process)
        }
        if let bound = session.sessionID(boundTo: process) {
            if sessionID != bound { noteStartedSubagent(sessionID, for: process) }
            return false
        }
        if let launched = session.launchedSessionID(foregroundProcess.arguments) {
            if sessionID != launched { noteStartedSubagent(sessionID, for: process) }
            return session.bind(sessionID: launched, process: process)
        }
        if AgyLaunch.hasContinueFlag(foregroundProcess.arguments) {
            // A continued conversation never fires SessionStart; one that fires
            // before Stop belongs to a subagent.
            noteStartedSubagent(sessionID, for: process)
            return false
        }
        return session.bind(sessionID: sessionID, process: process)
    }

    private mutating func noteStartedSubagent(_ sessionID: String, for process: ProcessInstance) {
        if startedSubagents?.process == process {
            startedSubagents?.ids.insert(sessionID)
        } else {
            startedSubagents = (process, [sessionID])
        }
    }

    /// The thread `process`, a `codex`, proved it runs, if it did.
    func provenSessionID(for process: ForegroundProcess) -> String? {
        if let launched, launched.process == process.instance { return launched.sessionID }
        return CodexLaunch.resumedThread(of: process)
    }

    mutating func sessionID(for foregroundProcess: ForegroundProcess?) -> String? {
        if keepsProcessSession, foregroundProcess?.agent != session.agent { return nil }
        return session.sessionID(for: foregroundProcess)
    }

    /// Session bound to this process, if any.
    func boundSessionID(for process: ProcessInstance) -> String? {
        session.sessionID(boundTo: process)
    }

    @discardableResult
    mutating func invalidateBinding(ifProcessChangedTo foregroundProcess: ForegroundProcess?) -> Bool {
        if keepsProcessSession, foregroundProcess?.agent != session.agent { return false }
        let changed = session.invalidateBinding(ifProcessChangedTo: foregroundProcess)
        if changed, let foregroundProcess, startedSubagents?.process != foregroundProcess.instance {
            startedSubagents = nil
        }
        return changed
    }
}

/// What an `agy` process's arguments say of the conversation it runs.
enum AgyLaunch {
    /// Options whose value is the next argument (`agy --help`).
    static let optionsWithValue: Set<String> = [
        "-i", "--prompt-interactive", "-p", "--print", "--prompt", "--settings", "--conversation", "--model",
        "--mode", "--add-dir", "--agent", "--effort", "--project", "--input-format", "--output-format",
        "--json-schema", "--log-file", "--print-timeout"
    ]

    /// The conversation `agy --conversation <id>` (or `=<id>`) resumes.
    static func resumedConversation(in arguments: [String]) -> String? {
        var args = arguments.makeIterator()
        while let argument = args.next(), argument != "--" {
            if argument == "--conversation" {
                return args.next().flatMap { $0.isEmpty ? nil : $0 }
            }
            if argument.hasPrefix("--conversation=") {
                let value = String(argument.dropFirst("--conversation=".count))
                return value.isEmpty ? nil : value
            }
            if optionsWithValue.contains(argument) { _ = args.next() }
        }
        return nil
    }

    /// Whether `arguments` includes `--continue`, or `-c` when not taking a
    /// shell script argument (such as `exec -a agy /bin/sh -c '...'`).
    static func hasContinueFlag(_ arguments: [String]) -> Bool {
        var index = arguments.startIndex
        while index < arguments.endIndex {
            let argument = arguments[index]
            if argument == "--" { return false }
            if argument == "--continue" { return true }
            if argument == "-c" {
                let next = arguments[safe: index + 1]
                if next == nil || next?.hasPrefix("-") == true { return true }
            }
            index += optionsWithValue.contains(argument) ? 2 : 1
        }
        return false
    }
}

/// What a `codex` process's arguments say of the thread it runs.
enum CodexLaunch {
    /// Whether `process` can prove a thread: it was launched with a prompt,
    /// or resumed one. A `codex` started without either never does.
    static func canProve(_ process: ForegroundProcess) -> Bool {
        prompt(of: process) != nil || resumedThread(of: process) != nil
    }

    /// The thread `codex resume <id>` named.
    static func resumedThread(of process: ForegroundProcess) -> String? {
        guard let index = process.arguments.firstIndex(of: "resume"), process.arguments.indices.contains(index + 1),
              !process.arguments[index + 1].hasPrefix("-") else { return nil }
        return process.arguments[index + 1]
    }

    /// The prompt `process` was launched with: its last argument, as
    /// Nirux's launch line ends, when it follows the program (`codex`, or a
    /// runtime's script), is no option nor an option's value, and no
    /// subcommand (`resume`, `fork`…) comes first.
    static func prompt(of process: ForegroundProcess) -> String? {
        let arguments = process.arguments
        let program = arguments.firstIndex { (($0 as NSString).lastPathComponent as NSString).deletingPathExtension == "codex" } ?? 0
        guard arguments.count > program + 1, let last = arguments.last, !last.hasPrefix("-"),
              arguments.count - 2 == program || !CodingAgent.codexOptionsWithValue.contains(arguments[arguments.count - 2])
        else { return nil }
        var index = program + 1
        while index < arguments.count - 1, arguments[index].hasPrefix("-") {
            index += CodingAgent.codexOptionsWithValue.contains(arguments[index]) ? 2 : 1
        }
        return subcommands.contains(arguments[index]) ? nil : last
    }

    /// Codex 0.167's subcommands (`codex --help`).
    private static let subcommands: Set<String> = [
        "agents", "exec", "e", "review", "login", "logout", "mcp", "plugin", "app-server", "remote-control", "app", "completion",
        "update", "doctor", "sandbox", "debug", "apply", "a", "resume", "queue", "archive", "delete", "migrate-rollouts",
        "migrate-nfs-db", "unarchive", "fork", "cloud", "exec-server", "features", "help"
    ]

    /// SHA-256 of `prompt`, in hex: what an event keeps of a prompt.
    static func promptDigest(_ prompt: String) -> String {
        SHA256.hash(data: Data(prompt.utf8)).map { String(format: "%02x", $0) }.joined()
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
    /// Where the process that fired a hook sits in the column's terminal.
    enum Emitter: Equatable {
        /// Not reported: an older Nirux build is still the hook command.
        case unknown
        /// The terminal's foreground process itself.
        case foregroundProcess
        /// A direct child of the foreground process, in its job: the real
        /// `claude` under a launcher that spawns instead of exec'ing (a
        /// Volta shim) — as long as the launcher never fires hooks itself.
        case foregroundChild
        /// Another member of the foreground job (an MCP server's `claude`).
        case foregroundJob
        /// Outside the foreground job: the Bash tool's detached process
        /// groups, or a process that already exited.
        case elsewhere

        static func placing(
            _ process: ProcessInstance?,
            foreground: ForegroundProcess?,
            shellPID: pid_t,
            snapshot: ProcessSnapshot
        ) -> Emitter {
            guard let process else { return .unknown }
            if process == foreground?.instance { return .foregroundProcess }
            guard shellPID > 0, snapshot.isProcess(process, inForegroundProcessGroupOf: shellPID) else {
                return .elsewhere
            }
            let isChild = foreground.map { snapshot.isProcess(process, childOf: $0.instance.pid) } ?? false
            return isChild ? .foregroundChild : .foregroundJob
        }
    }

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

    private var session = AgentSessionBinding(agent: .claude)
    /// Bound session known to have no conversation yet. Decided from hook
    /// evidence, not the transcript file: Claude writes that lazily, and a
    /// session resumed from another directory reports a path that doesn't
    /// exist yet.
    private var unpromptedSessionID: String?
    /// Bound session the column's `claude` confirmed through a hook. From
    /// then on, another member of its job reporting a different session is
    /// nested (an MCP server running `claude -p`).
    private var confirmedSessionID: String?
    /// Foreground process seen firing hooks itself: its children are then
    /// ordinary job members, not a launcher's real `claude`.
    private var hookFiringForeground: ProcessInstance?

    mutating func prepareResume(sessionID: String) {
        session.prepareResume(sessionID: sessionID)
    }

    mutating func admit(
        _ name: AgentHookEvent.Name,
        sessionID: String?,
        source: String?,
        emitter: Emitter,
        foregroundProcess: ForegroundProcess?
    ) -> Admission {
        // No agent in the foreground: this is the column's own finished run
        // (a quick top-level `claude -p`) or a replay queued while Nirux was
        // closed. Route it as before; there is no live process to bind.
        guard let foregroundProcess, let agent = foregroundProcess.agent else { return .accepted }
        // A Claude hook under another agent's column (Codex, Gemini…) comes
        // from a `claude` that agent ran.
        guard agent == .claude else { return .rejected }
        let sessionID = sessionID.flatMap { $0.isEmpty ? nil : $0 }
        let boundSessionID = session.sessionID(boundTo: foregroundProcess.instance)
        if let admission = admitUnproven(
            emitter, sessionID: sessionID, boundSessionID: boundSessionID, foreground: foregroundProcess.instance
        ) {
            return admission
        }
        guard let sessionID else { return .accepted }
        if sessionID == boundSessionID {
            confirmedSessionID = sessionID
            let isPrompted = [.userPromptSubmit, .stop, .stopFailure, .preToolUse, .permissionRequest, .postToolUse, .permissionDenied]
                .contains(name)
                || (name == .sessionStart && source == "compact")
            guard isPrompted, unpromptedSessionID == sessionID else { return .accepted }
            unpromptedSessionID = nil
            return .restoreChanged
        }
        // The foreground `claude` reports another conversation. /clear,
        // /resume and /branch switch through SessionStart. Turn events only
        // adopt a column that is unbound or was never prompted: otherwise a
        // different ID there may be an in-process teammate's. Tool events may
        // come from a subagent. A SessionEnd is the straggler of the session
        // just left.
        switch name {
        case .sessionStart:
            break
        case .userPromptSubmit, .notification, .stop:
            guard boundSessionID == nil || boundSessionID == unpromptedSessionID else { return .accepted }
        case .stopFailure:
            // Another conversation's failure (a teammate's, one left by
            // /clear) must not stop this one's turn or offer Resume here.
            return boundSessionID == nil ? .accepted : .rejected
        case .sessionEnd:
            return boundSessionID == nil ? .accepted : .rejected
        case .preToolUse, .permissionRequest, .postToolUse, .permissionDenied, .subagentStop, .turnComplete, .approvalResolved:
            return .accepted
        }
        let changed = session.bind(sessionID: sessionID, process: foregroundProcess.instance)
        confirmedSessionID = sessionID
        unpromptedSessionID = name == .sessionStart && (source == "startup" || source == "clear")
            ? sessionID
            : nil
        return changed ? .restoreChanged : .accepted
    }

    /// Nil when the emitter is the column's `claude` itself, which may
    /// bind; otherwise the admission for an emitter that cannot.
    private mutating func admitUnproven(
        _ emitter: Emitter,
        sessionID: String?,
        boundSessionID: String?,
        foreground: ProcessInstance
    ) -> Admission? {
        switch emitter {
        case .foregroundProcess:
            hookFiringForeground = foreground
            return nil
        case .foregroundChild where hookFiringForeground != foreground:
            // A child firing before the foreground `claude`'s own first hook
            // (a `claude mcp serve` racing its SessionStart) may bind
            // briefly; the parent's SessionStart rebinds.
            return nil
        case .unknown:
            // Without emitter identity nothing is provable: route, never bind.
            return .accepted
        case .elsewhere:
            return .rejected
        case .foregroundChild, .foregroundJob:
            if let boundSessionID, boundSessionID == confirmedSessionID,
               let sessionID, sessionID != boundSessionID { return .rejected }
            return .accepted
        }
    }

    /// Session bound to this `claude` process, if any.
    func boundSessionID(for process: ProcessInstance) -> String? {
        session.sessionID(boundTo: process)
    }

    /// `process` fired hooks itself: it would send SessionEnd on a clean
    /// exit.
    func hasFiredHooks(_ process: ProcessInstance) -> Bool {
        hookFiringForeground == process
    }

    /// The conversation `process` confirmed through its own hooks — still
    /// known after it exited, when its binding is gone. Nil for a session
    /// never prompted: it has nothing to resume.
    func lastConfirmedSessionID(of process: ProcessInstance) -> String? {
        guard hookFiringForeground == process, let confirmedSessionID,
              confirmedSessionID != unpromptedSessionID else { return nil }
        return confirmedSessionID
    }

    /// The session whose permission requests the sidebar may answer: the
    /// one this foreground `claude` confirmed through its own hooks, when
    /// `emitter` is that `claude` (or the real one under a launcher). Never
    /// another member of its job, a nested run, or a teammate's session.
    func approvableSessionID(emitter: Emitter, foregroundProcess: ForegroundProcess) -> String? {
        switch emitter {
        case .foregroundProcess:
            break
        case .foregroundChild where hookFiringForeground != foregroundProcess.instance:
            break
        case .foregroundChild, .foregroundJob, .elsewhere, .unknown:
            return nil
        }
        return confirmedSessionID(of: foregroundProcess)
    }

    /// The session bound to this foreground `claude`, once confirmed by one
    /// of its hooks — not merely restored from its launch arguments.
    func confirmedSessionID(of foregroundProcess: ForegroundProcess) -> String? {
        guard foregroundProcess.agent == session.agent,
              let bound = session.sessionID(boundTo: foregroundProcess.instance),
              bound == confirmedSessionID else { return nil }
        return bound
    }

    /// Nil when no session is bound to this foreground process — restore
    /// then asks through the picker.
    mutating func restore(for foregroundProcess: ForegroundProcess?) -> Restore? {
        guard let sessionID = session.sessionID(for: foregroundProcess) else { return nil }
        return sessionID == unpromptedSessionID ? .fresh : .resume(sessionID)
    }

    /// Only another `claude` replaces the binding: a shell in the foreground
    /// may just mean this one is suspended (Ctrl-Z), and saves never ask for
    /// a Claude session while no `claude` is in the foreground.
    @discardableResult
    mutating func invalidateBinding(ifProcessChangedTo foregroundProcess: ForegroundProcess?) -> Bool {
        guard foregroundProcess?.agent == session.agent else { return false }
        return session.invalidateBinding(ifProcessChangedTo: foregroundProcess)
    }
}

extension ProcessInstance {
    /// The agent process that fired the hook this receiver serves. Codex
    /// runs `notify` directly. Claude runs each hook under a detached
    /// `sh -c`, so its emitter is the first ancestor that is not a shell —
    /// found by position rather than by name, so a nested Claude whose argv
    /// doesn't read `claude` (an Agent SDK `node cli.js`) is still told
    /// apart from the column's own.
    static func hookEmitter(for agent: CodingAgent) -> ProcessInstance? {
        switch agent {
        case .codex: return running(pid: getppid())
        case .claude, .agy, .gemini, .opencode: return firstNonShellAncestor(from: getppid())
        }
    }

    /// `pid` itself when it is not a shell. Nil once the walk reaches
    /// launchd — an orphaned hook shell whose emitter already exited.
    static func firstNonShellAncestor(from pid: pid_t, maxDepth: Int = 8) -> ProcessInstance? {
        var current = pid
        for _ in 0..<maxDepth {
            guard current > 1, let entry = kernelEntry(pid: current) else { return nil }
            let name = ProcessSnapshot.execName(from: ProcessSnapshot.arguments(of: current, maxArgs: 2))
                ?? entry.name
            if !Shell.isShell(name) { return entry.instance }
            current = entry.parentPID
        }
        return nil
    }

    /// One process's identity, parent and `p_comm` from the kernel.
    static func kernelEntry(pid: pid_t) -> (instance: ProcessInstance, parentPID: pid_t, name: String)? {
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
