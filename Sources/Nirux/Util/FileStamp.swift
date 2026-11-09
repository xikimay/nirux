import Darwin
import Foundation

/// What tells a file changed: which file, its size, and when it was last
/// written. Nil when nothing is there.
struct FileStamp: Equatable, Sendable {
    let device: Int64
    let inode: UInt64
    let size: Int64
    let modified: Int64

    init?(_ url: URL) {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return nil }
        device = Int64(info.st_dev)
        inode = UInt64(info.st_ino)
        size = Int64(info.st_size)
        modified = Int64(info.st_mtimespec.tv_sec) * 1_000_000_000 + Int64(info.st_mtimespec.tv_nsec)
    }
}
