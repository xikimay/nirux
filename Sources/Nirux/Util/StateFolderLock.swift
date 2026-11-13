import AppKit

/// One Nirux per state folder. The first Nirux on a folder holds an
/// exclusive lock on `<state folder>/app.lock` for its whole life; another
/// one started on the same folder brings it to the front and quits before
/// reading anything. Two on one folder restored the same workspaces,
/// relaunched the same agent sessions twice, and saved over each other.
/// The lock goes with the process, a crash included, so it never needs
/// clearing; opened close-on-exec, it stays out of the shells Nirux starts.
/// A Nirux on another folder (NIRUX_STATE_DIR), or in another account, has
/// its own.
struct StateFolderLock {
    static let fileName = "app.lock"

    /// The open lock file: the lock lasts while it stays open.
    let descriptor: Int32

    enum Outcome {
        case acquired(StateFolderLock)
        /// Another process holds it: its pid, as it wrote it, if readable.
        case held(by: pid_t?)
        /// The file can't be opened or locked (a read-only folder): Nirux
        /// opens anyway, as before.
        case unavailable(String)
    }

    /// Takes the lock in `folder`, trying again for `wait` seconds while
    /// another process holds it: a Nirux that is quitting, as before
    /// Sparkle's relaunch, lets go when its process ends.
    static func acquire(in folder: URL, wait: TimeInterval = 5, pid: pid_t = getpid()) -> Outcome {
        let path = folder.appendingPathComponent(fileName).path
        let descriptor = open(path, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { return .unavailable("can't open \(path): \(String(cString: strerror(errno)))") }
        let deadline = Date().addingTimeInterval(wait)
        while flock(descriptor, LOCK_EX | LOCK_NB) != 0 {
            let error = errno
            if error == EINTR { continue }
            guard error == EWOULDBLOCK, Date() < deadline else {
                let holder = error == EWOULDBLOCK ? holderPID(descriptor) : nil
                close(descriptor)
                return error == EWOULDBLOCK ? .held(by: holder) : .unavailable("can't lock \(path): \(String(cString: strerror(error)))")
            }
            usleep(100_000)
        }
        // Who holds it, for the next one to bring to the front.
        let text = Data("\(pid)\n".utf8)
        if ftruncate(descriptor, 0) == 0 {
            _ = text.withUnsafeBytes { pwrite(descriptor, $0.baseAddress, text.count, 0) }
        }
        return .acquired(StateFolderLock(descriptor: descriptor))
    }

    /// The pid the holder wrote; nil when unreadable.
    private static func holderPID(_ descriptor: Int32) -> pid_t? {
        var buffer = [UInt8](repeating: 0, count: 32)
        let count = pread(descriptor, &buffer, buffer.count, 0)
        guard count > 0, let text = String(bytes: buffer[0..<count], encoding: .utf8) else { return nil }
        return pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// This launch is a second Nirux on the folder: brings the one holding
    /// the lock to the front, says so on stderr, and quits with status 0.
    @MainActor
    static func yield(to holder: pid_t?) -> Never {
        let running = holder.flatMap { NSRunningApplication(processIdentifier: $0) }
        let shown = running?.activate(options: [.activateAllWindows]) ?? false
        let who = holder.map { "process \($0)" } ?? "another process"
        FileHandle.standardError.write(Data(
            "Nirux: already open on this state folder (\(who))\(shown ? ", brought to the front" : ""). Not opening a second one.\n".utf8
        ))
        exit(EXIT_SUCCESS)
    }

    /// Lets go (tests; the app keeps it until it quits).
    func release() {
        close(descriptor)
    }
}
