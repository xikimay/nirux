import AppKit
import Foundation
import GhosttyTerminal

enum AgentStatus: Equatable, Hashable {
    case idle, working, needsAttention
}

struct ProcessInstance: Equatable {
    let pid: pid_t
    let startedAt: TimeInterval
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
        let name: String
        let startedAt: TimeInterval
        let arguments: [String]
    }

    private var childrenMap: [pid_t: [pid_t]] = [:]
    private var processGroupMap: [pid_t: [pid_t]] = [:]
    private var commMap: [pid_t: String] = [:]
    private var instanceMap: [pid_t: ProcessInstance] = [:]
    private var capturedArguments: [pid_t: [String]]?

    init() {
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
            let name = withUnsafePointer(to: &procs[i].kp_proc.p_comm) { ptr in
                ptr.withMemoryRebound(to: CChar.self, capacity: Int(MAXCOMLEN)) {
                    String(cString: $0)
                }
            }
            let startTime = procs[i].kp_proc.p_starttime
            add(
                pid: pid,
                parentPID: ppid,
                processGroupID: processGroupID,
                name: name,
                startedAt: TimeInterval(startTime.tv_sec)
                    + TimeInterval(startTime.tv_usec) / 1_000_000
            )
        }
    }

    init(entries: [Entry]) {
        capturedArguments = Dictionary(uniqueKeysWithValues: entries.map { ($0.pid, $0.arguments) })
        for entry in entries {
            add(
                pid: entry.pid,
                parentPID: entry.parentPID,
                processGroupID: entry.processGroupID,
                name: entry.name,
                startedAt: entry.startedAt
            )
        }
    }

    private func add(
        pid: pid_t,
        parentPID: pid_t,
        processGroupID: pid_t,
        name: String,
        startedAt: TimeInterval
    ) {
        childrenMap[parentPID, default: []].append(pid)
        processGroupMap[processGroupID, default: []].append(pid)
        commMap[pid] = name
        instanceMap[pid] = ProcessInstance(pid: pid, startedAt: startedAt)
    }

    func foregroundProcess(
        shellPID: pid_t,
        processGroupID: pid_t?
    ) -> ForegroundProcess? {
        let groupedPID: pid_t? = processGroupID.flatMap { groupID -> pid_t? in
            guard let members = processGroupMap[groupID], !members.isEmpty else { return nil }
            return members.first(where: { $0 == groupID })
                ?? members.first(where: { $0 != shellPID })
                ?? members.first
        }
        let pid = groupedPID ?? childrenMap[shellPID]?.first ?? shellPID
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

    private static let runtimeBinaries: Set<String> = [
        "node", "python", "python3", "ruby", "perl", "java", "deno", "bun"
    ]

    fileprivate static func execName(from argv: [String]) -> String? {
        guard let first = argv.first else { return nil }
        let name0 = (first as NSString).lastPathComponent
        // If argv[0] is a known runtime, try argv[1] for the real command name
        if runtimeBinaries.contains(name0), argv.count >= 2 {
            let arg1 = argv[1]
            if !arg1.hasPrefix("-") {
                let base = ((arg1 as NSString).lastPathComponent as NSString).deletingPathExtension
                if !base.isEmpty { return base }
            }
        }
        return name0
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
        let limit = min(Int(argc), maxArgs)
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

    /// When the current foreground process took over (drives the "working
    /// · 12m" display in the sidebar). Nil while the idle shell runs.
    var foregroundProcessStartedAt: Date? { state.machine.foregroundSince }

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

    /// Apply a hook event routed by AgentHookCenter (main queue). Returns
    /// true when the column flipped INTO needsAttention — the caller then
    /// fires the workspace-level notification path.
    @discardableResult
    func applyAgentHook(_ event: AgentHookEvent, isUserFocused: Bool) -> Bool {
        state.machine.applyHook(event.name, kind: event.kind, isUserFocused: isUserFocused)
    }

    /// Last computed agent state (no snapshot needed — read from persistent state)
    var cachedAgentState: AgentStatus { state.machine.state }

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

    /// Returns the cwd of the child process (follows cd).
    /// Uses `proc_pidinfo(PROC_PIDVNODEPATHINFO)` — `/proc` isn't available
    /// on macOS and `proc_pidpath` gives the executable path, not the cwd.
    var childCwd: String? {
        guard state.childPid > 0 else { return nil }
        return cwdFromPid(state.childPid)
    }

    private func cwdFromPid(_ pid: pid_t) -> String? {
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
        state.writeToPty(data)
    }

    func sendRaw(_ string: String) {
        if let data = string.data(using: .utf8) {
            state.writeToPty(data)
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
    private static let effectivePath: String = computeEffectivePath()

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
    var onProcessExit: (() -> Void)?
    var machine = AgentStatusMachine()

    func foregroundProcess(snapshot: ProcessSnapshot) -> ForegroundProcess? {
        guard childPid > 0 else { return nil }
        let processGroupID = ptyFd >= 0 ? tcgetpgrp(ptyFd) : -1
        return snapshot.foregroundProcess(
            shellPID: childPid,
            processGroupID: processGroupID > 0 ? processGroupID : nil
        )
    }

    func markPtyStarted() {
        machine.reset()
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
        session.receive(data)
        if let str = String(bytes: data, encoding: .utf8),
           str.contains("\u{1b}]") {
            parseOscSequences(str)
        }
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
