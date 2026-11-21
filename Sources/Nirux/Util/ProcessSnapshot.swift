import Foundation

struct ProcessInstance: Codable, Hashable {
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
        var procs = Self.readProcessTable { buffer, size in
            var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
            return sysctl(&mib, 4, buffer, &size, nil, 0) == 0 ? 0 : errno
        }
        for i in procs.indices {
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

    /// The whole process table. `read` is sysctl(KERN_PROC_ALL) on a
    /// buffer (nil asks for the size) of `size` bytes, returning 0 or an
    /// errno. Processes started between the size query and the read fail
    /// it with ENOMEM — about one scan in 1,500 with a dozen agents at work
    /// — and an empty snapshot shows no foreground process in any column:
    /// ask again, with more room each time. Empty when it still fails.
    static func readProcessTable(
        attempts: Int = 4,
        read: (UnsafeMutableRawPointer?, inout Int) -> Int32
    ) -> [kinfo_proc] {
        let stride = MemoryLayout<kinfo_proc>.stride
        for attempt in 0..<attempts {
            var size = 0
            guard read(nil, &size) == 0, size > 0 else { return [] }
            // The kernel's estimate leaves room for 5 more processes.
            var procs = [kinfo_proc](repeating: kinfo_proc(), count: size / stride + (16 << attempt))
            size = procs.count * stride
            let status = procs.withUnsafeMutableBytes { read($0.baseAddress, &size) }
            if status == 0 {
                procs.removeLast(procs.count - min(procs.count, size / stride))
                return procs
            }
            guard status == ENOMEM else { return [] }
        }
        return []
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

    /// `rootPID` and its descendants, with their names: what its terminal
    /// runs, `limit` of them at most.
    func tree(of rootPID: pid_t, limit: Int = 256) -> [(process: ProcessInstance, name: String)] {
        var pending = [rootPID]
        var found: [(process: ProcessInstance, name: String)] = []
        var next = 0
        while next < pending.count, found.count < limit {
            let pid = pending[next]
            next += 1
            if let instance = instanceMap[pid] { found.append((instance, commMap[pid] ?? "")) }
            pending.append(contentsOf: childrenMap[pid] ?? [])
        }
        return found
    }

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
    /// breadth-first, like `firstDescendantName`. `outsideForegroundJob`
    /// leaves out the job in front of the shell `rootPID` (its process
    /// group, a wrapper's agent child included); a job stopped with ^Z has
    /// a group of its own.
    func descendantArguments(
        of rootPID: pid_t, named names: Set<String>, outsideForegroundJob: Bool = false, limit: Int = 256
    ) -> [[String]] {
        let skipped = outsideForegroundJob
            ? Set(terminalForegroundProcessGroupMap[rootPID].flatMap { processGroupMap[$0] } ?? [])
            : []
        var pending = childrenMap[rootPID] ?? []
        var visited = Set<pid_t>()
        var next = 0
        var found: [[String]] = []
        while next < pending.count, visited.count < limit {
            let pid = pending[next]
            next += 1
            guard visited.insert(pid).inserted else { continue }
            let arguments = capturedArguments.map { $0[pid] ?? [] } ?? Self.arguments(of: pid, maxArgs: 32)
            if !skipped.contains(pid), let name = Self.execName(from: arguments) ?? commMap[pid], names.contains(name) {
                found.append(arguments)
            }
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

    static let runtimeBinaries: Set<String> = [
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
                      CodingAgent(rawValue: scriptName(script)) != nil {
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
        guard let (argc, strings) = argumentArea(of: pid) else { return [] }
        return Array(CStrings(rest: strings).prefix(max(0, min(argc, maxArgs))).prefix { !$0.isEmpty })
    }

    /// The environment `pid` started with, from KERN_PROCARGS2: what it
    /// changed since doesn't show. Empty when it can't be read, as for a
    /// macOS binary read by one that isn't.
    static func environment(of pid: pid_t) -> [String: String] {
        argumentArea(of: pid).map { environment(argc: $0.argc, strings: $0.strings) } ?? [:]
    }

    /// The environment in KERN_PROCARGS2's strings, past `argc` arguments.
    /// Past them, the empty strings an argv overwritten in place (Node's
    /// `process.title`) leaves are skipped.
    static func environment(argc: Int, strings: ArraySlice<UInt8>) -> [String: String] {
        let entries = CStrings(rest: strings).dropFirst(max(0, argc)).drop { $0.isEmpty }.prefix { !$0.isEmpty }
        return Dictionary(entries.compactMap { entry in
            entry.firstIndex(of: "=").map { (String(entry[..<$0]), String(entry[entry.index(after: $0)...])) }
        }, uniquingKeysWith: { first, _ in first })
    }

    /// KERN_PROCARGS2 of `pid`: its argc, and the strings past its exec path,
    /// its arguments then its environment; nil when it can't be read.
    private static func argumentArea(of pid: pid_t) -> (argc: Int, strings: ArraySlice<UInt8>)? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size: Int = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buf = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buf, &size, nil, 0) == 0 else { return nil }
        guard size > MemoryLayout<Int32>.size else { return nil }
        let argc = buf.withUnsafeBufferPointer {
            $0.baseAddress!.withMemoryRebound(to: Int32.self, capacity: 1) { $0.pointee }
        }
        // Skip exec path + null padding
        var i = MemoryLayout<Int32>.size
        while i < size && buf[i] != 0 { i += 1 }
        while i < size && buf[i] == 0 { i += 1 }
        return (Int(argc), buf[i..<size])
    }

    /// The NUL-terminated strings of a byte area, empty ones included, read
    /// as they are asked for.
    private struct CStrings: Sequence, IteratorProtocol {
        var rest: ArraySlice<UInt8>

        mutating func next() -> String? {
            guard let end = rest.firstIndex(of: 0) else { return nil }
            defer { rest = rest[(end + 1)...] }
            return String(decoding: rest[..<end], as: UTF8.self) // swiftlint:disable:this optional_data_string_conversion
        }
    }
}
