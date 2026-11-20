import Foundation

/// A value kept in a file of the state directory, which another Nirux on
/// the same directory may write too: read again when the file changed on
/// disk.
@MainActor
final class FileBackedValue<Value: Equatable> {
    /// Tests point it elsewhere.
    var url: URL {
        didSet { loaded = nil }
    }
    private let read: (URL) -> Value
    private let write: (Value, URL) -> Void
    private var loaded: (value: Value, stamp: Stamp?)?

    init(url: URL, read: @escaping (URL) -> Value, write: @escaping (Value, URL) -> Void) {
        self.url = url
        self.read = read
        self.write = write
    }

    var value: Value {
        let stamp = Self.stamp(of: url)
        if let loaded, loaded.stamp == stamp { return loaded.value }
        let value = read(url)
        loaded = (value, stamp)
        return value
    }

    /// Changes the value as the file has it now, and writes it when the
    /// change changed anything.
    @discardableResult
    func update<Result>(_ change: (inout Value) -> Result) -> Result {
        let before = value
        var after = before
        let result = change(&after)
        guard after != before else { return result }
        write(after, url)
        loaded = (after, Self.stamp(of: url))
        return result
    }

    /// Its writers replace the file (an atomic write, a rename): a new
    /// file number tells two writes within the date's precision apart.
    private struct Stamp: Equatable {
        let modified: Date?
        let fileNumber: Int?
    }

    private static func stamp(of url: URL) -> Stamp? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else { return nil }
        return Stamp(modified: attributes[.modificationDate] as? Date, fileNumber: attributes[.systemFileNumber] as? Int)
    }
}
