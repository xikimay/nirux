import AppKit
import Foundation
import GhosttyTerminal

enum AgentStatus: Equatable, Hashable, Sendable {
    case idle, working, needsAttention
}

struct ProcessInstance: Codable, Equatable {
    let pid: pid_t
    let startedAt: TimeInterval

    static func running(pid: pid_t) -> ProcessInstance? {
        kernelEntry(pid: pid)?.instance
    }
}

struct ForegroundProcess: Equatable {
    let instance: ProcessInstance
    let name: String
    let arguments: [String]

    func hasFlag(_ flag: String) -> Bool {
        arguments.contains(flag)
    }

    func flagValue(_ flag: String) -> String? {
        guard let index = arguments.firstIndex(of: flag),
              arguments.indices.contains(index + 1) else { return nil }
        return arguments[index + 1]
    }
}

/// Single sysctl snapshot of the process table, shared across all terminals.
/// Create once per refresh cycle instead of one KERN_PROC_ALL per terminal.
final class ProcessSnapshot {
    struct Entry {
        let pid: pid_t
        let parentPID: pid_t
        let processGroupID: pid_t
        let terminalForegroundProcessGroupID: pid_t
        let name: String
        let startedAt: TimeInterval
        let arguments: [String]
    }

    private var childrenMap: [pid_t: [pid_t]] = [:]
    private var processGroupMap: [pid_t: [pid_t]] = [:]
    private var terminalForegroundProcessGroupMap: [pid_t: pid_t] = [:]
    private var commMap: [pid_t: String] = [:]
    private var instanceMap: [pid_t: ProcessInstance] = [:]
    private var capturedArguments: [pid_t: [String]]?

    init() {
        PollingDiagnostics.recordProcessTableScan()
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        var size: Int = 0
        guard sysctl(&mib, 4, nil, &size, nil, 0) == 0, size > 0 else { return }
        let count = size / MemoryLayout<kinfo_proc>.size
        var procs = [kinfo_proc](repeating: kinfo_proc(), count: count)
        guard sysctl(&mib, 4, &procs, &size, nil, 0) == 0 else { return }
        let actual = size / MemoryLayout<kinfo_proc>.size
        for i in 0..<actual {
            let pid = procs[i].kp_proc.p_pid
            let ppid = procs[i].kp_eproc.e_ppid
            let processGroupID = procs[i].kp_eproc.e_pgid
            let terminalForegroundProcessGroupID = procs[i].kp_eproc.e_tpgid
            let name = withUnsafePointer(to: &procs[i].kp_proc.p_comm) { ptr in
                ptr.withMemoryRebound(to: CChar.self, capacity: Int(MAXCOMLEN)) {
                    String(cString: $0)
                }
            }
            let startTime = procs[i].kp_proc.p_starttime
            add(Entry(
                pid: pid,
                parentPID: ppid,
                processGroupID: processGroupID,
                terminalForegroundProcessGroupID: terminalForegroundProcessGroupID,
                name: name,
                startedAt: TimeInterval(startTime.tv_sec)
                    + TimeInterval(startTime.tv_usec) / 1_000_000,
                arguments: []
            ))
        }
    }

    init(entries: [Entry]) {
        capturedArguments = Dictionary(uniqueKeysWithValues: entries.map { ($0.pid, $0.arguments) })
        for entry in entries {
            add(entry)
        }
    }

    private func add(_ entry: Entry) {
        childrenMap[entry.parentPID, default: []].append(entry.pid)
        processGroupMap[entry.processGroupID, default: []].append(entry.pid)
        terminalForegroundProcessGroupMap[entry.pid] = entry.terminalForegroundProcessGroupID
        commMap[entry.pid] = entry.name
        instanceMap[entry.pid] = ProcessInstance(pid: entry.pid, startedAt: entry.startedAt)
    }

    func foregroundProcess(shellPID: pid_t) -> ForegroundProcess? {
        let pid = foregroundPID(shellPID: shellPID)
        guard let instance = instanceMap[pid] else { return nil }
        let arguments: [String]
        if let capturedArguments {
            arguments = capturedArguments[pid] ?? []
        } else {
            arguments = Self.arguments(of: pid, maxArgs: 32)
        }
        guard let name = Self.execName(from: arguments) ?? commMap[pid] else { return nil }
        return ForegroundProcess(instance: instance, name: name, arguments: arguments)
    }

    /// `foregroundProcess(shellPID:)`'s process, without reading its
    /// arguments (a sysctl per call on a live snapshot).
    func foregroundInstance(shellPID: pid_t) -> ProcessInstance? {
        instanceMap[foregroundPID(shellPID: shellPID)]
    }

    private func foregroundPID(shellPID: pid_t) -> pid_t {
        let processGroupID = terminalForegroundProcessGroupMap[shellPID]
            .flatMap { $0 > 0 ? $0 : nil }
        let groupedPID: pid_t? = processGroupID.flatMap { groupID -> pid_t? in
            guard let members = processGroupMap[groupID], !members.isEmpty else { return nil }
            return members.first(where: { $0 == groupID })
                ?? members.first(where: { $0 != shellPID })
                ?? members.first
        }
        return groupedPID ?? childrenMap[shellPID]?.first ?? shellPID
    }

    /// This exact process (pid and start time) is still running.
    func contains(_ process: ProcessInstance) -> Bool {
        instanceMap[process.pid] == process
    }

    /// The process-table sysctl failed and captured nothing — a caller
    /// gating a destructive action must not read that as "no agent".
    var isEmpty: Bool { commMap.isEmpty }

    /// First process name among `rootPID`'s descendants (children,
    /// grandchildren, …) that `matches`. Unlike `foregroundProcess`, this
    /// also sees stopped (^Z) and background jobs and processes under a
    /// wrapper (npx, caffeinate) — everything that dies with the PTY.
    /// Breadth-first, so the shell's own jobs are checked before a big
    /// foreground build (make -j) can use up the `limit`.
    func firstDescendantName(of rootPID: pid_t, limit: Int = 256, where matches: (String) -> Bool) -> String? {
        var pending = childrenMap[rootPID] ?? []
        var visited = Set<pid_t>()
        var next = 0
        while next < pending.count, visited.count < limit {
            let pid = pending[next]
            next += 1
            guard visited.insert(pid).inserted else { continue }
            let arguments: [String]
            if let capturedArguments {
                arguments = capturedArguments[pid] ?? []
            } else {
                // Room for runtime flags before the script (`node
                // --no-warnings=… --max-old-space-size=… …/gemini`).
                arguments = Self.arguments(of: pid, maxArgs: 8)
            }
            if let name = Self.execName(from: arguments) ?? commMap[pid], matches(name) { return name }
            pending.append(contentsOf: childrenMap[pid] ?? [])
        }
        return nil
    }

    /// The arguments of `rootPID`'s descendants whose name is in `names`,
    /// breadth-first, like `firstDescendantName`.
    func descendantArguments(of rootPID: pid_t, named names: Set<String>, limit: Int = 256) -> [[String]] {
        var pending = childrenMap[rootPID] ?? []
        var visited = Set<pid_t>()
        var next = 0
        var found: [[String]] = []
        while next < pending.count, visited.count < limit {
            let pid = pending[next]
            next += 1
            guard visited.insert(pid).inserted else { continue }
            let arguments = capturedArguments.map { $0[pid] ?? [] } ?? Self.arguments(of: pid, maxArgs: 32)
            if let name = Self.execName(from: arguments) ?? commMap[pid], names.contains(name) { found.append(arguments) }
            pending.append(contentsOf: childrenMap[pid] ?? [])
        }
        return found
    }

    func isProcess(_ process: ProcessInstance, childOf parentPID: pid_t) -> Bool {
        instanceMap[process.pid] == process && childrenMap[parentPID]?.contains(process.pid) == true
    }

    func isProcess(
        _ process: ProcessInstance,
        inForegroundProcessGroupOf shellPID: pid_t
    ) -> Bool {
        guard instanceMap[process.pid] == process,
              let processGroupID = terminalForegroundProcessGroupMap[shellPID],
              processGroupID > 0 else { return false }
        return processGroupMap[processGroupID]?.contains(process.pid) == true
    }

    private static let runtimeBinaries: Set<String> = [
        "node", "python", "python3", "ruby", "perl", "java", "deno", "bun"
    ]

    static func execName(from argv: [String]) -> String? {
        guard let first = argv.first else { return nil }
        let name0 = (first as NSString).lastPathComponent
        // If argv[0] is a known runtime, try argv[1] for the real command name
        if runtimeBinaries.contains(name0), argv.count >= 2 {
            let arg1 = argv[1]
            if !arg1.hasPrefix("-") {
                let base = scriptName(arg1)
                if !base.isEmpty { return base }
            } else if let script = argv.dropFirst().first(where: { !isValuelessLongFlag($0) }),
                      !script.hasPrefix("-"), (script as NSString).pathExtension.isEmpty,
                      AgentStatusMachine.isRecognizedAgentProcess(scriptName(script)) {
                // Runtime flags before an agent's bin shim: Gemini CLI's
                // shebang (`env -S node --no-warnings=…`), its relaunched
                // child (`--max-old-space-size=…`), a shell alias
                // (`--no-deprecation`). Only flags that can't take a separate
                // value are skipped — after `-r`, `-m` or `--import` the next
                // argument is the flag's — and only an extensionless agent
                // name is trusted, so `node --env-file=.env codex.mjs` stays
                // `node`.
                return scriptName(script)
            }
        }
        return name0
    }

    private static func scriptName(_ argument: String) -> String {
        ((argument as NSString).lastPathComponent as NSString).deletingPathExtension
    }

    /// `--name=value`, or a `--no…` switch (`--no-deprecation`,
    /// `--noprofile`): carries its value, if any, inline.
    private static func isValuelessLongFlag(_ argument: String) -> Bool {
        argument.hasPrefix("--") && (argument.contains("=") || argument.hasPrefix("--no"))
    }

    /// Read up to maxArgs arguments from KERN_PROCARGS2
    static func arguments(of pid: pid_t, maxArgs: Int) -> [String] {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size: Int = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 0 else { return [] }
        var buf = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buf, &size, nil, 0) == 0 else { return [] }
        guard size > MemoryLayout<Int32>.size else { return [] }
        let argc = buf.withUnsafeBufferPointer {
            $0.baseAddress!.withMemoryRebound(to: Int32.self, capacity: 1) { $0.pointee }
        }
        // Skip exec path + null padding
        var i = MemoryLayout<Int32>.size
        while i < size && buf[i] != 0 { i += 1 }
        while i < size && buf[i] == 0 { i += 1 }
        // Read argv entries
        var args: [String] = []
        let limit = max(0, min(Int(argc), maxArgs))
        for _ in 0..<limit {
            guard i < size else { break }
            var end = i
            while end < size && buf[end] != 0 { end += 1 }
            guard end > i else { break }
            args.append(String(decoding: buf[i..<end], as: UTF8.self)) // swiftlint:disable:this optional_data_string_conversion
            i = end + 1
        }
        return args
    }
}

/// Bridges libghostty's InMemoryTerminalSession to a real PTY + shell.
/// The .inMemory backend correctly routes special keys (backspace, arrows)
/// via TerminalHardwareKeyRouter.directControlInputForAppKit.
final class PtySession: @unchecked Sendable {
    let terminalSession: InMemoryTerminalSession
    // Store fd in a sendable wrapper so closures can capture it
    private let state = PtyState()
    /// Called when the shell reports a new working directory (via OSC 7)
    var onCwdChanged: ((String) -> Void)? {
        get { state.onCwdChanged }
        set { state.onCwdChanged = newValue }
    }

    /// Called when the terminal title changes (via OSC 0/2)
    var onTitleChanged: ((String) -> Void)? {
        get { state.onTitleChanged }
        set { state.onTitleChanged = newValue }
    }

    /// Called when an OSC 9 notification is received AND this session has
    /// no hook coverage — hooked sessions get the same turn-complete signal
    /// from the Stop hook, so firing both would double-count.
    var onOsc9Received: (() -> Void)? {
        get { state.onOsc9Received }
        set { state.onOsc9Received = newValue }
    }

    /// Called on the main queue when the output shows a local dev-server
    /// URL (`http://localhost:5173/`). Throttled per port.
    var onLocalServerURL: ((LocalServerURL) -> Void)? {
        get { state.onLocalServerURL }
        set { state.onLocalServerURL = newValue }
    }

    /// Called on the main queue when the shell process exits.
    var onProcessExit: (() -> Void)? {
        get { state.onProcessExit }
        set { state.onProcessExit = newValue }
    }

    /// True after the shell process exited. The session can be restarted
    /// with another `start(...)` call — the terminal surface (and its
    /// scrollback) survives.
    var hasExited: Bool { state.hasExited }

    /// Last applied grid size — the right starting size for a restart.
    var lastSize: (cols: Int, rows: Int) { (state.lastCols, state.lastRows) }

    /// The shell's pid while it runs.
    var shellPID: pid_t? { state.childPid > 0 ? state.childPid : nil }

    /// Start of the agent's current turn (drives the "working · 12m"
    /// display in the sidebar). Nil between turns.
    var agentTurnStartedAt: Date? {
        state.machine.turnStartedAt.map { Date(timeIntervalSince1970: $0) }
    }

    /// Why the agent waits on the user, while it does.
    var agentAttentionReason: AgentAttentionReason? { state.machine.attentionReason }

    /// The oldest dialog (permission, question) the agent may be showing —
    /// even while the column is focused and reads as idle.
    var pendingAgentDialog: AgentPermissionRequest? { state.machine.pendingDialogs.first }

    /// The dialog the foreground `claude` is showing, if any (see
    /// `AgentStatusMachine.visibleDialog`).
    func agentVisibleDialog(foreground: ForegroundProcess?) -> AgentPermissionRequest? {
        state.machine.visibleDialog(foreground: foreground)
    }

    /// The request the sidebar can answer, or whose answer is on its way.
    func sidebarApproval(now: TimeInterval) -> AgentPermissionRequest? {
        state.machine.sidebarApproval(now: now)
    }

    func markApprovalSent(
        requestID: String,
        behavior: PermissionApproval.Behavior,
        now: TimeInterval
    ) -> AgentPermissionRequest? {
        state.machine.markApprovalSent(requestID: requestID, behavior: behavior, now: now)
    }

    func takeUndecidedApprovals(
        where shouldTake: (AgentPermissionRequest) -> Bool = { _ in true }
    ) -> [AgentPermissionRequest] {
        state.machine.takeUndecidedApprovals(where: shouldTake)
    }

    func dropApproval(requestID: String) -> AgentPermissionRequest? {
        state.machine.dropApproval(requestID: requestID)
    }

    // MARK: Stuck agents (see `AgentStuckState`)

    func agentStuckState(now: TimeInterval, waitThreshold: TimeInterval?, foreground: ForegroundProcess?) -> AgentStuckState? {
        state.machine.stuckState(now: now, waitThreshold: waitThreshold, foreground: foreground)
    }

    func takeAgentStuckAlert(
        now: TimeInterval,
        waitThreshold: TimeInterval?,
        foreground: ForegroundProcess?
    ) -> AgentAttentionReason? {
        state.machine.takeStuckAlert(now: now, waitThreshold: waitThreshold, foreground: foreground)
    }

    /// What blocks the agent on the user now (see `AgentWait`).
    func agentBlockedWait(now: TimeInterval, foreground: ForegroundProcess?) -> AgentWait? {
        state.machine.blockedWait(now: now, foreground: foreground)
    }

    var agentMidTurnExit: AgentMidTurnExit? { state.machine.midTurnExit }

    var agentTurnFailure: AgentTurnFailure? { state.machine.turnFailure }

    func noteAgentExited(_ exit: AgentMidTurnExit) {
        state.machine.noteAgentExited(exit)
    }

    func clearAgentMidTurnExit() {
        state.machine.clearMidTurnExit()
    }

    /// Why Resume can't type `continue` now, if it can't (see
    /// `AgentStatusMachine.resumeRefusal`). `foreground` is this terminal's
    /// foreground process in `snapshot`; the failed `claude` may be it or
    /// run under it (a launcher that spawns it).
    func agentResumeRefusal(
        foreground: ForegroundProcess?,
        snapshot: ProcessSnapshot,
        now: TimeInterval
    ) -> AgentResumeRefusal? {
        guard !hasExited, let foreground else { return .notClaude }
        return state.machine.resumeRefusal(
            foreground: foreground,
            ownsEmitter: { $0 == foreground.instance || snapshot.isProcess($0, childOf: foreground.instance.pid) },
            now: now
        )
    }

    /// Resume a turn that failed on an API error: `continue` and Enter,
    /// typed only when `agentResumeRefusal` allows it. Returns the refusal
    /// otherwise.
    func resumeFailedTurn(snapshot: ProcessSnapshot, now: TimeInterval) -> AgentResumeRefusal? {
        let foreground = foregroundProcess(snapshot: snapshot)
        if let refusal = agentResumeRefusal(foreground: foreground, snapshot: snapshot, now: now) { return refusal }
        guard let input = RemotePromptSanitizer.terminalInput(for: "continue") else { return .notStopped }
        state.machine.markResumeSent(now: now)
        sendRaw(input)
        state.machine.noteResumeTyped()
        return nil
    }

    /// The user's login shell ($SHELL) when it's a mainstream
    /// POSIX-compatible one, else zsh. Restricted to an allowlist because
    /// command-backed columns launch it with zsh-style `-i -l -c` flags
    /// that exotic shells (nu, xonsh, elvish) reject — for those users the
    /// hardcoded /bin/zsh was the working behavior. Computed once — checked
    /// in the parent process, never post-fork.
    static let defaultShell: String = {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? ""
        let posixCompatible: Set<String> = ["zsh", "bash", "sh", "dash", "ksh", "tcsh", "fish"]
        let name = (shell as NSString).lastPathComponent
        if shell.hasPrefix("/"), posixCompatible.contains(name),
           FileManager.default.fileExists(atPath: shell) {
            return shell
        }
        return "/bin/zsh"
    }()

    /// Compute agent status. With Claude Code hooks installed, lifecycle
    /// events (prompt submitted, tool call, turn stop, permission request)
    /// are authoritative; agents without hooks fall back to output-activity
    /// detection. Called on the heartbeat with a shared process snapshot.
    func agentStatus(foregroundProcess: ForegroundProcess?, isUserFocused: Bool) -> AgentStatus {
        let fgName = foregroundProcess?.name ?? ""
        return state.machine.tick(fgName: fgName, isUserFocused: isUserFocused, now: Date())
    }

    /// Apply a hook event routed by AgentHookCenter (main queue).
    /// `firedAttention` means the column flipped INTO needsAttention — the
    /// caller then fires the workspace-level notification path.
    @discardableResult
    func applyAgentHook(_ event: AgentHookEvent, isUserFocused: Bool) -> AgentHookOutcome {
        let dialogsBefore = state.machine.pendingDialogs.count
        let outcome = state.machine.apply(event, isUserFocused: isUserFocused)
        let dialogs = state.machine.pendingDialogs
        if dialogs.count != dialogsBefore {
            // Stale-gate reports need the trail: which event opened or
            // closed what (NIRUX_TERM_DEBUG=1).
            NiruxDebugLog.log("agent dialogs \(dialogsBefore)→\(dialogs.count) on \(event.name.rawValue) "
                + "agent=\(event.agentID ?? "main"): "
                + dialogs.map { "\($0.toolName ?? "?")[\($0.key ?? "-")]" }.joined(separator: ","))
        }
        return outcome
    }

    /// Last computed agent state (no snapshot needed — read from persistent state)
    var cachedAgentState: AgentStatus { state.machine.state }

    /// Epoch seconds of the agent's last sign of life: output that wasn't
    /// input echo (since the foreground command started), or a hook event
    /// (of any command). 0 = none.
    var lastAgentActivityAt: TimeInterval { max(state.machine.lastReadAt, state.machine.lastEventAt) }

    /// The last status tick saw a recognized agent in the foreground.
    var lastSeenRunningAgent: Bool {
        state.machine.lastForegroundName.map(AgentStatusMachine.isRecognizedAgentProcess) ?? false
    }

    /// Hook kind ("claude"/"codex") once the running agent emitted a hook
    /// event — closing only trusts an "idle" status that hooks drive.
    var agentHookKind: String? { state.machine.hookKind }

    /// A recognized agent that closing this terminal would kill: the
    /// foreground process, or any descendant of the shell — a job suspended
    /// with ^Z, or an agent under a wrapper, dies with the PTY too. Fails
    /// closed: an empty snapshot, or a turn the status machine still sees
    /// in flight, falls back to the heartbeat's last view of the agent — so
    /// an agent that exited since the last tick (≤ 2 s) may still prompt.
    func agentProcessName(snapshot: ProcessSnapshot) -> String? {
        guard !hasExited, state.childPid > 0 else { return nil }
        let isAgent = AgentStatusMachine.isRecognizedAgentProcess
        if let name = foregroundProcessName(snapshot: snapshot), isAgent(name) { return name }
        if let name = snapshot.firstDescendantName(of: state.childPid, where: isAgent) { return name }
        guard snapshot.isEmpty || cachedAgentState != .idle else { return nil }
        return [state.machine.lastForegroundName, state.machine.hookKind].compactMap { $0 }.first(where: isAgent)
    }

    /// Remote prompts are accepted only while an integrated agent process
    /// (Claude Code, Codex) is currently in the foreground. A stable UUID
    /// alone is not enough: the same column can later fall back to an idle
    /// shell.
    func acceptsRemotePrompts(snapshot: ProcessSnapshot) -> Bool {
        guard !hasExited,
              let process = foregroundProcessName(snapshot: snapshot)
        else { return false }
        return AgentStatusMachine.acceptsRemotePrompts(processName: process)
    }

    func recentOutput(maxLines: Int = 40, maxCharacters: Int = 3_500) -> String {
        state.outputBuffer.tail(maxLines: maxLines, maxCharacters: maxCharacters)
    }

    /// Clear attention flag (user has seen it)
    func clearAgentAttention() {
        state.machine.clearAttention()
    }

    /// Name of the foreground process (e.g. "zsh", "node", "claude").
    /// Shows what's running right now — no caching, no filtering.
    func foregroundProcessName(snapshot: ProcessSnapshot) -> String? {
        // childPid is cleared on exit — pid 0 would resolve to kernel_task.
        guard state.childPid > 0 else { return nil }
        return state.foregroundProcess(snapshot: snapshot)?.name
    }

    func foregroundProcess(snapshot: ProcessSnapshot) -> ForegroundProcess? {
        state.foregroundProcess(snapshot: snapshot)
    }

    func foregroundInstance(snapshot: ProcessSnapshot) -> ProcessInstance? {
        guard let shellPID else { return nil }
        return snapshot.foregroundInstance(shellPID: shellPID)
    }

    func isProcessInForegroundJob(
        _ process: ProcessInstance,
        snapshot: ProcessSnapshot
    ) -> Bool {
        state.isProcessInForegroundJob(process, snapshot: snapshot)
    }

    /// Returns the cwd of the child process (follows cd), nil until the
    /// shell has exec'd.
    /// Uses `proc_pidinfo(PROC_PIDVNODEPATHINFO)` — `/proc` isn't available
    /// on macOS and `proc_pidpath` gives the executable path, not the cwd.
    var childCwd: String? {
        guard state.childPid > 0 else { return nil }
        return Self.cwd(ofExecedProcess: state.childPid)
    }

    /// Nil until `pid` has exec'd. Before that, the child `start` forked
    /// may not have reached its `chdir` yet and still sits in Nirux's own
    /// working directory (`/` for the app, the checkout under `swift test`):
    /// an editor, a save or a file picker reading it would root itself
    /// there. The flag is read first: a fork starts without it, it never
    /// clears, and the `chdir` comes before the exec, so the cwd read after
    /// it is the shell's.
    static func cwd(ofExecedProcess pid: pid_t) -> String? {
        var bsdInfo = proc_bsdshortinfo()
        let bsdSize = Int32(MemoryLayout<proc_bsdshortinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDT_SHORTBSDINFO, 0, &bsdInfo, bsdSize) == bsdSize,
              bsdInfo.pbsi_flags & UInt32(PROC_FLAG_EXEC) != 0 else { return nil }
        // Use proc_pidinfo with PROC_PIDVNODEPATHINFO to get cwd
        var info = proc_vnodepathinfo()
        let size = MemoryLayout<proc_vnodepathinfo>.size
        let ret = proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, Int32(size))
        guard ret == size else { return nil }
        return withUnsafePointer(to: &info.pvi_cdir.vip_path) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { cpath in
                String(cString: cpath)
            }
        }
    }

    init() {
        let st = state
        terminalSession = InMemoryTerminalSession(
            write: { data in
                st.noteTerminalWrite(data)
                st.writeToPty(data)
            },
            resize: { viewport in
                st.resize(cols: Int(viewport.columns), rows: Int(viewport.rows))
            }
        )
    }

    /// Send raw bytes directly to the PTY, bypassing ghostty.
    /// Used for keys that ghostty's inMemory backend doesn't route correctly
    /// (e.g. Enter when Claude Code enables kitty keyboard protocol).
    func sendRaw(_ data: Data) {
        state.noteTypedInput(data)
        state.writeToPty(data)
    }

    /// Whether ghostty writes the user's text (see `PtyState.noteTerminalWrite`):
    /// terminal replies (device attributes, focus and mouse reports…) all
    /// start with ESC; a bracketed paste does too, with its own marker.
    static func isUserText(_ data: Data) -> Bool {
        guard let first = data.first else { return false }
        return first != 0x1B || data.starts(with: [0x1B, 0x5B, 0x32, 0x30, 0x30, 0x7E]) // ESC[200~
    }

    func sendRaw(_ string: String) {
        if let data = string.data(using: .utf8) {
            sendRaw(data)
        }
    }

    /// Resize the PTY (notify the shell of new terminal dimensions)
    func resize(cols: Int, rows: Int) {
        state.resize(cols: cols, rows: rows)
    }

    /// Force a SIGWINCH to the foreground process group so TUI apps redraw.
    /// Uses tcgetpgrp() to target the entire group (zsh + codex/claude/vim etc.)
    func forceRedraw() {
        guard state.ptyFd >= 0, state.childPid > 0 else { return }
        state.markTerminalRedraw()
        state.lastCols = 0
        state.lastRows = 0
        // Send to the foreground process group of the terminal
        let pgrp = tcgetpgrp(state.ptyFd)
        if pgrp > 0 {
            killpg(pgrp, SIGWINCH)
        } else {
            kill(state.childPid, SIGWINCH)
        }
    }

    func start(
        shell: String = "/bin/zsh",
        args: [String] = ["-l"],
        cwd: String,
        cols: Int = 80,
        rows: Int = 24,
        environment: [String: String] = [:]
    ) {
        // Compute PATH BEFORE fork (Foundation APIs like FileManager are not
        // async-signal-safe and crash in child processes). The effective path
        // is memoized via a static-let and only applied to the child, leaving
        // the parent process's PATH untouched.
        let effectivePath = Self.effectivePath

        // Read settings BEFORE fork — FileManager is forbidden in child process
        let noFlicker = Persistence.load()?.settings?.claudeNoFlicker != false

        // Prefer the viewport size that arrived while the PTY didn't exist yet
        // (the shell start is deferred ~0.5s after the surface) — otherwise the
        // fork keeps the caller's 80x24 and the upstream debounces never
        // re-send the real size.
        let initialCols = state.pendingCols > 0 ? state.pendingCols : cols
        let initialRows = state.pendingRows > 0 ? state.pendingRows : rows
        NiruxDebugLog.log("pty start cols=\(initialCols) rows=\(initialRows) (pending \(state.pendingCols)x\(state.pendingRows))")

        var ws = winsize()
        ws.ws_col = UInt16(initialCols)
        ws.ws_row = UInt16(initialRows)

        var fd: Int32 = 0
        let pid = forkpty(&fd, nil, nil, &ws)

        if pid == 0 {
            // Child: exec shell via execv (not execl which is unavailable in Swift 6)
            setenv("PATH", effectivePath, 1)
            setenv("TERM", "xterm-256color", 1)
            setenv("LANG", "en_US.UTF-8", 1)
            for (name, value) in environment {
                setenv(name, value, 1)
            }
            if noFlicker {
                setenv("CLAUDE_CODE_NO_FLICKER", "1", 1)
            }

            chdir(cwd)

            var cArgs: [UnsafeMutablePointer<CChar>?] = [strdup(shell)]
            for arg in args { cArgs.append(strdup(arg)) }
            cArgs.append(nil)
            execv(shell, cArgs)
            _exit(1)
        }

        guard pid > 0 else {
            // Fork failed — keep the session in the exited state so the
            // restart overlay stays actionable instead of dead-ending.
            state.hasExited = true
            state.onProcessExit?()
            return
        }
        state.ptyFd = fd
        state.childPid = pid
        state.hasExited = false
        state.lastCols = initialCols
        state.lastRows = initialRows
        state.markPtyStarted()

        // Read PTY output → feed to terminal for rendering
        let session = terminalSession
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .global(qos: .userInteractive))
        source.setEventHandler { [state] in
            state.readFromPty(into: session)
        }
        source.setCancelHandler {
            close(fd)
        }
        source.resume()
        state.readSource = source

        // Watch for shell exit — without this a dead shell leaves a mute
        // terminal with no way to know (or restart). Also reaps the zombie.
        state.exitSource?.cancel()
        let exitSource = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .main)
        exitSource.setEventHandler { [state] in
            var status: Int32 = 0
            _ = waitpid(pid, &status, 0)
            // Cancel the read source BEFORE clearing the fd: its cancel
            // handler closes the master fd. Left armed, it would spin at
            // EOF (or, when a grandchild holds the pty open, never fire at
            // all) — leaking the fd and, after a restart reassigns
            // state.ptyFd, reading from the NEW shell's fd.
            state.readSource?.cancel()
            state.readSource = nil
            state.ptyFd = -1
            // Clear childPid so deinit can't SIGTERM whatever process later
            // recycles this pid, and process attribution stops resolving
            // the dead shell's identity.
            state.childPid = 0
            state.hasExited = true
            state.machine.reset()
            state.onProcessExit?()
        }
        exitSource.resume()
        state.exitSource = exitSource
    }

    /// PATH to pass to child shells — includes standard locations so login
    /// shells can find Homebrew, fnm, starship, etc. even on first launch
    /// after Gatekeeper. Computed once per process on first access (must be
    /// triggered from the parent — FileManager is not safe after fork).
    static let effectivePath: String = computeEffectivePath()

    private static func computeEffectivePath() -> String {
        let current = String(cString: getenv("PATH") ?? strdup(""))
        var paths = current.split(separator: ":").map(String.init)

        // Read /etc/paths and /etc/paths.d/* (same thing path_helper does)
        if let etcPaths = try? String(contentsOfFile: "/etc/paths", encoding: .utf8) {
            for line in etcPaths.split(separator: "\n") {
                let pathEntry = String(line).trimmingCharacters(in: .whitespaces)
                if !pathEntry.isEmpty && !paths.contains(pathEntry) { paths.append(pathEntry) }
            }
        }
        let pathsD = "/etc/paths.d"
        if let entries = try? FileManager.default.contentsOfDirectory(atPath: pathsD) {
            for entry in entries.sorted() {
                if let content = try? String(contentsOfFile: "\(pathsD)/\(entry)", encoding: .utf8) {
                    for line in content.split(separator: "\n") {
                        let pathEntry = String(line).trimmingCharacters(in: .whitespaces)
                        if !pathEntry.isEmpty && !paths.contains(pathEntry) { paths.append(pathEntry) }
                    }
                }
            }
        }

        // Also ensure common user paths
        let home = String(cString: getenv("HOME") ?? strdup(""))
        let extras = [
            "/opt/homebrew/bin",
            "/opt/homebrew/sbin",
            "/usr/local/bin",
            "\(home)/.local/bin",
            "\(home)/.bun/bin"
        ]
        for pathEntry in extras where !paths.contains(pathEntry) {
            paths.append(pathEntry)
        }

        return paths.joined(separator: ":")
    }

    deinit {
        state.exitSource?.cancel()
        state.readSource?.cancel()
        if state.childPid > 0 { kill(state.childPid, SIGTERM) }
    }
}

/// Sendable state container for PTY file descriptors
private final class PtyState: @unchecked Sendable {
    var ptyFd: Int32 = -1
    var childPid: pid_t = 0
    var readSource: DispatchSourceRead?
    var exitSource: DispatchSourceProcess?
    var hasExited: Bool = false
    var onCwdChanged: ((String) -> Void)?
    var onTitleChanged: ((String) -> Void)?
    var onOsc9Received: (() -> Void)?
    var onLocalServerURL: ((LocalServerURL) -> Void)?
    var onProcessExit: (() -> Void)?
    var machine = AgentStatusMachine()
    let outputBuffer = TerminalOutputBuffer()
    /// Read-queue only. A (re)start sets `localServerStateIsStale` from
    /// main instead of resetting them, so a straggling read handler of the
    /// previous shell never sees them replaced mid-scan.
    private var localServerScanner = LocalServerURLScanner()
    private var localServerLastForwarded: [Int: TimeInterval] = [:]
    private var localServerStateIsStale = false
    private static let localServerForwardInterval: TimeInterval = 1
    /// Something reached the PTY through `sendRaw` — keystrokes (including
    /// the Enter after a ⌘V paste, which itself goes through ghostty),
    /// dropped files, remote prompts, commands Nirux types. Unlike
    /// `machine.hasUserInput` it ignores ghostty's own writes (replies to
    /// the terminal queries Claude Code sends at startup) and the lone
    /// Ctrl+L redraw nudge. Once open, a TUI repaint can still resurface
    /// an old URL — at most one proposal per port, and only if listening.
    private var hasTypedInput = false

    func noteTypedInput(_ data: Data) {
        guard data != Self.redrawNudge else { return }
        machine.noteKeystroke(now: Date())
        hasTypedInput = true
    }

    private static let redrawNudge = Data([0x0C])

    /// Ghostty writes to the PTY for text the user enters through it — a
    /// paste (any way: ⌘V, the Edit menu, a right-click), dictation, the
    /// emoji picker — and for its own replies to terminal queries, which
    /// may come on the read queue. The user's text counts as a keystroke,
    /// noted on the main queue like every other.
    func noteTerminalWrite(_ data: Data) {
        guard PtySession.isUserText(data) else { return }
        DispatchQueue.main.async { [self] in
            machine.noteKeystroke(now: Date())
        }
    }

    func foregroundProcess(snapshot: ProcessSnapshot) -> ForegroundProcess? {
        guard childPid > 0 else { return nil }
        return snapshot.foregroundProcess(shellPID: childPid)
    }

    func isProcessInForegroundJob(
        _ process: ProcessInstance,
        snapshot: ProcessSnapshot
    ) -> Bool {
        guard childPid > 0 else { return false }
        return snapshot.isProcess(process, inForegroundProcessGroupOf: childPid)
    }

    func markPtyStarted() {
        machine.reset()
        localServerStateIsStale = true
        hasTypedInput = false
    }

    func writeToPty(_ data: Data) {
        machine.noteUserInput(now: Date())
        guard ptyFd >= 0 else { return }
        data.withUnsafeBytes { buf in
            guard let ptr = buf.baseAddress else { return }
            _ = write(ptyFd, ptr, buf.count)
        }
    }

    var lastCols: Int = 0
    var lastRows: Int = 0
    /// Last viewport size seen before the PTY existed. The shell starts ~0.5s
    /// after the surface (ColumnState defers it), so the initial grid resize
    /// arrives while ptyFd is still -1; without this the fork falls back to
    /// 80x24 and the debounces upstream never re-send the real size.
    var pendingCols: Int = 0
    var pendingRows: Int = 0

    private var targetCols: Int = 0
    private var targetRows: Int = 0
    private var winsizeQuietTimer: Timer?

    /// Coalesce winsize updates: apply the first change immediately, then hold
    /// a quiet window so storms (fullscreen transitions, width-preset cycling,
    /// session restore) deliver only the final settled size. Rapid zig-zag
    /// SIGWINCH bursts can wedge TUI renderers (Claude Code ends up stuck on
    /// an intermediate width) — a single trailing resize never does.
    func resize(cols: Int, rows: Int) {
        if Thread.isMainThread {
            resizeOnMain(cols: cols, rows: rows)
        } else {
            DispatchQueue.main.async { self.resizeOnMain(cols: cols, rows: rows) }
        }
    }

    private func resizeOnMain(cols: Int, rows: Int) {
        guard ptyFd >= 0 else {
            NiruxDebugLog.log("pty fd=-1 resize deferred cols=\(cols) rows=\(rows)")
            pendingCols = cols
            pendingRows = rows
            return
        }
        targetCols = cols
        targetRows = rows
        guard winsizeQuietTimer == nil else { return }
        applyTargetWinsize()
        startWinsizeQuietWindow()
    }

    private func startWinsizeQuietWindow() {
        winsizeQuietTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: false) { [weak self] _ in
            guard let self else { return }
            self.winsizeQuietTimer = nil
            if self.targetCols != self.lastCols || self.targetRows != self.lastRows {
                self.applyTargetWinsize()
                self.startWinsizeQuietWindow()
            }
        }
    }

    private func applyTargetWinsize() {
        let cols = targetCols
        let rows = targetRows
        guard ptyFd >= 0, cols > 0, rows > 0 else { return }
        guard cols != lastCols || rows != lastRows else {
            NiruxDebugLog.log("pty fd=\(ptyFd) pid=\(childPid) resize skipped cols=\(cols) rows=\(rows)")
            return
        }
        NiruxDebugLog.log("pty fd=\(ptyFd) pid=\(childPid) TIOCSWINSZ cols=\(cols) rows=\(rows) (was \(lastCols)x\(lastRows))")
        machine.noteInteraction(now: Date())
        lastCols = cols
        lastRows = rows
        var ws = winsize()
        ws.ws_col = UInt16(cols)
        ws.ws_row = UInt16(rows)
        _ = ioctl(ptyFd, TIOCSWINSZ, &ws)
    }

    func markTerminalRedraw() {
        machine.noteInteraction(now: Date())
    }

    func readFromPty(into session: InMemoryTerminalSession) {
        guard ptyFd >= 0 else { return }
        var buffer = [UInt8](repeating: 0, count: 8192)
        let bytesRead = read(ptyFd, &buffer, buffer.count)
        guard bytesRead > 0 else {
            // EOF — the child is gone; stop writes from hitting a closed fd.
            ptyFd = -1
            readSource?.cancel()
            return
        }
        let data = Data(buffer[0..<bytesRead])
        machine.noteRead(now: Date())
        outputBuffer.append(data)
        session.receive(data)
        if let str = String(bytes: data, encoding: .utf8),
           str.contains("\u{1b}]") {
            parseOscSequences(str)
        }
        // Output before the first typed input is launch noise — notably
        // `claude --continue` replaying old transcripts.
        if hasTypedInput, onLocalServerURL != nil {
            detectLocalServerURLs(in: buffer, count: bytesRead)
        }
    }

    private func detectLocalServerURLs(in buffer: [UInt8], count: Int) {
        if localServerStateIsStale {
            localServerStateIsStale = false
            localServerScanner = LocalServerURLScanner()
            localServerLastForwarded = [:]
        }
        let urls = buffer.withUnsafeBytes {
            localServerScanner.scan(UnsafeRawBufferPointer(rebasing: $0[..<count]))
        }
        guard !urls.isEmpty, let callback = onLocalServerURL else { return }
        // TUIs repaint the same URL on every frame; the workspace dedupes
        // per port, this just keeps the main queue quiet. Short enough not
        // to swallow the reprint of a quick server restart.
        let now = ProcessInfo.processInfo.systemUptime
        let fresh = urls.filter { url in
            if let last = localServerLastForwarded[url.port],
               now - last < Self.localServerForwardInterval { return false }
            if localServerLastForwarded.count >= 64 { localServerLastForwarded.removeAll() }
            localServerLastForwarded[url.port] = now
            return true
        }
        guard !fresh.isEmpty else { return }
        DispatchQueue.main.async { fresh.forEach(callback) }
    }

    /// Parse OSC sequences from terminal output (cwd, title).
    private func parseOscSequences(_ str: String) {
        // OSC 7 (cwd reporting): \e]7;file://hostname/path\a
        if let callback = onCwdChanged, str.contains("\u{1b}]7;") {
            if let range = str.range(of: "file://"),
               let end = str[range.upperBound...].firstIndex(where: { $0 == "\u{07}" || $0 == "\u{1b}" }) {
                let urlPart = String(str[range.lowerBound..<end])
                if let urlComps = URLComponents(string: urlPart),
                   let path = urlComps.path.removingPercentEncoding {
                    DispatchQueue.main.async { callback(path) }
                }
            }
        }
        // OSC 0/2 (terminal title): \e]0;title\a or \e]2;title\a
        if let titleCallback = onTitleChanged {
            for prefix in ["\u{1b}]0;", "\u{1b}]2;"] {
                if let range = str.range(of: prefix) {
                    let after = str[range.upperBound...]
                    if let end = after.firstIndex(where: { $0 == "\u{07}" || $0 == "\u{1b}" }) {
                        let title = String(after[..<end])
                        DispatchQueue.main.async { titleCallback(title) }
                        break
                    }
                }
            }
        }
        // OSC 9 (notification): Claude Code emits this when a turn
        // completes. Only forwarded for sessions WITHOUT hook coverage —
        // hooked sessions get the same signal from the Stop hook, and the
        // hasUserInput gate keeps startup replay from fabricating attention.
        if str.contains("\u{1b}]9;"),
           machine.hookKind == nil, machine.hasUserInput,
           let callback = onOsc9Received {
            DispatchQueue.main.async { callback() }
        }
    }
}
