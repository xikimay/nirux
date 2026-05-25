import AppKit
import Foundation
import GhosttyTerminal

enum AgentStatus: Equatable {
    case idle, working, needsAttention
}

/// Single sysctl snapshot of the process table, shared across all terminals.
/// Create once per refresh cycle instead of one KERN_PROC_ALL per terminal.
final class ProcessSnapshot {
    private var childrenMap: [pid_t: [pid_t]] = [:]
    private var commMap: [pid_t: String] = [:]

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
            childrenMap[ppid, default: []].append(pid)
            let name = withUnsafePointer(to: &procs[i].kp_proc.p_comm) { ptr in
                ptr.withMemoryRebound(to: CChar.self, capacity: Int(MAXCOMLEN)) {
                    String(cString: $0)
                }
            }
            commMap[pid] = name
        }
    }

    func children(of ppid: pid_t) -> [pid_t] {
        childrenMap[ppid] ?? []
    }

    func commName(of pid: pid_t) -> String? {
        commMap[pid]
    }

    private static let runtimeBinaries: Set<String> = [
        "node", "python", "python3", "ruby", "perl", "java", "deno", "bun"
    ]

    /// Check if a process was launched with a specific CLI flag.
    static func hasFlag(_ flag: String, pid: pid_t) -> Bool {
        let argv = readArgv(of: pid, maxArgs: 32)
        return argv.contains(flag)
    }

    /// Returns the argv token immediately following `flag` (e.g. the value of
    /// `--permission-mode <value>`).
    static func flagValue(_ flag: String, pid: pid_t) -> String? {
        let argv = readArgv(of: pid, maxArgs: 32)
        guard let idx = argv.firstIndex(of: flag), idx + 1 < argv.count else { return nil }
        return argv[idx + 1]
    }

    /// Get the best process name from argv via KERN_PROCARGS2.
    /// For runtimes (node, python...), resolves argv[1] to find the actual command.
    static func execName(of pid: pid_t) -> String? {
        let argv = readArgv(of: pid, maxArgs: 2)
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
    private static func readArgv(of pid: pid_t, maxArgs: Int) -> [String] {
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

    /// Called when an OSC 9 notification is received (agent turn completed)
    var onOsc9Received: (() -> Void)? {
        get { state.onOsc9Received }
        set { state.onOsc9Received = newValue }
    }

    /// Compute agent status using burst detection (rapid consecutive reads = active)
    /// - isUserFocused: true if the user is currently focused on this specific column
    func agentStatus(snapshot: ProcessSnapshot, isUserFocused: Bool) -> AgentStatus {
        let now = Date()
        let fgName = foregroundProcessName(snapshot: snapshot) ?? ""
        let isAgent = ["claude", "codex"].contains(fgName)

        // Track foreground changes and clear stale output from the previous
        // command so process startup does not look like a completed turn.
        if fgName != state.lastForegroundName {
            state.markForegroundProcessChange(to: fgName, now: now)
        }

        let isStartingUp = state.shouldSuppressAgentAttention(now: now)
        let inBurst = !isStartingUp
            && state.lastBurstTime != nil
            && now.timeIntervalSince(state.lastBurstTime!) < 3.0

        let prev = state.agentState
        switch state.agentState {
        case .idle:
            if isAgent && inBurst { state.agentState = .working }
        case .working:
            if !isAgent {
                state.agentState = .idle
            } else if isStartingUp {
                state.agentState = .idle
            } else if !inBurst {
                state.agentState = isUserFocused ? .idle : .needsAttention
            }
        case .needsAttention:
            if !isAgent {
                state.agentState = .idle
            } else if inBurst {
                state.agentState = .working
            } else if isUserFocused {
                state.agentState = .idle; state.lastBurstTime = nil
            }
        }
        if state.agentState != prev {
            NSLog(
                "[AgentStatus] \(fgName) \(prev) → \(state.agentState)"
                + " | isAgent=\(isAgent) inBurst=\(inBurst) "
                + "isStartingUp=\(isStartingUp) isUserFocused=\(isUserFocused)"
            )
        }
        return state.agentState
    }

    /// Last computed agent state (no snapshot needed — read from persistent state)
    var cachedAgentState: AgentStatus { state.agentState }

    /// Clear attention flag (user has seen it)
    func clearAgentAttention() {
        if state.agentState == .needsAttention {
            state.agentState = .idle
            state.lastBurstTime = nil
        }
    }

    /// Name of the foreground process (e.g. "zsh", "node", "claude").
    /// Shows what's running right now — no caching, no filtering.
    func foregroundProcessName(snapshot: ProcessSnapshot) -> String? {
        return state.foregroundProcessName(snapshot: snapshot)
            ?? snapshot.commName(of: state.childPid)
    }

    /// Check if the foreground process was launched with a specific CLI flag.
    func foregroundProcessHasFlag(_ flag: String, snapshot: ProcessSnapshot) -> Bool {
        return state.foregroundProcessHasFlag(flag, snapshot: snapshot)
    }

    /// Returns the argv token immediately following `flag`, e.g. the value of
    /// `--permission-mode <value>`. Returns nil if the flag isn't present or
    /// has no argument after it.
    func foregroundProcessFlagValue(_ flag: String, snapshot: ProcessSnapshot) -> String? {
        return state.foregroundProcessFlagValue(flag, snapshot: snapshot)
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

    func start(shell: String = "/bin/zsh", args: [String] = ["-l"], cwd: String, cols: Int = 80, rows: Int = 24) {
        // Compute PATH BEFORE fork (Foundation APIs like FileManager are not
        // async-signal-safe and crash in child processes). The effective path
        // is memoized via a static-let and only applied to the child, leaving
        // the parent process's PATH untouched.
        let effectivePath = Self.effectivePath

        // Read settings BEFORE fork — FileManager is forbidden in child process
        let noFlicker = Persistence.load()?.settings?.claudeNoFlicker != false

        var ws = winsize()
        ws.ws_col = UInt16(cols)
        ws.ws_row = UInt16(rows)

        var fd: Int32 = 0
        let pid = forkpty(&fd, nil, nil, &ws)

        if pid == 0 {
            // Child: exec shell via execv (not execl which is unavailable in Swift 6)
            setenv("PATH", effectivePath, 1)
            setenv("TERM", "xterm-256color", 1)
            setenv("LANG", "en_US.UTF-8", 1)
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

        guard pid > 0 else { return }
        state.ptyFd = fd
        state.childPid = pid
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
        state.readSource?.cancel()
        if state.childPid > 0 { kill(state.childPid, SIGTERM) }
    }
}

/// Sendable state container for PTY file descriptors
private final class PtyState: @unchecked Sendable {
    var ptyFd: Int32 = -1
    var childPid: pid_t = 0
    var readSource: DispatchSourceRead?
    var onCwdChanged: ((String) -> Void)?
    var onTitleChanged: ((String) -> Void)?
    var onOsc9Received: (() -> Void)?
    var lastOsc9Timestamp: Date?
    var agentState: AgentStatus = .idle
    var hasUserInputSinceStart: Bool = false
    var lastBurstTime: Date?
    var readCountInWindow: Int = 0
    var windowStart: Date = Date()
    var lastForegroundName: String?
    var foregroundSince: Date?
    var lastInteractionTime: Date?  // last write or resize (echo/redraw follows)
    var burstDetectionSuppressedUntil: Date?

    private static let writeEchoSuppressionInterval: TimeInterval = 0.3
    private static let displayRefreshSuppressionInterval: TimeInterval = 1.5
    private static let foregroundStartupSuppressionInterval: TimeInterval = 5.0

    func foregroundProcessName(snapshot: ProcessSnapshot) -> String? {
        guard childPid > 0 else { return nil }
        // Find the first direct child of the shell (the foreground command)
        let children = snapshot.children(of: childPid)
        // If no children, shell is idle — return shell name
        guard let fgPid = children.first else {
            return ProcessSnapshot.execName(of: childPid)
        }
        // Use argv[0] basename for the foreground process (most accurate)
        if let name = ProcessSnapshot.execName(of: fgPid) { return name }
        // Fallback to p_comm from the snapshot
        return snapshot.commName(of: fgPid)
    }

    func foregroundProcessHasFlag(_ flag: String, snapshot: ProcessSnapshot) -> Bool {
        guard childPid > 0 else { return false }
        let children = snapshot.children(of: childPid)
        guard let fgPid = children.first else { return false }
        return ProcessSnapshot.hasFlag(flag, pid: fgPid)
    }

    func foregroundProcessFlagValue(_ flag: String, snapshot: ProcessSnapshot) -> String? {
        guard childPid > 0 else { return nil }
        let children = snapshot.children(of: childPid)
        guard let fgPid = children.first else { return nil }
        return ProcessSnapshot.flagValue(flag, pid: fgPid)
    }

    func markPtyStarted(now: Date = Date()) {
        hasUserInputSinceStart = false
        foregroundSince = nil
        lastForegroundName = nil
        agentState = .idle
        lastBurstTime = nil
        resetBurstWindow(now: now)
    }

    func markForegroundProcessChange(to name: String, now: Date = Date()) {
        lastForegroundName = name
        foregroundSince = now
        lastBurstTime = nil
        resetBurstWindow(now: now)
    }

    func shouldSuppressAgentAttention(now: Date = Date()) -> Bool {
        guard hasUserInputSinceStart else { return true }
        if let foregroundSince,
           now.timeIntervalSince(foregroundSince) < Self.foregroundStartupSuppressionInterval {
            return true
        }
        return false
    }

    func writeToPty(_ data: Data) {
        hasUserInputSinceStart = true
        markInteraction(suppressBurstDetectionFor: Self.writeEchoSuppressionInterval)
        guard ptyFd >= 0 else { return }
        data.withUnsafeBytes { buf in
            guard let ptr = buf.baseAddress else { return }
            _ = write(ptyFd, ptr, buf.count)
        }
    }

    var lastCols: Int = 0
    var lastRows: Int = 0

    func resize(cols: Int, rows: Int) {
        // Debounce: only send SIGWINCH if dimensions actually changed
        guard ptyFd >= 0, cols != lastCols || rows != lastRows else { return }
        markInteraction(suppressBurstDetectionFor: Self.displayRefreshSuppressionInterval)
        lastCols = cols
        lastRows = rows
        var ws = winsize()
        ws.ws_col = UInt16(cols)
        ws.ws_row = UInt16(rows)
        _ = ioctl(ptyFd, TIOCSWINSZ, &ws)
    }

    func markTerminalRedraw() {
        markInteraction(suppressBurstDetectionFor: Self.displayRefreshSuppressionInterval)
    }

    private func markInteraction(suppressBurstDetectionFor interval: TimeInterval) {
        let now = Date()
        lastInteractionTime = now
        burstDetectionSuppressedUntil = now.addingTimeInterval(interval)
        resetBurstWindow(now: now)
    }

    private func resetBurstWindow(now: Date) {
        windowStart = now
        readCountInWindow = 0
    }

    func readFromPty(into session: InMemoryTerminalSession) {
        guard ptyFd >= 0 else { return }
        var buffer = [UInt8](repeating: 0, count: 8192)
        let bytesRead = read(ptyFd, &buffer, buffer.count)
        guard bytesRead > 0 else {
            readSource?.cancel()
            return
        }
        let data = Data(buffer[0..<bytesRead])
        updateBurstDetection()
        session.receive(data)
        if let str = String(bytes: data, encoding: .utf8),
           str.contains("\u{1b}]") {
            parseOscSequences(str)
        }
    }

    /// Burst detection: 5+ reads within 2s = real agent activity.
    /// Skips reads that are echo from typing or redraw from resize.
    private func updateBurstDetection() {
        let now = Date()
        if shouldSuppressAgentAttention(now: now) {
            lastBurstTime = nil
            resetBurstWindow(now: now)
            return
        }
        if let suppressedUntil = burstDetectionSuppressedUntil {
            if now < suppressedUntil {
                resetBurstWindow(now: now)
                return
            }
            burstDetectionSuppressedUntil = nil
        }
        let isEcho = lastInteractionTime != nil
            && now.timeIntervalSince(lastInteractionTime!) < Self.writeEchoSuppressionInterval
        guard !isEcho else { return }
        if now.timeIntervalSince(windowStart) > 2.0 {
            windowStart = now
            readCountInWindow = 1
        } else {
            readCountInWindow += 1
            if readCountInWindow >= 5 { lastBurstTime = now }
        }
    }

    /// Parse OSC sequences from terminal output (cwd, title, notifications).
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
        // OSC 9 (notification): Claude Code emits this when a turn completes
        if str.contains("\u{1b}]9;") {
            let now = Date()
            lastOsc9Timestamp = now
            lastBurstTime = nil
            guard !shouldSuppressAgentAttention(now: now) else { return }
            if let callback = onOsc9Received {
                DispatchQueue.main.async { callback() }
            }
        }
    }
}
