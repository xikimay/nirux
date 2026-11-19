import Foundation

/// A file of lines that writers append to, and one reader drains by moving
/// it aside, then reading and deleting it (the hook and Mission queues). A
/// writer may have opened the file before the reader moved it, so it locks
/// the file and checks it still bears the queue's name before writing; the
/// reader moves it only under that lock. A line a writer reports written is
/// in the file the reader takes, or in the next one, never in one already
/// read.
enum QueueFile {
    /// Where `append` hands over to a test: the file opened, then locked
    /// and checked.
    enum Step { case opened, checked }

    /// Appends `line` in one `write`: O_APPEND keeps concurrent writers
    /// from interleaving mid-line. Nil once written, else the error number
    /// (EAGAIN for a queue held too long, or moved aside under it each time
    /// it was opened).
    static func append(_ line: Data, to url: URL, handOver: (Step) -> Void = { _ in }) -> Int32? {
        for _ in 0..<maxOpens {
            let fd = open(url.path, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, 0o600)
            guard fd >= 0 else { return errno }
            defer { close(fd) }
            handOver(.opened)
            if let error = lock(fd, within: 1) { return error }
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

    enum Taking: Equatable {
        case taken
        /// No queue to take, or none Nirux may open.
        case absent
        /// A writer holds it: take it again in a moment.
        case busy
    }

    /// Moves the queue at `url` to `aside`, replacing any file there. It
    /// waits out a writer for a few milliseconds: callers drain right
    /// before deciding what to type.
    static func takeAside(_ url: URL, to aside: URL) -> Taking {
        let fd = open(url.path, O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else { return .absent }
        defer { close(fd) }
        if let error = lock(fd, within: 0.01) { return error == EWOULDBLOCK ? .busy : .absent }
        guard isNamed(url, fd), rename(url.path, aside.path) == 0 else { return .absent }
        return .taken
    }

    /// Nil once `fd` is locked, else the error number. A holder writes a
    /// line or moves the file in microseconds; one stopped meanwhile (^Z)
    /// keeps it until `seconds` passed.
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
