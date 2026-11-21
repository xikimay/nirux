import Foundation

/// An element decoded if it can be, skipped if not.
struct Lossy<Value: Decodable>: Decodable {
    let value: Value?

    init(from decoder: Decoder) throws {
        value = try? Value(from: decoder)
    }

    static func array<Key: CodingKey>(_ container: KeyedDecodingContainer<Key>, _ key: Key) -> [Value] {
        ((try? container.decodeIfPresent([Lossy<Value>].self, forKey: key)) ?? []).compactMap(\.value)
    }
}
