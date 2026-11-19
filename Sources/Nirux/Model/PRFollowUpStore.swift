import Foundation

/// Each pull request's follow-up (`PRFollowUp.Entry`), by URL, in
/// `pr-follow-up.json` in the state directory: its rounds outlive a
/// relaunch and a workspace opened again.
struct PRFollowUpStore: Codable, Equatable {
    var pullRequests: [String: PRFollowUp.Entry] = [:]
    /// By space: when its follow-up was turned on, where a pull request
    /// first seen since starts (`Entry.since`).
    var spacesOnSince: [String: TimeInterval] = [:]
    /// When this build's follow-up first ran: a space that never set the
    /// option counts as turned on then, so an upgrade doesn't sweep in
    /// every task's old feedback.
    var firstLaunchAt: TimeInterval?

    /// Where a space's follow-up starts: when it was turned on, else the
    /// first launch.
    func followedSince(space: String) -> TimeInterval? {
        spacesOnSince[space] ?? firstLaunchAt
    }

    /// Keeps `time` as the first launch, unless one is kept already.
    mutating func noteLaunch(at time: TimeInterval) {
        if firstLaunchAt == nil { firstLaunchAt = time }
    }

    /// An entry nothing changed for this long goes at the next change,
    /// unless it holds a stop: its pull request merged or closed while no
    /// workspace followed it. One read merged or closed goes at once (the
    /// shell's part).
    static let lifetime: TimeInterval = 30 * 24 * 60 * 60

    /// Changes the entry of `url` (a new one follows from `since`, else
    /// `now`), stamped `now` when that changed anything; returns whether
    /// it did, and so whether to save.
    @discardableResult
    mutating func update(
        _ url: String, now: TimeInterval, since: TimeInterval? = nil, _ change: (inout PRFollowUp.Entry) -> Void
    ) -> Bool {
        let before = pullRequests[url]
        var entry = before ?? PRFollowUp.Entry(since: since ?? now)
        change(&entry)
        guard entry != before else { return false }
        entry.updatedAt = now
        pullRequests[url] = entry
        pullRequests = pullRequests.filter { $0.value.stop != nil || now - $0.value.updatedAt < Self.lifetime }
        return true
    }

    static var url: URL { Persistence.stateDirectory.appendingPathComponent("pr-follow-up.json") }

    /// Empty for a missing or unreadable file.
    static func load(from url: URL = url) -> PRFollowUpStore {
        (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(PRFollowUpStore.self, from: $0) } ?? PRFollowUpStore()
    }

    /// 0600: it lists the user's pull requests.
    func save(to url: URL = url) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        do {
            try SpaceDefaultsStore.writePrivately(encoder.encode(self), to: url)
        } catch {
            NiruxDebugLog.log("PRFollowUpStore: could not save \(url.path): \(error)")
        }
    }

    /// One entry another build wrote differently is dropped, not the file:
    /// the others keep their rounds.
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        pullRequests = values.lenient(.pullRequests, [String: LenientValue<PRFollowUp.Entry>]()).compactMapValues(\.value)
        spacesOnSince = values.lenient(.spacesOnSince, [:])
        firstLaunchAt = values.lenient(.firstLaunchAt, nil)
    }

    init() {}
}


/// A value decoded if it can be: one another build wrote differently
/// takes a default rather than failing the whole file.
struct LenientValue<Value: Decodable>: Decodable {
    let value: Value?

    init(from decoder: Decoder) throws {
        value = try? Value(from: decoder)
    }
}

extension KeyedDecodingContainer {
    /// The value at `key`, or `fallback` when it is missing or unreadable.
    func lenient<Value: Decodable>(_ key: Key, _ fallback: Value) -> Value {
        ((try? decodeIfPresent(LenientValue<Value>.self, forKey: key)) ?? nil)?.value ?? fallback
    }
}
