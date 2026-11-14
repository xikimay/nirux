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
    let pid: pid_t

    /// What the holder wrote in the file: its pid, and whether it is
    /// quitting (`markQuitting`).
    struct Holder: Equatable {
        let pid: pid_t
        let isQuitting: Bool
    }

    enum Outcome {
        case acquired(StateFolderLock)
        /// Another process holds it: what it wrote, if readable.
        case held(by: Holder?)
        /// The file can't be opened or locked (a read-only folder): Nirux
        /// opens anyway, as before.
        case unavailable(String)
    }

    /// Takes the lock in `folder`. A holder that runs and isn't quitting is
    /// yielded to at once; one that is quitting (Sparkle relaunches the app
    /// as it goes), or that wrote nothing readable, is waited for, `wait`
    /// seconds at most.
    static func acquire(
        in folder: URL, wait: TimeInterval = 5, pid: pid_t = getpid(), isRunning: (pid_t) -> Bool = processIsRunning
    ) -> Outcome {
        let path = folder.appendingPathComponent(fileName).path
        let descriptor = open(path, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { return .unavailable("can't open \(path): \(String(cString: strerror(errno)))") }
        let deadline = Date().addingTimeInterval(wait)
        while true {
            if flock(descriptor, LOCK_EX | LOCK_NB) == 0 {
                let lock = StateFolderLock(descriptor: descriptor, pid: pid)
                lock.write(quitting: false)
                return .acquired(lock)
            }
            let error = errno
            if error == EINTR { continue }
            guard error == EWOULDBLOCK else {
                close(descriptor)
                return .unavailable("can't lock \(path): \(String(cString: strerror(error)))")
            }
            let holder = readHolder(descriptor)
            if let holder, !holder.isQuitting, isRunning(holder.pid) {
                close(descriptor)
                return .held(by: holder)
            }
            guard Date() < deadline else {
                close(descriptor)
                return .held(by: holder)
            }
            usleep(100_000)
        }
    }

    /// Alive, even if another user's.
    static func processIsRunning(_ pid: pid_t) -> Bool {
        kill(pid, 0) == 0 || errno == EPERM
    }

    /// What the holder wrote. It writes then truncates, so a read finds the
    /// whole line or the previous one, never a mix; only a file just made
    /// is empty, and is read again for a moment.
    private static func readHolder(_ descriptor: Int32) -> Holder? {
        for attempt in 0..<10 {
            var buffer = [UInt8](repeating: 0, count: 64)
            let count = pread(descriptor, &buffer, buffer.count, 0)
            if count > 0, let text = String(bytes: buffer[0..<count], encoding: .utf8) {
                let words = text.split(whereSeparator: \.isWhitespace)
                guard let first = words.first, let pid = pid_t(first) else { return nil }
                return Holder(pid: pid, isQuitting: words.dropFirst().first == "quitting")
            }
            if attempt < 9 { usleep(50_000) }
        }
        return nil
    }

    /// `<pid>` or `<pid> quitting`: written over the old line, then cut to
    /// its length.
    private func write(quitting: Bool) {
        let text = Data("\(pid)\(quitting ? " quitting" : "")\n".utf8)
        let written = text.withUnsafeBytes { pwrite(descriptor, $0.baseAddress, text.count, 0) }
        if written == text.count { ftruncate(descriptor, off_t(text.count)) }
    }

    /// Nirux is quitting: a Nirux opened meanwhile waits for it instead of
    /// bringing it to the front.
    func markQuitting() {
        write(quitting: true)
    }

    /// Lets go (tests; the app keeps it until it quits).
    func release() {
        close(descriptor)
    }

    // MARK: - Yielding

    /// Set on a Nirux that LaunchServices starts while bringing a holder to
    /// the front: should it ever start one rather than activate the one
    /// running, that one doesn't try in turn.
    static let yieldingEnvironmentKey = "NIRUX_YIELDING_TO_HOLDER"

    /// This launch is a second Nirux on the folder: brings the holder to
    /// the front and quits with status 0. When it can't, says why (in an
    /// alert too when LaunchServices started this one, so a Dock click
    /// doesn't just bounce) and quits with status 1.
    @MainActor
    static func yield(to holder: Holder?) -> Never {
        let running = holder.flatMap { NSRunningApplication(processIdentifier: $0.pid) }
        let who = holder.map { "process \($0.pid)" } ?? "another process"
        if let running, !(holder?.isQuitting ?? false), bringToFront(running) {
            FileHandle.standardError.write(Data(
                "Nirux: already open on this state folder (\(who)): brought it to the front. Not opening a second one.\n".utf8
            ))
            exit(EXIT_SUCCESS)
        }
        let state = holder?.isQuitting == true ? "is still quitting" : running == nil ? "can't be found" : "didn't come to the front"
        let kill = holder.map { " (kill \($0.pid))" } ?? ""
        LaunchArguments.refuse(
            standardError: "Nirux: already open on this state folder (\(who)), which \(state). Not opening a second one. "
                + "If it doesn't respond, quit it\(kill), then open Nirux again.\n",
            alertTitle: "Nirux is already open",
            alertText: "Another Nirux (\(who)) has your workspaces open, and it \(state). Nirux doesn't open twice on the "
                + "same workspaces. If it doesn't respond, quit it in Activity Monitor, then open Nirux again.",
            status: EXIT_FAILURE
        )
    }

    /// Asks LaunchServices to open the holder's bundle, which activates the
    /// running app (a process that never became active can't activate
    /// another itself); true once LaunchServices answers with that very
    /// process. A holder without a bundle (a `swift run` build) is only
    /// asked to come forward, and counts as not brought.
    @MainActor
    private static func bringToFront(_ running: NSRunningApplication) -> Bool {
        guard ProcessInfo.processInfo.environment[yieldingEnvironmentKey] == nil, let bundle = running.bundleURL else {
            running.activate(options: [.activateAllWindows])
            return false
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        configuration.createsNewApplicationInstance = false
        configuration.environment = [yieldingEnvironmentKey: "1"]
        let answer = OpenAnswer()
        NSWorkspace.shared.openApplication(at: bundle, configuration: configuration) { app, _ in
            answer.finish(app?.processIdentifier)
        }
        return answer.wait(seconds: 5) == running.processIdentifier
    }
}

/// LaunchServices' answer, which comes on another queue.
private final class OpenAnswer: @unchecked Sendable {
    private let done = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var pid: pid_t?

    func finish(_ pid: pid_t?) {
        lock.withLock { self.pid = pid }
        done.signal()
    }

    func wait(seconds: TimeInterval) -> pid_t? {
        guard done.wait(timeout: .now() + seconds) == .success else { return nil }
        return lock.withLock { pid }
    }
}
