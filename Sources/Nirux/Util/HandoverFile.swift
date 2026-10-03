import Darwin
import Foundation

/// Moves a session handover written by an agent (`/tmp/nirux-handover-*`)
/// into a freshly created worktree. The source path arrives in a URL, so it
/// is treated as hostile: only a regular, single-link file owned by the
/// current user, directly inside /tmp, is accepted. `/tmp` is world-writable,
/// so another account could plant a symlink or a hard link there to make
/// Nirux hand one of the user's files to an agent as instructions.
///
/// The content is read through the descriptor that was validated (no
/// check-then-use race on the path) and written to a new file in the
/// worktree; the destination is never opened through a symlink.
enum HandoverFile {
    static let filenamePrefix = "nirux-handover-"
    static let maxBytes = 1_048_576

    enum TransferError: Error, Equatable {
        case notAllowedPath
        case cannotOpen(Int32)
        case notRegularFile
        case notOwnedByUser
        case multipleLinks
        case tooLarge
        case empty
        case readFailed(Int32)
        case writeFailed(Int32)

        /// One sentence for the user-facing "handover ignored" sheet.
        var explanation: String {
            switch self {
            case .notAllowedPath:
                return "Nirux only accepts a handover created directly in /tmp with a name starting with “nirux-handover-”."
            case .cannotOpen(let code):
                if code == ELOOP { return "The handover path is a symbolic link." }
                if code == ENOENT { return "The handover file doesn’t exist." }
                return "The handover file couldn’t be opened (\(String(cString: strerror(code))))."
            case .notRegularFile: return "The handover path is not a regular file."
            case .notOwnedByUser: return "The handover file belongs to another user."
            case .multipleLinks: return "The handover file is a hard link to another file."
            case .tooLarge: return "The handover file is larger than 1 MB."
            case .empty: return "The handover file is empty: the agent didn’t write it."
            case .readFailed(let code), .writeFailed(let code):
                return "Copying the handover failed (\(String(cString: strerror(code))))."
            }
        }
    }

    /// Lexical gate, applied when the URL is parsed: an absolute path whose
    /// parent is /tmp (or /private/tmp) and whose name starts with the
    /// handover prefix. No filesystem access.
    static func isAllowedSourcePath(_ path: String) -> Bool {
        let parent = (path as NSString).deletingLastPathComponent
        let name = (path as NSString).lastPathComponent
        return ["/tmp", "/private/tmp"].contains(parent)
            && name.hasPrefix(filenamePrefix)
            && name.count > filenamePrefix.count
            && !path.hasSuffix("/")
    }

    /// Create an empty handover file for an agent to fill (the in-app
    /// worktree flow). Created here with O_EXCL under an unguessable name, so
    /// another account can't plant a symlink that the agent's write would
    /// follow; the agent then writes into a file the user already owns.
    static func makeEmptySource(agent: String) -> String? {
        let safeAgent = agent.filter { $0.isASCII && ($0.isLetter || $0.isNumber) }
        let path = "/tmp/\(filenamePrefix)\(safeAgent)-\(UUID().uuidString).md"
        let descriptor = open(path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { return nil }
        close(descriptor)
        return path
    }

    /// Move `source` to `destinationDirectory/filename`. On success the
    /// source is removed. On failure the source stays in place, but a stale
    /// entry at the destination may already have been removed.
    static func transfer(
        from source: String,
        toDirectory destinationDirectory: String,
        filename: String
    ) -> Result<Void, TransferError> {
        guard isAllowedSourcePath(source),
              let tmpReal = "/tmp".realPath,
              (source as NSString).deletingLastPathComponent.realPath == tmpReal
        else { return .failure(.notAllowedPath) }

        // O_NOFOLLOW: a symlink as the final component fails with ELOOP.
        // O_NONBLOCK: a FIFO planted under the name can't hang the open.
        let descriptor = open(source, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { return .failure(.cannotOpen(errno)) }
        defer { close(descriptor) }

        var info = stat()
        guard fstat(descriptor, &info) == 0 else { return .failure(.cannotOpen(errno)) }
        guard (info.st_mode & S_IFMT) == S_IFREG else { return .failure(.notRegularFile) }
        guard info.st_uid == getuid() else { return .failure(.notOwnedByUser) }
        guard info.st_nlink == 1 else { return .failure(.multipleLinks) }
        guard info.st_size <= maxBytes else { return .failure(.tooLarge) }

        let content: Data
        switch readAll(descriptor) {
        case .success(let data): content = data
        case .failure(let error): return .failure(error)
        }
        // An empty file (e.g. the in-app flow's pre-created one, never filled)
        // must not count as delivered: the agent would be told to follow it.
        guard !content.isEmpty else { return .failure(.empty) }

        let destination = (destinationDirectory as NSString).appendingPathComponent(filename)
        if case .failure(let error) = writeNew(content, to: destination) {
            return .failure(error)
        }

        // Unlink only the inode that was validated and copied.
        var current = stat()
        if lstat(source, &current) == 0, current.st_dev == info.st_dev, current.st_ino == info.st_ino {
            unlink(source)
        }
        return .success(())
    }

    /// Writes a handover Nirux composed itself (New Task…) to
    /// `directory/filename`, as `transfer` writes a moved one: a new private
    /// file, never written through a symlink.
    static func deliver(_ text: String, toDirectory directory: String, filename: String) -> Result<Void, TransferError> {
        let content = Data(text.utf8)
        guard !content.isEmpty else { return .failure(.empty) }
        guard content.count <= maxBytes else { return .failure(.tooLarge) }
        return writeNew(content, to: (directory as NSString).appendingPathComponent(filename))
    }

    private static func readAll(_ descriptor: Int32) -> Result<Data, TransferError> {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = read(descriptor, &buffer, buffer.count)
            if count == 0 { return .success(data) }
            if count < 0 {
                if errno == EINTR { continue }
                return .failure(.readFailed(errno))
            }
            data.append(buffer, count: count)
            // The file may have grown since fstat.
            if data.count > maxBytes { return .failure(.tooLarge) }
        }
    }

    /// Replace whatever sits at `destination` (a stale handover, or a
    /// symlink committed to the repo) with a new private file. unlink(2)
    /// removes a symlink itself, and O_EXCL|O_NOFOLLOW refuses to create
    /// through one if it reappears in between.
    private static func writeNew(_ content: Data, to destination: String) -> Result<Void, TransferError> {
        if unlink(destination) != 0, errno != ENOENT {
            return .failure(.writeFailed(errno))
        }
        let descriptor = open(destination, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { return .failure(.writeFailed(errno)) }
        defer { close(descriptor) }
        let failure: Int32? = content.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let written = write(descriptor, raw.baseAddress! + offset, raw.count - offset)
                if written < 0 {
                    if errno == EINTR { continue }
                    return errno
                }
                offset += written
            }
            return nil
        }
        if let failure {
            unlink(destination)
            return .failure(.writeFailed(failure))
        }
        return .success(())
    }
}
