import Foundation

extension Data {
    /// memchr(3): Collection's `firstIndex(of:)` walks Data a byte at a time.
    func firstIndex(of byte: UInt8, from start: Index) -> Index? {
        withUnsafeBytes { buffer in
            let offset = start - startIndex
            guard let base = buffer.baseAddress, offset < buffer.count,
                  let found = memchr(base + offset, Int32(byte), buffer.count - offset) else { return nil }
            return startIndex + base.distance(to: UnsafeRawPointer(found))
        }
    }

    /// memmem(3), for the same reason.
    func contains(_ other: Data) -> Bool {
        withUnsafeBytes { buffer in
            other.withUnsafeBytes { needle in
                memmem(buffer.baseAddress, buffer.count, needle.baseAddress, needle.count) != nil
            }
        }
    }
}
