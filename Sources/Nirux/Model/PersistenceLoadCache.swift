import Foundation

/// Content-addressed memo of the last state.json `load()` resolved, so its
/// hot callers (every terminal launch, launch-mode lookups, the heartbeat
/// save) skip JSON decoding while the file is unchanged.
final class PersistenceLoadCache: @unchecked Sendable {
    struct Entry {
        let path: String
        let contents: Data
        let state: PersistedState?
        /// False when `state` came from a recovery copy, not from `contents`.
        let decodedFromContents: Bool
    }

    private let lock = NSLock()
    private var entry: Entry?

    func lookup(path: String, contents: Data) -> Entry? {
        lock.lock()
        defer { lock.unlock() }
        guard let entry, entry.path == path, entry.contents == contents else { return nil }
        return entry
    }

    func store(_ newEntry: Entry) {
        lock.lock()
        entry = newEntry
        lock.unlock()
    }

    func clear() {
        lock.lock()
        entry = nil
        lock.unlock()
    }
}
