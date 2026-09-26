import Foundation

/// TCP ports with a LISTEN socket in one of the user's own processes, read
/// through libproc like `lsof` does. No connection is ever made, so dev
/// servers don't log anything, and the check stays free of side effects
/// even when it repeats every few seconds. Servers run by another user
/// (`sudo`, root-owned helpers) aren't visible. About 2 ms for ~750
/// processes; blocking — call it off the main thread.
enum LocalListeners {
    /// Who holds a listening socket, relative to this app.
    enum Owner: Hashable {
        /// Docker, another terminal app, a daemonized server…
        case outsideNirux
        /// A process in the Nirux terminal whose shell is `shell`.
        case terminal(shell: pid_t)
        /// Nirux itself.
        case nirux
    }

    /// Listening ports and who holds them. Workspaces scan on their own
    /// timers and share a result younger than `maxAge`, unless it predates
    /// `notBefore` (a detection the scan must postdate). Uptime seconds.
    static func listeners(
        maxAge: TimeInterval = 0.9,
        notBefore: TimeInterval = -.infinity
    ) -> [Int: Set<Owner>] {
        cache.value(maxAge: maxAge, notBefore: notBefore) {
            let uid = getuid()
            let niruxPID = getpid()
            var listeners: [Int: Set<Owner>] = [:]
            for pid in allPIDs() where pid > 0 && bsdInfo(of: pid)?.pbsi_uid == uid {
                let pidPorts = listeningPorts(of: pid)
                guard !pidPorts.isEmpty, !isSystemService(pid) else { continue }
                let owner = owner(ofListener: pid, niruxPID: niruxPID) { bsdInfo(of: $0).map { pid_t($0.pbsi_ppid) } }
                for port in pidPorts { listeners[port, default: []].insert(owner) }
            }
            return listeners
        }
    }

    /// Ports worth proposing to the workspace whose terminal shells are
    /// `ownShells`: a port held only from *another* workspace's terminals
    /// belongs to that workspace (its Vite on :5173 isn't this one's, even
    /// if Claude here mentions the URL). Servers outside Nirux — Docker,
    /// other terminal apps — count everywhere.
    static func ports(_ listeners: [Int: Set<Owner>], ownShells: Set<pid_t>) -> Set<Int> {
        Set(listeners.compactMap { port, owners in
            owners.contains { owner in
                switch owner {
                case .outsideNirux: true
                case .terminal(let shell): ownShells.contains(shell)
                case .nirux: false
                }
            } ? port : nil
        })
    }

    /// Every terminal shell is a child of this process, so walking up from
    /// a listener finds its terminal — or leaves the app entirely.
    static func owner(ofListener pid: pid_t, niruxPID: pid_t, parentOf: (pid_t) -> pid_t?) -> Owner {
        guard pid != niruxPID else { return .nirux }
        var current = pid
        for _ in 0..<64 {
            guard let parent = parentOf(current), parent > 1 else { return .outsideNirux }
            if parent == niruxPID { return .terminal(shell: current) }
            current = parent
        }
        return .outsideNirux
    }

    /// macOS services that listen on dev-looking ports — AirPlay Receiver
    /// (ControlCenter) holds :5000 and :7000 — are never dev servers. Only
    /// daemon locations are excluded: the system Ruby under
    /// /System/Library/Frameworks can still serve a Jekyll site.
    static func isSystemExecutable(_ path: String) -> Bool {
        systemPrefixes.contains { path.hasPrefix($0) }
    }

    private static let systemPrefixes = [
        "/System/Library/CoreServices/",
        "/System/Library/PrivateFrameworks/",
        "/usr/libexec/",
        "/usr/sbin/"
    ]

    private static let cache = ScanCache()

    private final class ScanCache: @unchecked Sendable {
        private let lock = NSLock()
        private var scannedAt: TimeInterval = -.infinity
        private var result: [Int: Set<Owner>] = [:]

        func value(
            maxAge: TimeInterval,
            notBefore: TimeInterval,
            scan: () -> [Int: Set<Owner>]
        ) -> [Int: Set<Owner>] {
            lock.lock()
            defer { lock.unlock() }
            let now = ProcessInfo.processInfo.systemUptime
            if now - scannedAt >= maxAge || scannedAt < notBefore {
                result = scan()
                scannedAt = now
            }
            return result
        }
    }

    private static func allPIDs() -> [pid_t] {
        let estimate = proc_listallpids(nil, 0)
        guard estimate > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(estimate) + 64)
        let count = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        guard count > 0 else { return [] }
        return Array(pids.prefix(Int(count)))
    }

    private static func bsdInfo(of pid: pid_t) -> proc_bsdshortinfo? {
        var info = proc_bsdshortinfo()
        let size = Int32(MemoryLayout<proc_bsdshortinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDT_SHORTBSDINFO, 0, &info, size) == size else { return nil }
        return info
    }

    private static func listeningPorts(of pid: pid_t) -> Set<Int> {
        let bufferSize = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard bufferSize > 0 else { return [] }
        let stride = MemoryLayout<proc_fdinfo>.stride
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(bufferSize) / stride + 1)
        let filled = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &fds, Int32(fds.count * stride))
        guard filled > 0 else { return [] }
        var ports = Set<Int>()
        let socketInfoSize = Int32(MemoryLayout<socket_fdinfo>.size)
        for fd in fds.prefix(Int(filled) / stride) where fd.proc_fdtype == UInt32(PROX_FDTYPE_SOCKET) {
            var info = socket_fdinfo()
            guard proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDSOCKETINFO, &info, socketInfoSize) == socketInfoSize,
                  info.psi.soi_kind == SOCKINFO_TCP,
                  info.psi.soi_proto.pri_tcp.tcpsi_state == TSI_S_LISTEN
            else { continue }
            // insi_lport holds the port in network byte order.
            let port = UInt16(bigEndian: UInt16(truncatingIfNeeded: info.psi.soi_proto.pri_tcp.tcpsi_ini.insi_lport))
            if port > 0 { ports.insert(Int(port)) }
        }
        return ports
    }

    private static func isSystemService(_ pid: pid_t) -> Bool {
        var path = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        guard proc_pidpath(pid, &path, UInt32(path.count)) > 0 else { return false }
        return path.withUnsafeBufferPointer { buffer in
            buffer.baseAddress.map { isSystemExecutable(String(cString: $0)) } ?? false
        }
    }
}
