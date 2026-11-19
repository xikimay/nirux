import Foundation

/// A file of lines that writers append to, and one reader drains by moving
/// it aside, then reading and deleting it (the hook and Mission queues). A
/// writer may have opened the file before the reader moved it, so it locks
/// the file and checks it still bears the queue's name before writing; the
/// reader moves it only under that lock. A line a writer reports written is
/// in the file the reader takes, or in the next one, never in one already
/// read. While a writer stopped mid-write keeps the lock, the others write
/// unlocked and the reader takes the queue after a few seconds: the race
/// is back for those moments only.
enum QueueFile {
    /// Where `append` hands over to a test: the file opened, then locked
    /// and checked.
    enum Step { case opened, checked }

    /// Appends `line` in one `write`: O_APPEND keeps concurrent writers
    /// from interleaving mid-line. Nil once written, else the error number
    /// (EAGAIN for a queue moved aside under it each time it was opened). A
    /// holder stopped mid-write (^Z) mustn't hold every writer up: past a
    /// moment, it writes unlocked, its name still checked.
    static func append(_ line: Data, to url: URL, handOver: (Step) -> Void = { _ in }) -> Int32? {
        for _ in 0..<maxOpens {
            let fd = open(url.path, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, 0o600)
            guard fd >= 0 else { return errno }
            defer { close(fd) }
            handOver(.opened)
            if let error = lock(fd, within: 0.05), error != EWOULDBLOCK { return error }
            // Moved aside since it was opened: the next file takes it.
            guard isNamed(url, fd) else { continue }
            handOver(.checked)
            let written = line.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
            guard written == line.count else { return written < 0 ? errno : EIO }
            return nil
        }
        return EAGAIN
    }

    private static let maxOpens = 10

    /// A reader's drains: one takes the queue from a writer that kept it
    /// through `busyDrainsBeforeTaking` of them in a row (a few seconds),
    /// and logs it.
    struct Reader {
        let name: String
        private var busyDrains = 0

        init(name: String) { self.name = name }

        mutating func takeAside(_ url: URL, to aside: URL) -> Taking {
            let forcing = busyDrains >= QueueFile.busyDrainsBeforeTaking
            let taking = QueueFile.takeAside(url, to: aside, force: forcing)
            if taking == .taken, forcing {
                NSLog("[%@] a writer kept the queue through %d drains: taken without its lock", name, busyDrains)
            }
            busyDrains = taking == .busy ? busyDrains + 1 : 0
            return taking
        }
    }

    static let busyDrainsBeforeTaking = 20

    enum Taking: Equatable {
        case taken
        /// No queue to take, or none Nirux may open.
        case absent
        /// A writer holds it: take it again in a moment.
        case busy
    }

    /// Moves the queue at `url` to `aside`, replacing any file there. It
    /// waits out a writer for a few milliseconds: callers drain right
    /// before deciding what to type. `force` takes it from a writer that
    /// kept it.
    private static func takeAside(_ url: URL, to aside: URL, force: Bool) -> Taking {
        let fd = open(url.path, O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else { return .absent }
        defer { close(fd) }
        if let error = lock(fd, within: 0.01), !(force && error == EWOULDBLOCK) {
            return error == EWOULDBLOCK ? .busy : .absent
        }
        guard isNamed(url, fd), rename(url.path, aside.path) == 0 else { return .absent }
        return .taken
    }

    /// Nil once `fd` is locked, else the error number. A holder writes a
    /// line or moves the file in microseconds; past `seconds`, EWOULDBLOCK.
    private static func lock(_ fd: Int32, within seconds: TimeInterval) -> Int32? {
        let deadline = Date().addingTimeInterval(seconds)
        while flock(fd, LOCK_EX | LOCK_NB) != 0 {
            let error = errno
            switch error {
            case EINTR:
                continue
            case EWOULDBLOCK where Date() < deadline:
                usleep(200)
            case ENOTSUP, EOPNOTSUPP:
                // A file system without flock: unlocked, as before.
                return nil
            default:
                return error
            }
        }
        return nil
    }

    private static func isNamed(_ url: URL, _ fd: Int32) -> Bool {
        var held = stat(), named = stat()
        return fstat(fd, &held) == 0 && stat(url.path, &named) == 0
            && held.st_dev == named.st_dev && held.st_ino == named.st_ino
    }
}
