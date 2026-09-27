import Foundation

/// Read-only view of the Mission ledger for CLI wait loops. The app replaces
/// `missions.json` atomically on every save, so a changed inode, size, or
/// modification time is the only signal worth decoding the file again.
struct MissionLedgerReader {
    private struct Signature: Equatable {
        let device: dev_t
        let inode: ino_t
        let size: off_t
        let modifiedSeconds: Int
        let modifiedNanoseconds: Int
    }

    let url: URL
    /// Last successfully decoded ledger; empty until a read succeeds.
    private(set) var missions: [Mission] = []
    private var signature: Signature?

    init(url: URL) {
        self.url = url
    }

    /// Decode the ledger again only when the file changed since the last
    /// successful read. Returns true when `missions` was replaced. A failed
    /// read keeps the previous missions and is retried on the next call.
    @discardableResult
    mutating func refresh() -> Bool {
        guard let current = Self.signature(of: url), current != signature,
              let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([Mission].self, from: data)
        else { return false }
        missions = decoded
        signature = current
        return true
    }

    private static func signature(of url: URL) -> Signature? {
        var info = stat()
        guard stat(url.path, &info) == 0 else { return nil }
        return Signature(
            device: info.st_dev,
            inode: info.st_ino,
            size: info.st_size,
            modifiedSeconds: info.st_mtimespec.tv_sec,
            modifiedNanoseconds: info.st_mtimespec.tv_nsec
        )
    }
}
