import Foundation

/// A file of lines that writers append to, and one reader drains by moving
/// it aside, then reading and deleting it (the hook and Mission queues). A
/// writer may have opened the file before the reader moved it, so it locks
/// the file and checks it still bears the queue's name before writing; the
/// reader moves it only under that lock. A line a writer reports written is
/// in the file the reader takes, or in the next one, never in one already
/// read.
enum QueueFile {
    /// Appends `line` in one `write`: O_APPEND keeps concurrent writers
    /// from interleaving mid-line. Nil once written, else the error number
    /// (EAGAIN for a queue moved aside under it each time it was opened).
    /// `afterOpen` runs each time the file is opened, before the lock: where
    /// a test drains the queue.
    static func append(_ line: Data, to url: URL, afterOpen: () -> Void = {}) -> Int32? {
        for _ in 0..<maxOpens {
            let fd = open(url.path, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, 0o600)
            guard fd >= 0 else { return errno }
            defer { close(fd) }
            afterOpen()
            guard lock(fd, blocking: true) else { return errno }
            // Moved aside since it was opened: the next file takes it.
            guard isNamed(url, fd) else { continue }
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

    /// Moves the queue at `url` to `aside`, replacing any file there.
    static func takeAside(_ url: URL, to aside: URL) -> Taking {
        let fd = open(url.path, O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else { return .absent }
        defer { close(fd) }
        guard lock(fd, blocking: false) else { return errno == EWOULDBLOCK ? .busy : .absent }
        guard isNamed(url, fd), rename(url.path, aside.path) == 0 else { return .absent }
        return .taken
    }

    private static func lock(_ fd: Int32, blocking: Bool) -> Bool {
        while flock(fd, blocking ? LOCK_EX : LOCK_EX | LOCK_NB) != 0 {
            guard errno == EINTR else { return false }
        }
        return true
    }

    private static func isNamed(_ url: URL, _ fd: Int32) -> Bool {
        var held = stat(), named = stat()
        return fstat(fd, &held) == 0 && stat(url.path, &named) == 0
            && held.st_dev == named.st_dev && held.st_ino == named.st_ino
    }
}
