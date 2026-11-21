import Foundation

/// The result of a size-limited read of a regular file.
public enum RegularFileRead {
    case missing
    case notARegularFile
    case tooLarge
    /// A regular file whose bytes can't be read (permissions, say).
    case unreadableBytes
    case data(Data)

    public var contents: Data? {
        if case .data(let data) = self { return data }
        return nil
    }

    /// Opened without following a link and without blocking, then checked on
    /// the open file: a FIFO swapped in after a check would block the read.
    public static func read(_ fileURL: URL, maxBytes: Int) -> Self {
        guard maxBytes >= 0 else { return .tooLarge }
        let descriptor = open(fileURL.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else {
            switch errno {
            case ENOENT, ENOTDIR: return .missing
            case ELOOP: return .notARegularFile
            default: return .unreadableBytes
            }
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        var info = stat()
        guard fstat(descriptor, &info) == 0 else { return .unreadableBytes }
        guard info.st_mode & S_IFMT == S_IFREG else { return .notARegularFile }
        guard info.st_size <= maxBytes else { return .tooLarge }
        let data: Data
        do {
            data = try handle.read(upToCount: maxBytes == Int.max ? maxBytes : maxBytes + 1) ?? Data()
        } catch {
            return .unreadableBytes
        }
        return data.count <= maxBytes ? .data(data) : .tooLarge
    }
}
